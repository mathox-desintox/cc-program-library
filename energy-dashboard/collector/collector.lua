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

local COMPONENT_VERSION = "0.6.0"

local all_cfg = configlib.load_all()
local cfg     = all_cfg.collector or {}
local NETWORK_ID      = all_cfg.network_id or "default"
local TICK_SECONDS    = cfg.tick_seconds or 1
local RETRY_SECONDS   = 5
local PERIPHERAL_TYPE = "flux_accessor_ext"
local PREFERRED_PNAME = cfg.peripheral

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

local function snapshot(accessor)
    local function safe(method)
        local ok, v = ppm.call(accessor, method)
        return ok and v or nil
    end
    return {
        stored         = safe("getEnergyLong")         or 0,
        storedString   = safe("getEnergyString")       or "0",
        capacity       = safe("getEnergyCapacityLong") or 0,
        capacityString = safe("getEnergyCapacityString") or "0",
        online         = safe("isOnline") == true,
        cellCount      = safe("getNetworkFluxCellCount") or 0,
    }
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
}

-- Trackers updated by the main loop, rendered into ui.groups by update_ui().
local trackers = {
    modem_sides   = {},
    accessor_name = nil,
    accessor_live = false,
    packets_sent  = 0,
    last_send_ms  = 0,
    last_reading  = nil,
    last_event    = "",
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
    send_rows[#send_rows + 1] = { label = "tick", value = tostring(TICK_SECONDS) .. "s" }

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

log.init("collector", log.LEVEL.INFO, "/edash_collector.log")
log.silence_terminal(true)
log.info("collector " .. COMPONENT_VERSION .. " starting")
log.info(string.format("config: tick=%ds network_id=%s peripheral=%s",
    TICK_SECONDS, NETWORK_ID, tostring(PREFERRED_PNAME or "auto")))

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
            while ppm.is_live(name) do
                local ok, reading = pcall(snapshot, accessor)
                if ok and reading then
                    broadcast(reading)
                    trackers.packets_sent = trackers.packets_sent + 1
                    trackers.last_send_ms = os.epoch("utc")
                    trackers.last_reading = reading
                else
                    log.warn("snapshot error: " .. tostring(reading))
                    mark_event("snapshot error")
                end
                update_ui()
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
    update_ui()
    while true do
        pcall(status.render, term, ui)
        sleep(0.5)
    end
end

parallel.waitForAny(main_loop, render_loop)
