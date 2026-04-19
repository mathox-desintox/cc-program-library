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

    -- Field value "pill" colours (mek-scada-style: each value sits in a
    -- coloured box so it's obvious it's interactive. State colours:
    --   normal   : gray pill, white text
    --   selected : cyan pill, black text (row is also highlighted)
    --   changed  : yellow pill when the value differs from the default
    --              (only applied in the unselected state so the
    --              selection colour never gets drowned out)
    pill_bg           = colors.gray,
    pill_fg           = colors.white,
    pill_sel_bg       = colors.cyan,
    pill_sel_fg       = colors.black,
    pill_changed_bg   = colors.yellow,
    pill_changed_fg   = colors.black,
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
    { key = "default_horizon", label = "default_horizon", kind = "enum",
      options = { "m1", "m5", "m15", "h1", "h8", "h24" },
      help = "Which time window the chart/stats use at startup. Click tabs on the monitor to change live." },
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

-- String shown inside the pill for a given field value. Kind-aware:
-- peripherals default to "auto" instead of empty; enums and text/number
-- just stringify the current value. No surrounding brackets or arrows —
-- the coloured pill background carries the "interactive" affordance.
local function value_text(field, v)
    if field.kind == "peripheral" then
        return (v == nil) and "auto" or tostring(v)
    end
    if v == nil or v == "" then return "(unset)" end
    return tostring(v)
end

-- Pick pill colours for a value given row state. `changed` overrides the
-- normal colouring when the row is NOT selected so the user can see at
-- a glance which fields differ from defaults.
local function pill_colors(selected, changed)
    if selected then return T.pill_sel_bg, T.pill_sel_fg end
    if changed  then return T.pill_changed_bg, T.pill_changed_fg end
    return T.pill_bg, T.pill_fg
end

local function default_for(page, field)
    if page.id == "shared" then return config.DEFAULTS[field.key] end
    return (config.DEFAULTS[page.id] or {})[field.key]
end

local function is_changed(page, field, current)
    return current ~= default_for(page, field)
end

-- --- inline text editor -------------------------------------------------
--
-- Takes over the value area of a single field row and lets the user type
-- a replacement directly. Highlighted distinct from the row's selection
-- styling so they can see they're in edit mode. Enter commits, Esc cancels,
-- clicking outside the field commits. Left/right/home/end move the cursor.

local function inline_edit_text(y, x_start, w_budget, current, is_number)
    local buf = tostring(current == nil and "" or current)
    local cursor = #buf + 1
    -- Pill has 1 col of padding on each side; the inner text area fits the
    -- remaining budget.
    local max_text = math.max(3, w_budget - 2)

    local function render_box()
        term.setCursorPos(x_start, y)
        set_bg(T.pill_changed_bg); set_fg(T.pill_changed_fg)
        -- Horizontal scroll: keep cursor visible within max_text cols.
        local win_start = 1
        if cursor > max_text then win_start = cursor - max_text + 1 end
        local display = buf:sub(win_start, win_start + max_text - 1)
        term.write(" " .. display .. string.rep(" ", max_text - #display) .. " ")
        -- Position the blinking cursor just after the typed content.
        local cx = x_start + 1 + (cursor - win_start)
        term.setCursorPos(math.min(cx, x_start + 1 + max_text), y)
        term.setCursorBlink(true)
    end

    while true do
        render_box()
        local event, p1, p2, p3 = os.pullEvent()

        if event == "char" then
            buf = buf:sub(1, cursor - 1) .. p1 .. buf:sub(cursor)
            cursor = cursor + 1
        elseif event == "key" then
            if p1 == keys.enter then
                term.setCursorBlink(false)
                if is_number then
                    local n = tonumber(buf)
                    if n then return n, true end
                    return current, false
                end
                return buf, true
            elseif p1 == keys.escape then
                term.setCursorBlink(false); return current, false
            elseif p1 == keys.backspace and cursor > 1 then
                buf = buf:sub(1, cursor - 2) .. buf:sub(cursor); cursor = cursor - 1
            elseif p1 == keys.delete and cursor <= #buf then
                buf = buf:sub(1, cursor - 1) .. buf:sub(cursor + 1)
            elseif p1 == keys.left and cursor > 1       then cursor = cursor - 1
            elseif p1 == keys.right and cursor <= #buf  then cursor = cursor + 1
            elseif p1 == keys.home                      then cursor = 1
            elseif p1 == keys["end"]                    then cursor = #buf + 1
            end
        elseif event == "mouse_click" then
            -- Click outside the editable field commits what's typed.
            if p3 ~= y or p2 < x_start or p2 >= x_start + max_text + 2 then
                term.setCursorBlink(false)
                if is_number then
                    local n = tonumber(buf)
                    if n then return n, true end
                    return current, false
                end
                return buf, true
            end
            -- Click inside moves the cursor to the clicked column.
            local rel = p2 - (x_start + 1) + 1
            cursor = math.max(1, math.min(rel, #buf + 1))
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

        draw_footer_bar(" \24\25 navigate  |  enter pick  |  esc cancel")

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

    -- Right side: cancel always; save only on the last page (wizard flow —
    -- you can only finish from the end). Button labels are clean verbs;
    -- keyboard shortcuts are documented in the help panel / docs and work
    -- silently so we don't clutter the labels with "(s)" / "(q)".
    local on_last = (page_idx >= total_pages)
    local save_text   = "[ save ]"
    local cancel_text = "[ cancel ]"
    local right_width = #cancel_text + (on_last and (#save_text + 1) or 0)
    local right_start = w - right_width - 1

    if right_start > x + 2 then
        if on_last then
            b = draw_button(right_start, h, "save", colors.lime, colors.black, false)
            b.action = "save"; buttons[#buttons + 1] = b
            right_start = right_start + b.w + 1
        end
        b = draw_button(right_start, h, "cancel", colors.red, colors.black, false)
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
    local label_w = 18
    local field_geom = {}  -- i -> { y, x_value, w_budget, pill_w }
    for i, field in ipairs(page.fields) do
        local y = rows_y + i - 1
        if y >= h - 5 then break end
        local current  = page.get(all_cfg, field.key)
        local selected = (i == sel_field_idx)
        local changed  = is_changed(page, field, current)
        local row_bg   = selected and T.sel_bg or T.bg
        local row_fg   = selected and T.sel_fg or T.fg
        fill_line(y, row_bg)
        if selected then write_at(2, y, "\16", T.sel_fg, T.sel_bg) end

        write_at(4, y, util.pad(field.label, label_w), row_fg, row_bg)

        -- Draw the value pill: a coloured box with a single leading + trailing
        -- space of padding. Pill width adapts to the text but is bounded by
        -- the remaining row budget.
        local x_value   = 4 + label_w
        local w_budget  = w - x_value - 2
        local vtext     = value_text(field, current)
        local shown     = util.truncate(vtext, math.max(1, w_budget - 2))
        local pill_w    = #shown + 2  -- leading + trailing space
        local pill_bg, pill_fg = pill_colors(selected, changed)
        write_at(x_value, y, " " .. shown .. " ", pill_fg, pill_bg)
        -- Restore the row's background for anything drawn after the pill.
        set_bg(row_bg); set_fg(row_fg)

        field_geom[i] = { y = y, x_value = x_value, w_budget = w_budget, pill_w = pill_w }
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
    return field_geom, buttons
end

-- --- per-field editing --------------------------------------------------
--
-- `row_geom` is { y, x_value, w_budget } — the location of the value area
-- on the currently-rendered page. text/number fields turn that area into
-- an inline editable text box. enums cycle in place; peripherals open a
-- popup picker.

local function edit_field(page, field, all_cfg, row_geom)
    local current = page.get(all_cfg, field.key)

    if field.kind == "text" then
        local v, ok = inline_edit_text(row_geom.y, row_geom.x_value, row_geom.w_budget, current, false)
        if ok then page.set(all_cfg, field.key, v) end

    elseif field.kind == "number" then
        local v, ok = inline_edit_text(row_geom.y, row_geom.x_value, row_geom.w_budget, current, true)
        if ok then page.set(all_cfg, field.key, v) end

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

    -- Show a post-save / post-cancel completion screen with a [reboot]
    -- button alongside the usual "continue".
    local function completion_screen(lines_iter)
        clear_screen()
        draw_title_bar("Configure")
        fill_line(2, T.bg)
        local _, h = term.getSize()
        local y = 4
        for _, line in ipairs(lines_iter) do
            write_at(2, y, line.text, line.color or T.fg, T.bg)
            y = y + 1
        end

        -- Completion action strip (replaces the plain footer bar).
        fill_line(h, T.bg)
        local btns = {}
        local b = draw_button(2, h, "reboot now", colors.lime, colors.black, false)
        b.action = "reboot"; btns[#btns + 1] = b
        b = draw_button(2 + b.w + 1, h, "continue", colors.gray, colors.white, false)
        b.action = "continue"; btns[#btns + 1] = b
        set_bg(T.bg); set_fg(T.fg)

        while true do
            local event, p1, p2, p3 = os.pullEvent()
            if event == "key" then
                if p1 == keys.enter then os.reboot() end
                return
            elseif event == "mouse_click" and p1 == 1 then
                for _, bb in ipairs(btns) do
                    if p3 == bb.y and p2 >= bb.x and p2 < bb.x + bb.w then
                        if bb.action == "reboot" then os.reboot() end
                        return
                    end
                end
                return  -- click outside buttons = continue
            end
        end
    end

    local function do_save()
        local ok, err = config.save_all(all_cfg)
        if ok then
            completion_screen({
                { text = "saved to " .. config.FILE,        color = T.ok  },
                { text = "restart component(s) to apply.",  color = T.dim },
                { text = ""                                                },
                { text = "reboot now to auto-start them, or continue without.",
                                                             color = T.dim },
            })
        else
            completion_screen({
                { text = "save failed: " .. tostring(err),  color = T.err },
            })
        end
    end

    local function do_cancel()
        completion_screen({
            { text = "discarded - no changes written.",     color = T.dim },
        })
    end

    while true do
        local page = pages[page_idx]
        if field_idx > #page.fields then field_idx = #page.fields end
        if field_idx < 1 then field_idx = 1 end
        local field_geom, buttons = draw_page(page, page_idx, #pages, all_cfg, field_idx)
        local on_last_page = (page_idx == #pages)

        local event, p1, p2, p3 = os.pullEvent()

        if event == "key" then
            local key = p1
            if     key == keys.up    and field_idx > 1            then field_idx = field_idx - 1
            elseif key == keys.down  and field_idx < #page.fields then field_idx = field_idx + 1
            elseif key == keys.left  and page_idx  > 1            then page_idx = page_idx - 1; field_idx = 1
            elseif key == keys.right and page_idx  < #pages       then page_idx = page_idx + 1; field_idx = 1
            elseif key == keys.tab   and page_idx  < #pages       then page_idx = page_idx + 1; field_idx = 1
            elseif key == keys.enter then
                edit_field(page, page.fields[field_idx], all_cfg, field_geom[field_idx])
            elseif key == keys.s and on_last_page then do_save(); return
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

            -- Field hit-test: click on the row y starts editing THAT field.
            if not handled then
                for i, geom in pairs(field_geom or {}) do
                    if y == geom.y then
                        field_idx = i
                        edit_field(page, page.fields[i], all_cfg, geom)
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
