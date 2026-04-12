-- ============================================
-- MA Farm / Floor Builder Installer
-- ============================================
--
-- Upload this file to pastebin, then in-game:
--   pastebin run <CODE>
--
-- It downloads the selected program from GitHub.
--

-- CHANGE THIS to your GitHub raw URL base
local REPO = "https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main"

local PROGRAMS = {
    {
        name     = "Farm Builder",
        desc     = "Mystical Agriculture farm plots + MA growth accelerators",
        file     = "farm-builder/farm.lua",
        target   = "farm.lua",
        device   = "turtle",
    },
    {
        name     = "Floor Builder",
        desc     = "Underground floor excavation + shell + lighting",
        file     = "floor-builder/floor.lua",
        target   = "floor.lua",
        device   = "turtle",
    },
    {
        name     = "Floor Monitor",
        desc     = "Floor builder status on advanced monitor",
        file     = "floor-builder/floor_monitor.lua",
        target   = "startup/floor_monitor.lua",
        device   = "computer",
    },
    {
        name     = "Floor Pocket",
        desc     = "Floor builder status on pocket computer",
        file     = "floor-builder/floor_pocket.lua",
        target   = "startup/floor_pocket.lua",
        device   = "pocket",
    },
}

-- Colors (fallback for basic computers)
local function setColor(c)
    if term.isColor() then term.setTextColor(c) end
end

local function header()
    term.clear()
    term.setCursorPos(1, 1)
    setColor(colors.yellow)
    print("== MA Installer ==")
    setColor(colors.white)
end

local function download(url, path)
    setColor(colors.lightGray)
    write("  Downloading " .. path .. "... ")
    local response = http.get(url)
    if not response then
        setColor(colors.red)
        print("FAILED")
        return false
    end
    local content = response.readAll()
    response.close()
    local f = fs.open(path, "w")
    f.write(content)
    f.close()
    setColor(colors.lime)
    print("OK (" .. #content .. " bytes)")
    return true
end

-- Main
header()

-- Scrollable menu
local function menu(items)
    local sel = 1
    local _, h = term.getSize()
    local maxVisible = h - 3 -- room for header + footer
    while true do
        term.clear()
        term.setCursorPos(1, 1)
        setColor(colors.yellow)
        print("== MA Installer ==")

        local total = #items
        local offset = 0
        if total > maxVisible then
            offset = math.min(sel - 1, total - maxVisible)
        end

        for i = 1, math.min(maxVisible, total) do
            local idx = i + offset
            local prog = items[idx]
            if idx == sel then
                setColor(colors.black)
                term.setBackgroundColor(colors.white)
            else
                setColor(colors.white)
                term.setBackgroundColor(colors.black)
            end
            term.clearLine()
            write(" " .. prog.name)
            if idx == sel then
                setColor(colors.gray)
            else
                setColor(colors.gray)
            end
            print(" [" .. prog.device .. "]")
        end

        term.setBackgroundColor(colors.black)
        if total > maxVisible then
            setColor(colors.gray)
            print(" (" .. sel .. "/" .. total .. ")")
        end

        setColor(colors.lightGray)
        term.setCursorPos(1, h)
        write("Up/Down=navigate Enter=select")

        local evt, key = os.pullEvent("key")
        if key == keys.up and sel > 1 then
            sel = sel - 1
        elseif key == keys.down and sel < total then
            sel = sel + 1
        elseif key == keys.enter then
            term.setBackgroundColor(colors.black)
            return sel
        end
    end
end

local choice = menu(PROGRAMS)
local prog = PROGRAMS[choice]

term.clear()
term.setCursorPos(1, 1)
setColor(colors.white)
print("Installing: " .. prog.name)
print()

local url = REPO .. "/" .. prog.file
local ok = download(url, prog.target)

if ok then
    print()
    setColor(colors.lime)
    if prog.target:find("^startup/") then
        print("Installed! Will auto-run on")
        print("  next reboot.")
    else
        print("Installed! Run with:")
        setColor(colors.white)
        print("  " .. prog.target:gsub("%.lua$", ""))
    end
else
    print()
    setColor(colors.red)
    print("Installation failed.")
    print("Check the REPO URL in the installer.")
end

setColor(colors.white)
