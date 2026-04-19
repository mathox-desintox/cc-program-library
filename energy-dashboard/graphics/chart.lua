-- energy-dashboard/graphics/chart.lua
--
-- Minimal chart primitives for monitor displays. CC's font has no
-- sub-cell resolution, so charts are rendered as column (bar) charts:
-- each column is one character wide, filled from the baseline up to a
-- row proportional to the sample value. Good enough for rate/fill
-- trends on a 5x3 advanced monitor array (~35x36 chars).

local M = {}

-- stats over a flat value array
local function stats(values)
    local n = #values
    if n == 0 then return nil end
    local vmin, vmax = math.huge, -math.huge
    local sum = 0
    for i = 1, n do
        local v = values[i]
        if v < vmin then vmin = v end
        if v > vmax then vmax = v end
        sum = sum + v
    end
    local mean = sum / n
    local sq = 0
    for i = 1, n do
        local d = values[i] - mean
        sq = sq + d * d
    end
    return {
        min = vmin, max = vmax, mean = mean,
        stdev = math.sqrt(sq / n),
        first = values[1], last = values[n],
        n = n,
    }
end

M.stats = stats

-- Draw a column chart of `values` at (x,y) filling a box of width w, height h.
--
-- Values are expected oldest->newest. The chart is auto-scaled unless
-- opts.ymin/ymax are given, in which case values are clamped to that range.
--
-- Returns the stats table so callers can render legends (min/max/volatility).
function M.column_chart(mon, x, y, w, h, values, opts)
    opts = opts or {}
    local bar   = opts.bar_color   or colors.cyan
    local empty = opts.empty_color or colors.gray
    local bg    = opts.bg          or colors.black

    local box_row = string.rep(" ", w)
    if #values == 0 then
        mon.setBackgroundColor(bg)
        for r = 0, h - 1 do
            mon.setCursorPos(x, y + r)
            mon.write(box_row)
        end
        return nil
    end

    local s = stats(values)
    local vmin = opts.ymin or s.min
    local vmax = opts.ymax or s.max
    if vmax <= vmin then vmax = vmin + 1 end

    -- Pre-compute the column height for each x position.
    local n = #values
    local cols = {}
    for col = 0, w - 1 do
        -- Nearest-neighbour sampling (handles both n<w and n>w cases).
        local src
        if n == 1 then
            src = 1
        else
            src = math.floor(col * (n - 1) / (w - 1) + 0.5) + 1
        end
        if src < 1 then src = 1 end
        if src > n then src = n end
        local v = values[src]
        if v < vmin then v = vmin end
        if v > vmax then v = vmax end
        local frac = (v - vmin) / (vmax - vmin)
        cols[col + 1] = math.floor(frac * h + 0.5)
    end

    -- Render row by row (top to bottom) so each row is one setBgColor +
    -- one write per colour run; faster than cell-by-cell.
    for row = 0, h - 1 do
        local from_bottom = h - row   -- row index counted from the baseline
        mon.setCursorPos(x, y + row)
        -- Build a run-length string alternating bar/empty per column.
        local cur_color = nil
        local run = ""
        for col = 1, w do
            local color = (cols[col] >= from_bottom) and bar or empty
            if color ~= cur_color then
                if cur_color then
                    mon.setBackgroundColor(cur_color)
                    mon.write(run)
                end
                cur_color = color
                run = " "
            else
                run = run .. " "
            end
        end
        if cur_color then
            mon.setBackgroundColor(cur_color)
            mon.write(run)
        end
    end
    mon.setBackgroundColor(bg)
    return s
end

-- Draw a signed column chart of `values` at (x,y) over a box w×h. Used
-- for rate series where values may be positive or negative. A zero line
-- is drawn across the baseline row: positive values fill UP from there,
-- negative values fill DOWN. The y-axis auto-scales so both extremes are
-- visible; the baseline is positioned to keep the larger side from
-- clipping.
--
-- opts.timestamps     : parallel array of wall-clock ms. When present the
--                       x-axis maps by timestamp, leaving gaps for server
--                       downtime or missing samples (hole-tolerant mode).
-- opts.window_ms      : width of the x-axis in ms (required when
--                       timestamps given). x = 0 maps to newest-window_ms,
--                       x = w-1 maps to newest timestamp.
-- opts.pos_color      : colour for positive bars
-- opts.neg_color      : colour for negative bars
-- opts.zero_color     : colour of the baseline row (empty/no-data cells)
-- opts.bg             : colour to clear the box to first
--
-- Returns the stats table (nil if no values).
function M.signed_chart(mon, x, y, w, h, values, opts)
    opts = opts or {}
    local pos_color  = opts.pos_color  or colors.lime
    local neg_color  = opts.neg_color  or colors.orange
    local zero_color = opts.zero_color or colors.gray
    local bg         = opts.bg         or colors.black

    -- Clear the box first so gaps in time-based mode look clean.
    local blank = string.rep(" ", w)
    mon.setBackgroundColor(bg)
    for r = 0, h - 1 do
        mon.setCursorPos(x, y + r)
        mon.write(blank)
    end

    if not values or #values == 0 then return nil end
    local s = stats(values)

    -- Decide baseline row. Keep a proportional split when both signs are
    -- present; stay at bottom/top for single-sign series.
    local vmax = math.max(s.max, 0)
    local vmin = math.min(s.min, 0)
    local span = vmax - vmin
    if span <= 0 then span = 1 end

    local baseline_row  -- 0-indexed row from top
    local up_rows, down_rows
    if s.min >= 0 then
        baseline_row = h - 1
        up_rows = h
        down_rows = 0
    elseif s.max <= 0 then
        baseline_row = 0
        up_rows = 0
        down_rows = h
    else
        local frac_up = vmax / span
        up_rows   = math.max(1, math.min(h - 1, math.floor(frac_up * h + 0.5)))
        down_rows = h - up_rows
        baseline_row = up_rows - 1  -- the row where zero sits
    end

    -- Per-column decision: pick a sample (by index or by time), compute
    -- fill height in up/down direction, render.
    local n = #values
    local timestamps = opts.timestamps
    local use_time   = timestamps and opts.window_ms and #timestamps == n

    local newest_ts
    if use_time then newest_ts = timestamps[n] end

    for col = 0, w - 1 do
        local v, has_sample
        if use_time then
            -- Each column represents a time bucket of window_ms / w. Pick the
            -- sample whose timestamp falls within that bucket; leave the
            -- column blank if no sample lands in it (= a "hole").
            local bucket_end   = newest_ts - (w - 1 - col)     * (opts.window_ms / w)
            local bucket_start = bucket_end - (opts.window_ms / w)
            local best_v, best_d
            for i = 1, n do
                local t = timestamps[i]
                if t and t >= bucket_start and t <= bucket_end then
                    local center = (bucket_start + bucket_end) / 2
                    local d = math.abs(t - center)
                    if not best_d or d < best_d then best_v = values[i]; best_d = d end
                end
            end
            v = best_v
            has_sample = v ~= nil
        else
            local src
            if n == 1 then src = 1
            else src = math.floor(col * (n - 1) / (w - 1) + 0.5) + 1 end
            if src < 1 then src = 1 end
            if src > n then src = n end
            v = values[src]
            has_sample = true
        end

        -- Baseline cell (zero line): always drawn.
        mon.setBackgroundColor(zero_color)
        mon.setCursorPos(x + col, y + baseline_row)
        mon.write(" ")

        if has_sample and v ~= nil then
            if v > 0 and up_rows > 0 then
                local filled = math.max(1, math.floor(v / vmax * (up_rows - 0) + 0.5))
                if filled > up_rows then filled = up_rows end
                mon.setBackgroundColor(pos_color)
                for r = 1, filled do
                    mon.setCursorPos(x + col, y + baseline_row - r)
                    mon.write(" ")
                end
            elseif v < 0 and down_rows > 0 then
                local filled = math.max(1, math.floor(-v / -vmin * (down_rows - 0) + 0.5))
                if filled > down_rows then filled = down_rows end
                mon.setBackgroundColor(neg_color)
                for r = 1, filled do
                    mon.setCursorPos(x + col, y + baseline_row + r)
                    mon.write(" ")
                end
            end
        end
    end

    mon.setBackgroundColor(bg)
    return s
end

return M
