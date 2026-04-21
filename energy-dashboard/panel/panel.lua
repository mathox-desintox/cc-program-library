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

local COMPONENT_VERSION = "0.8.6"

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
local DEBUG_LOGGING     = cfg.debug_logging == true

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
-- For every pair of adjacent non-nil buckets (b_prev, b_curr) we compute
-- the rate over that span and WRITE IT BACK across every bucket in the
-- inclusive range [b_prev, b_curr]. That way sparse tier data (e.g. the
-- m1 ring pushing a sample every 60s rendered into ~13s sub-buckets for
-- the 15m horizon) still produces a continuous line instead of isolated
-- dots separated by nil gaps. Leading and trailing buckets stay nil
-- when there is no sample before / after them - the chart renders those
-- as blank corners rather than extrapolating.
--
-- `min_dt_ms` rejects pairs whose wall-clock separation is suspiciously
-- short compared to the bucket width. Typically only trips at cold
-- start when the first two filled buckets have their representative
-- samples near their shared boundary.
local function bucket_to_rates(bucket_v, bucket_ts, width, min_dt_ms)
    local rates = {}

    local filled = {}
    for b = 1, width do
        if bucket_v[b] ~= nil then filled[#filled + 1] = b end
    end

    for i = 2, #filled do
        local b_prev, b_curr = filled[i - 1], filled[i]
        local dt_ms = bucket_ts[b_curr] - bucket_ts[b_prev]
        if dt_ms > 0 and (not min_dt_ms or dt_ms >= min_dt_ms) then
            local rate = (bucket_v[b_curr] - bucket_v[b_prev]) / (dt_ms / 1000)
            for fill = b_prev, b_curr do
                rates[fill] = rate
            end
        end
    end
    return rates
end

-- Reject rate values whose magnitude is wildly out of band with the
-- rest of the series. A single bad stored reading upstream (e.g.
-- AppliedFlux returning a spurious value for one tick) lands in the
-- batch average as a dip or spike; the NEXT batch is clean, so the
-- delta between the two batches is enormous and one rate bucket shows
-- orders of magnitude above reality. That briefly flashes peak+/peak-
-- and pushes the chart's y-axis into the stratosphere - and also
-- paints a red (discharge) segment for the dip half of the glitch.
-- Filtering against the median absolute magnitude catches those cases
-- (50x the median = clearly a glitch) without touching reasonable
-- pulsed workloads.
local OUTLIER_MULTIPLE = 50

-- Returns (dropped_count, median, threshold) so callers can surface the
-- filter's activity in debug logs without re-running the math.
local function filter_outlier_rates(rates, width)
    local sorted = {}
    for b = 1, width do
        if rates[b] ~= nil then sorted[#sorted + 1] = math.abs(rates[b]) end
    end
    if #sorted < 3 then return 0 end
    table.sort(sorted)
    local median = sorted[math.ceil(#sorted / 2)]
    if median <= 0 then return 0 end
    local threshold = median * OUTLIER_MULTIPLE
    local dropped = 0
    for b = 1, width do
        if rates[b] ~= nil and math.abs(rates[b]) > threshold then
            rates[b] = nil
            dropped = dropped + 1
        end
    end
    return dropped, median, threshold
end


-- Rate in FE/s across the whole window: prefer endpoint-based (more
-- accurate across any gaps) falling back to the last computed rate.
local function window_rate(values, ts)
    if #values < 2 then return 0 end
    local dt_s = (ts[#ts] - ts[1]) / 1000
    if dt_s <= 0 then return 0 end
    return (values[#values] - values[1]) / dt_s
end

-- "Nice" y-axis ceiling: round `x` up to the next number of the form
-- s * 10^n where s is one of {1, 2, 3, 5, 7}. These are the scale values
-- engineers commonly use for axis ticks - they're short to print (max 1
-- digit) and give predictable step sizes. Using the same ceiling for
-- successive renders makes the axis labels stable across small data
-- fluctuations instead of jittering every tick.
local NICE_STEPS = { 1, 2, 3, 5, 7 }

local function nice_ceil(x)
    if x <= 0 then return 1 end
    local exp = math.floor(math.log(x) / math.log(10))
    local pow = 10 ^ exp
    local mantissa = x / pow
    for _, step in ipairs(NICE_STEPS) do
        if mantissa <= step + 1e-9 then return step * pow end
    end
    return 10 * pow   -- rolls over into the next decade as s=1
end

-- Compact axis label for a rate in FE/s, always positive (sign is
-- conveyed by the chart's colour / position). Reworks util.fmtRate's
-- output so nice-ceiling values never get truncated at axis_w = 9:
-- scales up the SI prefix until the display number is < 1000, then
-- picks the shortest format that captures at least one significant
-- digit. Examples: 200 MFE/s with /t unit -> "10 MFE/t", 5 kFE/s with
-- /t unit -> "250 FE/t", 7 FE/s with /t unit -> "0.35 FE/t".
local function axis_label(rate_s, unit)
    local abs = math.abs(rate_s)
    local suffix = (unit == "t") and "/t" or "/s"
    if abs == 0 then return "0 FE" .. suffix end

    local display = (unit == "t") and (abs / 20) or abs
    local units = { "FE", "kFE", "MFE", "GFE", "TFE", "PFE", "EFE" }
    local i = 1
    while display >= 1000 and i < #units do
        display = display / 1000
        i = i + 1
    end
    if display >= 10 then
        return string.format("%d %s%s", math.floor(display + 0.5), units[i], suffix)
    elseif display >= 1 then
        return string.format("%.1f %s%s", display, units[i], suffix)
    end
    return string.format("%.2f %s%s", display, units[i], suffix)
end

-- Per-horizon cache of the nice-ceiling positive and negative bounds,
-- keeping the chart's y-range stable between renders. We only recompute
-- when the peak either exceeds ~83% of the current ceiling (time to
-- grow) or drops below ~30% of it (time to shrink). Any movement in
-- between reuses the cached value so the axis labels don't flicker on
-- every new sample.
local vmax_cache = {}
local GROW_AT   = 0.83
local SHRINK_AT = 0.30

local function stable_ceiling(current, peak, grow_factor)
    if current == 0 then return nice_ceil(peak * grow_factor) end
    if peak >= current * GROW_AT or peak <= current * SHRINK_AT then
        return nice_ceil(peak * grow_factor)
    end
    return current
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
    -- Chart uses the full row width. Axis labels render on top of the
    -- chart's top and bottom rows as a small overlay so we don't lose
    -- horizontal resolution to a dedicated gutter.
    local chart_x, chart_w = 2, w - 2
    local axis_w = 9

    -- Bucket the stored series into exactly chart_w time buckets over
    -- the horizon's window, then diff adjacent buckets to get a per-
    -- column rate. Each column represents (window / chart_w) seconds,
    -- which is a stable x-axis: only the newest bucket changes rapidly,
    -- older columns stay put. That fixes the "chart flies by" effect
    -- that came from re-sampling 300 raw rates onto 35 columns.
    local tier = (agg.history or {})[hz.tier]
    local stored_vals, stored_ts = tail_series(tier, hz.count)
    local window_ms = hz.window_s * 1000
    -- Bucket at TWICE the cell width so each hires sub-column carries
    -- its own real rate value instead of an interpolation between cells.
    -- The chart's 2x horizontal teletext resolution is only meaningful
    -- when the upstream data has that resolution available.
    local sub_w               = chart_w * 2
    local bucket_v, bucket_ts = bucket_stored(stored_vals, stored_ts, sub_w, window_ms)
    -- Reject rate pairs whose dt is under half a sub-bucket-width:
    -- those are always artefacts of two buckets happening to anchor on
    -- samples close in time, and they're the main source of the
    -- garbage peak+/peak-/vol values that otherwise dwarf real extremes.
    local min_dt_ms           = (window_ms / sub_w) * 0.5
    local rates               = bucket_to_rates(bucket_v, bucket_ts, sub_w, min_dt_ms)
    -- Drop rate outliers BEFORE the cache update / chart render, so a
    -- single bad upstream sample doesn't briefly rescale the y-axis
    -- to a glitched ceiling or flash the peak stats.
    local dropped, med, thr   = filter_outlier_rates(rates, sub_w)
    if DEBUG_LOGGING and dropped > 0 then
        log.debug(string.format(
            "[%s] outlier filter dropped %d rate(s) (median=%.3g threshold=%.3g)",
            hz.key, dropped, med or 0, thr or 0))
    end

    -- Y-axis range via nice-ceiling with hysteresis. The bounds snap to
    -- values of the form s * 10^n (s in {1,2,3,5,7}) so axis labels
    -- stay short + stable across small data fluctuations, while the
    -- 1.2x growth factor places typical data around 70-85% of the
    -- chart height (peaks can still reach the top but the whole
    -- vertical range is useful, not just the top strip).
    --
    -- An opposite-sign peak that's less than MINOR_RATIO of the
    -- dominant peak is treated as a visual clip, NOT a reason to drop
    -- into mixed-sign layout. 0.25 means the chart sticks to a 0-pinned
    -- baseline until the minor side reaches a quarter of the dominant -
    -- a mostly-charging grid with occasional short discharges keeps its
    -- clean baseline, but a genuinely mixed workload still gets the
    -- full top/bottom layout.
    local MINOR_RATIO = 0.25
    -- Growth factors: dominant-sign charts get 20% headroom so the data
    -- sits in the upper 70-85% of the chart with room for spikes; a
    -- mixed-sign chart can't afford that because both sides share the
    -- same vertical space, so the ceiling hugs the peak more tightly.
    local GROW_DOMINANT = 1.2
    local GROW_MIXED    = 1.05
    local rstats = chart.stats_sparse(rates, sub_w) or {}    -- nil when no data
    local vmin, vmax = 0, 1

    local cache = vmax_cache[selected_horizon] or { pos = 0, neg = 0 }
    if rstats.n and rstats.n > 0 then
        local pos_peak = math.max(rstats.max or 0, 0)
        local neg_peak = math.abs(math.min(rstats.min or 0, 0))

        if pos_peak > 0 and neg_peak < pos_peak * MINOR_RATIO then
            -- Dominant positive series: pin bottom at 0, forget any
            -- cached negative ceiling (tiny dips will clip visually).
            cache.pos = stable_ceiling(cache.pos, pos_peak, GROW_DOMINANT)
            cache.neg = 0
        elseif neg_peak > 0 and pos_peak < neg_peak * MINOR_RATIO then
            -- Dominant negative series: pin top at 0.
            cache.pos = 0
            cache.neg = stable_ceiling(cache.neg, neg_peak, GROW_DOMINANT)
        else
            -- Genuinely mixed - show both sides, each side independently
            -- stabilised with a tighter ceiling since the chart has to
            -- fit both halves in the same height.
            cache.pos = pos_peak > 0 and stable_ceiling(cache.pos, pos_peak, GROW_MIXED) or 0
            cache.neg = neg_peak > 0 and stable_ceiling(cache.neg, neg_peak, GROW_MIXED) or 0
        end
        vmax_cache[selected_horizon] = cache

        if cache.pos > 0 and cache.neg > 0 then
            vmin, vmax = -cache.neg, cache.pos
        elseif cache.pos > 0 then
            vmin, vmax = 0, cache.pos
        elseif cache.neg > 0 then
            vmin, vmax = -cache.neg, 0
        end
    end

    -- Chart is always drawn. hires_line_chart uses CC's teletext block
    -- characters to get 2x horizontal and 3x vertical sub-pixel
    -- resolution vs. the old cell-sized line, so flat-ish rate curves
    -- actually show their small variations instead of quantising to
    -- the coarse cell grid.
    local s = chart.hires_line_chart(mon, chart_x, chart_top, chart_w, chart_h, rates, {
        pos_color = THEME.charging,
        neg_color = THEME.draining,
        bg        = THEME.bg,
        ymin      = vmin,
        ymax      = vmax,
    })

    -- Axis labels painted AFTER the chart: the label mask a few cells
    -- of chart at the top-left and bottom-left, which is a worthwhile
    -- trade for keeping full horizontal resolution. `axis_label` uses
    -- a compact nice-ceiling-aware format so labels like "200 MFE/t"
    -- or "0 FE/t" always fit in axis_w columns without the "..."
    -- truncation we had on "157.73 MFE/t".
    gfx.write(mon, chart_x, chart_top,
        " " .. util.pad(axis_label(vmax, RATE_UNIT), axis_w) .. " ",
        P.label)
    gfx.write(mon, chart_x, chart_bot,
        " " .. util.pad(axis_label(vmin, RATE_UNIT), axis_w) .. " ",
        P.label)

    -- Mixed-sign layout: also label the 0 row so the user can read
    -- where the baseline between charge and discharge sits. Skip the
    -- label when it would overlap the top/bottom labels (< 2 cells of
    -- clearance) - in that case the side label carries enough info.
    if vmin < 0 and vmax > 0 and chart_h >= 5 then
        local span = vmax - vmin
        local frac_from_bottom = (0 - vmin) / span
        local zero_y = chart_bot - math.floor(frac_from_bottom * (chart_h - 1) + 0.5)
        if zero_y - chart_top >= 2 and chart_bot - zero_y >= 2 then
            gfx.write(mon, chart_x, zero_y,
                " " .. util.pad(axis_label(0, RATE_UNIT), axis_w) .. " ",
                P.label)
        end
    end

    -- Data availability for the derived stats. We require the series to
    -- span at least the horizon's window before exposing rate / peak /
    -- vol / ETA — otherwise those numbers mean "over whatever happens
    -- to be in the buffer" and mislead far more than they help. The 5%
    -- slack absorbs the few-ms jitter between consecutive broadcasts.
    local data_span_ms = 0
    if #stored_ts >= 2 then
        data_span_ms = stored_ts[#stored_ts] - stored_ts[1]
    end
    local have_full_window = data_span_ms >= (window_ms * 0.95)

    local row  = chart_bot + 2
    local col2 = 2 + math.floor(w / 2)

    if have_full_window and s then
        local rate_s  = window_rate(stored_vals, stored_ts)
        local vol_pct = (s.mean ~= 0) and (s.stdev / math.abs(s.mean) * 100) or 0
        gfx.indicator(mon, 2,    row, "rate",  6, util.fmtRate(rate_s, RATE_UNIT), P.label, rate_color(rate_s))
        gfx.indicator(mon, col2, row, "vol",   5, string.format("%.2f%%", vol_pct),  P.label, P.value)
        row = row + 1
        gfx.indicator(mon, 2,    row, "peak+", 6, util.fmtRate(s.max, RATE_UNIT), P.label, P.ok)
        gfx.indicator(mon, col2, row, "peak-", 5, util.fmtRate(s.min, RATE_UNIT), P.label, P.warn)
        row = row + 1
        local eta_text = "idle"
        if     agg.eta_to_full_s  then eta_text = "to full: "  .. util.fmtDuration(agg.eta_to_full_s)
        elseif agg.eta_to_empty_s then eta_text = "to empty: " .. util.fmtDuration(agg.eta_to_empty_s) end
        gfx.indicator(mon, 2, row, "ETA", 6, eta_text, P.label, P.value)
    else
        -- Partial window: suppress rate / peak / vol / ETA entirely. Show
        -- a single progress line so the user knows how much more history
        -- we still need before the numbers are trustworthy.
        local pct = math.min(100, math.floor(data_span_ms / window_ms * 100 + 0.5))
        local notice = string.format(
            "%s stats: need full window  (%d%% collected)",
            hz.label, pct)
        gfx.write(mon, 2, row + 1, notice, P.warn)
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
    active_tab   = 1,
}
local status_layout = nil

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

log.init("panel", DEBUG_LOGGING and log.LEVEL.DEBUG or log.LEVEL.INFO, "/edash_panel.log")
log.silence_terminal(true)
log.info("panel " .. COMPONENT_VERSION .. " starting"
    .. (DEBUG_LOGGING and "  [debug_logging=on]" or ""))

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
                    if DEBUG_LOGGING then
                        local p = msg.payload
                        local n_col = 0
                        for _ in pairs(p.per_collector or {}) do n_col = n_col + 1 end
                        local s1 = (p.history or {}).s1 or {}
                        local s1_vals = s1.values or {}
                        log.debug(string.format(
                            "rx aggregate: stored=%s cap=%s collectors=%d s1_len=%d",
                            tostring(p.network_stored or 0),
                            tostring(p.network_capacity or 0),
                            n_col, #s1_vals))
                    end
                else
                    trackers.packets_dropped = trackers.packets_dropped + 1
                    if DEBUG_LOGGING then
                        log.debug("dropped invalid / wrong-network packet")
                    end
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
            local ok, layout = pcall(status.render, term, term_ui)
            if ok then status_layout = layout end
            sleep(0.5)
        end
    end,

    -- monitor_touch handler: switch horizons when the user taps a tab.
    -- CC emits (event, side, x, y) for monitor_touch. We filter to our
    -- monitor's side so other monitors don't trip our handler.
    function()
        while true do
            local _, side, tx, ty = os.pullEvent("monitor_touch")
            if side == mon_name and tab_layout then
                for _, r in ipairs(tab_layout.rects) do
                    if ty == r.y and tx >= r.x and tx < r.x + r.w then
                        selected_horizon = r.key
                        mark_event_t("horizon: " .. r.key)
                        if DEBUG_LOGGING then log.debug("horizon -> " .. r.key) end
                        pcall(render, mon)
                        break
                    end
                end
            end
        end
    end,

    -- Terminal input: clickable tabs + keyboard nav on the panel's own
    -- status canvas (separate from the chart monitor above).
    function()
        while true do
            local ev, p1, p2, p3 = os.pullEvent()
            if ev == "mouse_click" and p1 == 1 and status_layout then
                local idx = status.hit_test_tab(status_layout, p2, p3)
                if idx then
                    term_ui.active_tab = idx
                    pcall(status.render, term, term_ui)
                end
            elseif ev == "key" and status_layout then
                local target = status.key_to_tab(term_ui.active_tab or 1,
                                                 status_layout.group_count or 1, p1)
                if target then
                    term_ui.active_tab = target
                    pcall(status.render, term, term_ui)
                end
            end
        end
    end
)
