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

local COMPONENT_VERSION = "0.10.1"

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

-- Feature-detect the cached (non-mainThread) API from appflux-cc-patch
-- 0.2.0+. When present every tick read is a simple cache lookup with
-- no mainThread round-trip, so the collector can sample at the full
-- 20 Hz configured by tick_seconds = 0.05. Falls back to the old
-- mainThread methods on the 0.1.0 mod which caps us at ~8 Hz.
local function detect_cached_api(accessor_name)
    if not peripheral or not peripheral.getMethods then return false end
    local methods = peripheral.getMethods(accessor_name) or {}
    for _, m in ipairs(methods) do
        if m == "getCachedEnergy" then return true end
    end
    return false
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
-- otherwise.
local function make_snapshot_meta(accessor, use_cached)
    local function safe(method)
        local ok, v = ppm.call(accessor, method)
        return ok and v or nil
    end
    if use_cached then
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

            -- Pick fast-path (cached, non-mainThread) vs legacy API.
            -- Cached API needs appflux-cc-patch >= 0.2.0 - when
            -- present, tick reads are instant volatile-field lookups;
            -- otherwise we fall back to the mainThread method and
            -- top out at ~8 samples/sec regardless of tick_seconds.
            local use_cached = detect_cached_api(name)
            local tick_stored   = make_tick_stored(accessor, use_cached)
            local snapshot_meta = make_snapshot_meta(accessor, use_cached)
            log.info("read path: " .. (use_cached and "cached (fast)" or "mainThread (legacy)"))
            mark_event("read path: " .. (use_cached and "cached" or "legacy"))

            -- Sample at TICK_SECONDS, buffer, broadcast at BROADCAST_SECONDS.
            -- The latest stored reading feeds the batch every tick; the
            -- slow-changing metadata (capacity, cellCount, online, ...)
            -- is read ONCE per broadcast window rather than every tick.
            --
            -- Ticks where the peripheral call fails are dropped from the
            -- batch rather than zeroed. Skip counts are surfaced on the
            -- status canvas, shipped in the payload for the core, and
            -- (when debug_logging) logged per flush.
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
                    -- Slow snapshot ONCE per broadcast. If it fails, fall
                    -- back to the previous reading's metadata so we still
                    -- ship a packet instead of silently dropping it.
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
                    payload.skipped = skipped_in_batch
                    broadcast(payload)

                    trackers.packets_sent       = trackers.packets_sent + 1
                    trackers.last_send_ms       = now_ms
                    trackers.last_batch_size    = #batch
                    trackers.last_batch_skipped = skipped_in_batch
                    trackers.last_reading       = payload
                    if DEBUG_LOGGING then
                        local first = batch[1].stored
                        local last  = newest.stored
                        local dt_ms = newest.ts - batch[1].ts
                        -- Count unique stored values + track the min/max in
                        -- the batch. If AppliedFlux only updates its cached
                        -- FE aggregate every N ticks (which AE2's cached
                        -- inventory does NOT guarantee to refresh every
                        -- tick), we'll see n=20 but unique=20/N - a strong
                        -- signal that per-tick sampling is oversampling.
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
                            #batch, unique, skipped_in_batch, dt_ms,
                            tostring(first), tostring(last),
                            tostring(vmin), tostring(vmax),
                            tostring(last - first)))
                    end
                    batch = {}
                    skipped_in_batch = 0
                    last_broadcast_ms = now_ms
                end

                sleep(TICK_SECONDS)
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
