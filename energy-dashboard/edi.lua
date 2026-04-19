-- ============================================================
-- edi - Energy Dashboard Installer
-- ============================================================
--
-- Upload this single file to pastebin, then in-game:
--   pastebin run <CODE>
--
-- Installs one of the dashboard components (collector / core / panel)
-- driven by build/manifest.json on GitHub. After a successful install
-- it writes /startup.lua so the component auto-runs on every boot; the
-- component itself launches `configure` on first run if no config
-- file exists yet (scada-mek-style first-run wizard).
--
-- State lives in /.edi_state (plain Lua-serialised table) so update and
-- uninstall know what was previously installed on this computer.

local MANIFEST_URL = "https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/build/manifest.json"
local STATE_FILE   = "/.edi_state"
local STARTUP_FILE = "/startup.lua"

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

    install       = colors.lime,
    reinstall     = colors.yellow,
    update        = colors.cyan,
    uninstall     = colors.red,
    back          = colors.lightGray,
    exit          = colors.lightGray,

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
    set_bg(bg)
    term.setCursorPos(1, y)
    term.write(string.rep(" ", w))
end

local function pad_right(s, w)
    if #s >= w then return s:sub(1, w) end
    return s .. string.rep(" ", w - #s)
end

-- Word-wrap text to an array of lines of max width `w`.
local function wrap(text, w)
    if not text or text == "" or w < 1 then return {} end
    local lines, current = {}, ""
    for word in tostring(text):gmatch("%S+") do
        if current == "" then current = word
        elseif #current + 1 + #word <= w then current = current .. " " .. word
        else lines[#lines + 1] = current; current = word end
    end
    if current ~= "" then lines[#lines + 1] = current end
    return lines
end

-- Truncate with ".." suffix if text wouldn't fit in `w` columns.
local function truncate(text, w)
    text = tostring(text or "")
    if #text <= w then return text end
    if w <= 2 then return text:sub(1, w) end
    local cut = text:sub(1, w - 2)
    local ws = cut:find(" [^ ]*$")
    if ws and ws > math.floor((w - 2) * 0.5) then cut = cut:sub(1, ws - 1) end
    return cut .. ".."
end

local function write_at(x, y, s, fg, bg)
    term.setCursorPos(x, y)
    if fg then set_fg(fg) end
    if bg then set_bg(bg) end
    term.write(s)
end

local function draw_title_bar(title, right_text)
    local w = screen_wh()
    fill_line(1, T.title_bg)
    title = tostring(title or "")
    local right = right_text and tostring(right_text) or ""
    -- Reserve space for right_text if it fits alongside the title (min 4
    -- cols of gap + the right text itself); otherwise drop it.
    local right_budget = (right ~= "" and (#right + 4) <= (w - 2 - 1)) and #right or 0
    local title_max = w - 2 - (right_budget > 0 and right_budget + 2 or 0)
    write_at(2, 1, truncate(title, title_max), T.title_fg, T.title_bg)
    if right_budget > 0 then
        write_at(w - right_budget, 1, right, T.title_fg, T.title_bg)
    end
    set_bg(T.bg); set_fg(T.fg)
end

local function draw_footer_bar(text)
    local w, h = term.getSize()
    fill_line(h, T.footer_bg)
    write_at(2, h, truncate(tostring(text or ""), w - 3), T.footer_fg, T.footer_bg)
    set_bg(T.bg); set_fg(T.fg)
end

local function draw_section(y, text)
    local w = screen_wh()
    set_bg(T.bg)
    term.setCursorPos(2, y); term.write(string.rep(" ", w - 2))  -- clear the row
    write_at(2, y, "-- ", T.section, T.bg)
    -- Truncate title to the space between "-- " (col 5) and the right edge,
    -- leaving a couple cols for a trailing dash.
    local title_max = math.max(4, w - 5 - 2)
    local shown = truncate(tostring(text or ""), title_max)
    write_at(5, y, shown, T.section, T.bg)
    local trail_x = 5 + #shown + 1
    if trail_x < w - 1 then
        write_at(trail_x, y, " " .. string.rep("-", w - trail_x - 1), T.section, T.bg)
    end
end

local function clear_screen()
    set_bg(T.bg); set_fg(T.fg)
    term.clear()
end

-- --- menu item ----------------------------------------------------------

-- Item shape:
--   { tag = "[install] ", tag_color = T.install, label = "collector",
--     desc = "…",         action = "install", component = "collector" }
--
-- Special forms:
--   { section = "Components" }  - non-selectable section header
--   { spacer = true }           - non-selectable empty row

local function is_selectable(it)
    return not it.section and not it.spacer
end

local function draw_menu_item(y, it, selected)
    local w = screen_wh()
    if it.section then
        draw_section(y, it.section)
        return
    end
    if it.spacer then
        fill_line(y, T.bg)
        return
    end

    local bg = selected and T.sel_bg or T.bg
    local fg = selected and T.sel_fg or T.fg

    fill_line(y, bg)

    -- cursor chevron when selected
    if selected then
        write_at(2, y, "\16", T.sel_fg, T.sel_bg)   -- char 16 = ► in CC charset
    end

    -- Budget the row: 1 col cursor gutter + tag + label + (gap + desc) → w-1
    local x = 4
    local right_edge = w - 1
    local desc_present = it.desc and it.desc ~= ""

    -- tag with semantic colour (but respect selection)
    if it.tag then
        local tag_fg = selected and T.sel_fg or (it.tag_color or T.fg)
        local tag = truncate(it.tag, math.max(0, right_edge - x))
        write_at(x, y, tag, tag_fg, bg)
        x = x + #tag
    end

    -- Label. If a description exists, reserve the last ~third of the row
    -- for it (with a 2-col gap) so the label doesn't eat the whole line.
    local label = tostring(it.label or "")
    local label_budget
    if desc_present then
        label_budget = math.max(4, math.floor((right_edge - x) * 0.55))
    else
        label_budget = right_edge - x
    end
    label = truncate(label, label_budget)
    write_at(x, y, label, fg, bg)
    x = x + #label

    -- description (dim, right-trailing, word-safe truncation)
    if desc_present and x + 2 < right_edge then
        local max = right_edge - x - 2
        write_at(x + 2, y, truncate(it.desc, max),
                 selected and T.sel_fg or T.dim, bg)
    end
end

-- --- arrow-key menu -----------------------------------------------------

local function first_selectable(items)
    for i, it in ipairs(items) do if is_selectable(it) then return i end end
    return 1
end
local function last_selectable(items)
    local last = 1
    for i, it in ipairs(items) do if is_selectable(it) then last = i end end
    return last
end

local function arrow_menu(items, title, right_text, footer_text)
    local sel = first_selectable(items)
    while true do
        clear_screen()
        draw_title_bar(title or "Energy Dashboard Installer", right_text)
        -- spacer row
        fill_line(2, T.bg)

        local _, h = screen_wh()
        local start_y = 3
        local max_rows = h - start_y - 1   -- leave room for footer

        -- simple viewport: show items from 1 and trust that we fit for now.
        -- If the list grows long we can add scrolling later.
        local offset = 0
        if #items > max_rows then offset = math.min(sel - 1, #items - max_rows) end

        for i = 1, math.min(max_rows, #items) do
            local idx = i + offset
            local it = items[idx]
            if it then draw_menu_item(start_y + i - 1, it, idx == sel) end
        end

        draw_footer_bar(footer_text or " \24\25  navigate     enter select     q  quit")

        local _, key = os.pullEvent("key")
        if key == keys.up then
            local i = sel - 1
            while i >= 1 and not is_selectable(items[i]) do i = i - 1 end
            if i >= 1 then sel = i end
        elseif key == keys.down then
            local i = sel + 1
            while i <= #items and not is_selectable(items[i]) do i = i + 1 end
            if i <= #items then sel = i end
        elseif key == keys.home then sel = first_selectable(items)
        elseif key == keys.end_ then sel = last_selectable(items)
        elseif key == keys.enter then return items[sel]
        elseif key == keys.q then return nil
        end
    end
end

-- --- state (what's installed) -------------------------------------------

local function load_state()
    if not fs.exists(STATE_FILE) then return { installed = {} } end
    local f = fs.open(STATE_FILE, "r"); if not f then return { installed = {} } end
    local data = f.readAll(); f.close()
    local ok, s = pcall(textutils.unserialise, data)
    if not ok or type(s) ~= "table" then return { installed = {} } end
    s.installed = s.installed or {}
    return s
end

local function save_state(s)
    local f = fs.open(STATE_FILE, "w"); if not f then return false end
    f.write(textutils.serialise(s)); f.close()
    return true
end

-- --- manifest -----------------------------------------------------------

local function fetch_manifest()
    clear_screen()
    draw_title_bar("Energy Dashboard Installer", "starting")
    fill_line(2, T.bg)
    local label = "Fetching manifest..."
    write_at(2, 4, label, T.dim, T.bg)

    -- Status column follows the label + a 2-col gap. Was hardcoded to col 26,
    -- which overflowed on narrow pocket terminals.
    local w = screen_wh()
    local status_x = math.min(2 + #label + 2, w - 10)

    local res = http.get(MANIFEST_URL)
    if not res then
        write_at(status_x, 4, "FAILED", T.err, T.bg)
        local msg = wrap("Could not reach GitHub. Check the http allow-list in your CC:Tweaked config, and verify the server is online.", w - 4)
        for i, line in ipairs(msg) do
            write_at(2, 5 + i, line, T.err, T.bg)
        end
        return nil
    end
    local body = res.readAll(); res.close()
    local ok, m = pcall(textutils.unserialiseJSON, body)
    if not ok or type(m) ~= "table" or type(m.components) ~= "table" then
        write_at(status_x, 4, "PARSE FAIL", T.err, T.bg)
        return nil
    end
    write_at(status_x, 4, "OK", T.ok, T.bg)
    -- Version tag after another small gap; skip if no room.
    local ver_x = status_x + 4
    if ver_x + 8 < w then
        write_at(ver_x, 4, "v" .. tostring(m.version or "?"), T.dim, T.bg)
    end
    return m
end

-- --- file ops -----------------------------------------------------------

local function download(url, target)
    local dir = fs.getDir(target)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local res = http.get(url); if not res then return false, "http.get failed" end
    local body = res.readAll(); res.close()
    local f = fs.open(target, "w"); if not f then return false, "cannot open " .. target end
    f.write(body); f.close()
    return true, #body
end

local function write_startup(main)
    -- /startup.lua detects which component is present and runs it.
    -- Works even if multiple main files are on disk (unusual).
    local f = fs.open(STARTUP_FILE, "w")
    if not f then return false end
    f.writeLine("-- edash startup - generated by edi. Safe to delete to disable auto-run.")
    f.writeLine("for _, name in ipairs({\"" .. main .. "\", \"collector.lua\", \"core.lua\", \"panel.lua\"}) do")
    f.writeLine("  if fs.exists(name) then shell.run(name); return end")
    f.writeLine("end")
    f.close()
    return true
end

local function install_component(manifest, name)
    local c = manifest.components[name]
    if not c then return false end

    clear_screen()
    draw_title_bar("Installing " .. name, "v" .. tostring(manifest.version or "?"))
    fill_line(2, T.bg)
    -- Description may be long; wrap it so it doesn't overflow the screen.
    local w_hdr = screen_wh()
    for dli, dline in ipairs(wrap(c.description or "", w_hdr - 3)) do
        write_at(2, 3 + dli, dline, T.dim, T.bg)
    end

    local total = #c.files
    local installed_files = {}
    for i, file in ipairs(c.files) do
        local y = 6 + i - 1
        local w = screen_wh()

        -- step prefix
        local step = string.format("  [%d/%d]  ", i, total)
        write_at(2, y, step, T.dim, T.bg)

        -- Reserve 10 cols at right for status ("OK 1234B" / "FAILED"), plus
        -- one col gap on each side. Truncate filename into whatever remains.
        local status_x = w - 10
        local name_start = 2 + #step
        local name_budget = math.max(4, status_x - name_start - 2)
        local shown_name = truncate(file.dst, name_budget)
        write_at(name_start, y, shown_name, T.fg, T.bg)

        -- dots filler between the name and the status column
        local dots_x = name_start + #shown_name + 1
        local dots_w = math.max(0, status_x - dots_x - 1)
        write_at(dots_x, y, string.rep(".", dots_w), T.dim, T.bg)

        local url = manifest.repo .. "/" .. file.src
        local ok, sz = download(url, file.dst)
        if ok then
            write_at(status_x, y, pad_right(string.format("OK %dB", sz), 10), T.ok, T.bg)
            installed_files[#installed_files + 1] = file.dst
        else
            write_at(status_x, y, "FAILED", T.err, T.bg)
            local tw = screen_wh()
            local msg_lines = wrap("error: " .. tostring(sz), tw - 4)
            for li, line in ipairs(msg_lines) do
                fill_line(y + 1 + li, T.bg)
                write_at(2, y + 1 + li, line, T.err, T.bg)
            end
            draw_footer_bar(" press any key to return to menu")
            os.pullEvent("key")
            return false
        end
    end

    -- write startup
    local start_y = 6 + total + 1
    write_at(2, start_y, "  /startup.lua  ", T.dim, T.bg)
    if write_startup(c.main) then
        write_at(2 + 16, start_y, "OK", T.ok, T.bg)
    else
        write_at(2 + 16, start_y, "WARN", T.warn, T.bg)
    end

    -- record state
    local state = load_state()
    state.installed[name] = {
        version      = manifest.version,
        files        = installed_files,
        main         = c.main,
        installed_at = os.epoch("utc"),
    }
    save_state(state)

    -- success summary - wrap so it fits on narrow terminals
    local summary_y = start_y + 2
    local tw = screen_wh()
    local run_cmd = c.main:gsub("%.lua$", "")
    for li, line in ipairs(wrap("Installed " .. name .. ". Run with: " .. run_cmd, tw - 4)) do
        fill_line(summary_y + li - 1, T.bg)
        write_at(2, summary_y + li - 1, line, T.ok, T.bg)
    end
    local hint_y = summary_y + #wrap("Installed " .. name .. ". Run with: " .. run_cmd, tw - 4)
    for li, line in ipairs(wrap("Reboot or press Enter - first run will launch 'configure'.", tw - 4)) do
        fill_line(hint_y + li - 1, T.bg)
        write_at(2, hint_y + li - 1, line, T.dim, T.bg)
    end

    draw_footer_bar(" press any key to return to menu")
    os.pullEvent("key")
    return true
end

local function uninstall_component(name)
    local state = load_state()
    local rec = state.installed[name]
    if not rec then return false end

    clear_screen()
    draw_title_bar("Uninstalling " .. name)
    fill_line(2, T.bg)

    local y = 4
    for _, path in ipairs(rec.files or {}) do
        if fs.exists(path) then
            fs.delete(path)
            write_at(2, y, "  removed  ", T.dim, T.bg)
            write_at(13, y, path, T.fg, T.bg)
            y = y + 1
        end
    end
    state.installed[name] = nil
    save_state(state)
    fill_line(y + 1, T.bg)
    write_at(2, y + 1, "Done. /startup.lua left in place in case other components remain.",
             T.ok, T.bg)
    draw_footer_bar(" press any key")
    os.pullEvent("key")
    return true
end

local function update_all(manifest)
    local state = load_state()
    local names = {}
    for n in pairs(state.installed) do names[#names + 1] = n end
    if #names == 0 then
        clear_screen()
        draw_title_bar("Update")
        fill_line(2, T.bg)
        write_at(2, 4, "nothing installed yet - pick [install] from the menu first.",
                 T.dim, T.bg)
        draw_footer_bar(" press any key")
        os.pullEvent("key")
        return
    end
    for _, n in ipairs(names) do install_component(manifest, n) end
end

-- --- menu builders ------------------------------------------------------

local function tag_for_install(installed)
    if installed then
        return "[reinstall] ", T.reinstall
    else
        return "[install]   ", T.install
    end
end

local function build_main_menu(manifest)
    local state = load_state()
    local items = { { section = "Components" } }

    local names = {}
    for n in pairs(manifest.components) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do
        local c = manifest.components[n]
        local installed = state.installed[n] ~= nil
        local tag, tag_color = tag_for_install(installed)
        items[#items + 1] = {
            tag = tag, tag_color = tag_color,
            label = pad_right(n, 11),
            desc  = c.description or "",
            action = "install", component = n,
        }
    end

    items[#items + 1] = { spacer = true }
    items[#items + 1] = { section = "Actions" }
    items[#items + 1] = {
        tag = "[update]    ", tag_color = T.update,
        label = pad_right("all installed", 14),
        desc  = "re-fetch every component currently on disk",
        action = "update",
    }
    items[#items + 1] = {
        tag = "[uninstall] ", tag_color = T.uninstall,
        label = pad_right("...", 14),
        desc  = "remove an installed component",
        action = "uninstall_menu",
    }
    items[#items + 1] = {
        tag = "[exit]      ", tag_color = T.exit,
        label = "",
        action = "quit",
    }
    return items
end

local function build_uninstall_menu()
    local state = load_state()
    local items = { { section = "Uninstall" } }
    local names = {}
    for n in pairs(state.installed) do names[#names + 1] = n end
    table.sort(names)
    if #names == 0 then
        items[#items + 1] = {
            tag = "            ", label = "(nothing installed)",
        }
    else
        for _, n in ipairs(names) do
            items[#items + 1] = {
                tag = "[uninstall] ", tag_color = T.uninstall,
                label = n,
                action = "uninstall", component = n,
            }
        end
    end
    items[#items + 1] = { spacer = true }
    items[#items + 1] = {
        tag = "[back]      ", tag_color = T.back,
        label = "",
        action = "back",
    }
    return items
end

-- --- main ---------------------------------------------------------------

local function status_line(manifest)
    local state = load_state()
    local n = 0
    for _ in pairs(state.installed) do n = n + 1 end
    return string.format("manifest v%s  %d installed",
        tostring(manifest.version or "?"), n)
end

local function main()
    local manifest = fetch_manifest()
    if not manifest then
        draw_footer_bar(" press any key")
        os.pullEvent("key")
        clear_screen(); return
    end

    while true do
        local choice = arrow_menu(
            build_main_menu(manifest),
            "Energy Dashboard Installer",
            status_line(manifest),
            " \24\25  navigate     enter select     q  quit"
        )
        if not choice or choice.action == "quit" then
            clear_screen(); return
        elseif choice.action == "install" then
            install_component(manifest, choice.component)
        elseif choice.action == "update" then
            update_all(manifest)
        elseif choice.action == "uninstall_menu" then
            while true do
                local sub = arrow_menu(build_uninstall_menu(),
                    "Energy Dashboard Installer", "uninstall",
                    " \24\25  navigate     enter select     q  back")
                if not sub or sub.action == "back" then break end
                if sub.action == "uninstall" then uninstall_component(sub.component) end
            end
        end
    end
end

local ok, err = pcall(main)
set_bg(colors.black); set_fg(colors.white)
if not ok then print("edi crashed: " .. tostring(err)) end
