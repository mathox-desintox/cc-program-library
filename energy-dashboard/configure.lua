-- energy-dashboard/configure.lua
--
-- Interactive config editor. Reads /.edi_state to know which components
-- are installed locally, autodetects attached peripherals, and writes
-- /edash_config.lua.
--
-- Visual style mirrors edi.lua: themed title bar, colored section headers,
-- full-width selection highlight, gray footer bar.

local config = require("common.config")
local util   = require("common.util")

-- --- theme --------------------------------------------------------------

local has_color = term.isColor and term.isColor()
local T = {
    bg            = colors.black,
    fg            = colors.white,
    dim           = colors.lightGray,

    title_bg      = colors.blue,
    title_fg      = colors.white,

    section       = colors.cyan,
    footer_bg     = colors.gray,
    footer_fg     = colors.white,

    sel_bg        = colors.white,
    sel_fg        = colors.black,

    changed       = colors.yellow,     -- rows whose value differs from default
    action        = colors.lime,
    danger        = colors.red,
    back          = colors.lightGray,

    ok            = colors.lime,
    warn          = colors.yellow,
    err           = colors.red,
}

local function set_fg(c) if has_color then term.setTextColor(c) end end
local function set_bg(c) if has_color then term.setBackgroundColor(c) end end

-- --- render primitives --------------------------------------------------

local function screen_wh() return term.getSize() end

local function fill_line(y, bg)
    local w = screen_wh()
    set_bg(bg); term.setCursorPos(1, y); term.write(string.rep(" ", w))
end

local function write_at(x, y, s, fg, bg)
    term.setCursorPos(x, y)
    if fg then set_fg(fg) end
    if bg then set_bg(bg) end
    term.write(s)
end

local function clear_screen()
    set_bg(T.bg); set_fg(T.fg); term.clear()
end

local function draw_title_bar(title, right_text)
    local w = screen_wh()
    fill_line(1, T.title_bg)
    write_at(2, 1, title, T.title_fg, T.title_bg)
    if right_text then
        local x = math.max(2 + #title + 2, w - #right_text)
        write_at(x, 1, right_text, T.title_fg, T.title_bg)
    end
    set_bg(T.bg); set_fg(T.fg)
end

local function draw_footer_bar(text)
    local _, h = screen_wh()
    fill_line(h, T.footer_bg)
    write_at(2, h, text, T.footer_fg, T.footer_bg)
    set_bg(T.bg); set_fg(T.fg)
end

local function draw_section(y, text)
    local w = screen_wh()
    fill_line(y, T.bg)
    write_at(2, y, "-- ", T.section, T.bg)
    write_at(5, y, text, T.section, T.bg)
    local trail_x = 5 + #text + 1
    if trail_x < w - 1 then
        write_at(trail_x, y, " " .. string.rep("-", w - trail_x - 1), T.section, T.bg)
    end
end

-- --- menu item model ----------------------------------------------------
-- Each row is either a selectable action/entry, a section header, or a spacer.
--   action row: { key, label, value, kind, options?, ptype?, default? }
--       kind = "text" | "number" | "enum" | "peripheral" | "action"
--   header:     { section = "..." }
--   spacer:     { spacer = true }

local function is_selectable(it) return not it.section and not it.spacer end

local function draw_entry(y, it, selected)
    local w = screen_wh()
    if it.section then draw_section(y, it.section); return end
    if it.spacer  then fill_line(y, T.bg);          return end

    local bg = selected and T.sel_bg or T.bg
    local fg = selected and T.sel_fg or T.fg

    fill_line(y, bg)

    if selected then write_at(2, y, "\16", T.sel_fg, T.sel_bg) end

    local label_col_w = 20
    local label = util.pad(it.label or "", label_col_w)
    write_at(4, y, label, fg, bg)

    -- value display (right of label) with "changed" highlight
    local x = 4 + label_col_w
    if it.value_text then
        local max = w - x - 2
        local value_fg = fg
        if selected then
            value_fg = T.sel_fg
        elseif it.is_changed then
            value_fg = T.changed
        end
        write_at(x, y, util.truncate(it.value_text, max), value_fg, bg)
    end

    -- tag (right-most) for action rows like [save], [back]
    if it.tag then
        local tag_x = w - #it.tag - 1
        local tag_fg = selected and T.sel_fg or (it.tag_color or T.fg)
        write_at(tag_x, y, it.tag, tag_fg, bg)
    end
end

-- --- arrow-key menu -----------------------------------------------------

local function first_selectable(items)
    for i, it in ipairs(items) do if is_selectable(it) then return i end end
    return 1
end

local function arrow_menu(items, title, right_text, footer_text)
    local sel = first_selectable(items)
    while true do
        clear_screen()
        draw_title_bar(title or "Configure", right_text)
        fill_line(2, T.bg)

        local _, h = screen_wh()
        local start_y = 3
        local max_rows = h - start_y - 1
        local offset = 0
        if #items > max_rows then offset = math.min(sel - 1, #items - max_rows) end

        for i = 1, math.min(max_rows, #items) do
            local idx = i + offset
            if items[idx] then draw_entry(start_y + i - 1, items[idx], idx == sel) end
        end

        draw_footer_bar(footer_text or " \24\25  navigate     enter select     q  back")

        local _, key = os.pullEvent("key")
        if key == keys.up then
            local i = sel - 1
            while i >= 1 and not is_selectable(items[i]) do i = i - 1 end
            if i >= 1 then sel = i end
        elseif key == keys.down then
            local i = sel + 1
            while i <= #items and not is_selectable(items[i]) do i = i + 1 end
            if i <= #items then sel = i end
        elseif key == keys.enter then return items[sel]
        elseif key == keys.q then return nil end
    end
end

-- --- value prompts ------------------------------------------------------

local function edit_screen_header(label, current)
    clear_screen()
    draw_title_bar("Edit: " .. label)
    fill_line(2, T.bg)
    write_at(2, 4, "current: ", T.dim, T.bg)
    write_at(11, 4, tostring(current), T.fg, T.bg)
    fill_line(5, T.bg)
end

local function prompt_text(label, current)
    edit_screen_header(label, current)
    write_at(2, 6, "New value (blank = keep):", T.fg, T.bg)
    write_at(2, 7, "> ", T.dim, T.bg)
    term.setCursorPos(4, 7)
    set_bg(T.bg); set_fg(T.fg)
    local input = read()
    if input == nil or input == "" then return current end
    return input
end

local function prompt_number(label, current)
    local v = prompt_text(label, current)
    if v == current then return current end
    local n = tonumber(v)
    if not n then
        fill_line(9, T.bg)
        write_at(2, 9, "not a number - keeping current", T.err, T.bg)
        sleep(1.2)
        return current
    end
    return n
end

local function prompt_enum(label, current, options)
    local items = { { section = label } }
    for _, o in ipairs(options) do
        items[#items + 1] = {
            label = tostring(o),
            value_text = (o == current) and "(current)" or "",
            enum_value = o,
        }
    end
    items[#items + 1] = { spacer = true }
    items[#items + 1] = { label = "[cancel]", tag = "[cancel]", tag_color = T.back, cancel = true }
    local sel = arrow_menu(items, "Edit: " .. label,
        "current: " .. tostring(current),
        " \24\25  navigate     enter pick     q  cancel")
    if not sel or sel.cancel then return current end
    return sel.enum_value
end

local function prompt_peripheral(label, current, ptype)
    local names = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == ptype then names[#names + 1] = name end
    end

    local items = { { section = label .. "  (" .. ptype .. ")" } }
    if #names == 0 then
        items[#items + 1] = { label = "(nothing of type " .. ptype .. " attached)" }
    else
        for _, n in ipairs(names) do
            items[#items + 1] = {
                label = n,
                value_text = (n == current) and "(current)" or "",
                periph_name = n,
            }
        end
    end
    items[#items + 1] = { spacer = true }
    items[#items + 1] = {
        label = "(auto-pick first available)",
        value_text = (current == nil) and "(current)" or "",
        periph_auto = true,
    }
    items[#items + 1] = { label = "[cancel]", tag = "[cancel]", tag_color = T.back, cancel = true }

    local sel = arrow_menu(items, "Edit: " .. label,
        "current: " .. tostring(current or "auto"),
        " \24\25  navigate     enter pick     q  cancel")
    if not sel or sel.cancel then return current end
    if sel.periph_auto then return nil end
    if sel.periph_name then return sel.periph_name end
    return current
end

-- --- component editors --------------------------------------------------

-- Builds the rows for a given component. `cfg_section` is the live (mutable)
-- config table for that component; `defaults_section` is the default table,
-- used to compute "changed" highlighting.

local function build_rows_collector(cfg_section, defaults_section)
    return {
        {
            key        = "peripheral",
            label      = "peripheral",
            value_text = tostring(cfg_section.peripheral or "auto"),
            is_changed = cfg_section.peripheral ~= defaults_section.peripheral,
            kind       = "peripheral",
            ptype      = "flux_accessor_ext",
        },
        {
            key        = "tick_seconds",
            label      = "tick_seconds",
            value_text = tostring(cfg_section.tick_seconds),
            is_changed = cfg_section.tick_seconds ~= defaults_section.tick_seconds,
            kind       = "number",
        },
    }
end

local function build_rows_core(cfg_section, defaults_section)
    local rows = {}
    local function row(key, kind)
        rows[#rows + 1] = {
            key = key, label = key, kind = kind,
            value_text = tostring(cfg_section[key]),
            is_changed = cfg_section[key] ~= defaults_section[key],
        }
    end
    row("broadcast_interval_ms", "number")
    row("persist_interval_ms",   "number")
    row("stale_ms",              "number")
    row("state_file",            "text")
    row("log_file",              "text")
    return rows
end

local function build_rows_panel(cfg_section, defaults_section)
    return {
        {
            key = "monitor",      label = "monitor", kind = "peripheral", ptype = "monitor",
            value_text = tostring(cfg_section.monitor or "auto"),
            is_changed = cfg_section.monitor ~= defaults_section.monitor,
        },
        {
            key = "rate_unit",    label = "rate_unit", kind = "enum", options = { "t", "s" },
            value_text = "/" .. tostring(cfg_section.rate_unit),
            is_changed = cfg_section.rate_unit ~= defaults_section.rate_unit,
        },
        {
            key = "redraw_ms",    label = "redraw_ms", kind = "number",
            value_text = tostring(cfg_section.redraw_ms),
            is_changed = cfg_section.redraw_ms ~= defaults_section.redraw_ms,
        },
        {
            key = "stale_ms",     label = "stale_ms", kind = "number",
            value_text = tostring(cfg_section.stale_ms),
            is_changed = cfg_section.stale_ms ~= defaults_section.stale_ms,
        },
        {
            key = "theme",        label = "theme", kind = "text",
            value_text = tostring(cfg_section.theme),
            is_changed = cfg_section.theme ~= defaults_section.theme,
        },
    }
end

local function edit_component(name, cfg_section, defaults_section)
    local builders = {
        collector = build_rows_collector,
        core      = build_rows_core,
        panel     = build_rows_panel,
    }
    local build = builders[name]
    if not build then return end

    while true do
        local rows = build(cfg_section, defaults_section)
        local items = { { section = name .. " settings" } }
        for _, r in ipairs(rows) do items[#items + 1] = r end
        items[#items + 1] = { spacer = true }
        items[#items + 1] = { label = "[back]", tag = "[back]", tag_color = T.back, back = true }

        local sel = arrow_menu(items, "Configure " .. name, nil,
            " \24\25  navigate     enter edit     q  back")
        if not sel or sel.back then return end
        if     sel.kind == "text"       then cfg_section[sel.key] = prompt_text(sel.label, cfg_section[sel.key])
        elseif sel.kind == "number"     then cfg_section[sel.key] = prompt_number(sel.label, cfg_section[sel.key])
        elseif sel.kind == "enum"       then cfg_section[sel.key] = prompt_enum(sel.label, cfg_section[sel.key], sel.options)
        elseif sel.kind == "peripheral" then cfg_section[sel.key] = prompt_peripheral(sel.label, cfg_section[sel.key], sel.ptype)
        end
    end
end

-- --- shared section editor (network_id + future shared keys) ------------

local function edit_shared(all_cfg, defaults)
    while true do
        local items = {
            { section = "Shared" },
            {
                key = "network_id", label = "network_id", kind = "text",
                value_text = tostring(all_cfg.network_id),
                is_changed = all_cfg.network_id ~= defaults.network_id,
            },
            { spacer = true },
            { label = "[back]", tag = "[back]", tag_color = T.back, back = true },
        }
        local sel = arrow_menu(items, "Configure shared", nil,
            " \24\25  navigate     enter edit     q  back")
        if not sel or sel.back then return end
        if sel.kind == "text" then all_cfg.network_id = prompt_text(sel.label, all_cfg.network_id) end
    end
end

-- --- installed-components detection -------------------------------------

local function load_edi_state()
    if not fs.exists("/.edi_state") then return { installed = {} } end
    local f = fs.open("/.edi_state", "r"); if not f then return { installed = {} } end
    local data = f.readAll(); f.close()
    local ok, s = pcall(textutils.unserialise, data)
    if not ok or type(s) ~= "table" then return { installed = {} } end
    s.installed = s.installed or {}
    return s
end

local function installed_components()
    local state = load_edi_state()
    local present = {}
    for n in pairs(state.installed) do present[n] = true end
    if fs.exists("collector.lua") then present.collector = true end
    if fs.exists("core.lua")      then present.core      = true end
    if fs.exists("panel.lua")     then present.panel     = true end
    local out = {}
    for n in pairs(present) do out[#out + 1] = n end
    table.sort(out)
    return out
end

-- --- top-level menu -----------------------------------------------------

local function component_summary(name, all_cfg)
    if name == "collector" then
        return string.format("peripheral=%s  tick=%ss",
            tostring(all_cfg.collector.peripheral or "auto"),
            tostring(all_cfg.collector.tick_seconds))
    elseif name == "core" then
        return string.format("bcast=%sms  persist=%sms",
            tostring(all_cfg.core.broadcast_interval_ms),
            tostring(all_cfg.core.persist_interval_ms))
    elseif name == "panel" then
        return string.format("monitor=%s  rate=/%s",
            tostring(all_cfg.panel.monitor or "auto"),
            tostring(all_cfg.panel.rate_unit))
    end
    return ""
end

local function main()
    local comps = installed_components()
    if #comps == 0 then
        clear_screen()
        draw_title_bar("Configure")
        fill_line(2, T.bg)
        for i, line in ipairs(util.wrap(
            "nothing appears to be installed on this computer. Run `pastebin run F3bHqTDi` to install a component, then re-run configure.",
            screen_wh() - 4)) do
            write_at(2, 3 + i, line, T.dim, T.bg)
        end
        draw_footer_bar(" press any key")
        os.pullEvent("key")
        return
    end

    local all_cfg  = config.load_all()
    local defaults = config.DEFAULTS  -- for change detection

    while true do
        local items = { { section = "Shared" }, {
            key = "shared", label = "network_id", kind = "shared",
            value_text = tostring(all_cfg.network_id),
            is_changed = all_cfg.network_id ~= defaults.network_id,
        }, { spacer = true }, { section = "Components" } }

        for _, name in ipairs(comps) do
            items[#items + 1] = {
                component = name,
                label = name,
                value_text = component_summary(name, all_cfg),
                is_changed = false,   -- per-component change check is per-row
            }
        end
        items[#items + 1] = { spacer = true }
        items[#items + 1] = { label = "save and exit",  tag = "[save]",    tag_color = T.action,  action = "save" }
        items[#items + 1] = { label = "discard changes",tag = "[discard]", tag_color = T.danger,  action = "discard" }
        items[#items + 1] = { label = "reset to defaults", tag = "[reset]", tag_color = T.warn,   action = "reset" }

        local sel = arrow_menu(items, "Energy Dashboard Configure",
            "network_id=" .. tostring(all_cfg.network_id),
            " \24\25  navigate     enter select     q  quit")
        if not sel then clear_screen(); return end

        if sel.kind == "shared" then
            edit_shared(all_cfg, defaults)
        elseif sel.component then
            edit_component(sel.component, all_cfg[sel.component], defaults[sel.component])
        elseif sel.action == "save" then
            local ok, err = config.save_all(all_cfg)
            clear_screen(); draw_title_bar("Configure"); fill_line(2, T.bg)
            if ok then
                write_at(2, 4, "saved to " .. config.FILE, T.ok, T.bg)
                write_at(2, 5, "restart the component(s) to apply.", T.dim, T.bg)
            else
                write_at(2, 4, "save failed: " .. tostring(err), T.err, T.bg)
            end
            draw_footer_bar(" press any key")
            os.pullEvent("key")
            return
        elseif sel.action == "discard" then
            clear_screen(); return
        elseif sel.action == "reset" then
            -- deep copy DEFAULTS back into all_cfg (in-place swap)
            all_cfg = config.load_all()  -- reload from disk, then overwrite with defaults
            for k in pairs(all_cfg) do all_cfg[k] = nil end
            for k, v in pairs(config.DEFAULTS) do
                if type(v) == "table" then
                    all_cfg[k] = {}
                    for kk, vv in pairs(v) do all_cfg[k][kk] = vv end
                else
                    all_cfg[k] = v
                end
            end
        end
    end
end

local ok, err = pcall(main)
set_bg(colors.black); set_fg(colors.white); term.setCursorPos(1, 1)
if not ok then print("configure crashed: " .. tostring(err)) end
