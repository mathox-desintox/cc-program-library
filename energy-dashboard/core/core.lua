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

local comms = require("common.comms")
local log   = require("common.log")
local util  = require("common.util")

-- ─── config ──────────────────────────────────────────────────────────────

local BROADCAST_INTERVAL_MS = 1000   -- how often we publish aggregate
local PERSIST_INTERVAL_MS   = 30000  -- disk save cadence
local STALE_MS              = 5000   -- mark a collector stale after this
local STATE_FILE            = "/edash_core.dat"

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

-- ─── state ───────────────────────────────────────────────────────────────

-- collectors[id] = {
--   last_msg = <raw packet>,
--   last_ingest_ms = <ms>,
--   history_1s = ring<{ts, stored}>(60)  → 1 minute raw
--   history_1m = ring<{ts, stored}>(60)  → 1 hour @ 1m avg
--   history_5m = ring<{ts, stored}>(288) → 24 hour @ 5m avg
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

-- ─── disk persistence ────────────────────────────────────────────────────

-- We persist ONLY lifetime counters + per-collector produced/consumed. The
-- in-memory histories are re-populated from live data after restart; a
-- history-gap during downtime is acceptable.

local function save_state()
    local snapshot = {
        lifetime = {
            produced_fe     = lifetime.produced_fe,
            consumed_fe     = lifetime.consumed_fe,
            uptime_prior_ms = lifetime.uptime_prior_ms
                             + (os.epoch("utc") - lifetime.started_at_ms),
        },
        collectors = {},
    }
    for id, entry in pairs(collectors) do
        snapshot.collectors[id] = {
            lifetime_produced_fe = entry.lifetime_produced_fe,
            lifetime_consumed_fe = entry.lifetime_consumed_fe,
        }
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
    -- Per-collector lifetime values seeded into their entries as they first
    -- report in, via get_or_create_entry().
    if snapshot.collectors then
        for id, c in pairs(snapshot.collectors) do
            -- Stash until we create the in-memory entry.
            collectors[id] = {
                _restored_produced = c.lifetime_produced_fe or 0,
                _restored_consumed = c.lifetime_consumed_fe or 0,
            }
        end
    end
end

-- ─── ingest ──────────────────────────────────────────────────────────────

local function get_or_create_entry(id)
    local entry = collectors[id]
    if entry and entry.history_1s then return entry end
    local restored_produced = (entry and entry._restored_produced) or 0
    local restored_consumed = (entry and entry._restored_consumed) or 0
    entry = {
        last_msg = nil,
        last_ingest_ms = 0,
        history_1s = util.ring(60),
        history_1m = util.ring(60),
        history_5m = util.ring(288),
        samples_since_1m_rollup = 0,
        samples_since_5m_rollup = 0,
        lifetime_produced_fe = restored_produced,
        lifetime_consumed_fe = restored_consumed,
    }
    collectors[id] = entry
    log.info("collector " .. id .. " registered")
    return entry
end

local function ingest(msg)
    local entry = get_or_create_entry(msg.src.id)
    local now_ms = os.epoch("utc")
    entry.last_msg = msg
    entry.last_ingest_ms = now_ms

    local stored = msg.payload.stored or 0
    local sample = { ts = msg.ts, stored = stored }

    -- Update lifetime produced/consumed from delta vs previous raw sample.
    local prev = entry.history_1s:at(1)  -- previous newest
    if prev then
        local delta = stored - prev.stored
        if delta > 0 then
            entry.lifetime_produced_fe = entry.lifetime_produced_fe + delta
            lifetime.produced_fe       = lifetime.produced_fe + delta
        elseif delta < 0 then
            entry.lifetime_consumed_fe = entry.lifetime_consumed_fe + (-delta)
            lifetime.consumed_fe       = lifetime.consumed_fe + (-delta)
        end
    end

    -- Push raw sample to 1s ring.
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

-- ─── rate computation ────────────────────────────────────────────────────

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

-- ─── aggregation ─────────────────────────────────────────────────────────

-- Merge all collectors into one network-wide snapshot. Extend this when we
-- want multi-network support (group by payload.networkId).
local function aggregate(now_ms)
    local stored, capacity, cells = 0, 0, 0
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
        network_stored   = stored,
        network_capacity = capacity,
        network_cells    = cells,
        network_online   = online and any_collector,
        network_stale    = (not any_collector) or stale,
        rates            = rates,
        eta_to_full_s    = eta_to_full,
        eta_to_empty_s   = eta_to_empty,
        per_collector    = per_collector,
        lifetime = {
            produced_fe       = lifetime.produced_fe,
            consumed_fe       = lifetime.consumed_fe,
            uptime_current_ms = now_ms - lifetime.started_at_ms,
            uptime_prior_ms   = lifetime.uptime_prior_ms,
        },
    }
end

local function broadcast_aggregate()
    local payload = aggregate(os.epoch("utc"))
    local pkt = comms.packet(comms.KIND.CORE_AGGREGATE, comms.ROLE.CORE, payload)
    rednet.broadcast(pkt, comms.PROTO_DATA)
end

-- ─── main ────────────────────────────────────────────────────────────────

log.init("core", log.LEVEL.INFO, "/edash_core.log")
log.info("starting")

local sides = comms.open_all_modems()
if #sides == 0 then log.error("no modem found") error("attach a modem", 0) end
log.info("opened modems on: " .. table.concat(sides, ", "))

load_state()

parallel.waitForAny(
    -- Ingest loop: listen for collector state packets.
    function()
        while true do
            local _, msg = rednet.receive(comms.PROTO_DATA, 5)
            if msg then
                local ok, reason = comms.valid(msg)
                if ok and msg.kind == comms.KIND.COLLECTOR_STATE and msg.src.role == comms.ROLE.COLLECTOR then
                    ingest(msg)
                elseif not ok then
                    log.debug("dropping invalid packet: " .. tostring(reason))
                end
            end
        end
    end,

    -- Broadcast loop: publish aggregate every BROADCAST_INTERVAL_MS.
    function()
        while true do
            local ok, err = pcall(broadcast_aggregate)
            if not ok then log.warn("broadcast failed: " .. tostring(err)) end
            sleep(BROADCAST_INTERVAL_MS / 1000)
        end
    end,

    -- Persist loop: write state to disk periodically.
    function()
        while true do
            sleep(PERSIST_INTERVAL_MS / 1000)
            local ok, err = pcall(save_state)
            if not ok then log.warn("persist failed: " .. tostring(err)) end
        end
    end
)
