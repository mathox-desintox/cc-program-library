-- energy-dashboard/panel/panel.lua
--
-- Render the core's aggregate state on an advanced monitor. Listens only
-- for CORE_AGGREGATE packets on PROTO_DATA — collectors never talk to the
-- panel directly in the three-tier architecture.
--
-- Run on an advanced computer with a monitor attached and a modem.

local comms     = require("common.comms")
local log       = require("common.log")
local ppm       = require("common.ppm")
local util      = require("common.util")
local gfx       = require("graphics.core")
local themes    = require("graphics.themes")
local configlib = require("common.config")
local status    = require("common.status")

local COMPONENT_VERSION = "0.4.0"

-- First-run wizard: auto-launch `configure` on first boot so the user
-- picks which monitor + rate unit they want before we start drawing.
configlib.run_first_run_wizard("panel")

-- ─── config ──────────────────────────────────────────────────────────────

local all_cfg = configlib.load_all()
local cfg     = all_cfg.panel or {}
local NETWORK_ID        = all_cfg.network_id or "default"
local REDRAW_MS         = cfg.redraw_ms or 250
local STALE_MS          = cfg.stale_ms  or 5000
local RATE_UNIT         = cfg.rate_unit or "t"     -- "t" = FE/tick (MC native), "s" = FE/second
local PREFERRED_MONITOR = cfg.monitor               -- nil = auto-pick first
local THEME_NAME        = cfg.theme or "default"
local THEME             = themes[THEME_NAME] or themes.default
local P                 = themes.pairs(THEME)

-- Stamp outgoing packets (future commands / pings) and drop mismatched
-- incoming aggregates. Isolates multiple dashboards on the same
-- ender-modem channel.
comms.set_network_id(NETWORK_ID)

-- ─── state ───────────────────────────────────────────────────────────────

-- Most recent aggregate received, plus when we received it.
local latest        = nil
local latest_rx_ms  = 0

-- ─── helpers ─────────────────────────────────────────────────────────────

local function status_for(agg, now_ms)
    if not agg then return "NO DATA", P.critical end
    if now_ms - latest_rx_ms >= STALE_MS then return "STALE", P.warn end
    if agg.network_stale then return "STALE", P.warn end
    if not agg.network_online then return "OFFLINE", P.critical end
    return "ONLINE", P.ok
end

local function rate_color(rate_per_s)
    if rate_per_s > 0 then return P.charging end
    if rate_per_s < 0 then return P.draining end
    return P.value
end

-- ─── rendering ───────────────────────────────────────────────────────────

local function render(mon)
    local now_ms = os.epoch("utc")
    local w, h = mon.getSize()
    gfx.clear(mon, THEME.bg)

    -- Title + status
    gfx.write(mon, 2, 1, "FLUX NETWORK", P.title)
    local st_text, st_color = status_for(latest, now_ms)
    gfx.write(mon, w - #st_text, 1, st_text, st_color)

    if not latest then
        gfx.write(mon, 2, 3, "waiting for core aggregate on " .. comms.PROTO_DATA .. "...", P.label)
        return
    end

    local agg  = latest
    local cap  = agg.network_capacity or 0
    local stored = agg.network_stored or 0
    local fill = cap > 0 and (stored * 100 / cap) or 0

    -- Top numbers block
    local label_w = 10
    gfx.indicator(mon, 2, 3, "Stored",    label_w, util.fmtFE(stored),   P.label, P.value)
    gfx.indicator(mon, 2, 4, "Capacity",  label_w, util.fmtFE(cap),      P.label, P.value)
    gfx.indicator(mon, 2, 5, "Fill",      label_w, string.format("%.1f%%", fill), P.label, P.value)

    -- Rates (four key horizons; the future UI will let you pick others)
    local rates = agg.rates or {}
    local row = 7
    gfx.write(mon, 2, row, "Rate", P.accent); row = row + 1
    local function rate_row(r, label, name)
        local rs = rates[name] or 0
        gfx.indicator(mon, 2, r, "  " .. label, label_w, util.fmtRate(rs, RATE_UNIT), P.label, rate_color(rs))
    end
    rate_row(row,     "instant", "instant"); row = row + 1
    rate_row(row,     "5 min",   "m5");      row = row + 1
    rate_row(row,     "1 hr",    "h1");      row = row + 1
    rate_row(row,     "24 hr",   "h24");     row = row + 1

    -- ETA (based on instant rate — matches the "Rate instant" line)
    row = row + 1
    local eta_text = "idle"
    if agg.eta_to_full_s  then eta_text = "to full: "  .. util.fmtDuration(agg.eta_to_full_s)
    elseif agg.eta_to_empty_s then eta_text = "to empty: " .. util.fmtDuration(agg.eta_to_empty_s) end
    gfx.indicator(mon, 2, row, "ETA", label_w, eta_text, P.label, P.value); row = row + 2

    -- Fill bar (full width, one row, with % label below)
    if row < h - 2 then
        local bar_w = w - 2
        gfx.hbar(mon, 2, row, bar_w, fill, THEME.bar_full, THEME.bar_empty)
        gfx.write(mon, 2, row + 1, string.format("%.1f%%", fill), P.value)
    end

    -- Footer: cells + uptime + lifetime produced/consumed
    if h >= 3 then
        local ncollectors = 0
        for _ in pairs(agg.per_collector or {}) do ncollectors = ncollectors + 1 end

        local uptime_s = ((agg.lifetime and agg.lifetime.uptime_current_ms) or 0) / 1000
        local line1 = string.format("cells: %d    collectors: %d    uptime: %s",
            agg.network_cells or 0, ncollectors, util.fmtDuration(uptime_s))
        gfx.write(mon, 2, h - 1, line1, P.label)

        if agg.lifetime then
            local line2 = string.format("lifetime  +%s  -%s",
                util.fmtFE(agg.lifetime.produced_fe or 0),
                util.fmtFE(agg.lifetime.consumed_fe or 0))
            gfx.write(mon, 2, h, line2, P.dim and P.label or P.label)
        end
    end
end

-- ─── terminal status canvas ─────────────────────────────────────────────

local term_ui = {
    title        = "panel",
    version      = COMPONENT_VERSION,
    status       = { text = "STARTING", color = colors.cyan },
    right_header = "net: " .. NETWORK_ID,
    groups       = {},
    footer       = "",
}

local trackers = {
    modem_sides      = {},
    monitor_name     = nil,
    monitor_size     = "?",
    aggregates_rx    = 0,
    packets_dropped  = 0,
    last_event       = "",
}

local function set_status_t(text, color) term_ui.status = { text = text, color = color } end
local function mark_event_t(text)        trackers.last_event = text; term_ui.footer = text end

local function ago(ts_ms)
    if not ts_ms or ts_ms == 0 then return "never" end
    return string.format("%.1fs ago", (os.epoch("utc") - ts_ms) / 1000)
end

local function update_term_ui()
    local bullet_ok   = { "\7", colors.lime   }
    local bullet_wait = { "\7", colors.yellow }
    local bullet_err  = { "\7", colors.red    }

    local net_rows = {
        { label = "modems",     value = #trackers.modem_sides > 0 and table.concat(trackers.modem_sides, ", ") or "(none)",
          bullet = (#trackers.modem_sides > 0 and bullet_ok or bullet_err)[1],
          bullet_color = (#trackers.modem_sides > 0 and bullet_ok or bullet_err)[2] },
        { label = "monitor",    value = tostring(trackers.monitor_name or "?") .. "  " .. trackers.monitor_size,
          bullet = (trackers.monitor_name and bullet_ok or bullet_err)[1],
          bullet_color = (trackers.monitor_name and bullet_ok or bullet_err)[2] },
        { label = "network_id", value = NETWORK_ID },
        { label = "rate unit",  value = "/" .. RATE_UNIT },
    }

    local link_rows
    local now_ms = os.epoch("utc")
    if latest_rx_ms > 0 then
        local fresh = (now_ms - latest_rx_ms) < STALE_MS
        local b = fresh and bullet_ok or bullet_err
        link_rows = {
            { label = "core link",  value = fresh and "healthy" or "STALE", bullet = b[1], bullet_color = b[2] },
            { label = "aggs rx",    value = tostring(trackers.aggregates_rx) },
            { label = "last recv",  value = ago(latest_rx_ms) },
        }
    else
        link_rows = {
            { label = "core link",  value = "waiting for core", bullet = bullet_wait[1], bullet_color = bullet_wait[2] },
            { label = "aggs rx",    value = "0" },
        }
    end

    local tot_rows
    if latest then
        local a = latest
        local fill = (a.network_capacity and a.network_capacity > 0) and (a.network_stored * 100 / a.network_capacity) or 0
        tot_rows = {
            { label = "stored",   value = util.fmtFE(a.network_stored)   },
            { label = "capacity", value = util.fmtFE(a.network_capacity) },
            { label = "fill",     value = string.format("%.1f%%", fill)  },
            { label = "cells",    value = tostring(a.network_cells)      },
        }
    else
        tot_rows = { { label = "(no aggregate yet)", value = "" } }
    end

    term_ui.groups = {
        { title = "network",   rows = net_rows  },
        { title = "core link", rows = link_rows },
        { title = "totals",    rows = tot_rows  },
    }
end

-- ─── main ────────────────────────────────────────────────────────────────

log.init("panel", log.LEVEL.INFO, "/edash_panel.log")
log.silence_terminal(true)
log.info("panel " .. COMPONENT_VERSION .. " starting")

trackers.modem_sides = comms.open_all_modems()
if #trackers.modem_sides == 0 then
    log.error("no modem found")
    set_status_t("NO MODEM", colors.red)
    mark_event_t("no modem attached")
    update_term_ui()
    status.render(term, term_ui)
    sleep(5)
    error("attach a modem", 0)
end

local mon, mon_name
if PREFERRED_MONITOR and peripheral.getType(PREFERRED_MONITOR) == "monitor" then
    mon = peripheral.wrap(PREFERRED_MONITOR)
    mon_name = PREFERRED_MONITOR
else
    if PREFERRED_MONITOR then
        log.warn("configured monitor '" .. PREFERRED_MONITOR .. "' not found; falling back to auto")
    end
    mon, mon_name = ppm.find_one("monitor")
end
if not mon then
    log.error("no monitor found")
    set_status_t("NO MONITOR", colors.red)
    mark_event_t("no monitor attached")
    update_term_ui()
    status.render(term, term_ui)
    sleep(5)
    error("attach an advanced monitor", 0)
end
mon.setTextScale(1)

local mw, mh = mon.getSize()
trackers.monitor_name = mon_name
trackers.monitor_size = string.format("%dx%d", mw, mh)
log.info(string.format("modem=%s monitor=%s (%dx%d) rate=/%s theme=%s",
    trackers.modem_sides[1], tostring(mon_name), mw, mh, RATE_UNIT, THEME_NAME))
mark_event_t("monitor attached: " .. tostring(mon_name) .. " " .. trackers.monitor_size)
set_status_t("RUNNING", colors.lime)

parallel.waitForAny(
    -- receive loop
    function()
        while true do
            local _, msg = rednet.receive(comms.PROTO_DATA, 5)
            if msg then
                local ok = comms.valid(msg)
                if ok and msg.kind == comms.KIND.CORE_AGGREGATE then
                    latest = msg.payload
                    latest_rx_ms = os.epoch("utc")
                    trackers.aggregates_rx = trackers.aggregates_rx + 1
                else
                    trackers.packets_dropped = trackers.packets_dropped + 1
                end
            end
        end
    end,

    -- monitor redraw loop
    function()
        while true do
            pcall(render, mon)
            sleep(REDRAW_MS / 1000)
        end
    end,

    -- terminal status render loop
    function()
        while true do
            update_term_ui()
            pcall(status.render, term, term_ui)
            sleep(0.5)
        end
    end
)
