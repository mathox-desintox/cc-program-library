-- ============================================
-- Floor Builder Pocket Monitor
-- ATM10 Modpack - Advanced Pocket Computer
-- ============================================
--
-- Displays floor builder turtle status on an advanced pocket computer.
-- Uses full color palette for the small screen.
--
-- Usage: floor_pocket
--

local PROTOCOL = "mathox_base_floor_builder_v1"
local REFRESH  = 1

-- Open rednet
local modem = peripheral.find("modem")
if not modem then
    print("No modem found!")
    return
end
rednet.open(peripheral.getName(modem))

local last = nil
local lastTime = 0

-- Phase display info
local PHASE_INFO = {
    dig            = { label = "EXCAVATING",     color = colors.orange,  bg = colors.brown },
    ceiling        = { label = "CEILING",        color = colors.blue,    bg = colors.blue },
    floor_place    = { label = "FLOOR",          color = colors.blue,    bg = colors.blue },
    walls          = { label = "WALLS",          color = colors.cyan,    bg = colors.cyan },
    floor_lights   = { label = "FLOOR LIGHTS",   color = colors.yellow,  bg = colors.brown },
    ceiling_lights = { label = "CEILING LIGHTS", color = colors.yellow,  bg = colors.brown },
    wall_lights    = { label = "WALL LIGHTS",    color = colors.yellow,  bg = colors.brown },
    done           = { label = "COMPLETE",       color = colors.lime,    bg = colors.green },
}

local function formatTime(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then return string.format("%dh%02dm", h, m) end
    return string.format("%dm%02ds", m, s)
end

local function drawBar(value, maxVal, fg)
    local w = term.getSize()
    local pctStr = string.format(" %3d%%", math.floor(value / maxVal * 100))
    local barW = w - #pctStr
    local filled = math.floor((value / maxVal) * barW)

    for i = 1, barW do
        if i <= filled then
            term.setBackgroundColor(fg)
            term.setTextColor(colors.black)
        else
            term.setBackgroundColor(colors.gray)
            term.setTextColor(colors.lightGray)
        end
        term.write("\127")
    end
    term.setBackgroundColor(colors.black)
    term.setTextColor(colors.white)
    print(pctStr)
end

local function drawScreen()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)

    -- Title
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    local title = " FLOOR BUILDER "
    local pad = math.floor((w - #title) / 2)
    term.write(string.rep(" ", pad) .. title .. string.rep(" ", w - pad - #title))
    term.setBackgroundColor(colors.black)

    if not last then
        term.setCursorPos(1, 4)
        term.setTextColor(colors.orange)
        print("Waiting for turtle...")
        term.setTextColor(colors.gray)
        print(PROTOCOL)
        return
    end

    local d = last
    local age = os.clock() - lastTime
    local stale = age > 30
    local info = PHASE_INFO[d.phase] or { label = d.phase or "?", color = colors.white, bg = colors.gray }

    -- Floor + Phase
    term.setCursorPos(1, 3)
    term.setTextColor(colors.lightGray)
    term.write("Floor ")
    term.setTextColor(colors.white)
    term.write(tostring(d.floor or "?"))

    term.setCursorPos(1, 4)
    term.setBackgroundColor(info.bg)
    term.setTextColor(colors.white)
    local phaseStr = " " .. info.label .. " "
    term.write(phaseStr .. string.rep(" ", w - #phaseStr))
    term.setBackgroundColor(colors.black)

    if stale then
        term.setCursorPos(1, 5)
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        local staleStr = " STALE " .. formatTime(age) .. " "
        term.write(staleStr .. string.rep(" ", w - #staleStr))
        term.setBackgroundColor(colors.black)
    end

    -- Progress
    local line = stale and 7 or 6

    if d.phase == "dig" then
        term.setCursorPos(1, line)
        term.setTextColor(colors.lightGray)
        term.write("Pass ")
        term.setTextColor(colors.orange)
        print((d.dig_pass or "?") .. "/5")
        line = line + 1
        if d.row_z then
            local done = d.row_z - 2573
            term.setCursorPos(1, line)
            drawBar(done, 103, colors.orange)
            line = line + 1
        end
    elseif d.phase == "ceiling" or d.phase == "floor_place" then
        if d.row_z then
            local done = d.row_z - 2573
            term.setCursorPos(1, line)
            term.setTextColor(colors.lightGray)
            print("Row " .. done .. "/103")
            line = line + 1
            term.setCursorPos(1, line)
            drawBar(done, 103, colors.blue)
            line = line + 1
        end
    elseif d.phase == "walls" then
        if d.wall_y then
            local done = d.wall_y - 9
            term.setCursorPos(1, line)
            term.setTextColor(colors.lightGray)
            print("Layer " .. done .. "/8")
            line = line + 1
            term.setCursorPos(1, line)
            drawBar(done, 8, colors.cyan)
            line = line + 1
        end
    elseif d.phase and d.phase:find("lights") then
        local maxL = d.phase == "wall_lights" and 52 or 312
        if d.light_idx then
            term.setCursorPos(1, line)
            term.setTextColor(colors.lightGray)
            print("Light " .. d.light_idx .. "/" .. maxL)
            line = line + 1
            term.setCursorPos(1, line)
            drawBar(d.light_idx, maxL, colors.yellow)
            line = line + 1
        end
    elseif d.phase == "done" then
        term.setCursorPos(1, line)
        term.setBackgroundColor(colors.green)
        term.setTextColor(colors.white)
        local msg = " ALL COMPLETE! "
        term.write(string.rep(" ", math.floor((w - #msg) / 2)) .. msg)
        term.setBackgroundColor(colors.black)
        line = line + 1
    end

    -- Fuel
    line = line + 1
    if d.fuel and line <= h then
        term.setCursorPos(1, line)
        local fuelColor = colors.lime
        if d.fuel < 1000 then fuelColor = colors.red
        elseif d.fuel < 5000 then fuelColor = colors.orange end
        term.setTextColor(colors.lightGray)
        term.write("Fuel ")
        term.setTextColor(fuelColor)
        print(tostring(d.fuel))
        line = line + 1
    end

    -- Position
    if d.pos and line <= h then
        term.setCursorPos(1, line)
        term.setTextColor(colors.gray)
        print(string.format("%d,%d,%d", d.pos.x or 0, d.pos.y or 0, d.pos.z or 0))
        line = line + 1
    end

    -- Event
    if d.event and line <= h then
        line = line + 1
        term.setCursorPos(1, line)
        if d.event == "error" then
            term.setBackgroundColor(colors.red)
            term.setTextColor(colors.white)
            local msg = " ERR "
            term.write(msg .. string.rep(" ", w - #msg))
            term.setBackgroundColor(colors.black)
            if d.message and line + 1 <= h then
                term.setCursorPos(1, line + 1)
                term.setTextColor(colors.red)
                print(d.message:sub(1, w))
            end
        elseif d.event == "all_complete" then
            term.setBackgroundColor(colors.lime)
            term.setTextColor(colors.black)
            term.write(" DONE " .. string.rep(" ", w - 6))
        elseif d.event == "phase_complete" then
            term.setTextColor(colors.lime)
            print("Done: " .. (d.completed or ""))
        end
        term.setBackgroundColor(colors.black)
    end
end

-- Main loop
drawScreen()
while true do
    local id, msg = rednet.receive(PROTOCOL, REFRESH)
    if msg and type(msg) == "table" then
        last = msg
        lastTime = os.clock()
    end
    drawScreen()
end
