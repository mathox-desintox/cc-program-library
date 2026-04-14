-- ============================================
-- Floor Builder Pocket Monitor
-- ATM10 Modpack - Advanced Pocket Computer
-- ============================================
--
-- Displays floor builder turtle status on an advanced pocket computer.
-- Multi-page interface: tap left/right edges or use arrow keys.
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
local page = 1
local NUM_PAGES = 2

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

local PHASE_ORDER = { "dig", "ceiling", "floor_place", "walls", "floor_lights", "ceiling_lights", "wall_lights" }

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

local function drawHeader(w)
    term.setBackgroundColor(colors.blue)
    term.setTextColor(colors.white)
    local title = " FLOOR BUILDER "
    local pad = math.floor((w - #title) / 2)
    term.write(string.rep(" ", pad) .. title .. string.rep(" ", w - pad - #title))
    term.setBackgroundColor(colors.black)
end

local function drawFooter(w, h)
    term.setCursorPos(1, h)
    term.setBackgroundColor(colors.gray)
    term.setTextColor(colors.white)
    local nav = " < " .. page .. "/" .. NUM_PAGES .. " > "
    local pad = math.floor((w - #nav) / 2)
    term.write(string.rep(" ", pad) .. nav .. string.rep(" ", w - pad - #nav))
    term.setBackgroundColor(colors.black)
end

---------------------------------------------
-- PAGE 1: Phases + Progress
---------------------------------------------

local function drawPage1(d, w, h)
    local line = 3

    -- Floor Y level
    term.setCursorPos(1, line)
    term.setTextColor(colors.lightGray)
    term.write("Floor Y=")
    term.setTextColor(colors.white)
    print(tostring(d.floor_y or "?"))
    line = line + 1

    -- Stale warning
    local age = os.clock() - lastTime
    if age > 30 then
        term.setCursorPos(1, line)
        term.setBackgroundColor(colors.red)
        term.setTextColor(colors.white)
        local staleStr = " STALE " .. formatTime(age)
        term.write(staleStr .. string.rep(" ", w - #staleStr))
        term.setBackgroundColor(colors.black)
        line = line + 1
    end

    -- Phase list
    line = line + 1
    local currentIdx = 0
    for i, p in ipairs(PHASE_ORDER) do
        if p == d.phase then currentIdx = i end
    end
    if d.phase == "done" then currentIdx = #PHASE_ORDER + 1 end

    for i, p in ipairs(PHASE_ORDER) do
        if line >= h then break end
        local pinfo = PHASE_INFO[p]
        term.setCursorPos(1, line)
        if i < currentIdx then
            term.setTextColor(colors.lime)
            term.write("x ")
            term.setTextColor(colors.gray)
        elseif i == currentIdx then
            term.setBackgroundColor(pinfo.bg)
            term.setTextColor(colors.white)
            term.write("> ")
        else
            term.setTextColor(colors.gray)
            term.write("  ")
        end
        local label = pinfo.label
        term.write(label .. string.rep(" ", w - #label - 2))
        term.setBackgroundColor(colors.black)
        line = line + 1
    end

    -- Active phase stats
    line = line + 1
    local s = d.stats or {}
    local done, total, barColor = 0, 0, colors.white

    if d.phase == "dig" then
        total = s.blocks_total or 0
        done = s.blocks_broken or 0
        barColor = colors.orange
    elseif d.phase == "ceiling" or d.phase == "floor_place" then
        total = s.place_total or 0
        done = s.blocks_placed or 0
        barColor = colors.blue
    elseif d.phase == "walls" then
        total = s.place_total or 0
        done = s.blocks_placed or 0
        barColor = colors.cyan
    elseif d.phase and d.phase:find("lights") then
        total = s.lights_total or 0
        done = s.lights_placed or 0
        barColor = colors.yellow
    end

    if total > 0 and line < h then
        term.setCursorPos(1, line)
        term.setTextColor(colors.lightGray)
        print(done .. "/" .. total)
        line = line + 1
        if line < h then
            term.setCursorPos(1, line)
            drawBar(done, total, barColor)
            line = line + 1
        end
    end

    -- ETA
    if s.eta and s.eta > 0 and line < h then
        term.setCursorPos(1, line)
        term.setTextColor(colors.orange)
        print("ETA: " .. formatTime(s.eta))
    end
end

---------------------------------------------
-- PAGE 2: Stats
---------------------------------------------

local function drawPage2(d, w, h)
    local line = 3

    -- Fuel
    if d.fuel then
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
    line = line + 1
    if d.pos then
        term.setCursorPos(1, line)
        term.setTextColor(colors.lightGray)
        term.write("Pos ")
        term.setTextColor(colors.white)
        print(string.format("%d,%d,%d", d.pos.x or 0, d.pos.y or 0, d.pos.z or 0))
        line = line + 1
    end

    -- Phase
    line = line + 1
    local info = PHASE_INFO[d.phase] or { label = d.phase or "?", color = colors.white }
    term.setCursorPos(1, line)
    term.setTextColor(colors.lightGray)
    term.write("Phase ")
    term.setTextColor(info.color)
    print(info.label)
    line = line + 1

    -- Uptimes
    line = line + 1
    if d.uptime then
        term.setCursorPos(1, line)
        term.setTextColor(colors.lightGray)
        print("Session: " .. formatTime(d.uptime))
        line = line + 1
    end
    if d.total_uptime then
        term.setCursorPos(1, line)
        term.setTextColor(colors.lightGray)
        print("Total: " .. formatTime(d.total_uptime))
        line = line + 1
    end

    -- Events
    if d.event and line < h then
        line = line + 1
        term.setCursorPos(1, line)
        if d.event == "error" then
            term.setBackgroundColor(colors.red)
            term.setTextColor(colors.white)
            term.write(" ERR " .. string.rep(" ", w - 5))
            term.setBackgroundColor(colors.black)
            if d.message and line + 1 < h then
                term.setCursorPos(1, line + 1)
                term.setTextColor(colors.red)
                print(d.message:sub(1, w))
            end
        elseif d.event == "all_complete" then
            term.setBackgroundColor(colors.lime)
            term.setTextColor(colors.black)
            term.write(" DONE " .. string.rep(" ", w - 6))
            term.setBackgroundColor(colors.black)
        elseif d.event == "phase_complete" then
            term.setTextColor(colors.lime)
            print("Done: " .. (d.completed or ""))
        end
    end
end

---------------------------------------------
-- MAIN DRAW
---------------------------------------------

local function drawScreen()
    local w, h = term.getSize()
    term.setBackgroundColor(colors.black)
    term.clear()
    term.setCursorPos(1, 1)

    drawHeader(w)

    if not last then
        term.setCursorPos(1, 4)
        term.setTextColor(colors.orange)
        print("Waiting for turtle...")
        term.setTextColor(colors.gray)
        print(PROTOCOL)
        return
    end

    if page == 1 then
        drawPage1(last, w, h)
    elseif page == 2 then
        drawPage2(last, w, h)
    end

    drawFooter(w, h)
end

---------------------------------------------
-- MAIN LOOP
---------------------------------------------

drawScreen()
while true do
    local evt, p1, p2, p3 = os.pullEvent()

    if evt == "rednet_message" and p3 == PROTOCOL then
        if type(p2) == "table" then
            last = p2
            lastTime = os.clock()
        end
    elseif evt == "mouse_click" then
        local w = term.getSize()
        local clickX = p2
        if clickX <= 3 then
            page = page > 1 and page - 1 or NUM_PAGES
        elseif clickX >= w - 2 then
            page = page < NUM_PAGES and page + 1 or 1
        end
    elseif evt == "key" then
        if p1 == keys.left then
            page = page > 1 and page - 1 or NUM_PAGES
        elseif p1 == keys.right then
            page = page < NUM_PAGES and page + 1 or 1
        end
    end

    drawScreen()
end
