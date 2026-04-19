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

    -- Rows are label + tag only; the selected item's full description
    -- renders in the detail panel at the bottom of the screen (word-
    -- wrapped, multi-line). This avoids the inline-truncation problem.
    local x = 4
    local right_edge = w - 1

    if it.tag then
        local tag_fg = selected and T.sel_fg or (it.tag_color or T.fg)
        local tag = truncate(it.tag, math.max(0, right_edge - x))
        write_at(x, y, tag, tag_fg, bg)
        x = x + #tag
    end

    local label = tostring(it.label or "")
    label = truncate(label, math.max(0, right_edge - x))
    write_at(x, y, label, fg, bg)
end

-- Detail panel: shows the currently selected item's full description word-
-- wrapped across the reserved bottom rows. Called by arrow_menu after the
-- list is drawn. Takes the y of the divider row + the height of the panel.
local function draw_detail_panel(divider_y, height, text)
    local w = screen_wh()
    draw_section(divider_y, "detail")
    local lines = wrap(text or "", w - 3)
    for i = 1, height - 1 do
        fill_line(divider_y + i, T.bg)
        if lines[i] then
            write_at(2, divider_y + i, lines[i], T.dim, T.bg)
        end
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
    -- Layout state is re-computed per render so mouse-click hit-testing
    -- can reuse it. We stash it in `rendered` between draw + input.
    local rendered = { start_y = 3, max_rows = 0, offset = 0 }

    while true do
        clear_screen()
        draw_title_bar(title or "Energy Dashboard Installer", right_text)
        fill_line(2, T.bg)

        local _, h = screen_wh()
        local start_y = 3

        -- Reserve the bottom for a detail panel + a footer row. Falls back
        -- to list-only on very short terminals.
        local detail_height = 4
        local footer_reserve = 1
        local list_reserve = detail_height + footer_reserve
        local max_rows = math.max(1, h - start_y - list_reserve)
        if h - start_y - footer_reserve < detail_height + 3 then
            detail_height = 0
            max_rows = math.max(1, h - start_y - footer_reserve)
        end

        local offset = 0
        if #items > max_rows then offset = math.min(sel - 1, #items - max_rows) end

        rendered.start_y = start_y
        rendered.max_rows = max_rows
        rendered.offset = offset

        for i = 1, math.min(max_rows, #items) do
            local idx = i + offset
            local it = items[idx]
            if it then draw_menu_item(start_y + i - 1, it, idx == sel) end
        end

        if detail_height > 0 then
            local current = items[sel] or {}
            draw_detail_panel(h - footer_reserve - detail_height + 1, detail_height, current.desc or "")
        end

        draw_footer_bar(footer_text or " \24\25  nav  |  enter / click  select  |  q  quit")

        local event, p1, p2, p3 = os.pullEvent()

        if event == "key" then
            local key = p1
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

        elseif event == "mouse_click" and p1 == 1 then
            -- Left click: if the click falls on a selectable row, activate
            -- it (same as select + enter). Clicks outside the list do nothing.
            local _, cy = p2, p3
            local row = cy - rendered.start_y + 1
            if row >= 1 and row <= rendered.max_rows then
                local idx = row + rendered.offset
                local it = items[idx]
                if it and is_selectable(it) then
                    sel = idx
                    return it
                end
            end

        elseif event == "mouse_scroll" then
            -- p1 = direction (-1 up, +1 down). Advance selection in that
            -- direction, skipping non-selectable rows.
            local dir = p1
            if dir < 0 then
                local i = sel - 1
                while i >= 1 and not is_selectable(items[i]) do i = i - 1 end
                if i >= 1 then sel = i end
            elseif dir > 0 then
                local i = sel + 1
                while i <= #items and not is_selectable(items[i]) do i = i + 1 end
                if i <= #items then sel = i end
            end
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

-- --- cleanup (purge everything) -----------------------------------------

-- Runtime files edash components create that aren't tracked in /.edi_state.
-- Listed explicitly so the cleanup is exhaustive + predictable.
local AUX_FILES = {
    STATE_FILE,                    -- /.edi_state
    STARTUP_FILE,                  -- /startup.lua
    "/.edash_first_run_done",
    "/edash_config.lua",
    "/edash_core.dat",
    "/edash_core.log",
    "/edash_collector.log",
    "/edash_panel.log",
}
-- Directories we remove if empty after file deletion. Never recursive-delete
-- these — we only prune empty leftovers from edi installs.
local AUX_DIRS = { "/common", "/graphics" }

-- Gather the full cleanup set: (component_files, aux_files, dirs_to_try).
-- Only returns paths that currently exist.
local function gather_cleanup()
    local state = load_state()
    local installed_files = {}
    local seen = {}
    for _, rec in pairs(state.installed) do
        for _, path in ipairs(rec.files or {}) do
            if not seen[path] and fs.exists(path) then
                seen[path] = true
                installed_files[#installed_files + 1] = path
            end
        end
    end
    local aux_existing = {}
    for _, p in ipairs(AUX_FILES) do
        if fs.exists(p) and not seen[p] then aux_existing[#aux_existing + 1] = p end
    end
    local dirs_existing = {}
    for _, d in ipairs(AUX_DIRS) do
        if fs.exists(d) and fs.isDir(d) then dirs_existing[#dirs_existing + 1] = d end
    end
    return installed_files, aux_existing, dirs_existing
end

local function dir_is_empty(path)
    local list = fs.list(path)
    return not list or #list == 0
end

-- Show the confirm screen. Returns true if the user typed 'y'.
local function confirm_cleanup(installed_files, aux_files, dirs)
    clear_screen()
    draw_title_bar("Cleanup", "DESTRUCTIVE")
    fill_line(2, T.bg)

    local w, h = term.getSize()
    local y = 3
    draw_section(y, "about to delete"); y = y + 1

    local total = #installed_files + #aux_files
    if total == 0 and #dirs == 0 then
        fill_line(y + 1, T.bg)
        write_at(2, y + 1, "nothing to clean up on this computer.", T.dim, T.bg)
        draw_footer_bar(" press any key")
        os.pullEvent("key")
        return false
    end

    for i, line in ipairs(wrap(
        string.format("%d installed component file(s)   %d state/log file(s)   %d dir(s) (if empty)",
            #installed_files, #aux_files, #dirs), w - 3)) do
        write_at(2, y + i, line, T.fg, T.bg)
    end
    y = y + 3

    -- Abbreviated preview list; the full list can overflow any terminal so
    -- we just show up to a handful.
    local preview = {}
    for _, p in ipairs(installed_files) do preview[#preview + 1] = p end
    for _, p in ipairs(aux_files)       do preview[#preview + 1] = p end
    local shown = 0
    for _, p in ipairs(preview) do
        if y >= h - 6 then break end
        write_at(2, y, "  " .. p, T.dim, T.bg); y = y + 1
        shown = shown + 1
    end
    if #preview > shown then
        write_at(2, y, "  ... and " .. (#preview - shown) .. " more", T.dim, T.bg); y = y + 1
    end

    -- red banner at the bottom
    fill_line(h - 2, T.bg)
    write_at(2, h - 2, "This is permanent. Installed components will be removed,",
        T.err, T.bg)
    fill_line(h - 1, T.bg)
    write_at(2, h - 1, "state + logs wiped, startup hook deleted.",
        T.err, T.bg)

    draw_footer_bar(" y confirm delete    any other key cancel")

    local _, char = os.pullEvent("char")
    return char == "y" or char == "Y"
end

-- Perform the deletion. Returns (n_deleted, n_errors).
local function perform_cleanup(installed_files, aux_files, dirs)
    clear_screen()
    draw_title_bar("Cleanup")
    fill_line(2, T.bg)
    draw_section(3, "deleting")

    local w, h = term.getSize()
    local y = 4
    local deleted, errors = 0, 0

    local function delete_one(path)
        local visible = y < h - 2
        if visible then
            fill_line(y, T.bg)
            write_at(2, y, truncate("  " .. path, w - 10), T.dim, T.bg)
        end
        local ok = pcall(fs.delete, path)
        if ok and not fs.exists(path) then
            if visible then write_at(w - 8, y, "OK", T.ok, T.bg) end
            deleted = deleted + 1
        else
            if visible then write_at(w - 8, y, "FAILED", T.err, T.bg) end
            errors = errors + 1
        end
        y = y + 1
    end

    for _, p in ipairs(installed_files) do delete_one(p) end
    for _, p in ipairs(aux_files)       do delete_one(p) end
    for _, d in ipairs(dirs) do
        if fs.exists(d) and fs.isDir(d) and dir_is_empty(d) then delete_one(d) end
    end

    -- summary
    fill_line(h - 2, T.bg)
    write_at(2, h - 2,
        string.format("cleanup done.  deleted: %d   errors: %d", deleted, errors),
        errors == 0 and T.ok or T.warn, T.bg)
    draw_footer_bar(" press any key")
    os.pullEvent("key")
    return deleted, errors
end

local function cleanup_all()
    local installed_files, aux_files, dirs = gather_cleanup()
    if not confirm_cleanup(installed_files, aux_files, dirs) then
        return false
    end
    perform_cleanup(installed_files, aux_files, dirs)
    return true
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
        tag = "[cleanup]   ", tag_color = T.uninstall,
        label = pad_right("everything", 14),
        desc  = "DESTRUCTIVE: delete every installed component file, configure + first-run state, logs, and /startup.lua. Confirmation required.",
        action = "cleanup",
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

-- Render a button at (x, y). Returns { x, y, w, action? }.
local function draw_pill(x, y, label, bg_color, fg_color, disabled)
    local text = "[ " .. label .. " ]"
    term.setCursorPos(x, y)
    if disabled then
        set_bg(colors.gray); set_fg(colors.lightGray)
    else
        set_bg(bg_color); set_fg(fg_color)
    end
    term.write(text)
    return { x = x, y = y, w = #text, disabled = disabled }
end

-- Quit dialog. If anything is installed we offer a Reboot button alongside
-- a plain Quit-only button, defaulted to Reboot (Enter triggers it).
-- Returns true if the caller should call os.reboot().
local function quit_prompt()
    local state = load_state()
    local installed_count = 0
    for _ in pairs(state.installed) do installed_count = installed_count + 1 end
    if installed_count == 0 then return false end

    clear_screen()
    draw_title_bar("Quit", string.format("%d installed", installed_count))
    fill_line(2, T.bg)

    local w = screen_wh()
    for i, line in ipairs(wrap(
        "Reboot the computer so installed components auto-start, or exit without rebooting? You can always come back by running the installer again.",
        w - 4)) do
        write_at(2, 3 + i, line, T.dim, T.bg)
    end

    local btn_y = 10
    local btns = {}
    local b = draw_pill(2, btn_y, "reboot now (enter)", colors.lime, colors.black, false)
    b.action = "reboot"; btns[#btns + 1] = b
    b = draw_pill(2 + b.w + 2, btn_y, "quit only", colors.gray, colors.white, false)
    b.action = "quit"; btns[#btns + 1] = b
    set_bg(T.bg); set_fg(T.fg)

    draw_footer_bar(" enter reboot  |  q / esc  quit without rebooting  |  click a button")

    while true do
        local event, p1, p2, p3 = os.pullEvent()
        if event == "key" then
            if p1 == keys.enter then return true
            elseif p1 == keys.q or p1 == keys.escape then return false
            end
        elseif event == "mouse_click" and p1 == 1 then
            for _, bb in ipairs(btns) do
                if p3 == bb.y and p2 >= bb.x and p2 < bb.x + bb.w then
                    return bb.action == "reboot"
                end
            end
        end
    end
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
            if quit_prompt() then
                clear_screen(); os.reboot()
            end
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
        elseif choice.action == "cleanup" then
            cleanup_all()
        end
    end
end

local ok, err = pcall(main)
set_bg(colors.black); set_fg(colors.white)
if not ok then print("edi crashed: " .. tostring(err)) end
