-- energy-dashboard/collector/collector.lua
--
-- RTU-style leaf program. Wraps a single flux_accessor_ext peripheral
-- (provided by the appflux-cc-patch server mod) and broadcasts its
-- readings to whichever core listens on PROTO_DATA.
--
-- The terminal shows a live status canvas (title bar, health indicators,
-- counters, latest reading). Log lines go to file only (log.lua silenced
-- for terminal output).

local comms     = require("common.comms")
local log       = require("common.log")
local ppm       = require("common.ppm")
local configlib = require("common.config")
local status    = require("common.status")

configlib.run_first_run_wizard("collector")

-- --- config --------------------------------------------------------------

local COMPONENT_VERSION = "0.11.0"

local all_cfg = configlib.load_all()
local cfg     = all_cfg.collector or {}
local NETWORK_ID        = all_cfg.network_id or "default"
local TICK_SECONDS      = cfg.tick_seconds or 0.05
local BROADCAST_SECONDS = cfg.broadcast_seconds or 1.0
local RETRY_SECONDS     = 5
local PERIPHERAL_TYPE   = "flux_accessor_ext"
local PREFERRED_PNAME   = cfg.peripheral
local DEBUG_LOGGING     = cfg.debug_logging == true

comms.set_network_id(NETWORK_ID)

-- --- helpers -------------------------------------------------------------

local function find_accessor()
    if PREFERRED_PNAME then
        if ppm.is_live(PREFERRED_PNAME) and peripheral.getType(PREFERRED_PNAME) == PERIPHERAL_TYPE then
            return peripheral.wrap(PREFERRED_PNAME), PREFERRED_PNAME
        end
    end
    return ppm.find_one(PERIPHERAL_TYPE)
end

-- Feature-detect the mod's API level. Three tiers:
--
--   "history" (patch 0.3.0+) : getStoredHistory(ticks) returns the
--      whole window of per-tick samples in a single call. Collector
--      needs exactly ONE peripheral call per broadcast to populate
--      the samples array - no tick-by-tick polling, no CC sleep
--      jitter, no cold-start race. The mod's own server-tick handler
--      guarantees samples at a deterministic 20 Hz.
--
--   "cached"  (patch 0.2.0)  : getCachedEnergy/Capacity/Online do
--      volatile-field reads without mainThread. Collector polls
--      tick-by-tick at sleep(tick_seconds) and builds the batch
--      locally.
--
--   "legacy"  (patch 0.1.0)  : only the mainThread methods. Each
--      read yields for 1 MC tick, capping us at ~8 samples/sec.
local function detect_api_level(accessor_name)
    if not peripheral or not peripheral.getMethods then return "legacy" end
    local methods = peripheral.getMethods(accessor_name) or {}
    local has_history, has_cached = false, false
    for _, m in ipairs(methods) do
        if     m == "getStoredHistory" then has_history = true
        elseif m == "getCachedEnergy"  then has_cached  = true end
    end
    if has_history then return "history" end
    if has_cached  then return "cached"  end
    return "legacy"
end

-- Per-tick stored read. On the cached API this is a ~microsecond
-- volatile-field read; on the legacy API it costs 1 MC tick.
--
-- The cached path also gates on getCachedTick() to avoid a post-
-- restart race: the mod's `cachedStored` field is initialised to 0
-- and the server-tick handler populates it on the FIRST tick after
-- a peripheral instance is created. A CC computer that happens to
-- query in that sub-tick window would otherwise read 0 and push
-- that through the whole pipeline - the network ring ends up with
-- a spurious 0 next to real-stored values, and the panel's bucket
-- math turns the 0->real transition into a rate on the order of
-- the whole network. We skip the tick entirely until the mod
-- reports a non-zero tick number.
local function make_tick_stored(accessor, use_cached)
    if use_cached then
        return function()
            local tok, tnum = ppm.call(accessor, "getCachedTick")
            if not tok or tnum == nil or tnum == 0 then return nil end
            local ok, v = ppm.call(accessor, "getCachedEnergy")
            if not ok then return nil end
            return v
        end
    end
    return function()
        local ok, v = ppm.call(accessor, "getEnergyLong")
        if not ok then return nil end
        return v
    end
end

-- Metadata snapshot read once per broadcast. Matches the cached API
-- fields when available; falls back to the legacy mainThread methods
-- otherwise. The `history` API level shares the cached-API metadata
-- methods since both come from the tick handler's cache.
local function make_snapshot_meta(accessor, api_level)
    local function safe(method)
        local ok, v = ppm.call(accessor, method)
        return ok and v or nil
    end
    if api_level == "history" or api_level == "cached" then
        return function()
            local stored = safe("getCachedEnergy") or 0
            return {
                storedString   = safe("getCachedEnergyString")   or tostring(stored),
                capacity       = safe("getCachedCapacity")       or 0,
                capacityString = safe("getCachedCapacityString") or "0",
                online         = safe("getCachedOnline") == true,
                cellCount      = safe("getNetworkFluxCellCount") or 0,
            }
        end
    end
    return function()
        return {
            storedString   = safe("getEnergyString")       or "0",
            capacity       = safe("getEnergyCapacityLong") or 0,
            capacityString = safe("getEnergyCapacityString") or "0",
            online         = safe("isOnline") == true,
            cellCount      = safe("getNetworkFluxCellCount") or 0,
        }
    end
end

-- On the `history` API level the collector runs on broadcast cadence
-- only: each broadcast cycle fetches the last `n_ticks` ring samples
-- in a SINGLE peripheral call and ships them as the batch. No
-- tick-by-tick polling loop, no sleep(TICK_SECONDS) jitter, and no
-- cold-start race (getStoredHistory returns an empty list until the
-- server-tick handler has written at least one sample).
local function fetch_history_batch(accessor, n_ticks)
    local ok, history = pcall(ppm.call, accessor, "getStoredHistory", n_ticks)
    if not ok or type(history) ~= "table" or #history == 0 then
        return nil
    end
    -- Result from CC-Tweaked Map<String,Object> -> Lua table. We
    -- only need the `stored` and `ts` fields; copy into the shape
    -- the core's ingest loop already understands.
    local batch = {}
    for i = 1, #history do
        local e = history[i]
        if type(e) == "table" and e.stored and e.ts then
            batch[#batch + 1] = { ts = e.ts, stored = e.stored }
        end
    end
    return batch
end

local function broadcast(reading)
    local pkt = comms.packet(comms.KIND.COLLECTOR_STATE, comms.ROLE.COLLECTOR, reading)
    rednet.broadcast(pkt, comms.PROTO_DATA)
end

-- --- status-canvas state -------------------------------------------------

local ui = {
    title        = "collector",
    version      = COMPONENT_VERSION,
    status       = { text = "STARTING", color = colors.cyan },
    right_header = "net: " .. NETWORK_ID,
    groups       = {},
    footer       = "",
    active_tab   = 1,
}
local status_layout = nil

-- Trackers updated by the main loop, rendered into ui.groups by update_ui().
local trackers = {
    modem_sides        = {},
    accessor_name      = nil,
    accessor_live      = false,
    packets_sent       = 0,
    last_send_ms       = 0,
    last_reading       = nil,
    last_batch_size    = 0,   -- sub-second samples shipped in the last batch
    last_batch_skipped = 0,   -- ticks where the peripheral call failed (in same batch)
    total_skipped      = 0,   -- cumulative since startup
    last_event         = "",
}

local function set_status(text, color) ui.status = { text = text, color = color } end
local function mark_event(text)        trackers.last_event = text; ui.footer = text end

local function update_ui()
    local bullet_ok = { "\7", colors.lime }
    local bullet_no = { "\7", colors.red  }
    local bullet_wait = { "\7", colors.yellow }

    local periph_rows = {
        { label = "modem",
          value = #trackers.modem_sides > 0 and table.concat(trackers.modem_sides, ", ") or "(none)",
          bullet = (#trackers.modem_sides > 0 and bullet_ok or bullet_no)[1],
          bullet_color = (#trackers.modem_sides > 0 and bullet_ok or bullet_no)[2] },
    }
    if trackers.accessor_name then
        local b = trackers.accessor_live and bullet_ok or bullet_no
        local accessor_online = trackers.last_reading and trackers.last_reading.online
        periph_rows[#periph_rows + 1] = {
            label = "accessor",
            value = trackers.accessor_name .. (accessor_online == false and " (grid offline)" or ""),
            bullet = b[1], bullet_color = b[2],
        }
    else
        periph_rows[#periph_rows + 1] = {
            label = "accessor", value = "searching...",
            bullet = bullet_wait[1], bullet_color = bullet_wait[2],
        }
    end

    local send_rows = {
        { label = "packets", value = tostring(trackers.packets_sent) },
    }
    if trackers.last_send_ms > 0 then
        local ago_s = (os.epoch("utc") - trackers.last_send_ms) / 1000
        send_rows[#send_rows + 1] = { label = "last send", value = string.format("%.1fs ago", ago_s) }
    else
        send_rows[#send_rows + 1] = { label = "last send", value = "never" }
    end
    send_rows[#send_rows + 1] = { label = "tick",       value = tostring(TICK_SECONDS) .. "s" }
    send_rows[#send_rows + 1] = { label = "flush",      value = tostring(BROADCAST_SECONDS) .. "s" }
    send_rows[#send_rows + 1] = { label = "batch last", value = tostring(trackers.last_batch_size or 0) }
    local skip_bullet = trackers.total_skipped > 0 and bullet_no or bullet_ok
    send_rows[#send_rows + 1] = {
        label = "skipped", bullet = skip_bullet[1], bullet_color = skip_bullet[2],
        value = string.format("%d last / %d total",
            trackers.last_batch_skipped or 0, trackers.total_skipped or 0),
    }

    local reading_rows
    if trackers.last_reading then
        local r = trackers.last_reading
        local fill = (r.capacity and r.capacity > 0) and (r.stored * 100 / r.capacity) or 0
        reading_rows = {
            { label = "stored",   value = r.storedString   .. " FE" },
            { label = "capacity", value = r.capacityString .. " FE" },
            { label = "fill",     value = string.format("%.1f%%", fill) },
            { label = "cells",    value = tostring(r.cellCount) },
        }
    else
        reading_rows = { { label = "stored", value = "(waiting for reading)" } }
    end

    ui.groups = {
        { title = "peripherals",    rows = periph_rows  },
        { title = "broadcast",      rows = send_rows    },
        { title = "latest reading", rows = reading_rows },
    }
end

-- --- main logic ----------------------------------------------------------

log.init("collector", DEBUG_LOGGING and log.LEVEL.DEBUG or log.LEVEL.INFO, "/edash_collector.log")
log.silence_terminal(true)
log.info("collector " .. COMPONENT_VERSION .. " starting")
log.info(string.format("config: tick=%ss flush=%ss network_id=%s peripheral=%s",
    tostring(TICK_SECONDS), tostring(BROADCAST_SECONDS), NETWORK_ID,
    tostring(PREFERRED_PNAME or "auto")))

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

local function main_loop()
    while true do
        local accessor, name = find_accessor()
        if not accessor then
            trackers.accessor_name = nil
            trackers.accessor_live = false
            set_status("WAITING", colors.yellow)
            mark_event("no " .. PERIPHERAL_TYPE .. " peripheral; retrying")
            log.warn("no " .. PERIPHERAL_TYPE .. "; retrying in " .. RETRY_SECONDS .. "s")
            update_ui()
            sleep(RETRY_SECONDS)
        else
            trackers.accessor_name = name
            trackers.accessor_live = true
            set_status("RUNNING", colors.lime)
            mark_event("peripheral wrapped at " .. tostring(name))
            log.info("peripheral wrapped at " .. tostring(name))

            -- Pick API tier. See detect_api_level for what each
            -- means. The "history" tier collapses the entire inner
            -- loop into one peripheral call per broadcast, so we run
            -- a completely different cycle below.
            local api_level = detect_api_level(name)
            local snapshot_meta = make_snapshot_meta(accessor, api_level)
            log.info("read path: " .. api_level)
            mark_event("read path: " .. api_level)

            -- Shared helper to build + broadcast a payload from an
            -- already-assembled `batch` (array of {ts, stored}). Used
            -- by both the history path (batch comes from one call)
            -- and the legacy/cached path (batch accumulated tick by
            -- tick). `skipped` is passed through to the core for
            -- diagnostics.
            local function broadcast_batch(batch, skipped, now_ms)
                local meta_ok, meta = pcall(snapshot_meta)
                if not meta_ok or type(meta) ~= "table" then
                    meta = (trackers.last_reading and {
                        storedString   = trackers.last_reading.storedString,
                        capacity       = trackers.last_reading.capacity,
                        capacityString = trackers.last_reading.capacityString,
                        online         = trackers.last_reading.online,
                        cellCount      = trackers.last_reading.cellCount,
                    }) or {}
                end
                local newest = batch[#batch]
                local payload = {}
                for k, v in pairs(meta) do payload[k] = v end
                payload.stored  = newest.stored
                payload.samples = batch
                payload.skipped = skipped
                broadcast(payload)

                trackers.packets_sent       = trackers.packets_sent + 1
                trackers.last_send_ms       = now_ms
                trackers.last_batch_size    = #batch
                trackers.last_batch_skipped = skipped
                trackers.last_reading       = payload
                if DEBUG_LOGGING then
                    local first = batch[1].stored
                    local last  = newest.stored
                    local dt_ms = newest.ts - batch[1].ts
                    local seen, unique = {}, 0
                    local vmin, vmax = math.huge, -math.huge
                    for _, s in ipairs(batch) do
                        local v = s.stored
                        if not seen[v] then seen[v] = true; unique = unique + 1 end
                        if v < vmin then vmin = v end
                        if v > vmax then vmax = v end
                    end
                    log.debug(string.format(
                        "batch n=%d unique=%d skipped=%d dt_ms=%d "
                        .. "first=%s last=%s min=%s max=%s delta=%s",
                        #batch, unique, skipped, dt_ms,
                        tostring(first), tostring(last),
                        tostring(vmin), tostring(vmax),
                        tostring(last - first)))
                end
            end

            if api_level == "history" then
                -- Broadcast cadence drives the loop directly. Each
                -- iteration: sleep for broadcast_seconds, then fetch
                -- the last (broadcast_seconds * 20 ticks) ring
                -- samples in one call. Empty result means the mod
                -- hasn't populated yet - skip this cycle, try again.
                local ticks_per_broadcast = math.max(1, math.floor(BROADCAST_SECONDS * 20 + 0.5))
                while ppm.is_live(name) do
                    local now_ms = os.epoch("utc")
                    local batch = fetch_history_batch(accessor, ticks_per_broadcast)
                    if batch and #batch > 0 then
                        broadcast_batch(batch, 0, now_ms)
                    elseif DEBUG_LOGGING then
                        log.debug("getStoredHistory returned empty; waiting for cache")
                    end
                    sleep(BROADCAST_SECONDS)
                end
            else
                -- Legacy / cached path: tick-by-tick polling loop.
                -- Builds the batch locally, broadcasts when
                -- broadcast_seconds has elapsed. Subject to CC
                -- sleep() jitter which gives us 19-20 samples per
                -- 1s broadcast even at tick_seconds = 0.05.
                local tick_stored = make_tick_stored(accessor, api_level == "cached")
                local batch = {}
                local skipped_in_batch = 0
                local last_broadcast_ms = os.epoch("utc")
                local broadcast_ms = BROADCAST_SECONDS * 1000

                while ppm.is_live(name) do
                    local ok, stored = pcall(tick_stored)
                    if ok and stored ~= nil then
                        batch[#batch + 1] = { ts = os.epoch("utc"), stored = stored }
                    else
                        skipped_in_batch = skipped_in_batch + 1
                        trackers.total_skipped = (trackers.total_skipped or 0) + 1
                        if not ok then
                            log.warn("tick_stored error: " .. tostring(stored))
                            mark_event("tick read error")
                        elseif DEBUG_LOGGING then
                            log.debug("tick_stored returned nil, skipping this tick")
                        end
                    end

                    local now_ms = os.epoch("utc")
                    if #batch > 0 and (now_ms - last_broadcast_ms) >= broadcast_ms then
                        broadcast_batch(batch, skipped_in_batch, now_ms)
                        batch = {}
                        skipped_in_batch = 0
                        last_broadcast_ms = now_ms
                    end

                    sleep(TICK_SECONDS)
                end
            end
            trackers.accessor_live = false
            set_status("RESCAN", colors.yellow)
            mark_event("peripheral disconnected; rescanning")
            log.warn("peripheral disconnected")
            update_ui()
        end
    end
end

local function render_loop()
    -- update_ui rebuilds ui.groups from `trackers`, which can be heavy
    -- (walks rows, allocates tables). We run it here at render cadence
    -- (2 Hz) instead of in the tick loop where it was previously called
    -- on every sample, which was adding non-trivial overhead to every
    -- iteration and capping the effective sample rate.
    while true do
        update_ui()
        local ok, layout = pcall(status.render, term, ui)
        if ok then status_layout = layout end
        sleep(0.5)
    end
end

-- Clickable tabs + keyboard nav (tab / arrows / 1..9) for the status
-- canvas. Shares `ui` + `status_layout` with render_loop.
local function input_loop()
    while true do
        local ev, p1, p2, p3 = os.pullEvent()
        if ev == "mouse_click" and p1 == 1 and status_layout then
            local idx = status.hit_test_tab(status_layout, p2, p3)
            if idx then
                ui.active_tab = idx
                pcall(status.render, term, ui)
            end
        elseif ev == "key" and status_layout then
            local target = status.key_to_tab(ui.active_tab or 1,
                                             status_layout.group_count or 1, p1)
            if target then
                ui.active_tab = target
                pcall(status.render, term, ui)
            end
        end
    end
end

parallel.waitForAny(main_loop, render_loop, input_loop)
