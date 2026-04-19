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

return M
