-- energy-dashboard/common/status.lua
--
-- Shared status canvas for collector / core / panel. Each component
-- builds a `state` table describing itself (title, status pill, grouped
-- label/value rows, footer) and calls status.render(term, state) from a
-- parallel render loop. Renderer redraws the whole screen each call -
-- cheap on CC:Tweaked, robust against partial-update glitches.

local M = {}

M.THEME = {
    bg           = colors.black,
    fg           = colors.white,
    dim          = colors.lightGray,

    title_bg     = colors.blue,
    title_fg     = colors.white,

    section      = colors.cyan,
    footer_bg    = colors.gray,
    footer_fg    = colors.white,

    ok           = colors.lime,
    warn         = colors.yellow,
    err          = colors.red,
    value        = colors.white,
    label        = colors.lightGray,
}

-- --- primitives ---------------------------------------------------------

local function wsize(mon) return mon.getSize() end

local function fill_line(mon, y, bg, w)
    mon.setBackgroundColor(bg)
    mon.setCursorPos(1, y)
    mon.write(string.rep(" ", w))
end

local function write_at(mon, x, y, s, fg, bg)
    mon.setCursorPos(x, y)
    if fg then mon.setTextColor(fg) end
    if bg then mon.setBackgroundColor(bg) end
    mon.write(s)
end

local function pad_right(s, w)
    s = tostring(s or "")
    if #s >= w then return s:sub(1, w) end
    return s .. string.rep(" ", w - #s)
end

local function truncate(text, w)
    text = tostring(text or "")
    if #text <= w then return text end
    if w <= 2 then return text:sub(1, w) end
    return text:sub(1, w - 2) .. ".."
end

-- Wrap to at most one line (truncate) + tell caller how long.
-- Used for section dividers where we want predictable widths.
local function section_line(mon, y, title, w)
    local T = M.THEME
    fill_line(mon, y, T.bg, w)
    write_at(mon, 2, y, "-- ", T.section, T.bg)
    write_at(mon, 5, y, title, T.section, T.bg)
    local trail_x = 5 + #title + 1
    if trail_x < w - 1 then
        write_at(mon, trail_x, y, " " .. string.rep("-", w - trail_x - 1), T.section, T.bg)
    end
end

local function row(mon, x, y, w, label, value, value_color)
    local T = M.THEME
    fill_line(mon, y, T.bg, w)
    local label_w = 14
    write_at(mon, x, y, pad_right(label or "", label_w), T.label, T.bg)
    local value_x = x + label_w
    local max = w - value_x - 1
    write_at(mon, value_x, y, truncate(tostring(value or ""), max), value_color or T.value, T.bg)
end

-- Bullet + text row, bullet color communicates health
--   ● ok, ● warn, ● err, ○ stale
local function bullet_row(mon, x, y, w, label, value, bullet, bullet_color)
    local T = M.THEME
    fill_line(mon, y, T.bg, w)
    write_at(mon, x, y, bullet or "\7", bullet_color or T.dim, T.bg)
    write_at(mon, x + 2, y, pad_right(label or "", 14 - 2), T.label, T.bg)
    local value_x = x + 14
    local max = w - value_x - 1
    write_at(mon, value_x, y, truncate(tostring(value or ""), max), T.value, T.bg)
end

-- --- public: render(mon, state) -----------------------------------------
--
-- state = {
--   title     = "collector",
--   version   = "0.3.0",
--   status    = { text = "RUNNING", color = colors.lime },
--   right_header = "network_id: default",   -- optional right-side title text
--   groups    = {
--     {
--       title = "peripherals",
--       rows = {
--         -- either a plain row:
--         { label = "modem",      value = "back" },
--         -- or a bullet row (health dot):
--         { label = "top",        value = "flux_accessor_ext", bullet = "\7", bullet_color = colors.lime },
--       },
--     },
--     ...
--   },
--   footer    = "last event text (dim)",
-- }

-- Render the canvas. When state.groups has more than one entry only
-- ONE group's body is drawn at a time; the rest are reachable via a
-- clickable tab strip on row 3 (plus keyboard left/right or 1..9). For
-- a single-group state the tab strip is hidden and the group renders
-- directly under the title / status pill, preserving the old layout.
--
-- The return value is a small layout descriptor the caller uses to
-- route mouse_click events - see M.hit_test_tab below.
function M.render(mon, state)
    local T = M.THEME
    local w, h = wsize(mon)

    mon.setBackgroundColor(T.bg); mon.clear()

    -- -- title bar --
    fill_line(mon, 1, T.title_bg, w)
    local title_text = (state.title or "?") .. (state.version and ("  v" .. state.version) or "")
    write_at(mon, 2, 1, title_text, T.title_fg, T.title_bg)
    if state.right_header then
        local rx = math.max(2 + #title_text + 2, w - #state.right_header - 1)
        write_at(mon, rx, 1, state.right_header, T.title_fg, T.title_bg)
    end

    -- -- status pill (row 2, right-aligned) --
    fill_line(mon, 2, T.bg, w)
    if state.status and state.status.text then
        local pill = " " .. state.status.text .. " "
        write_at(mon, w - #pill - 1, 2, pill,
            colors.black, state.status.color or T.ok)
    end

    local groups = state.groups or {}
    local active = state.active_tab or 1
    if active < 1 then active = 1 end
    if active > #groups then active = #groups end

    local tab_rects = {}
    local body_y = 3

    if #groups > 1 then
        -- Tab strip on row 3. Selected tab is inverted (black on section
        -- colour); unselected tabs render as dim [ label ] pills.
        fill_line(mon, 3, T.bg, w)
        local cx = 2
        for i, g in ipairs(groups) do
            local label = g.title or ("tab " .. i)
            local txt = "[" .. label .. "]"
            if cx + #txt > w then break end  -- overflow - drop rest
            local fg, bg
            if i == active then
                fg, bg = colors.black, T.section
            else
                fg, bg = T.label, T.bg
            end
            write_at(mon, cx, 3, txt, fg, bg)
            tab_rects[#tab_rects + 1] = {
                x = cx, y = 3, w = #txt, index = i, title = label,
            }
            cx = cx + #txt + 1
        end
        body_y = 5   -- one blank row under the tabs as a spacer
        fill_line(mon, 4, T.bg, w)
    end

    -- -- body: only the active group --
    local g = groups[active]
    if g then
        if body_y < h then
            section_line(mon, body_y, g.title or "", w); body_y = body_y + 1
        end
        for _, r in ipairs(g.rows or {}) do
            if body_y >= h - 1 then break end
            if r.bullet then
                bullet_row(mon, 2, body_y, w, r.label, r.value, r.bullet, r.bullet_color)
            else
                row(mon, 2, body_y, w, r.label, r.value, r.value_color)
            end
            body_y = body_y + 1
        end
    end

    -- -- footer --
    fill_line(mon, h, T.footer_bg, w)
    local footer_text = state.footer or ""
    if #groups > 1 then
        -- Hint at the tab nav when there's more than one; shown only if
        -- there is room after the regular footer text.
        local hint = "[tab \24\25 or click]"
        local combined = footer_text
        if combined == "" then combined = hint
        elseif #combined + 3 + #hint <= w - 3 then
            combined = combined .. "   " .. hint
        end
        write_at(mon, 2, h, truncate(combined, w - 3), T.footer_fg, T.footer_bg)
    elseif footer_text ~= "" then
        write_at(mon, 2, h, truncate(footer_text, w - 3), T.footer_fg, T.footer_bg)
    end

    mon.setBackgroundColor(T.bg); mon.setTextColor(T.fg)

    return { tab_rects = tab_rects, active = active, group_count = #groups }
end

-- Hit-test a mouse_click against the tab strip. Returns the 1-based
-- group index that was clicked, or nil when the click missed every
-- tab (or when the layout wasn't captured from a prior render).
function M.hit_test_tab(layout, x, y)
    if type(layout) ~= "table" then return nil end
    for _, r in ipairs(layout.tab_rects or {}) do
        if y == r.y and x >= r.x and x < r.x + r.w then return r.index end
    end
    return nil
end

-- Keyboard helper: given the current active index + group count,
-- resolve the usual navigation keys (tab / left / right / number keys
-- / home / end) into a new active index. Returns nil when the key
-- isn't one we care about so callers can keep chaining handlers.
function M.key_to_tab(active, group_count, key)
    if group_count <= 1 then return nil end
    if keys and (key == keys.tab or key == keys.right) then
        return ((active - 1 + 1) % group_count) + 1
    elseif keys and key == keys.left then
        return ((active - 1 - 1) % group_count) + 1
    elseif keys and key == keys.home then
        return 1
    elseif keys and key == keys["end"] then
        return group_count
    elseif type(key) == "number" and key >= keys.one and key <= keys.nine then
        local idx = key - keys.one + 1
        if idx <= group_count then return idx end
    end
    return nil
end

-- --- convenience bullet constants ---------------------------------------

M.BULLET = {
    OK    = { mark = "\7", color = colors.lime    },
    WARN  = { mark = "\7", color = colors.yellow  },
    ERR   = { mark = "\7", color = colors.red     },
    DIM   = { mark = "\7", color = colors.lightGray },
}

return M
