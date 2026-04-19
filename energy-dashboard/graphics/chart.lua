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

-- Stats ignoring nil holes. Used by line_chart so callers can render
-- legends (high / low / volatility) off the non-nil subset.
local function stats_sparse(values, width)
    local sum, n = 0, 0
    local vmin, vmax = math.huge, -math.huge
    for i = 1, width do
        local v = values[i]
        if v ~= nil then
            if v < vmin then vmin = v end
            if v > vmax then vmax = v end
            sum = sum + v; n = n + 1
        end
    end
    if n == 0 then return nil end
    local mean = sum / n
    local sq = 0
    for i = 1, width do
        local v = values[i]
        if v ~= nil then
            local d = v - mean
            sq = sq + d * d
        end
    end
    return { min = vmin, max = vmax, mean = mean, stdev = math.sqrt(sq / n), n = n }
end

-- Draw a signed LINE chart at (x, y) sized w×h. `values[c]` is the
-- sample for chart column c (1..w) or nil for a hole (empty column).
-- The chart auto-scales y to include zero so a flat baseline shows
-- which direction is positive. Adjacent non-nil columns are connected
-- with a stair-step fill so it reads as a line rather than bars.
--
-- opts.pos_color      : colour for cells at-or-above the zero line
-- opts.neg_color      : colour for cells below the zero line
-- opts.zero_color     : colour for the baseline row
-- opts.bg             : background colour to clear to first
--
-- Returns a stats table (nil if no non-nil values).
function M.line_chart(mon, x, y, w, h, values, opts)
    opts = opts or {}
    local pos_color  = opts.pos_color  or colors.lime
    local neg_color  = opts.neg_color  or colors.orange
    local zero_color = opts.zero_color or colors.gray
    local bg         = opts.bg         or colors.black

    local blank = string.rep(" ", w)
    mon.setBackgroundColor(bg)
    for r = 0, h - 1 do
        mon.setCursorPos(x, y + r)
        mon.write(blank)
    end

    local s = stats_sparse(values, w)
    if not s then return nil end

    -- Auto-scale strategy:
    --   same-sign series : tight range [min, max] with a small padding
    --                       so 1-2% variations use the full chart height.
    --                       Zero baseline is off-screen but the pos/neg
    --                       bar colour still carries the sign.
    --   mixed signs      : anchor zero on the chart so positive and
    --                       negative excursions are drawn above / below.
    local vmin, vmax, baseline_row
    if s.min >= 0 and s.max >= 0 and s.max > 0 then
        -- All non-negative, values cluster near max: zoom in.
        local pad = (s.max - s.min) * 0.1
        if pad <= 0 then pad = math.abs(s.max) * 0.05 + 1 end
        vmin = math.max(0, s.min - pad)
        vmax = s.max + pad
        baseline_row = h - 1                              -- off-screen below
    elseif s.max <= 0 and s.min <= 0 and s.min < 0 then
        -- All non-positive: zoom in on the negative range.
        local pad = (s.max - s.min) * 0.1
        if pad <= 0 then pad = math.abs(s.min) * 0.05 + 1 end
        vmin = s.min - pad
        vmax = math.min(0, s.max + pad)
        baseline_row = 0                                  -- off-screen above
    else
        -- Mixed: keep the zero-anchored layout.
        vmax = math.max(s.max, 0)
        vmin = math.min(s.min, 0)
        baseline_row = math.floor(vmax / (vmax - vmin) * (h - 1) + 0.5)
    end

    local span = vmax - vmin
    if span <= 0 then span = 1 end

    -- Draw the zero line only if it falls inside the visible range.
    if baseline_row >= 0 and baseline_row < h and vmin <= 0 and vmax >= 0 then
        mon.setBackgroundColor(zero_color)
        for c = 0, w - 1 do
            mon.setCursorPos(x + c, y + baseline_row)
            mon.write(" ")
        end
    end

    -- Compute each column's row position.
    local rows = {}
    for c = 1, w do
        local v = values[c]
        if v ~= nil then
            local frac = (v - vmin) / span            -- 0..1, 0 = vmin (bottom)
            rows[c] = h - 1 - math.floor(frac * (h - 1) + 0.5)
        end
    end

    -- Stair-step line: each column fills from its own row toward the next
    -- column's row, so adjacent points are visually connected even when
    -- their rows differ by several cells.
    for c = 1, w do
        local rc = rows[c]
        if rc then
            local rc_next = rows[c + 1] or rc
            local color = ((values[c] or 0) >= 0) and pos_color or neg_color
            mon.setBackgroundColor(color)
            local ystart = math.min(rc, rc_next)
            local yend   = math.max(rc, rc_next)
            for r = ystart, yend do
                mon.setCursorPos(x + c - 1, y + r)
                mon.write(" ")
            end
        end
    end

    mon.setBackgroundColor(bg)
    return s
end

-- Kept for legacy callers but no longer used by the panel.
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
