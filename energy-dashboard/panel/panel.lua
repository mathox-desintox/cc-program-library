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

local COMPONENT_VERSION = "0.7.2"

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
-- `min_samples` is the threshold below which we show a "need more data"
-- message instead of a chart.
local HORIZONS = {
    { key = "m1",  label = "1m",  tier = "s1", count = 60,  window_s =        60, min_samples = 5  },
    { key = "m5",  label = "5m",  tier = "s1", count = 300, window_s =     5*60, min_samples = 10 },
    { key = "m15", label = "15m", tier = "m1", count = 15,  window_s =    15*60, min_samples = 3  },
    { key = "h1",  label = "1h",  tier = "m1", count = 60,  window_s =    60*60, min_samples = 5  },
    { key = "h8",  label = "8h",  tier = "m5", count = 96,  window_s =  8*60*60, min_samples = 5  },
    { key = "h24", label = "24h", tier = "m5", count = 288, window_s = 24*60*60, min_samples = 5  },
    { key = "d7",  label = "7d",  tier = "h1", count = 168, window_s = 7*24*60*60,  min_samples = 3 },
    { key = "d30", label = "30d", tier = "h6", count = 120, window_s = 30*24*60*60, min_samples = 3 },
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

-- Take the newest `count` entries from a serialized tier. Returns two
-- parallel arrays (values, timestamps) in oldest->newest order. Core
-- 0.7.2+ ships wall-clock timestamps on every tier; older cores might
-- omit them, in which case we reconstruct from interval_ms as a
-- best-effort fallback (rate math will drift across broadcast jitter
-- / gaps but at least ordering is preserved).
local function tail_series(tier, count)
    if not tier or not tier.values then return {}, {} end
    local src = tier.values
    local n = #src
    if n == 0 then return {}, {} end
    local lo = math.max(1, n - count + 1)

    local values, ts = {}, {}
    for i = lo, n do values[#values + 1] = src[i] end

    if tier.ts then
        for i = lo, n do ts[#ts + 1] = tier.ts[i] end
    else
        local interval = tier.interval_ms or 1000
        local now_ms = os.epoch("utc")
        for i = lo, n do ts[#ts + 1] = now_ms - (n - i) * interval end
    end
    return values, ts
end

-- Bucket a stored-series into `width` equal-duration time buckets
-- covering the newest `window_ms` ms. For each bucket we keep the LAST
-- sample that lands in it. Returns two sparse arrays indexed 1..width
-- (bucket_v[i] / bucket_ts[i] is nil when no sample fell into bucket i).
--
-- The newest bucket (i = width) is the one anchored at the newest
-- sample; older buckets walk backwards from there. This makes the
-- rightmost column of the chart a live view and the leftmost the edge
-- of the requested window.
local function bucket_stored(values, ts, width, window_ms)
    local bucket_v, bucket_ts = {}, {}
    if #values == 0 then return bucket_v, bucket_ts end
    local newest = ts[#ts]
    local bucket_ms = window_ms / width
    for i = 1, #values do
        local age = newest - ts[i]
        local b = width - math.floor(age / bucket_ms)
        if b >= 1 and b <= width then
            -- Keep the LAST sample in each bucket (iteration is oldest->
            -- newest, so a later assignment naturally wins).
            bucket_v[b]  = values[i]
            bucket_ts[b] = ts[i]
        end
    end
    return bucket_v, bucket_ts
end

-- Given per-bucket stored snapshots, produce a per-column rate series.
-- Rate at column b is (stored[b] - stored[prev]) / (ts[b] - ts[prev])
-- where prev is the most recent earlier bucket that had a sample. This
-- naturally stretches rate across holes (downtime) and produces nil for
-- columns that had no sample at all (so the chart renders a gap).
--
-- `min_dt_ms` rejects pairs whose wall-clock separation is suspiciously
-- short compared to the bucket width. Those cases produce wildly
-- inflated rate values because the numerator reflects real change over
-- roughly a bucket's worth of time while the denominator collapses to
-- a fraction of that. Typically seen at cold start when the first two
-- filled buckets have their representative samples near their shared
-- boundary.
local function bucket_to_rates(bucket_v, bucket_ts, width, min_dt_ms)
    local rates = {}
    local prev_v, prev_ts
    for b = 1, width do
        if bucket_v[b] ~= nil then
            if prev_v ~= nil and bucket_ts[b] > prev_ts then
                local dt_ms = bucket_ts[b] - prev_ts
                if not min_dt_ms or dt_ms >= min_dt_ms then
                    rates[b] = (bucket_v[b] - prev_v) / (dt_ms / 1000)
                end
            end
            prev_v, prev_ts = bucket_v[b], bucket_ts[b]
        end
    end
    return rates
end

-- Count non-nil entries in a sparse array of length `width`.
local function sparse_count(arr, width)
    local n = 0
    for i = 1, width do if arr[i] ~= nil then n = n + 1 end end
    return n
end

-- Rate in FE/s across the whole window: prefer endpoint-based (more
-- accurate across any gaps) falling back to the last computed rate.
local function window_rate(values, ts)
    if #values < 2 then return 0 end
    local dt_s = (ts[#ts] - ts[1]) / 1000
    if dt_s <= 0 then return 0 end
    return (values[#values] - values[1]) / dt_s
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

    -- Reserve footer lines; whatever is left between row 8 and the footer
    -- is split between chart and stats.
    local foot_lines = 4           -- fill bar (1) + 2 footer lines
    local stats_lines = 4          -- rate / high / low / vol / ETA rows
    local chart_top = 9
    local chart_bot = h - foot_lines - stats_lines - 1
    if chart_bot < chart_top then chart_bot = chart_top end
    local chart_h = chart_bot - chart_top + 1
    local chart_x, chart_w = 2, w - 2

    -- Bucket the stored series into exactly chart_w time buckets over
    -- the horizon's window, then diff adjacent buckets to get a per-
    -- column rate. Each column represents (window / chart_w) seconds,
    -- which is a stable x-axis: only the newest bucket changes rapidly,
    -- older columns stay put. That fixes the "chart flies by" effect
    -- that came from re-sampling 300 raw rates onto 35 columns.
    local tier = (agg.history or {})[hz.tier]
    local stored_vals, stored_ts = tail_series(tier, hz.count)
    local window_ms = hz.window_s * 1000
    local bucket_v, bucket_ts = bucket_stored(stored_vals, stored_ts, chart_w, window_ms)
    -- Reject rate pairs whose dt is under half a bucket-width: those
    -- are always artefacts of two buckets happening to anchor on samples
    -- close in time, and they're the main source of the garbage
    -- peak+/peak-/vol values that otherwise dwarf real extremes.
    local min_dt_ms           = (window_ms / chart_w) * 0.5
    local rates               = bucket_to_rates(bucket_v, bucket_ts, chart_w, min_dt_ms)

    -- The chart is always drawn: line_chart handles sparse arrays and
    -- just leaves a blank column wherever a bucket has no samples yet.
    -- That covers the "window not fully populated" case naturally -
    -- newest data appears on the right, older (unfilled) slots on the
    -- left stay empty until the history buffer catches up.
    local s = chart.line_chart(mon, chart_x, chart_top, chart_w, chart_h, rates, {
        pos_color  = THEME.charging,
        neg_color  = THEME.draining,
        zero_color = THEME.bar_empty,
        bg         = THEME.bg,
    })

    -- Stats block below the chart.
    local have        = sparse_count(rates, chart_w)
    local need        = hz.min_samples or 2
    local have_enough = have >= need
    local row  = chart_bot + 2
    local col2 = 2 + math.floor(w / 2)

    if s then
        local rate_s  = window_rate(stored_vals, stored_ts)
        local vol_pct = (s.mean ~= 0) and (s.stdev / math.abs(s.mean) * 100) or 0
        gfx.indicator(mon, 2,    row, "rate",  6, util.fmtRate(rate_s, RATE_UNIT), P.label, rate_color(rate_s))
        gfx.indicator(mon, col2, row, "vol",   5, string.format("%.2f%%", vol_pct),  P.label, P.value)
        row = row + 1
        gfx.indicator(mon, 2,    row, "peak+", 6, util.fmtRate(s.max, RATE_UNIT), P.label, P.ok)
        gfx.indicator(mon, col2, row, "peak-", 5, util.fmtRate(s.min, RATE_UNIT), P.label, P.warn)
        row = row + 1
    else
        -- No rate samples at all yet: leave the first two rows empty but
        -- still advance `row` so the partial-data notice below shows up
        -- in the usual ETA slot.
        row = row + 2
    end

    if have_enough then
        local eta_text = "idle"
        if     agg.eta_to_full_s  then eta_text = "to full: "  .. util.fmtDuration(agg.eta_to_full_s)
        elseif agg.eta_to_empty_s then eta_text = "to empty: " .. util.fmtDuration(agg.eta_to_empty_s) end
        gfx.indicator(mon, 2, row, "ETA", 6, eta_text, P.label, P.value)
    else
        -- Partial window: chart's left side is blank until enough buckets
        -- fill in. Flag the calculated values as tentative and show the
        -- progress count in the ETA slot.
        local notice = string.format(
            "peak/vol stats: %d/%d buckets filled (wait for full %s)",
            have, need, hz.label)
        gfx.write(mon, 2, row, notice, P.warn)
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
