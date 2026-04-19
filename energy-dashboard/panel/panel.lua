-- energy-dashboard/panel/panel.lua
--
-- Render the core's aggregate state on an advanced monitor. Listens only
-- for CORE_AGGREGATE packets on PROTO_DATA - collectors never talk to the
-- panel directly in the three-tier architecture.
--
-- Run on an advanced computer with a monitor attached and a modem.

local comms     = require("common.comms")
local log       = require("common.log")
local ppm       = require("common.ppm")
local util      = require("common.util")
local gfx       = require("graphics.core")
local chart     = require("graphics.chart")
local themes    = require("graphics.themes")
local configlib = require("common.config")
local status    = require("common.status")

local COMPONENT_VERSION = "0.5.0"

-- First-run wizard: auto-launch `configure` on first boot so the user
-- picks which monitor + rate unit they want before we start drawing.
configlib.run_first_run_wizard("panel")

-- --- config --------------------------------------------------------------

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

-- --- horizons ------------------------------------------------------------

-- Each entry picks a tier from the aggregate's history and how many of
-- its newest samples to keep for the chart + stats. `window_s` is the
-- wall-clock span that window represents; used for rate calculations.
local HORIZONS = {
    { key = "m1",  label = "1m",  tier = "s1", count = 60,  window_s =       60 },
    { key = "m5",  label = "5m",  tier = "s1", count = 300, window_s =    5*60 },
    { key = "m15", label = "15m", tier = "m1", count = 15,  window_s =   15*60 },
    { key = "h1",  label = "1h",  tier = "m1", count = 60,  window_s =   60*60 },
    { key = "h8",  label = "8h",  tier = "m5", count = 96,  window_s = 8*60*60 },
    { key = "h24", label = "24h", tier = "m5", count = 288, window_s =24*60*60 },
}

local function horizon_by_key(k)
    for _, h in ipairs(HORIZONS) do if h.key == k then return h end end
    return HORIZONS[2]  -- default m5
end

-- --- state ---------------------------------------------------------------

-- Most recent aggregate received, plus when we received it.
local latest            = nil
local latest_rx_ms      = 0
local selected_horizon  = cfg.default_horizon or "m5"
-- Layout geometry stashed by render() so the touch handler can hit-test tabs.
local tab_layout        = nil

-- --- helpers -------------------------------------------------------------

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

-- --- rendering -----------------------------------------------------------

-- Take the newest `count` values from a serialized tier (oldest->newest).
local function tail_values(tier, count)
    if not tier or not tier.values then return {} end
    local src = tier.values
    local n = #src
    if n == 0 then return {} end
    if count >= n then return src end
    local out = {}
    local start = n - count + 1
    for i = start, n do out[#out + 1] = src[i] end
    return out
end

-- Rate in FE/s over the horizon: newest minus oldest of the window divided
-- by the elapsed seconds between them. Falls back to sample-count times
-- interval when timestamps are missing.
local function rate_over(tier, count)
    if not tier or not tier.values or #tier.values < 2 then return 0 end
    local vs = tier.values
    local n  = #vs
    local lo = math.max(1, n - count + 1)
    local first, last = vs[lo], vs[n]
    local dt_s
    if tier.ts and tier.ts[lo] and tier.ts[n] then
        dt_s = (tier.ts[n] - tier.ts[lo]) / 1000
    end
    if not dt_s or dt_s <= 0 then
        dt_s = (n - lo) * ((tier.interval_ms or 1000) / 1000)
    end
    if dt_s <= 0 then return 0 end
    return (last - first) / dt_s
end

-- Build a tab strip starting at x,y. Returns {rects, width} so the
-- touch handler can hit-test and the chart knows where to start.
local function draw_tabs(mon, x, y, selected)
    local rects = {}
    local cx = x
    for _, hz in ipairs(HORIZONS) do
        local txt = "[" .. hz.label .. "]"
        local col = (hz.key == selected) and P.accent or P.label
        gfx.write(mon, cx, y, txt, col)
        rects[#rects + 1] = { key = hz.key, x = cx, y = y, w = #txt }
        cx = cx + #txt + 1
    end
    return { rects = rects, end_x = cx }
end

local function render(mon)
    local now_ms = os.epoch("utc")
    local w, h = mon.getSize()
    gfx.clear(mon, THEME.bg)

    -- Row 1: title + status pill.
    gfx.write(mon, 2, 1, "FLUX NETWORK", P.title)
    local st_text, st_color = status_for(latest, now_ms)
    gfx.write(mon, w - #st_text, 1, st_text, st_color)

    if not latest then
        gfx.write(mon, 2, 3, "waiting for core aggregate on " .. comms.PROTO_DATA .. "...", P.label)
        tab_layout = nil
        return
    end

    local agg    = latest
    local cap    = agg.network_capacity or 0
    local stored = agg.network_stored or 0
    local fill   = cap > 0 and (stored * 100 / cap) or 0

    -- Rows 3..5: top totals.
    local label_w = 10
    gfx.indicator(mon, 2, 3, "Stored",    label_w, util.fmtFE(stored),   P.label, P.value)
    gfx.indicator(mon, 2, 4, "Capacity",  label_w, util.fmtFE(cap),      P.label, P.value)
    gfx.indicator(mon, 2, 5, "Fill",      label_w, string.format("%.1f%%", fill), P.label, P.value)

    -- Row 7: horizon tab strip. Clickable on advanced monitors.
    tab_layout = draw_tabs(mon, 2, 7, selected_horizon)
    local hz = horizon_by_key(selected_horizon)

    -- Collect the window values for the selected horizon.
    local tier = (agg.history or {})[hz.tier]
    local values = tail_values(tier, hz.count)

    -- Reserve footer lines; whatever is left between row 8 and the footer
    -- is split between chart and stats.
    local foot_lines = 4           -- fill bar (1) + % (0, inline) + 2 footer lines
    local stats_lines = 4          -- rate / high / low / vol / ETA on up to 4 rows
    local chart_top = 9
    local chart_bot = h - foot_lines - stats_lines - 1
    if chart_bot < chart_top then chart_bot = chart_top end
    local chart_h = chart_bot - chart_top + 1
    local chart_x, chart_w = 2, w - 2

    local s
    if #values >= 2 then
        s = chart.column_chart(mon, chart_x, chart_top, chart_w, chart_h, values, {
            bar_color   = THEME.bar_mid,
            empty_color = THEME.bar_empty,
            bg          = THEME.bg,
        })
    else
        gfx.write(mon, chart_x, chart_top + math.floor(chart_h / 2),
                  "gathering samples (" .. hz.label .. " window)...", P.label)
    end

    -- Stats block below the chart.
    local row = chart_bot + 2
    if s then
        local rate_s   = rate_over(tier, hz.count)
        local vol_pct  = (s.mean ~= 0) and (s.stdev / math.abs(s.mean) * 100) or 0
        local col2     = 2 + math.floor(w / 2)
        gfx.indicator(mon, 2,    row, "rate",  6, util.fmtRate(rate_s, RATE_UNIT), P.label, rate_color(rate_s))
        gfx.indicator(mon, col2, row, "vol",   5, string.format("%.2f%%", vol_pct),  P.label, P.value)
        row = row + 1
        gfx.indicator(mon, 2,    row, "high",  6, util.fmtFE(s.max),                P.label, P.ok)
        gfx.indicator(mon, col2, row, "low",   5, util.fmtFE(s.min),                P.label, P.warn)
        row = row + 1
        local eta_text = "idle"
        if agg.eta_to_full_s       then eta_text = "to full: "  .. util.fmtDuration(agg.eta_to_full_s)
        elseif agg.eta_to_empty_s  then eta_text = "to empty: " .. util.fmtDuration(agg.eta_to_empty_s) end
        gfx.indicator(mon, 2, row, "ETA", 6, eta_text, P.label, P.value)
    end

    -- Fill bar row + % label inline.
    local bar_row = h - 2
    if bar_row >= chart_bot + 2 then
        local bar_w = w - 8
        gfx.hbar(mon, 2, bar_row, bar_w, fill, THEME.bar_full, THEME.bar_empty)
        gfx.write(mon, 2 + bar_w + 1, bar_row, string.format("%.1f%%", fill), P.value)
    end

    -- Footer: cells/collectors/uptime on h-1, lifetime on h.
    local ncollectors = 0
    for _ in pairs(agg.per_collector or {}) do ncollectors = ncollectors + 1 end
    local uptime_s = ((agg.lifetime and agg.lifetime.uptime_current_ms) or 0) / 1000
    local line1 = string.format("cells: %d  collectors: %d  uptime: %s",
        agg.network_cells or 0, ncollectors, util.fmtDuration(uptime_s))
    gfx.write(mon, 2, h - 1, line1, P.label)
    if agg.lifetime then
        local line2 = string.format("lifetime  +%s  -%s",
            util.fmtFE(agg.lifetime.produced_fe or 0),
            util.fmtFE(agg.lifetime.consumed_fe or 0))
        gfx.write(mon, 2, h, line2, P.label)
    end
end

-- --- terminal status canvas ---------------------------------------------

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
        { label = "horizon",    value = selected_horizon },
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

-- --- main ----------------------------------------------------------------

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
    end,

    -- monitor_touch handler: switch horizons when the user taps a tab.
    -- CC emits (event, side, x, y). We filter to our monitor's side.
    function()
        while true do
            local _, side, tx, ty = os.pullEvent("monitor_touch")
            if side == mon_name and tab_layout then
                for _, r in ipairs(tab_layout.rects) do
                    if ty == r.y and tx >= r.x and tx < r.x + r.w then
                        selected_horizon = r.key
                        mark_event_t("horizon: " .. r.key)
                        pcall(render, mon)
                        break
                    end
                end
            end
        end
    end
)
