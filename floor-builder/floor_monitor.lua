-- ============================================
-- Floor Builder Monitor Display
-- ATM10 Modpack - Advanced Monitor
-- ============================================
--
-- Displays floor builder turtle status on an attached advanced monitor.
-- Uses full 16-color palette for clear status visualization.
--
-- Usage: floor_monitor
--

local PROTOCOL = "mathox_base_floor_builder_v1"
local REFRESH  = 1

-- Find monitor
local mon = peripheral.find("monitor")
if not mon then
    print("No monitor found! Attach a monitor and retry.")
    return
end
mon.setTextScale(0.5)

-- Open rednet
local modem = peripheral.find("modem")
if not modem then
    print("No modem found! Attach a modem and retry.")
    return
end
rednet.open(peripheral.getName(modem))
print("Listening on: " .. PROTOCOL)

-- State
local last = nil
local lastTime = 0
local startTime = os.clock()

-- Phase display names and colors
local PHASE_INFO = {
    dig            = { label = "EXCAVATING",      color = colors.orange },
    ceiling        = { label = "CEILING",         color = colors.blue },
    floor_place    = { label = "FLOOR",           color = colors.blue },
    walls          = { label = "WALLS",           color = colors.cyan },
    floor_lights   = { label = "FLOOR LIGHTS",    color = colors.yellow },
    ceiling_lights = { label = "CEILING LIGHTS",  color = colors.yellow },
    wall_lights    = { label = "WALL LIGHTS",     color = colors.yellow },
    done           = { label = "COMPLETE",        color = colors.lime },
}

local PHASE_ORDER = { "dig", "ceiling", "floor_place", "walls", "floor_lights", "ceiling_lights", "wall_lights" }

local function formatTime(seconds)
    local h = math.floor(seconds / 3600)
    local m = math.floor((seconds % 3600) / 60)
    local s = math.floor(seconds % 60)
    if h > 0 then return string.format("%dh%02dm%02ds", h, m, s) end
    return string.format("%dm%02ds", m, s)
end

-- Drawing helpers
local w, h

local function writeLine(line, text, fg, bg)
    if line > h then return end
    mon.setCursorPos(1, line)
    mon.setTextColor(fg or colors.white)
    mon.setBackgroundColor(bg or colors.black)
    mon.write(text .. string.rep(" ", w - #text))
end

local function writeCenter(line, text, fg, bg)
    if line > h then return end
    local pad = math.floor((w - #text) / 2)
    mon.setCursorPos(1, line)
    mon.setBackgroundColor(bg or colors.black)
    mon.setTextColor(fg or colors.white)
    mon.write(string.rep(" ", pad) .. text .. string.rep(" ", w - pad - #text))
end

local function drawBar(line, label, value, maxVal, fg, bg)
    if line > h then return end
    local labelStr = label .. " "
    local pctStr = string.format(" %3d%%", math.floor(value / maxVal * 100))
    local barW = w - #labelStr - #pctStr
    if barW < 1 then barW = 1 end
    local filled = math.floor((value / maxVal) * barW)

    mon.setCursorPos(1, line)
    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.lightGray)
    mon.write(labelStr)

    mon.setBackgroundColor(bg or colors.gray)
    mon.setTextColor(fg or colors.lime)
    for i = 1, barW do
        if i <= filled then
            mon.setBackgroundColor(fg or colors.lime)
            mon.setTextColor(colors.black)
            mon.write("\127")
        else
            mon.setBackgroundColor(colors.gray)
            mon.setTextColor(colors.lightGray)
            mon.write("\127")
        end
    end

    mon.setBackgroundColor(colors.black)
    mon.setTextColor(colors.white)
    mon.write(pctStr)
end

local function drawPhaseTimeline(line, currentPhase)
    if line > h then return end
    local currentIdx = 0
    for i, p in ipairs(PHASE_ORDER) do
        if p == currentPhase then currentIdx = i end
    end

    mon.setCursorPos(1, line)
    mon.setBackgroundColor(colors.black)
    for i, p in ipairs(PHASE_ORDER) do
        local info = PHASE_INFO[p]
        local short = info.label:sub(1, 1)
        if i < currentIdx then
            mon.setBackgroundColor(colors.green)
            mon.setTextColor(colors.white)
        elseif i == currentIdx then
            mon.setBackgroundColor(info.color)
            mon.setTextColor(colors.black)
        else
            mon.setBackgroundColor(colors.gray)
            mon.setTextColor(colors.lightGray)
        end
        local slotW = math.floor(w / #PHASE_ORDER)
        local padded = short .. string.rep(" ", slotW - 1)
        mon.write(padded)
    end
    mon.setBackgroundColor(colors.black)
end

local function drawScreen()
    mon.setBackgroundColor(colors.black)
    mon.clear()
    w, h = mon.getSize()

    -- Title bar
    writeCenter(1, " FLOOR BUILDER ", colors.black, colors.blue)

    if not last then
        writeCenter(4, "Waiting for turtle...", colors.orange)
        writeCenter(6, "Protocol: " .. PROTOCOL, colors.gray)
        return
    end

    local d = last
    local age = os.clock() - lastTime
    local stale = age > 30

    -- Floor number and phase
    local info = PHASE_INFO[d.phase] or { label = d.phase or "?", color = colors.white }
    writeLine(3, " Floor " .. (d.floor or "?") .. "  |  " .. info.label,
        info.color, colors.gray)

    if stale then
        writeLine(4, " NO UPDATE for " .. formatTime(age), colors.white, colors.red)
    end

    -- Phase timeline
    drawPhaseTimeline(6, d.phase)

    -- Phase-specific progress
    local line = 8
    local s = d.stats or {}

    if d.phase == "dig" then
        local passNum = d.dig_pass or 1
        local total = s.blocks_total or 1
        local done = s.blocks_broken or 0
        writeLine(line, " Blocks: " .. done .. " / " .. total ..
            "  (" .. math.floor(done / total * 100) .. "%)", colors.white)
        line = line + 1
        drawBar(line, "Progress", done, total, colors.orange)
        line = line + 1
        writeLine(line, " Pass " .. passNum, colors.lightGray)
        line = line + 1
    elseif d.phase == "ceiling" or d.phase == "floor_place" then
        local total = s.place_total or 1
        local done = s.blocks_placed or 0
        local label = d.phase == "ceiling" and "Ceiling" or "Floor"
        writeLine(line, " " .. label .. ": " .. done .. " / " .. total ..
            "  (" .. math.floor(done / total * 100) .. "%)", colors.white)
        line = line + 1
        drawBar(line, "Placed", done, total, colors.blue)
        line = line + 1
    elseif d.phase == "walls" then
        local total = s.place_total or 1
        local done = s.blocks_placed or 0
        writeLine(line, " Walls: " .. done .. " / " .. total ..
            "  (" .. math.floor(done / total * 100) .. "%)", colors.white)
        line = line + 1
        drawBar(line, "Placed", done, total, colors.cyan)
        line = line + 1
    elseif d.phase and d.phase:find("lights") then
        local total = s.lights_total or 1
        local done = s.lights_placed or 0
        writeLine(line, " Lights: " .. done .. " / " .. total ..
            "  (" .. math.floor(done / total * 100) .. "%)", colors.white)
        line = line + 1
        drawBar(line, "Placed", done, total, colors.yellow)
        line = line + 1
    elseif d.phase == "done" then
        writeCenter(line, "ALL COMPLETE!", colors.lime)
        line = line + 1
    end

    -- ETA
    if s.eta and s.eta > 0 then
        writeLine(line, " ETA: " .. formatTime(s.eta), colors.orange)
        line = line + 1
    end

    -- Separator
    line = line + 1

    -- Fuel gauge
    if d.fuel then
        local fuelColor = colors.lime
        if d.fuel < 1000 then fuelColor = colors.red
        elseif d.fuel < 5000 then fuelColor = colors.orange end
        local fuelMax = math.max(d.fuel, 10000)
        drawBar(line, "Fuel", d.fuel, fuelMax, fuelColor)
        line = line + 1
    end

    -- Position
    line = line + 1
    if d.pos then
        writeLine(line, string.format(" Pos: %d, %d, %d",
            d.pos.x or 0, d.pos.y or 0, d.pos.z or 0), colors.lightGray)
        line = line + 1
    end

    -- Uptime
    writeLine(line, " Uptime: " .. formatTime(os.clock() - startTime), colors.lightGray)
    line = line + 1

    -- Events
    if d.event then
        line = line + 1
        if d.event == "error" then
            writeLine(line, " ERROR: " .. (d.message or "unknown"), colors.white, colors.red)
        elseif d.event == "all_complete" then
            writeCenter(line, " BUILD COMPLETE ", colors.black, colors.lime)
        elseif d.event == "phase_complete" then
            writeLine(line, " Phase done: " .. (d.completed or ""), colors.lime)
        end
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
