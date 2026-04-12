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
        target   = "floor_monitor.lua",
        device   = "computer",
    },
    {
        name     = "Floor Pocket",
        desc     = "Floor builder status on pocket computer",
        file     = "floor-builder/floor_pocket.lua",
        target   = "floor_pocket.lua",
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
    print("================================")
    print("  MA Farm Installer")
    print("================================")
    setColor(colors.white)
    print()
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

-- Show menu
for i, prog in ipairs(PROGRAMS) do
    setColor(colors.cyan)
    write("  " .. i .. ") ")
    setColor(colors.white)
    write(prog.name)
    setColor(colors.gray)
    print("  [" .. prog.device .. "]")
    setColor(colors.lightGray)
    print("     " .. prog.desc)
end

print()
setColor(colors.yellow)
write("Select program (1-" .. #PROGRAMS .. "): ")
setColor(colors.white)

local choice = tonumber(read())
if not choice or choice < 1 or choice > #PROGRAMS then
    setColor(colors.red)
    print("Invalid choice.")
    return
end

local prog = PROGRAMS[choice]
print()
setColor(colors.white)
print("Installing: " .. prog.name)
print()

local url = REPO .. "/" .. prog.file
local ok = download(url, prog.target)

if ok then
    print()
    setColor(colors.lime)
    print("Installed! Run with:")
    setColor(colors.white)
    print("  " .. prog.target:gsub("%.lua$", ""))
else
    print()
    setColor(colors.red)
    print("Installation failed.")
    print("Check the REPO URL in the installer.")
end

setColor(colors.white)
