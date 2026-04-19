-- ============================================================
-- edi — Energy Dashboard Installer
-- ============================================================
--
-- Upload this single file to pastebin, then in-game:
--   pastebin run <CODE>
--
-- It fetches the manifest from GitHub and lets you install / update /
-- uninstall dashboard components (collector, core, panel) with arrow-key
-- navigation. No wget lists.
--
-- State lives in /.edi_state (plain Lua-serialised table) so "update" and
-- "uninstall" know what was previously installed.

-- Edit if you fork: point at your own manifest.
local MANIFEST_URL = "https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/build/manifest.json"
local STATE_FILE   = "/.edi_state"

-- ─── terminal helpers (degrade on non-colour terms) ─────────────────────

local has_color = term.isColor and term.isColor()
local function set_fg(c) if has_color then term.setTextColor(c) end end
local function set_bg(c) if has_color then term.setBackgroundColor(c) end end

local function clear_screen()
    set_bg(colors.black); set_fg(colors.white)
    term.clear(); term.setCursorPos(1, 1)
end

local function header(subtitle)
    clear_screen()
    set_fg(colors.yellow); print("== Energy Dashboard Installer ==")
    if subtitle then set_fg(colors.lightGray); print(subtitle) end
    set_fg(colors.white); print()
end

local function pause_and_return()
    set_fg(colors.lightGray)
    print()
    print("Press any key to continue...")
    set_fg(colors.white)
    os.pullEvent("key")
end

-- ─── state (what's installed) ───────────────────────────────────────────

local function load_state()
    if not fs.exists(STATE_FILE) then return { installed = {} } end
    local f = fs.open(STATE_FILE, "r")
    if not f then return { installed = {} } end
    local data = f.readAll(); f.close()
    local ok, s = pcall(textutils.unserialise, data)
    if not ok or type(s) ~= "table" then return { installed = {} } end
    s.installed = s.installed or {}
    return s
end

local function save_state(s)
    local f = fs.open(STATE_FILE, "w")
    if not f then return false end
    f.write(textutils.serialise(s))
    f.close()
    return true
end

-- ─── manifest ───────────────────────────────────────────────────────────

local function fetch_manifest()
    set_fg(colors.lightGray)
    write("Fetching manifest... ")
    local res = http.get(MANIFEST_URL)
    if not res then set_fg(colors.red); print("FAILED"); return nil end
    local body = res.readAll(); res.close()
    local ok, m = pcall(textutils.unserialiseJSON, body)
    if not ok or type(m) ~= "table" or type(m.components) ~= "table" then
        set_fg(colors.red); print("FAILED (unparseable)"); return nil
    end
    set_fg(colors.lime); print("OK (v" .. tostring(m.version or "?") .. ")")
    set_fg(colors.white)
    return m
end

-- ─── file ops ───────────────────────────────────────────────────────────

local function download(url, target)
    local dir = fs.getDir(target)
    if dir ~= "" and not fs.exists(dir) then fs.makeDir(dir) end
    local res = http.get(url)
    if not res then return false, "http.get failed" end
    local body = res.readAll(); res.close()
    local f = fs.open(target, "w")
    if not f then return false, "cannot open " .. target end
    f.write(body); f.close()
    return true, #body
end

local function install_component(manifest, name)
    local c = manifest.components[name]
    if not c then set_fg(colors.red); print("Unknown component: " .. name); return false end

    set_fg(colors.yellow); print("Installing " .. name .. " (" .. #c.files .. " files)")
    set_fg(colors.lightGray); print("  " .. (c.description or ""))
    print()

    local installed_files = {}
    for i, file in ipairs(c.files) do
        local url = manifest.repo .. "/" .. file.src
        set_fg(colors.lightGray); write(string.format("  [%d/%d] %s ... ", i, #c.files, file.dst))
        local ok, sz = download(url, file.dst)
        if ok then
            set_fg(colors.lime); print("OK (" .. sz .. " B)")
            installed_files[#installed_files + 1] = file.dst
        else
            set_fg(colors.red); print("FAILED (" .. tostring(sz) .. ")")
            set_fg(colors.white)
            return false
        end
    end

    -- record in state
    local state = load_state()
    state.installed[name] = {
        version = manifest.version,
        files   = installed_files,
        main    = c.main,
        installed_at = os.epoch("utc"),
    }
    save_state(state)

    print()
    set_fg(colors.lime); print("Installed " .. name)
    if c.main then
        set_fg(colors.white); print("Run with: "); set_fg(colors.yellow); print("  " .. c.main:gsub("%.lua$", ""))
    end
    set_fg(colors.white)
    return true
end

local function uninstall_component(name)
    local state = load_state()
    local rec = state.installed[name]
    if not rec then
        set_fg(colors.yellow); print("Not installed: " .. name); set_fg(colors.white)
        return false
    end
    set_fg(colors.yellow); print("Uninstalling " .. name); set_fg(colors.white)
    for _, path in ipairs(rec.files or {}) do
        if fs.exists(path) then
            fs.delete(path)
            set_fg(colors.lightGray); print("  removed " .. path); set_fg(colors.white)
        end
    end
    state.installed[name] = nil
    save_state(state)
    set_fg(colors.lime); print("Done"); set_fg(colors.white)
    return true
end

local function update_all(manifest)
    local state = load_state()
    local any = false
    for name in pairs(state.installed) do
        any = true
        install_component(manifest, name)
        print()
    end
    if not any then
        set_fg(colors.lightGray); print("Nothing installed yet."); set_fg(colors.white)
    end
end

-- ─── interactive menu ───────────────────────────────────────────────────

local function arrow_menu(items, title_fn)
    local sel = 1
    local _, h = term.getSize()
    local max_visible = h - 5
    while true do
        clear_screen()
        set_fg(colors.yellow); print("== Energy Dashboard Installer ==")
        if title_fn then set_fg(colors.lightGray); print(title_fn()) end
        print()

        local offset = 0
        if #items > max_visible then offset = math.min(sel - 1, #items - max_visible) end

        for i = 1, math.min(max_visible, #items) do
            local idx = i + offset
            local it = items[idx]
            if idx == sel then
                set_fg(colors.black); set_bg(colors.white)
            else
                set_fg(colors.white); set_bg(colors.black)
            end
            term.clearLine()
            write(" " .. (it.label or tostring(it)))
            if it.tag then
                set_fg(idx == sel and colors.gray or colors.lightGray)
                write("  " .. it.tag)
            end
            print()
        end

        set_bg(colors.black)
        if #items > max_visible then
            set_fg(colors.lightGray); print("  (" .. sel .. "/" .. #items .. ")")
        end

        set_fg(colors.lightGray)
        term.setCursorPos(1, h)
        write("Up/Down  Enter=select  Q=quit")

        local _, key = os.pullEvent("key")
        if key == keys.up and sel > 1 then sel = sel - 1
        elseif key == keys.down and sel < #items then sel = sel + 1
        elseif key == keys.enter then set_bg(colors.black); return items[sel]
        elseif key == keys.q then return nil end
    end
end

local function build_main_menu(manifest)
    local state = load_state()
    local items = {}

    -- components (install / reinstall)
    local names = {}
    for n in pairs(manifest.components) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do
        local c = manifest.components[n]
        local installed = state.installed[n] ~= nil
        items[#items + 1] = {
            label  = (installed and "[reinstall] " or "[install]   ") .. n,
            tag    = c.description or "",
            action = "install", component = n,
        }
    end

    -- update installed
    items[#items + 1] = {
        label  = "[update]    all installed",
        tag    = "re-fetch every component currently on disk",
        action = "update",
    }

    -- uninstall submenu
    items[#items + 1] = {
        label  = "[uninstall] ...",
        tag    = "remove an installed component",
        action = "uninstall_menu",
    }

    -- exit
    items[#items + 1] = { label = "[exit]", action = "quit" }
    return items
end

local function build_uninstall_menu()
    local state = load_state()
    local items = {}
    local names = {}
    for n in pairs(state.installed) do names[#names + 1] = n end
    table.sort(names)
    for _, n in ipairs(names) do
        items[#items + 1] = { label = n, action = "uninstall", component = n }
    end
    if #items == 0 then
        items[#items + 1] = { label = "(nothing installed)", action = "back" }
    end
    items[#items + 1] = { label = "[back]", action = "back" }
    return items
end

-- ─── main ───────────────────────────────────────────────────────────────

local function main()
    header()
    local manifest = fetch_manifest()
    if not manifest then pause_and_return(); return end

    while true do
        local choice = arrow_menu(
            build_main_menu(manifest),
            function()
                local state = load_state()
                local n = 0
                for _ in pairs(state.installed) do n = n + 1 end
                return "manifest v" .. (manifest.version or "?") .. "   " .. n .. " installed"
            end
        )
        if not choice or choice.action == "quit" then
            clear_screen()
            return
        elseif choice.action == "install" then
            clear_screen()
            install_component(manifest, choice.component)
            pause_and_return()
        elseif choice.action == "update" then
            clear_screen()
            update_all(manifest)
            pause_and_return()
        elseif choice.action == "uninstall_menu" then
            while true do
                local sub = arrow_menu(build_uninstall_menu(), function() return "uninstall menu" end)
                if not sub or sub.action == "back" then break end
                if sub.action == "uninstall" then
                    clear_screen()
                    uninstall_component(sub.component)
                    pause_and_return()
                end
            end
        end
    end
end

local ok, err = pcall(main)
set_bg(colors.black); set_fg(colors.white)
if not ok then print("edi crashed: " .. tostring(err)) end
