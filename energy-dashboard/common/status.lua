-- energy-dashboard/common/status.lua
--
-- Shared status canvas for collector / core / panel. Each component
-- builds a `state` table describing itself (title, status pill, grouped
-- label/value rows, footer) and calls status.render(term, state) from a
-- parallel render loop. Renderer redraws the whole screen each call —
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

-- ─── primitives ─────────────────────────────────────────────────────────

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
    write_at(mon, 2, y, "\140\140 ", T.section, T.bg)
    write_at(mon, 5, y, title, T.section, T.bg)
    local trail_x = 5 + #title + 1
    if trail_x < w - 1 then
        write_at(mon, trail_x, y, " " .. string.rep("\140", w - trail_x - 1), T.section, T.bg)
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

-- ─── public: render(mon, state) ─────────────────────────────────────────
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

function M.render(mon, state)
    local T = M.THEME
    local w, h = wsize(mon)

    -- ── title bar ──
    mon.setBackgroundColor(T.bg); mon.clear()
    fill_line(mon, 1, T.title_bg, w)
    local title_text = (state.title or "?") .. (state.version and ("  v" .. state.version) or "")
    write_at(mon, 2, 1, title_text, T.title_fg, T.title_bg)
    if state.right_header then
        local rx = math.max(2 + #title_text + 2, w - #state.right_header - 1)
        write_at(mon, rx, 1, state.right_header, T.title_fg, T.title_bg)
    end

    -- ── status pill (row 2, right-aligned) ──
    fill_line(mon, 2, T.bg, w)
    if state.status and state.status.text then
        local pill = " " .. state.status.text .. " "
        write_at(mon, w - #pill - 1, 2, pill,
            colors.black, state.status.color or T.ok)
    end

    -- ── groups ──
    local y = 3
    for _, g in ipairs(state.groups or {}) do
        if y >= h - 1 then break end
        section_line(mon, y, g.title or "", w); y = y + 1
        for _, r in ipairs(g.rows or {}) do
            if y >= h - 1 then break end
            if r.bullet then
                bullet_row(mon, 2, y, w, r.label, r.value, r.bullet, r.bullet_color)
            else
                row(mon, 2, y, w, r.label, r.value, r.value_color)
            end
            y = y + 1
        end
        -- spacer between groups
        if y < h - 1 then fill_line(mon, y, T.bg, w); y = y + 1 end
    end

    -- ── footer ──
    fill_line(mon, h, T.footer_bg, w)
    if state.footer then
        write_at(mon, 2, h, truncate(state.footer, w - 3), T.footer_fg, T.footer_bg)
    end

    mon.setBackgroundColor(T.bg); mon.setTextColor(T.fg)
end

-- ─── convenience bullet constants ───────────────────────────────────────

M.BULLET = {
    OK    = { mark = "\7", color = colors.lime    },
    WARN  = { mark = "\7", color = colors.yellow  },
    ERR   = { mark = "\7", color = colors.red     },
    DIM   = { mark = "\7", color = colors.lightGray },
}

return M
