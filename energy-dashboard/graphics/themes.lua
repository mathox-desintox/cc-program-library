-- energy-dashboard/graphics/themes.lua
--
-- Named colour palettes. Panels pick a theme at startup and reference
-- semantic colour slots (ok, warn, critical, bar_full, …) rather than raw
-- colours. Future configure-UI work can expose the theme choice.

local core = require("graphics.core")
local cpair = core.cpair

local M = {}

-- Default theme: dark, cyan/lime accents.
M.default = {
    -- structural
    bg            = colors.black,
    fg            = colors.white,
    dim           = colors.lightGray,
    accent        = colors.cyan,
    -- semantic state
    ok            = colors.lime,
    warn          = colors.yellow,
    critical      = colors.red,
    charging      = colors.lime,
    draining      = colors.red,
    stale         = colors.yellow,
    offline       = colors.red,
    -- bar colours
    bar_full      = colors.lime,
    bar_empty     = colors.gray,
    bar_mid       = colors.cyan,
}

-- Convenience colour-pair builders against a theme table `t`.
--   local P = themes.pairs(theme)
--   graphics.write(mon, 1, 1, "Hello", P.label)
function M.pairs(t)
    return {
        title    = cpair(t.fg,       t.bg),
        label    = cpair(t.dim,      t.bg),
        value    = cpair(t.fg,       t.bg),
        accent   = cpair(t.accent,   t.bg),
        ok       = cpair(t.ok,       t.bg),
        warn     = cpair(t.warn,     t.bg),
        critical = cpair(t.critical, t.bg),
        charging = cpair(t.charging, t.bg),
        draining = cpair(t.draining, t.bg),
    }
end

return M
