-- energy-dashboard/core/core.lua
--
-- Middle tier of the dashboard. Ingests state updates from one or more
-- collectors, maintains tiered history (1s / 1m / 5m) in ring buffers,
-- computes rates at seven horizons, and rebroadcasts an aggregate to
-- panels / remotes every second. Persists lifetime counters to disk so
-- totals survive restarts.
--
-- Run on any advanced computer with an ender modem. One core per
-- deployment; multiple collectors may feed it.

local comms     = require("common.comms")
local log       = require("common.log")
local util      = require("common.util")
local configlib = require("common.config")
local status    = require("common.status")

local COMPONENT_VERSION = "0.7.9"

-- First-run wizard: auto-launch `configure` on first boot so intervals,
-- state-file path, and log-file path can be adjusted before anything
-- is written to disk.
configlib.run_first_run_wizard("core")

-- --- config --------------------------------------------------------------

local all_cfg = configlib.load_all()
local cfg     = all_cfg.core or {}
local NETWORK_ID            = all_cfg.network_id or "default"
local BROADCAST_INTERVAL_MS = cfg.broadcast_interval_ms or 1000
local PERSIST_INTERVAL_MS   = cfg.persist_interval_ms   or 30000
local STALE_MS              = cfg.stale_ms              or 5000
local STATE_FILE            = cfg.state_file            or "/edash_core.dat"
local LOG_FILE              = cfg.log_file              or "/edash_core.log"
local DEBUG_LOGGING         = cfg.debug_logging == true
-- Flag a per-sample delta as "suspicious" when it moves more than this
-- fraction of the network capacity in a single tick. Tunable via config
-- for grids with unusually spiky workloads.
local ANOMALY_DELTA_PCT     = cfg.anomaly_delta_pct     or 0.5

-- Stamp our team id onto every outgoing packet; drop any incoming with a
-- mismatched id. Isolates multiple dashboards broadcasting on the same
-- ender-modem channel.
comms.set_network_id(NETWORK_ID)

-- Rollup thresholds. A new 1m sample is pushed when we've had this many
-- 1s samples; a 5m sample after this many 1m samples.
local ROLLUP_1M_THRESHOLD = 60
local ROLLUP_5M_THRESHOLD = 5

-- Rate horizons we report, in seconds. Mapped to whichever tier has the
-- best resolution inside that window (see pick_history() below).
local HORIZONS_S = {
    instant = 2,
    m1      = 60,
    m5      = 5 * 60,
    m15     = 15 * 60,
    h1      = 60 * 60,
    h8      = 8 * 60 * 60,
    h24     = 24 * 60 * 60,
}

-- --- state ---------------------------------------------------------------

-- collectors[id] = {
--   last_msg = <raw packet>,
--   last_ingest_ms = <ms>,
--   history_1s = ring<{ts, stored}>(60)  -> 1 minute raw
--   history_1m = ring<{ts, stored}>(60)  -> 1 hour @ 1m avg
--   history_5m = ring<{ts, stored}>(288) -> 24 hour @ 5m avg
--   samples_since_1m_rollup = <n>
--   samples_since_5m_rollup = <n>
--   lifetime_produced_fe = <n>  -- cumulative positive deltas
--   lifetime_consumed_fe = <n>  -- cumulative abs(negative deltas)
-- }
local collectors = {}

-- accumulates between restarts via disk persistence
local lifetime = {
    produced_fe       = 0,
    consumed_fe       = 0,
    started_at_ms     = os.epoch("utc"),
    uptime_prior_ms   = 0,  -- cumulative uptime from earlier runs
}

-- Network-wide rollup rings used to feed the panel's chart. Snapshotted
-- once per broadcast from the aggregated network_stored value, so every
-- panel gets the same series without recomputing per-collector totals.
--
--   s1: 5 min @ 1s      (fine detail for short windows)
--   m1: 1 hour @ 1m
--   m5: 24 h @ 5m
--   h1: 7 days @ 1h
--   h6: 30 days @ 6h
--
-- Longer tiers ship with timestamps so panels can render hole-tolerant
-- charts (server downtime / crashes leave gaps that the panel can show
-- as empty columns instead of compressing the time axis).
local net_history_s1 = util.ring(300)
local net_history_m1 = util.ring(60)
local net_history_m5 = util.ring(288)
local net_history_h1 = util.ring(168)
local net_history_h6 = util.ring(120)
local net_samples_since_1m = 0
local net_samples_since_5m = 0
local net_samples_since_1h = 0
local net_samples_since_6h = 0

-- Runtime counters. Declared up here (instead of alongside the status
-- canvas block near the bottom) so ingest() can bump the skip /
-- anomaly tallies as they happen.
local trackers = {
    modem_sides        = {},
    packets_received   = 0,
    packets_dropped    = 0,   -- invalid / wrong network_id
    aggregates_sent    = 0,
    last_ingest_ms     = 0,
    last_broadcast_ms  = 0,
    last_persist_ms    = 0,
    last_aggregate     = nil, -- the last aggregate payload
    samples_skipped    = 0,   -- ticks the upstream collectors dropped
    sample_anomalies   = 0,   -- per-tick deltas > ANOMALY_DELTA_PCT of capacity
    last_event         = "",
}

-- --- disk persistence ----------------------------------------------------

-- We persist lifetime counters, every network-wide rollup ring + its
-- since-rollup counters, and each collector's per-collector rings +
-- rollup counters + last_tick_stored. On restart the rings hydrate
-- from disk so the panel's long-horizon charts don't reset to empty.
-- A real time gap appears between the last saved sample and the first
-- fresh one; the panel's bucketing handles that naturally (the gap
-- shows as one averaged rate bucket across the downtime).

-- Serialise a ring into a plain { values = {...}, ts = {...} } table
-- (oldest -> newest). Reuses the wire format we already use for the
-- aggregate payload so there's only one ring format in the project.
local function dump_ring(ring)
    local values, ts_arr = {}, {}
    for s in ring:iter() do
        values[#values + 1] = s.stored
        ts_arr[#ts_arr + 1] = s.ts
    end
    return { values = values, ts = ts_arr }
end

-- Push the saved entries back into an empty ring in oldest->newest
-- order. Silently skips malformed entries so a partial / truncated
-- state file still yields a working (if shorter) history.
local function hydrate_ring(ring, saved)
    if type(saved) ~= "table" or type(saved.values) ~= "table" then return end
    local vals, ts_arr = saved.values, saved.ts
    if type(ts_arr) ~= "table" then return end
    for i = 1, #vals do
        if vals[i] ~= nil and ts_arr[i] ~= nil then
            ring:push({ ts = ts_arr[i], stored = vals[i] })
        end
    end
end

local function save_state()
    local now_ms = os.epoch("utc")
    local snapshot = {
        lifetime = {
            produced_fe     = lifetime.produced_fe,
            consumed_fe     = lifetime.consumed_fe,
            uptime_prior_ms = lifetime.uptime_prior_ms
                             + (now_ms - lifetime.started_at_ms),
        },
        net_history = {
            s1 = dump_ring(net_history_s1),
            m1 = dump_ring(net_history_m1),
            m5 = dump_ring(net_history_m5),
            h1 = dump_ring(net_history_h1),
            h6 = dump_ring(net_history_h6),
        },
        net_rollup = {
            since_1m = net_samples_since_1m,
            since_5m = net_samples_since_5m,
            since_1h = net_samples_since_1h,
            since_6h = net_samples_since_6h,
        },
        collectors = {},
    }
    for id, entry in pairs(collectors) do
        local saved = {
            lifetime_produced_fe = entry.lifetime_produced_fe,
            lifetime_consumed_fe = entry.lifetime_consumed_fe,
        }
        if entry.history_1s then
            saved.history_1s              = dump_ring(entry.history_1s)
            saved.history_1m              = dump_ring(entry.history_1m)
            saved.history_5m              = dump_ring(entry.history_5m)
            saved.samples_since_1m_rollup = entry.samples_since_1m_rollup
            saved.samples_since_5m_rollup = entry.samples_since_5m_rollup
            saved.last_tick_stored        = entry.last_tick_stored
        end
        snapshot.collectors[id] = saved
    end
    local f = fs.open(STATE_FILE, "w")
    if not f then log.warn("could not open " .. STATE_FILE .. " for writing") return end
    f.write(textutils.serialise(snapshot))
    f.close()
end

local function load_state()
    if not fs.exists(STATE_FILE) then return end
    local f = fs.open(STATE_FILE, "r")
    if not f then return end
    local data = f.readAll()
    f.close()
    local ok, snapshot = pcall(textutils.unserialise, data)
    if not ok or type(snapshot) ~= "table" then
        log.warn("state file unreadable; starting fresh")
        return
    end
    if snapshot.lifetime then
        lifetime.produced_fe     = snapshot.lifetime.produced_fe or 0
        lifetime.consumed_fe     = snapshot.lifetime.consumed_fe or 0
        lifetime.uptime_prior_ms = snapshot.lifetime.uptime_prior_ms or 0
    end
    if type(snapshot.net_history) == "table" then
        hydrate_ring(net_history_s1, snapshot.net_history.s1)
        hydrate_ring(net_history_m1, snapshot.net_history.m1)
        hydrate_ring(net_history_m5, snapshot.net_history.m5)
        hydrate_ring(net_history_h1, snapshot.net_history.h1)
        hydrate_ring(net_history_h6, snapshot.net_history.h6)
    end
    if type(snapshot.net_rollup) == "table" then
        net_samples_since_1m = snapshot.net_rollup.since_1m or 0
        net_samples_since_5m = snapshot.net_rollup.since_5m or 0
        net_samples_since_1h = snapshot.net_rollup.since_1h or 0
        net_samples_since_6h = snapshot.net_rollup.since_6h or 0
    end
    -- Per-collector values are staged onto a stub entry until the
    -- collector reports back in; get_or_create_entry() promotes the
    -- stub to a full entry and hydrates its rings at that point.
    if snapshot.collectors then
        for id, c in pairs(snapshot.collectors) do
            collectors[id] = {
                _restored_produced     = c.lifetime_produced_fe or 0,
                _restored_consumed     = c.lifetime_consumed_fe or 0,
                _restored_history_1s   = c.history_1s,
                _restored_history_1m   = c.history_1m,
                _restored_history_5m   = c.history_5m,
                _restored_since_1m     = c.samples_since_1m_rollup,
                _restored_since_5m     = c.samples_since_5m_rollup,
                _restored_last_tick    = c.last_tick_stored,
            }
        end
    end
end

-- --- ingest --------------------------------------------------------------

local function get_or_create_entry(id)
    local stub = collectors[id]
    if stub and stub.history_1s then return stub end
    local entry = {
        last_msg = nil,
        last_ingest_ms = 0,
        history_1s = util.ring(60),
        history_1m = util.ring(60),
        history_5m = util.ring(288),
        samples_since_1m_rollup = (stub and stub._restored_since_1m) or 0,
        samples_since_5m_rollup = (stub and stub._restored_since_5m) or 0,
        lifetime_produced_fe    = (stub and stub._restored_produced)  or 0,
        lifetime_consumed_fe    = (stub and stub._restored_consumed)  or 0,
        -- Last-seen per-tick stored value, used for lifetime delta
        -- accounting across batched packets. Starts from the persisted
        -- value if we have one so no energy is double-counted across a
        -- restart, else nil so the very first sample doesn't
        -- synthesise a spurious delta.
        last_tick_stored        = stub and stub._restored_last_tick,
    }
    if stub then
        hydrate_ring(entry.history_1s, stub._restored_history_1s)
        hydrate_ring(entry.history_1m, stub._restored_history_1m)
        hydrate_ring(entry.history_5m, stub._restored_history_5m)
    end
    collectors[id] = entry
    log.info("collector " .. id .. " registered")
    return entry
end

local function ingest(msg)
    local entry = get_or_create_entry(msg.src.id)
    local now_ms = os.epoch("utc")
    entry.last_msg = msg
    entry.last_ingest_ms = now_ms

    -- Collectors 0.7.0+ ship a `samples` array carrying every per-tick
    -- reading taken since the last flush. Older collectors (or the
    -- degenerate case of exactly one sample) still work via the single
    -- top-level `stored` field.
    local samples = msg.payload.samples
    if type(samples) ~= "table" or #samples == 0 then
        samples = { { ts = msg.ts, stored = msg.payload.stored or 0 } }
    end

    -- Track how many ticks the collector SKIPPED (peripheral call failed
    -- on its side) since the last flush. Exposed via trackers so the
    -- core's status canvas can raise a visible warning when upstream
    -- data quality is degrading.
    trackers.samples_skipped = (trackers.samples_skipped or 0)
                             + (msg.payload.skipped or 0)

    -- Lifetime counters track the per-tick delta across every sample in
    -- the batch so no produced/consumed energy is missed when we later
    -- average the batch down into a single ring entry.
    --
    -- While we're at it, flag deltas larger than ANOMALY_DELTA_PCT of
    -- capacity - those typically mean the peripheral returned a bad
    -- value (stored briefly reported as 0 or max_int, then corrected)
    -- and are the main source of chart holes interpreted as huge
    -- negative / positive rates.
    local capacity = msg.payload.capacity or 0
    local anomaly_threshold = capacity * ANOMALY_DELTA_PCT
    local batch_anomalies = 0
    local sum = 0
    for _, s in ipairs(samples) do
        local v = s.stored or 0
        if entry.last_tick_stored ~= nil then
            local delta = v - entry.last_tick_stored
            if capacity > 0 and math.abs(delta) > anomaly_threshold then
                batch_anomalies = batch_anomalies + 1
                trackers.sample_anomalies = (trackers.sample_anomalies or 0) + 1
                if DEBUG_LOGGING then
                    log.debug(string.format(
                        "anomaly collector=%s prev=%.0f curr=%.0f delta=%.0f (%.1f%% of cap)",
                        tostring(msg.src.id), entry.last_tick_stored, v, delta,
                        math.abs(delta) / capacity * 100))
                end
            end
            if delta > 0 then
                entry.lifetime_produced_fe = entry.lifetime_produced_fe + delta
                lifetime.produced_fe       = lifetime.produced_fe + delta
            elseif delta < 0 then
                entry.lifetime_consumed_fe = entry.lifetime_consumed_fe + (-delta)
                lifetime.consumed_fe       = lifetime.consumed_fe + (-delta)
            end
        end
        entry.last_tick_stored = v
        sum = sum + v
    end

    if DEBUG_LOGGING then
        log.debug(string.format(
            "ingest collector=%s batch=%d skipped=%d anomalies=%d first=%.0f last=%.0f",
            tostring(msg.src.id), #samples, msg.payload.skipped or 0, batch_anomalies,
            samples[1].stored or 0, samples[#samples].stored or 0))
    end

    -- Push a single averaged entry to the 1s ring. Timestamp is the
    -- newest sample's ts so downstream rate math uses wall-clock dt.
    local avg       = sum / #samples
    local newest_ts = samples[#samples].ts or msg.ts
    local sample    = { ts = newest_ts, stored = avg }
    entry.history_1s:push(sample)
    entry.samples_since_1m_rollup = entry.samples_since_1m_rollup + 1

    -- Roll up to 1m ring every ROLLUP_1M_THRESHOLD samples.
    if entry.samples_since_1m_rollup >= ROLLUP_1M_THRESHOLD then
        local avg = entry.history_1s:avg(function(s) return s.stored end)
        entry.history_1m:push({ ts = msg.ts, stored = avg })
        entry.samples_since_1m_rollup = 0
        entry.samples_since_5m_rollup = entry.samples_since_5m_rollup + 1
    end

    -- Roll up to 5m ring every ROLLUP_5M_THRESHOLD 1m samples.
    if entry.samples_since_5m_rollup >= ROLLUP_5M_THRESHOLD then
        local sum, count = 0, 0
        for i = 1, math.min(ROLLUP_5M_THRESHOLD, entry.history_1m:len()) do
            local s = entry.history_1m:at(i)
            if s then sum = sum + s.stored; count = count + 1 end
        end
        if count > 0 then
            entry.history_5m:push({ ts = msg.ts, stored = sum / count })
        end
        entry.samples_since_5m_rollup = 0
    end
end

-- --- rate computation ----------------------------------------------------

-- Pick the ring most suitable for a given window_s.
local function pick_history(entry, window_s)
    if window_s <= 60          then return entry.history_1s end
    if window_s <= 60 * 60     then return entry.history_1m end
    return entry.history_5m
end

-- Find the sample closest to (now - window_s), searching a ring.
local function sample_at_age(ring, now_ms, window_ms)
    if ring:len() == 0 then return nil end
    local target = now_ms - window_ms
    local best, best_d
    for i = 1, ring:len() do
        local s = ring:at(i)
        if s then
            local d = math.abs(s.ts - target)
            if not best_d or d < best_d then best = s; best_d = d end
        end
    end
    return best
end

-- FE/s rate over `window_s` seconds. Uses the highest-resolution ring
-- that covers the window, then picks the sample closest to (newest - window).
local function compute_rate(entry, window_s, now_ms)
    local ring = pick_history(entry, window_s)
    local newest = ring:at(1) or entry.history_1s:at(1)
    if not newest then return 0 end
    local past = sample_at_age(ring, now_ms, window_s * 1000)
    if not past or past == newest then return 0 end
    local dt_s = (newest.ts - past.ts) / 1000
    if dt_s <= 0 then return 0 end
    return (newest.stored - past.stored) / dt_s
end

-- --- network history snapshot -------------------------------------------

-- Helper: average the .stored field over the first `n` entries of a ring
-- (newest-first, as per Ring:at semantics).
local function ring_recent_mean(ring, n)
    local sum, count = 0, 0
    for i = 1, math.min(n, ring:len()) do
        local s = ring:at(i)
        if s then sum = sum + s.stored; count = count + 1 end
    end
    if count == 0 then return nil end
    return sum / count
end

local function push_network_sample(stored, now_ms)
    net_history_s1:push({ ts = now_ms, stored = stored })

    net_samples_since_1m = net_samples_since_1m + 1
    if net_samples_since_1m >= 60 then
        local v = ring_recent_mean(net_history_s1, 60)
        if v then net_history_m1:push({ ts = now_ms, stored = v }) end
        net_samples_since_1m = 0
        net_samples_since_5m = net_samples_since_5m + 1
    end

    if net_samples_since_5m >= 5 then
        local v = ring_recent_mean(net_history_m1, 5)
        if v then net_history_m5:push({ ts = now_ms, stored = v }) end
        net_samples_since_5m = 0
        net_samples_since_1h = net_samples_since_1h + 1
    end

    -- 12 × 5m = 1 hour
    if net_samples_since_1h >= 12 then
        local v = ring_recent_mean(net_history_m5, 12)
        if v then net_history_h1:push({ ts = now_ms, stored = v }) end
        net_samples_since_1h = 0
        net_samples_since_6h = net_samples_since_6h + 1
    end

    -- 6 × 1h = 6 hours
    if net_samples_since_6h >= 6 then
        local v = ring_recent_mean(net_history_h1, 6)
        if v then net_history_h6:push({ ts = now_ms, stored = v }) end
        net_samples_since_6h = 0
    end
end

-- Flatten a ring for the wire. `with_ts` ships per-sample timestamps so
-- the panel can render hole-tolerant charts across server restarts; for
-- short-window tiers (s1, m1) we drop them and rely on interval_ms to
-- keep the packet small.
local function serialize_ring(ring, interval_ms, with_ts)
    local values, ts_arr = {}, nil
    if with_ts then ts_arr = {} end
    for s in ring:iter() do
        values[#values + 1] = s.stored
        if with_ts then ts_arr[#ts_arr + 1] = s.ts end
    end
    return { interval_ms = interval_ms, values = values, ts = ts_arr }
end

-- --- aggregation ---------------------------------------------------------

-- Merge all collectors into one network-wide snapshot. Extend this when we
-- want multi-network support (group by payload.networkId).
local function aggregate(now_ms)
    local stored, stored_avg, capacity, cells = 0, 0, 0, 0
    local online, any_collector = true, false
    local stale = true
    local per_collector = {}
    local rates = {}
    for k in pairs(HORIZONS_S) do rates[k] = 0 end

    for id, entry in pairs(collectors) do
        if entry.last_msg then
            any_collector = true
            local p = entry.last_msg.payload
            stored   = stored + (p.stored or 0)
            -- The per-collector history_1s ring stores each batch as ONE
            -- averaged entry (mean of the per-tick samples). Summing those
            -- gives a smoothed network_stored that we use to feed the
            -- rate/chart rings. The single-tick `stored` above is kept
            -- for the "Stored" line on the panel so the user still sees
            -- the snappy current value.
            local latest_avg = entry.history_1s:at(1)
            stored_avg = stored_avg + ((latest_avg and latest_avg.stored) or p.stored or 0)
            capacity = capacity + (p.capacity or 0)
            cells    = cells + (p.cellCount or 0)
            if not p.online then online = false end
            if now_ms - entry.last_ingest_ms < STALE_MS then stale = false end

            for name, window_s in pairs(HORIZONS_S) do
                rates[name] = rates[name] + compute_rate(entry, window_s, now_ms)
            end

            per_collector[id] = {
                online   = p.online,
                stored   = p.stored,
                capacity = p.capacity,
                cells    = p.cellCount,
                stale    = now_ms - entry.last_ingest_ms >= STALE_MS,
                last_ingest_ms = entry.last_ingest_ms,
            }
        end
    end

    local eta_to_full, eta_to_empty
    if rates.instant > 0 then
        eta_to_full = (capacity - stored) / rates.instant
    elseif rates.instant < 0 then
        eta_to_empty = stored / -rates.instant
    end

    return {
        network_stored     = stored,
        network_stored_avg = stored_avg,
        network_capacity   = capacity,
        network_cells      = cells,
        network_online     = online and any_collector,
        network_stale      = (not any_collector) or stale,
        rates              = rates,
        eta_to_full_s      = eta_to_full,
        eta_to_empty_s     = eta_to_empty,
        per_collector      = per_collector,
        lifetime = {
            produced_fe       = lifetime.produced_fe,
            consumed_fe       = lifetime.consumed_fe,
            uptime_current_ms = now_ms - lifetime.started_at_ms,
            uptime_prior_ms   = lifetime.uptime_prior_ms,
        },
    }
end

-- --- status canvas -------------------------------------------------------

local ui = {
    title        = "core",
    version      = COMPONENT_VERSION,
    status       = { text = "STARTING", color = colors.cyan },
    right_header = "net: " .. NETWORK_ID,
    groups       = {},
    footer       = "",
}

local function set_status(text, color) ui.status = { text = text, color = color } end
local function mark_event(text)        trackers.last_event = text; ui.footer = text end

local function ago(ts_ms)
    if not ts_ms or ts_ms == 0 then return "never" end
    return string.format("%.1fs ago", (os.epoch("utc") - ts_ms) / 1000)
end

local function update_ui()
    local bullet_ok   = { "\7", colors.lime   }
    local bullet_wait = { "\7", colors.yellow }
    local bullet_err  = { "\7", colors.red    }

    -- Network group
    local net_rows = {
        { label = "modems",     value = #trackers.modem_sides > 0 and table.concat(trackers.modem_sides, ", ") or "(none)",
          bullet = (#trackers.modem_sides > 0 and bullet_ok or bullet_err)[1],
          bullet_color = (#trackers.modem_sides > 0 and bullet_ok or bullet_err)[2] },
        { label = "network_id", value = NETWORK_ID },
    }

    -- Collectors group
    local col_rows = {}
    -- Only fully-hydrated collectors have ingested at least once; partially
    -- restored stubs (from /edash_core.dat - carrying only lifetime counters
    -- until their computer reports back in) have no last_ingest_ms, so we
    -- skip them here to avoid nil arithmetic and to stop showing stale
    -- entries for collectors that may never come back.
    local collector_ids = {}
    for id, e in pairs(collectors) do
        if e.last_ingest_ms then collector_ids[#collector_ids + 1] = id end
    end
    table.sort(collector_ids)
    if #collector_ids == 0 then
        col_rows[#col_rows + 1] = { label = "(none yet)", value = "", bullet = bullet_wait[1], bullet_color = bullet_wait[2] }
    else
        local now = os.epoch("utc")
        for _, id in ipairs(collector_ids) do
            local e = collectors[id]
            local last = e.last_ingest_ms or 0
            local stale = (last == 0) or (now - last >= STALE_MS)
            local b = stale and bullet_err or bullet_ok
            col_rows[#col_rows + 1] = {
                label = "#" .. tostring(id),
                value = stale and ("stale  " .. ago(last)) or ago(last),
                bullet = b[1], bullet_color = b[2],
            }
        end
    end

    -- Stats group
    local stats_rows = {
        { label = "pkts in",   value = tostring(trackers.packets_received) },
        { label = "aggs out",  value = tostring(trackers.aggregates_sent) },
        { label = "last in",   value = ago(trackers.last_ingest_ms) },
        { label = "last out",  value = ago(trackers.last_broadcast_ms) },
        { label = "last save", value = ago(trackers.last_persist_ms) },
    }
    if trackers.packets_dropped > 0 then
        stats_rows[#stats_rows + 1] = { label = "dropped", value = tostring(trackers.packets_dropped), bullet = bullet_wait[1], bullet_color = bullet_wait[2] }
    end
    if (trackers.samples_skipped or 0) > 0 then
        stats_rows[#stats_rows + 1] = {
            label = "upstream skipped",
            value = tostring(trackers.samples_skipped),
            bullet = bullet_wait[1], bullet_color = bullet_wait[2],
        }
    end
    if (trackers.sample_anomalies or 0) > 0 then
        stats_rows[#stats_rows + 1] = {
            label = "anomalies",
            value = tostring(trackers.sample_anomalies),
            bullet = bullet_err[1], bullet_color = bullet_err[2],
        }
    end
    if DEBUG_LOGGING then
        stats_rows[#stats_rows + 1] = {
            label = "debug", value = "on",
            bullet = bullet_wait[1], bullet_color = bullet_wait[2],
        }
    end

    -- Totals group (from last aggregate we broadcast)
    local tot_rows
    if trackers.last_aggregate then
        local a = trackers.last_aggregate
        local fill = (a.network_capacity and a.network_capacity > 0) and (a.network_stored * 100 / a.network_capacity) or 0
        tot_rows = {
            { label = "stored",   value = util.fmtFE(a.network_stored)   },
            { label = "capacity", value = util.fmtFE(a.network_capacity) },
            { label = "fill",     value = string.format("%.1f%%", fill)  },
            { label = "cells",    value = tostring(a.network_cells)      },
        }
        if a.lifetime then
            tot_rows[#tot_rows + 1] = { label = "+ lifetime", value = util.fmtFE(a.lifetime.produced_fe) }
            tot_rows[#tot_rows + 1] = { label = "- lifetime", value = util.fmtFE(a.lifetime.consumed_fe) }
        end
    else
        tot_rows = { { label = "totals", value = "(no data yet)" } }
    end

    ui.groups = {
        { title = "network",    rows = net_rows   },
        { title = "collectors", rows = col_rows   },
        { title = "stats",      rows = stats_rows },
        { title = "totals",     rows = tot_rows   },
    }
end

local function broadcast_aggregate()
    local now_ms  = os.epoch("utc")
    local payload = aggregate(now_ms)

    -- Snapshot the network totals into rollup rings, then attach tiered
    -- series to the outgoing packet so panels can render charts without
    -- duplicating the history themselves.
    -- Feed the smoothed (batch-averaged) stored into the chart rings;
    -- the snappy single-tick `network_stored` stays on the panel's
    -- "Stored" readout.
    push_network_sample(payload.network_stored_avg or payload.network_stored or 0, now_ms)
    -- Ship wall-clock timestamps on EVERY tier. Reconstructing ts from
    -- interval_ms at the panel silently miscomputes rates whenever
    -- broadcast cadence jitters (sleep drift, server pause, core
    -- restart) because the numerator of the rate reflects real wall
    -- time but the denominator uses the assumed interval.
    payload.history = {
        s1 = serialize_ring(net_history_s1,             1000, true),
        m1 = serialize_ring(net_history_m1,        60 * 1000, true),
        m5 = serialize_ring(net_history_m5,    5 * 60 * 1000, true),
        h1 = serialize_ring(net_history_h1,   60 * 60 * 1000, true),
        h6 = serialize_ring(net_history_h6, 6 * 60 * 60 * 1000, true),
    }

    local pkt = comms.packet(comms.KIND.CORE_AGGREGATE, comms.ROLE.CORE, payload)
    rednet.broadcast(pkt, comms.PROTO_DATA)
    trackers.aggregates_sent    = trackers.aggregates_sent + 1
    trackers.last_broadcast_ms  = now_ms
    trackers.last_aggregate     = payload
end

-- --- main ----------------------------------------------------------------

log.init("core", DEBUG_LOGGING and log.LEVEL.DEBUG or log.LEVEL.INFO, LOG_FILE)
log.silence_terminal(true)
log.info("core " .. COMPONENT_VERSION .. " starting")

trackers.modem_sides = comms.open_all_modems()
if #trackers.modem_sides == 0 then
    log.error("no modem found")
    set_status("NO MODEM", colors.red)
    mark_event("no modem attached")
    update_ui()
    status.render(term, ui)
    sleep(5)
    error("no modem attached", 0)
end
log.info("opened modems on: " .. table.concat(trackers.modem_sides, ", "))
mark_event("modems opened on " .. table.concat(trackers.modem_sides, ", "))

load_state()
set_status("RUNNING", colors.lime)
update_ui()

parallel.waitForAny(
    -- Ingest loop: listen for collector state packets.
    function()
        while true do
            local _, msg = rednet.receive(comms.PROTO_DATA, 5)
            if msg then
                local ok, reason = comms.valid(msg)
                if ok and msg.kind == comms.KIND.COLLECTOR_STATE and msg.src.role == comms.ROLE.COLLECTOR then
                    ingest(msg)
                    trackers.packets_received = trackers.packets_received + 1
                    trackers.last_ingest_ms   = os.epoch("utc")
                elseif not ok then
                    trackers.packets_dropped = trackers.packets_dropped + 1
                    log.debug("dropping invalid packet: " .. tostring(reason))
                end
            end
        end
    end,

    -- Broadcast loop: publish aggregate every BROADCAST_INTERVAL_MS.
    function()
        while true do
            local ok, err = pcall(broadcast_aggregate)
            if not ok then
                log.warn("broadcast failed: " .. tostring(err))
                mark_event("broadcast failed: " .. tostring(err))
            end
            sleep(BROADCAST_INTERVAL_MS / 1000)
        end
    end,

    -- Persist loop: write state to disk periodically.
    function()
        while true do
            sleep(PERSIST_INTERVAL_MS / 1000)
            local ok, err = pcall(save_state)
            if ok then
                trackers.last_persist_ms = os.epoch("utc")
            else
                log.warn("persist failed: " .. tostring(err))
                mark_event("persist failed: " .. tostring(err))
            end
        end
    end,

    -- Status render loop.
    function()
        while true do
            update_ui()
            pcall(status.render, term, ui)
            sleep(0.5)
        end
    end
)
