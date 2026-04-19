-- energy-dashboard/graphics/core.lua
--
-- Low-level rendering primitives shared by all panel displays.
-- Keeps draw code in the panels terse and consistent. A proper widget
-- hierarchy (PushButton, LineGraph, etc.) comes in a later milestone.

local M = {}

M.ALIGN = { LEFT = 1, CENTER = 2, RIGHT = 3 }

-- A color pair. Passed to write() to set both fg+bg in one arg.
function M.cpair(fg, bg)
    return { fg = fg, bg = bg }
end

-- Set colours on a monitor. Accepts either a cpair OR (fg, bg).
function M.set_colors(mon, a, b)
    if type(a) == "table" then
        mon.setTextColor(a.fg)
        mon.setBackgroundColor(a.bg)
    else
        if a then mon.setTextColor(a) end
        if b then mon.setBackgroundColor(b) end
    end
end

-- Write text at (x, y) with optional colours + alignment in a given width.
--
--   write(mon, 2, 5, "42", cpair)                          -- left, natural width
--   write(mon, 2, 5, "42", cpair, 10, ALIGN.RIGHT)         -- right-aligned in 10 cols
--
function M.write(mon, x, y, text, cpair_or_fg, width_or_bg, align)
    -- Resolve colours. If cpair_or_fg is a table, treat as cpair.
    -- Otherwise it's fg, and width_or_bg must be bg (and align is nil).
    local w, a
    if type(cpair_or_fg) == "table" then
        M.set_colors(mon, cpair_or_fg)
        w = width_or_bg
        a = align
    else
        if cpair_or_fg then mon.setTextColor(cpair_or_fg) end
        -- Without a cpair, width + align mode aren't meaningful here;
        -- width_or_bg is interpreted as bg.
        if width_or_bg then mon.setBackgroundColor(width_or_bg) end
    end

    text = tostring(text)
    if w and #text < w then
        local slack = w - #text
        if a == M.ALIGN.CENTER then
            mon.setCursorPos(x + math.floor(slack / 2), y)
            mon.write(text)
            return
        elseif a == M.ALIGN.RIGHT then
            mon.setCursorPos(x + slack, y)
            mon.write(text)
            return
        end
        -- LEFT (default): also pad on the right so the slot is fully repainted
        mon.setCursorPos(x, y)
        mon.write(text .. string.rep(" ", slack))
        return
    end
    mon.setCursorPos(x, y)
    mon.write(text)
end

-- Solid-color rectangle. Useful for bars, panels, borders.
function M.fill_rect(mon, x, y, w, h, color)
    mon.setBackgroundColor(color)
    local row = string.rep(" ", w)
    for i = 0, h - 1 do
        mon.setCursorPos(x, y + i)
        mon.write(row)
    end
end

-- Clear the whole monitor to a background colour.
function M.clear(mon, bg)
    mon.setBackgroundColor(bg or colors.black)
    mon.clear()
end

-- Horizontal fill bar. Renders one row at (x, y) of total width w where
-- `pct` (0..100) sets how much is painted in `fill_color` vs `empty_color`.
function M.hbar(mon, x, y, w, pct, fill_color, empty_color)
    pct = math.max(0, math.min(100, pct or 0))
    local filled = math.floor(w * pct / 100 + 0.5)
    mon.setCursorPos(x, y)
    if filled > 0 then
        mon.setBackgroundColor(fill_color)
        mon.write(string.rep(" ", filled))
    end
    if filled < w then
        mon.setBackgroundColor(empty_color)
        mon.write(string.rep(" ", w - filled))
    end
    mon.setBackgroundColor(colors.black)
end

-- Labelled data indicator. Draws "label  value" on a single row, label in
-- dim colour, value highlighted. Width of label column is fixed so values
-- line up across rows.
function M.indicator(mon, x, y, label, label_w, value, cp_label, cp_value)
    M.write(mon, x, y, label, cp_label, label_w, M.ALIGN.LEFT)
    M.write(mon, x + label_w, y, tostring(value), cp_value)
end

return M
