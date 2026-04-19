-- energy-dashboard/configure.lua
--
-- Page-per-page configuration editor, scada-mek-style. Each installed
-- component gets its own page (plus a "Shared" page at the front for
-- network_id). Inside a page the user arrow-navigates between fields and
-- hits Enter *once* to edit - no separate "enter the page, then enter
-- the field" step. Enums cycle in place on Enter; peripherals still use
-- a popup picker. A detail panel at the bottom explains the selected
-- field.
--
-- Navigation: left/right to switch pages, up/down to navigate fields,
-- Enter to edit, S to save, Q to cancel/discard.

local config = require("common.config")
local util   = require("common.util")

-- --- theme --------------------------------------------------------------

local has_color = term.isColor and term.isColor()
local T = {
    bg         = colors.black,
    fg         = colors.white,
    dim        = colors.lightGray,
    title_bg   = colors.blue,
    title_fg   = colors.white,
    section    = colors.cyan,
    footer_bg  = colors.gray,
    footer_fg  = colors.white,
    sel_bg     = colors.white,
    sel_fg     = colors.black,
    changed    = colors.yellow,
    ok         = colors.lime,
    warn       = colors.yellow,
    err        = colors.red,
    accent     = colors.cyan,
}

local function set_fg(c) if has_color then term.setTextColor(c) end end
local function set_bg(c) if has_color then term.setBackgroundColor(c) end end

-- --- primitives ---------------------------------------------------------

local function screen_wh() return term.getSize() end

local function fill_line(y, bg)
    local w = screen_wh()
    set_bg(bg); term.setCursorPos(1, y); term.write(string.rep(" ", w))
end

local function write_at(x, y, s, fg, bg)
    term.setCursorPos(x, y)
    if fg then set_fg(fg) end
    if bg then set_bg(bg) end
    term.write(tostring(s or ""))
end

local function clear_screen()
    set_bg(T.bg); set_fg(T.fg); term.clear()
end

local function draw_title_bar(title, right_text)
    local w = screen_wh()
    fill_line(1, T.title_bg)
    title = tostring(title or "")
    local right = right_text and tostring(right_text) or ""
    local right_budget = (right ~= "" and (#right + 4) <= (w - 3)) and #right or 0
    local title_max = w - 2 - (right_budget > 0 and right_budget + 2 or 0)
    write_at(2, 1, util.truncate(title, title_max), T.title_fg, T.title_bg)
    if right_budget > 0 then
        write_at(w - right_budget, 1, right, T.title_fg, T.title_bg)
    end
    set_bg(T.bg); set_fg(T.fg)
end

local function draw_footer_bar(text)
    local w, h = term.getSize()
    fill_line(h, T.footer_bg)
    write_at(2, h, util.truncate(tostring(text or ""), w - 3), T.footer_fg, T.footer_bg)
    set_bg(T.bg); set_fg(T.fg)
end

local function draw_section(y, text)
    local w = screen_wh()
    fill_line(y, T.bg)
    write_at(2, y, "-- ", T.section, T.bg)
    local max = math.max(4, w - 5 - 2)
    local shown = util.truncate(tostring(text or ""), max)
    write_at(5, y, shown, T.section, T.bg)
    local trail_x = 5 + #shown + 1
    if trail_x < w - 1 then
        write_at(trail_x, y, " " .. string.rep("-", w - trail_x - 1), T.section, T.bg)
    end
end

-- --- page schema --------------------------------------------------------

local SHARED_PAGE = {
    id = "shared", title = "Shared",
    get = function(all, k) return all[k] end,
    set = function(all, k, v) all[k] = v end,
    fields = {
        {
            key  = "network_id", label = "network_id", kind = "text",
            help = "Per-world 'team' tag. Every packet is stamped with this; receivers silently drop mismatches. Use a unique value per deployment to keep multiple dashboards isolated on the same ender-modem broadcast domain.",
        },
    },
}

local function component_page(id, title, fields)
    return {
        id = id, title = title, fields = fields,
        get = function(all, k) return (all[id] or {})[k] end,
        set = function(all, k, v) all[id] = all[id] or {}; all[id][k] = v end,
    }
end

local COLLECTOR_PAGE = component_page("collector", "Collector", {
    { key = "peripheral",   label = "peripheral",   kind = "peripheral", ptype = "flux_accessor_ext",
      help = "Which flux_accessor_ext to read. Leave 'auto' to pick the first one found at startup." },
    { key = "tick_seconds", label = "tick_seconds", kind = "number",
      help = "How often the collector reads the accessor and broadcasts its state. Default 1 second." },
})

local CORE_PAGE = component_page("core", "Core", {
    { key = "broadcast_interval_ms", label = "broadcast_ms", kind = "number",
      help = "Cadence at which the core publishes an aggregate to panels. Default 1000 ms." },
    { key = "persist_interval_ms",   label = "persist_ms",   kind = "number",
      help = "Cadence for writing lifetime counters to disk. Default 30000 ms (30 s)." },
    { key = "stale_ms",              label = "stale_ms",     kind = "number",
      help = "After this many ms without an update, a collector is flagged stale on the status canvas. Default 5000." },
    { key = "state_file",            label = "state_file",   kind = "text",
      help = "Disk path for lifetime counters. Default /edash_core.dat." },
    { key = "log_file",              label = "log_file",     kind = "text",
      help = "Disk path for log output. Default /edash_core.log." },
})

local PANEL_PAGE = component_page("panel", "Panel", {
    { key = "monitor",   label = "monitor",   kind = "peripheral", ptype = "monitor",
      help = "Which monitor to draw the dashboard on. Leave 'auto' to pick the first one found." },
    { key = "rate_unit", label = "rate_unit", kind = "enum", options = { "t", "s" },
      help = "Unit for displayed rate: /t (per Minecraft tick, 20/s) or /s (per real-time second). Press Enter to toggle." },
    { key = "redraw_ms", label = "redraw_ms", kind = "number",
      help = "Cadence at which the monitor is re-rendered. Default 250 ms." },
    { key = "stale_ms",  label = "stale_ms",  kind = "number",
      help = "After this many ms with no aggregate from the core, the status pill shows STALE. Default 5000." },
    { key = "theme",     label = "theme",     kind = "text",
      help = "Named colour palette. Only 'default' is defined right now." },
})

-- --- installed-components detection -------------------------------------

local function installed_components()
    local present = {}
    if fs.exists("/.edi_state") then
        local f = fs.open("/.edi_state", "r")
        if f then
            local data = f.readAll(); f.close()
            local ok, s = pcall(textutils.unserialise, data)
            if ok and type(s) == "table" and type(s.installed) == "table" then
                for n in pairs(s.installed) do present[n] = true end
            end
        end
    end
    if fs.exists("collector.lua") then present.collector = true end
    if fs.exists("core.lua")      then present.core      = true end
    if fs.exists("panel.lua")     then present.panel     = true end
    return present
end

local function build_pages()
    local pages = { SHARED_PAGE }
    local present = installed_components()
    if present.collector then pages[#pages + 1] = COLLECTOR_PAGE end
    if present.core      then pages[#pages + 1] = CORE_PAGE      end
    if present.panel     then pages[#pages + 1] = PANEL_PAGE     end
    return pages
end

-- --- value formatting / changed detection -------------------------------

local function value_text(field, v)
    if v == nil then
        if field.kind == "peripheral" then return "auto" end
        return "(unset)"
    end
    if field.kind == "enum" then return "/" .. tostring(v) end
    return tostring(v)
end

local function default_for(page, field)
    if page.id == "shared" then return config.DEFAULTS[field.key] end
    return (config.DEFAULTS[page.id] or {})[field.key]
end

local function is_changed(page, field, current)
    return current ~= default_for(page, field)
end

-- --- inline input bar (replaces footer while editing) -------------------

local function prompt_inline(label, current)
    local w, h = term.getSize()
    fill_line(h - 1, T.bg)
    fill_line(h,     T.footer_bg)
    local prefix = tostring(label or "value") .. ":  "
    write_at(2, h - 1, prefix, T.accent, T.bg)
    write_at(2, h, " enter confirm    esc cancel    empty = keep", T.footer_fg, T.footer_bg)

    local input_x = 2 + #prefix
    local input_w = math.max(4, w - input_x - 1)

    local buf = ""
    while true do
        -- redraw input line
        fill_line(h - 1, T.bg)
        write_at(2, h - 1, prefix, T.accent, T.bg)
        if buf == "" and current ~= nil and current ~= "" then
            write_at(input_x, h - 1, util.truncate("(was " .. tostring(current) .. ")", input_w), T.dim, T.bg)
        else
            write_at(input_x, h - 1, util.truncate(buf, input_w), T.fg, T.bg)
        end
        term.setCursorPos(input_x + math.min(#buf, input_w), h - 1)
        set_fg(T.fg); set_bg(T.bg)

        local event, p1 = os.pullEvent()
        if event == "char" then
            buf = buf .. p1
        elseif event == "key" then
            if p1 == keys.enter then
                if buf == "" then return current, false end
                return buf, true
            elseif p1 == keys.backspace and #buf > 0 then
                buf = buf:sub(1, -2)
            elseif p1 == keys.escape then
                return current, false
            end
        end
    end
end

-- --- peripheral picker popup --------------------------------------------

local function pick_peripheral(label, current, ptype)
    local names = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == ptype then names[#names + 1] = name end
    end
    local rows = { "(auto-pick first available)" }
    for _, n in ipairs(names) do rows[#rows + 1] = n end

    local sel = 1
    for i, r in ipairs(rows) do
        if (i == 1 and current == nil) or r == current then sel = i end
    end

    while true do
        clear_screen()
        draw_title_bar("Pick " .. label, ptype)
        fill_line(2, T.bg)
        draw_section(3, "available " .. ptype .. "s")

        local w, h = screen_wh()
        for i, r in ipairs(rows) do
            local y = 4 + i - 1
            if y >= h - 1 then break end
            local bg = (i == sel) and T.sel_bg or T.bg
            local fg = (i == sel) and T.sel_fg or T.fg
            fill_line(y, bg)
            if i == sel then write_at(2, y, "\16", fg, bg) end
            write_at(4, y, util.truncate(r, w - 6), fg, bg)
            if (i == 1 and current == nil) or r == current then
                local tag = "(current)"
                write_at(w - #tag - 1, y, tag,
                    (i == sel) and T.sel_fg or T.dim, bg)
            end
        end

        draw_footer_bar(" \24\25  navigate     enter pick     esc cancel")

        local _, key = os.pullEvent("key")
        if     key == keys.up   and sel > 1       then sel = sel - 1
        elseif key == keys.down and sel < #rows   then sel = sel + 1
        elseif key == keys.enter then
            if sel == 1 then return nil, true end
            return rows[sel], true
        elseif key == keys.escape or key == keys.q then return current, false
        end
    end
end

-- --- page render --------------------------------------------------------

-- Draw a pill button at (x, y) and return { x, w, action, disabled }.
local function draw_button(x, y, label, bg_color, fg_color, disabled)
    local text = "[ " .. label .. " ]"
    local w = #text
    term.setCursorPos(x, y)
    if disabled then
        set_bg(colors.gray); set_fg(colors.lightGray)
    else
        set_bg(bg_color); set_fg(fg_color)
    end
    term.write(text)
    return { x = x, y = y, w = w, disabled = disabled }
end

-- Clickable button strip along the bottom row. Returns the hit-test list.
local function draw_button_strip(page_idx, total_pages)
    local w, h = term.getSize()
    fill_line(h, T.bg)

    local buttons = {}
    local x = 2

    -- Left side: prev / next (disabled at ends). Keep labels short so they
    -- all fit on pocket-sized terminals.
    local prev_disabled = (page_idx <= 1)
    local next_disabled = (page_idx >= total_pages)
    local b = draw_button(x, h, "< prev", colors.cyan, colors.black, prev_disabled)
    b.action = "prev"; buttons[#buttons + 1] = b
    x = x + b.w + 1

    b = draw_button(x, h, "next >", colors.cyan, colors.black, next_disabled)
    b.action = "next"; buttons[#buttons + 1] = b

    -- Right side: save (lime), cancel (red). Right-align so they hug the edge.
    local save_text = "[ save (s) ]"
    local cancel_text = "[ cancel (q) ]"
    local right_start = w - #cancel_text - #save_text - 1
    if right_start > x + 2 then
        b = draw_button(right_start, h, "save (s)", colors.lime, colors.black, false)
        b.action = "save"; buttons[#buttons + 1] = b
        b = draw_button(right_start + b.w + 1, h, "cancel (q)", colors.red, colors.black, false)
        b.action = "cancel"; buttons[#buttons + 1] = b
    end

    set_bg(T.bg); set_fg(T.fg)
    return buttons
end

-- Draw a page and return (field_row_ys, button_strip). field_row_ys maps
-- each visible field index to its screen y, used for click hit-testing.
local function draw_page(page, page_idx, total_pages, all_cfg, sel_field_idx)
    local w, h = term.getSize()
    clear_screen()
    draw_title_bar("Energy Dashboard Configure",
        string.format("page %d/%d", page_idx, total_pages))
    fill_line(2, T.bg)
    draw_section(3, page.title)

    local rows_y = 5
    local field_row_ys = {}
    for i, field in ipairs(page.fields) do
        local y = rows_y + i - 1
        if y >= h - 5 then break end
        field_row_ys[i] = y
        local current = page.get(all_cfg, field.key)
        local selected = (i == sel_field_idx)
        local bg = selected and T.sel_bg or T.bg
        local fg = selected and T.sel_fg or T.fg
        fill_line(y, bg)
        if selected then write_at(2, y, "\16", T.sel_fg, T.sel_bg) end

        local label_w = 18
        write_at(4, y, util.pad(field.label, label_w), fg, bg)

        local vtext = value_text(field, current)
        local value_fg = fg
        if not selected and is_changed(page, field, current) then
            value_fg = T.changed
        end
        local value_max = w - (4 + label_w) - 2
        write_at(4 + label_w, y, util.truncate(vtext, value_max), value_fg, bg)
    end

    -- Detail panel with help for the currently-selected field.
    local detail_y = h - 4
    draw_section(detail_y, "help")
    local current_field = page.fields[sel_field_idx]
    local help = current_field and current_field.help or ""
    local lines = util.wrap(help, w - 3)
    for i = 1, 3 do
        fill_line(detail_y + i, T.bg)
        if lines[i] then write_at(2, detail_y + i, lines[i], T.dim, T.bg) end
    end

    local buttons = draw_button_strip(page_idx, total_pages)
    return field_row_ys, buttons
end

-- --- per-field editing --------------------------------------------------

local function edit_field(page, field, all_cfg)
    local current = page.get(all_cfg, field.key)

    if field.kind == "text" then
        local v, ok = prompt_inline(field.label, current)
        if ok then page.set(all_cfg, field.key, v) end

    elseif field.kind == "number" then
        local v, ok = prompt_inline(field.label, current)
        if ok then
            local n = tonumber(v)
            if n then page.set(all_cfg, field.key, n) end
        end

    elseif field.kind == "enum" then
        local opts = field.options or {}
        local idx = 1
        for i, o in ipairs(opts) do if o == current then idx = i; break end end
        page.set(all_cfg, field.key, opts[(idx % #opts) + 1])

    elseif field.kind == "peripheral" then
        local v, ok = pick_peripheral(field.label, current, field.ptype)
        if ok then page.set(all_cfg, field.key, v) end
    end
end

-- --- main loop ----------------------------------------------------------

local function main()
    local pages = build_pages()
    if #pages == 0 then
        clear_screen()
        draw_title_bar("Configure")
        fill_line(2, T.bg)
        for i, line in ipairs(util.wrap(
            "nothing appears to be installed on this computer. Run 'pastebin run F3bHqTDi' first, then re-run configure.",
            screen_wh() - 4)) do
            write_at(2, 3 + i, line, T.dim, T.bg)
        end
        draw_footer_bar(" press any key")
        os.pullEvent("key")
        return
    end

    local all_cfg   = config.load_all()
    local page_idx  = 1
    local field_idx = 1

    local function do_save()
        local ok, err = config.save_all(all_cfg)
        clear_screen()
        draw_title_bar("Configure")
        fill_line(2, T.bg)
        if ok then
            write_at(2, 4, "saved to " .. config.FILE, T.ok, T.bg)
            write_at(2, 5, "restart component(s) to apply.", T.dim, T.bg)
        else
            write_at(2, 4, "save failed: " .. tostring(err), T.err, T.bg)
        end
        draw_footer_bar(" press any key")
        os.pullEvent("key")
    end

    local function do_cancel()
        clear_screen()
        set_fg(T.dim); print("discarded."); set_fg(T.fg)
    end

    while true do
        local page = pages[page_idx]
        if field_idx > #page.fields then field_idx = #page.fields end
        if field_idx < 1 then field_idx = 1 end
        local field_row_ys, buttons = draw_page(page, page_idx, #pages, all_cfg, field_idx)

        local event, p1, p2, p3 = os.pullEvent()

        if event == "key" then
            local key = p1
            if     key == keys.up    and field_idx > 1            then field_idx = field_idx - 1
            elseif key == keys.down  and field_idx < #page.fields then field_idx = field_idx + 1
            elseif key == keys.left  and page_idx  > 1            then page_idx = page_idx - 1; field_idx = 1
            elseif key == keys.right and page_idx  < #pages       then page_idx = page_idx + 1; field_idx = 1
            elseif key == keys.tab   and page_idx  < #pages       then page_idx = page_idx + 1; field_idx = 1
            elseif key == keys.enter then
                edit_field(page, page.fields[field_idx], all_cfg)
            elseif key == keys.s then do_save(); return
            elseif key == keys.q then do_cancel(); return
            end

        elseif event == "mouse_click" and p1 == 1 then
            local x, y = p2, p3

            -- Footer button strip hit-test
            local handled = false
            for _, b in ipairs(buttons or {}) do
                if y == b.y and x >= b.x and x < b.x + b.w and not b.disabled then
                    if     b.action == "prev"   and page_idx > 1      then page_idx = page_idx - 1; field_idx = 1
                    elseif b.action == "next"   and page_idx < #pages then page_idx = page_idx + 1; field_idx = 1
                    elseif b.action == "save"                          then do_save(); return
                    elseif b.action == "cancel"                        then do_cancel(); return
                    end
                    handled = true
                    break
                end
            end

            -- Field-row hit-test: click anywhere on a field row selects and
            -- starts editing that field in one step (single-click UX).
            if not handled then
                for i, row_y in ipairs(field_row_ys or {}) do
                    if y == row_y then
                        field_idx = i
                        edit_field(page, page.fields[i], all_cfg)
                        break
                    end
                end
            end

        elseif event == "mouse_scroll" then
            local dir = p1
            if dir < 0 and field_idx > 1              then field_idx = field_idx - 1
            elseif dir > 0 and field_idx < #page.fields then field_idx = field_idx + 1 end
        end
    end
end

local ok, err = pcall(main)
set_bg(colors.black); set_fg(colors.white); term.setCursorPos(1, 1)
if not ok then print("configure crashed: " .. tostring(err)) end
