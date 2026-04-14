-- ============================================
-- Underground Floor Builder
-- ATM10 Modpack - ComputerCraft Turtle
-- ============================================
--
-- Digs out a new floor below the existing facility,
-- builds smooth stone shell (ceiling/floor/walls),
-- and installs staggered diagonal lattice lighting.
--
-- Setup:
--   1. Place turtle at NW interior corner of the floor ABOVE, facing East
--      Position: (-3398, 22, 2574), facing East (+X)
--   2. Chests (from turtle's perspective):
--      FRONT (east):  smooth stone chest at same Y, lights chest above it
--      RIGHT (south): dump chest at same Y, coal chest above it
--   3. Equip a pickaxe in the turtle's tool slot
--   4. Run: floor              (full build, all phases)
--      Run: floor dig          (just excavation)
--      Run: floor shell        (ceiling + floor + walls)
--      Run: floor lights       (just lighting)
--      Run: floor status       (print progress and exit)
--
-- The turtle digs down through the existing floor. The shaft column
-- at (-3398, 2574) is kept open for the turtle to return to chests.
--

---------------------------------------------
-- CONFIGURATION
---------------------------------------------

local INTERIOR_HEIGHT        = 11 -- air blocks between floor and ceiling
local BUFFER_LAYERS          = 3  -- solid blocks between floors

-- Interior bounds (101x101)
local INT_X_MIN, INT_X_MAX   = -3398, -3298
local INT_Z_MIN, INT_Z_MAX   = 2574, 2674

-- Full area bounds (103x103 including walls)
local AREA_X_MIN, AREA_X_MAX = -3399, -3297
local AREA_Z_MIN, AREA_Z_MAX = 2573, 2675

-- Center block (for light skip)
local CENTER_X, CENTER_Z     = -3348, 2624

-- Turtle home (HOME_Y is GPS'd at runtime — turtle must be placed on top of
-- the floor above the one being built, at the NW interior corner)
local HOME_X, HOME_Z         = -3398, 2574
local HOME_FACING            = 0 -- East

-- Shaft column (kept open for vertical travel)
local SHAFT_X, SHAFT_Z       = HOME_X, HOME_Z

-- Block names
local SMOOTH_STONE           = "minecraft:smooth_stone"
local LIGHT_NAME             = "simplylight:illuminant_black_block_on"
local FUEL_ITEM              = "minecraft:coal"

-- Inventory thresholds
local DUMP_THRESHOLD         = 15   -- dump when this many slots occupied (3 free remaining)
local MIN_FUEL               = 1000 -- refuel when below this
local STONE_RESERVE          = 16   -- keep stone in this slot for liquid handling

-- Rednet
local REDNET_PROTOCOL        = "mathox_base_floor_builder_v1"

-- Progress file
local PROGRESS_FILE          = "floor_progress"
local UPTIME_FILE            = "floor_uptime"

---------------------------------------------
-- COMPUTED Y LEVELS
---------------------------------------------

-- All Y levels are derived from HOME_Y, which is determined at runtime via GPS.
-- The turtle must be placed on top of the floor above the one being built;
-- that floor's floor block sits at HOME_Y-1, and the new floor is dug below.
local HOME_Y       -- GPS'd at startup in initLevels()
local CEILING_Y    -- HOME_Y - BUFFER_LAYERS - 2
local FLOOR_Y      -- CEILING_Y - INTERIOR_HEIGHT - 1
local DIG_TOP_Y    -- HOME_Y - 2 (just below prev floor's floor block)
local DIG_BOT_Y    -- = FLOOR_Y
local WALL_LIGHT_Y -- midpoint of interior
local DIG_PASSES             = {}

local function initLevels()
    CEILING_Y = HOME_Y - BUFFER_LAYERS - 2
    FLOOR_Y = CEILING_Y - INTERIOR_HEIGHT - 1
    DIG_TOP_Y = HOME_Y - 2
    DIG_BOT_Y = FLOOR_Y
    WALL_LIGHT_Y = math.floor((FLOOR_Y + 1 + CEILING_Y - 1) / 2)

    -- Dig passes (up to 3 layers each, top to bottom). Each pass at nav_y covers
    -- [nav_y-1, nav_y, nav_y+1] — nav layer is cleared by vertical movement.
    DIG_PASSES = {}
    local top_uncovered = DIG_TOP_Y
    while top_uncovered - 2 >= DIG_BOT_Y do
        local nav = top_uncovered - 1
        DIG_PASSES[#DIG_PASSES + 1] = { nav_y = nav, dig_up = true, dig_down = true }
        top_uncovered = top_uncovered - 3
    end
    local remaining = top_uncovered - DIG_BOT_Y + 1
    if remaining == 1 then
        DIG_PASSES[#DIG_PASSES + 1] = { nav_y = top_uncovered, dig_up = false, dig_down = false }
    elseif remaining == 2 then
        DIG_PASSES[#DIG_PASSES + 1] = { nav_y = top_uncovered, dig_up = false, dig_down = true }
    end
end

---------------------------------------------
-- STATE
---------------------------------------------

-- Position starts at 0,0,0 — overwritten by initLevels() → gps.locate() before use.
local x, y, z = 0, 0, 0
local facing  = HOME_FACING

local DX      = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }
local DZ      = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }

local state   = {
    phase = "dig",
    mode = "build",
    dig_pass = 1,
    row_z = AREA_Z_MIN,
    wall_y = 0, -- set to FLOOR_Y+1 in initLevels
    light_idx = 1,
    home_y = 0, -- set in main() from GPS on fresh start, persisted for resume
    x = 0,
    y = 0,
    z = 0,
    facing = HOME_FACING,
}

---------------------------------------------
-- PROGRESS PERSISTENCE
---------------------------------------------

local function saveState()
    state.x, state.y, state.z, state.facing = x, y, z, facing
    local f = fs.open(PROGRESS_FILE, "w")
    for k, v in pairs(state) do
        f.writeLine(k .. "=" .. tostring(v))
    end
    f.close()
end

local function loadState()
    if not fs.exists(PROGRESS_FILE) then return false end
    local f = fs.open(PROGRESS_FILE, "r")
    while true do
        local line = f.readLine()
        if not line then break end
        local k, v = line:match("^([%w_]+)=(.+)$")
        if k and v then
            state[k] = tonumber(v) or v
        end
    end
    f.close()
    -- Restore position from saved state
    x, y, z, facing = state.x, state.y, state.z, state.facing
    return true
end

local function clearState()
    if fs.exists(PROGRESS_FILE) then fs.delete(PROGRESS_FILE) end
end

---------------------------------------------
-- UPTIME TRACKING
---------------------------------------------

local priorUptime = 0 -- accumulated from previous runs

local function loadUptime()
    if fs.exists(UPTIME_FILE) then
        local f = fs.open(UPTIME_FILE, "r")
        priorUptime = tonumber(f.readAll()) or 0
        f.close()
    end
end

local function saveUptime(sessionStart)
    local total = priorUptime + (os.clock() - (sessionStart or 0))
    local f = fs.open(UPTIME_FILE, "w")
    f.write(tostring(total))
    f.close()
end

---------------------------------------------
-- REDNET BROADCASTING
---------------------------------------------

local modemSide = nil

---------------------------------------------
-- GPS LOCALIZATION
---------------------------------------------

-- Try to locate via GPS. Returns x, y, z or nil if GPS unavailable.
local function gpsLocate()
    if not gps or not gps.locate then return nil end
    local gx, gy, gz = gps.locate(3)
    if not gx then return nil end
    return gx, gy, gz
end

-- Determine the turtle's current facing by moving forward one block via GPS delta.
-- Returns the new facing (0-3) or nil if detection failed.
-- Leaves the turtle at its original position.
local function detectFacingGPS()
    local gx1, _, gz1 = gpsLocate()
    if not gx1 then return nil end

    -- Try to move forward, turning right if blocked
    local turns = 0
    while not turtle.forward() do
        if turtle.detect() then
            return nil -- can't determine without digging
        end
        turtle.turnRight()
        turns = turns + 1
        if turns >= 4 then return nil end
    end

    local gx2, _, gz2 = gpsLocate()
    if not gx2 then
        turtle.back()
        return nil
    end

    local dx, dz = gx2 - gx1, gz2 - gz1
    local detectedFacing
    if dx == 1 then
        detectedFacing = 0 -- east
    elseif dz == 1 then
        detectedFacing = 1 -- south
    elseif dx == -1 then
        detectedFacing = 2 -- west
    elseif dz == -1 then
        detectedFacing = 3 -- north
    end

    turtle.back()
    return detectedFacing
end

-- Full GPS localization: sets x, y, z, facing from actual world position.
-- Returns true on success, false if GPS unavailable.
local function localizeGPS()
    local gx, gy, gz = gpsLocate()
    if not gx then
        print("  GPS unavailable — using saved position")
        return false
    end
    print("  GPS position: " .. gx .. "," .. gy .. "," .. gz)
    local newFacing = detectFacingGPS()
    if newFacing == nil then
        print("  Facing detection failed — keeping saved facing")
    else
        print("  GPS facing: " .. newFacing)
        facing = newFacing
    end
    x, y, z = gx, gy, gz
    return true
end

---------------------------------------------
-- REDNET BROADCASTING
---------------------------------------------

local function initRednet()
    local modem = peripheral.find("modem")
    if not modem then
        error("No modem found! A wireless modem is required for remote monitoring.")
    end
    modemSide = peripheral.getName(modem)
    rednet.open(modemSide)
    print("  Rednet open on " .. modemSide)
end

-- Stats tracking for progress display
local stats = {
    blocks_broken    = 0,
    blocks_total     = 0,
    blocks_placed    = 0,
    place_total      = 0,
    lights_placed    = 0,
    lights_total     = 0,
    program_start    = 0, -- os.clock() when program began (set once)
    phase_start      = 0, -- os.clock() when the current phase began
}

local lastBroadcast = 0
local BROADCAST_INTERVAL = 2 -- seconds between auto-broadcasts

local function computeETA()
    -- Simple per-phase ETA: time elapsed in current phase / work done so far,
    -- extrapolated to the remaining work. Recomputed on every broadcast so it
    -- self-corrects as the rate changes.
    if not stats.phase_start or stats.phase_start == 0 then return nil end
    local elapsed = os.clock() - stats.phase_start
    local done, total = 0, 0
    if stats.blocks_total > 0 then
        done, total = stats.blocks_broken, stats.blocks_total
    elseif stats.place_total > 0 then
        done, total = stats.blocks_placed, stats.place_total
    elseif stats.lights_total > 0 then
        done, total = stats.lights_placed, stats.lights_total
    end
    if done <= 0 or total <= 0 or elapsed <= 0 then return nil end
    local remaining = total - done
    if remaining <= 0 then return 0 end
    return math.floor(remaining * elapsed / done)
end

local function broadcast(extra)
    if not modemSide then return end
    stats.eta = computeETA()
    local msg = {
        turtle       = "floor_builder",
        floor_y      = FLOOR_Y,
        phase        = state.phase,
        dig_pass     = state.dig_pass,
        row_z        = state.row_z,
        wall_y       = state.wall_y,
        light_idx    = state.light_idx,
        fuel         = turtle.getFuelLevel(),
        pos          = { x = x, y = y, z = z },
        uptime       = stats.program_start > 0 and (os.clock() - stats.program_start) or 0,
        total_uptime = priorUptime + (stats.program_start > 0 and (os.clock() - stats.program_start) or 0),
        stats        = stats,
    }
    if extra then
        for k, v in pairs(extra) do msg[k] = v end
    end
    pcall(function() rednet.broadcast(msg, REDNET_PROTOCOL) end)
    lastBroadcast = os.clock()
end

local function tickBroadcast()
    if os.clock() - lastBroadcast >= BROADCAST_INTERVAL then
        broadcast()
    end
end

---------------------------------------------
-- MOVEMENT
---------------------------------------------

-- Forward declarations (used by ensureFuel before definition)
local ascendToHome
local moveToY, moveToX, moveToZ, moveTo

local function turnRight()
    turtle.turnRight()
    facing = (facing + 1) % 4
    pcall(saveState)
end

local function turnLeft()
    turtle.turnLeft()
    facing = (facing - 1) % 4
    pcall(saveState)
end

local function face(dir)
    local diff = (dir - facing) % 4
    if diff == 1 then
        turnRight()
    elseif diff == 2 then
        turnRight(); turnRight()
    elseif diff == 3 then
        turnLeft()
    end
end

local function ensureFuel(min)
    if turtle.getFuelLevel() == "unlimited" then return end
    if turtle.getFuelLevel() >= min then return end
    -- Try to consume fuel from inventory first
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and d.name == FUEL_ITEM then
            turtle.select(s)
            turtle.refuel(64)
            if turtle.getFuelLevel() >= min then
                turtle.select(1); return
            end
        end
    end
    turtle.select(1)
    -- Still not enough — go home and wait for coal
    if turtle.getFuelLevel() < min then
        print("  FUEL CRITICAL (" .. turtle.getFuelLevel() .. "/" .. min .. ")")
        print("  Returning home for coal...")
        local rx, ry, rz, rf = x, y, z, facing
        ascendToHome()
        moveToY(HOME_Y + 1) -- coal chest level
        face(1)             -- south
        while turtle.getFuelLevel() < min do
            local sucked = false
            for _ = 1, 4 do
                if turtle.suck(64) then sucked = true end
            end
            -- Consume whatever we got
            for s2 = 1, 16 do
                local d2 = turtle.getItemDetail(s2)
                if d2 and d2.name == FUEL_ITEM then
                    turtle.select(s2)
                    turtle.refuel(64)
                end
            end
            if turtle.getFuelLevel() < min and not sucked then
                print("  Coal chest empty! Restock and press any key...")
                os.pullEvent("key")
            end
        end
        moveToY(HOME_Y)
        turtle.select(1)
        moveTo(rx, ry, rz)
        face(rf)
    end
end

local function fwd()
    ensureFuel(10)
    for attempt = 1, 60 do
        if turtle.forward() then
            x = x + DX[facing]
            z = z + DZ[facing]
            pcall(saveState) -- persist actual position on every move
            tickBroadcast()
            return true
        end
        if turtle.detect() then
            turtle.dig()
        end
        turtle.attack()
        sleep(0.1)
    end
    error("Stuck forward at " .. x .. "," .. y .. "," .. z)
end

local function goUp()
    ensureFuel(10)
    for attempt = 1, 60 do
        if turtle.up() then
            y = y + 1
            pcall(saveState)
            tickBroadcast()
            return true
        end
        if turtle.detectUp() then
            turtle.digUp()
        end
        sleep(0.1)
    end
    error("Stuck up at " .. x .. "," .. y .. "," .. z)
end

local function goDown()
    ensureFuel(10)
    for attempt = 1, 60 do
        if turtle.down() then
            y = y - 1
            pcall(saveState)
            tickBroadcast()
            return true
        end
        if turtle.detectDown() then
            turtle.digDown()
        end
        sleep(0.1)
    end
    error("Stuck down at " .. x .. "," .. y .. "," .. z)
end

moveToY = function(ty)
    while y < ty do goUp() end
    while y > ty do goDown() end
end

moveToX = function(tx)
    if tx > x then face(0) elseif tx < x then face(2) end
    while x ~= tx do fwd() end
end

moveToZ = function(tz)
    if tz > z then face(1) elseif tz < z then face(3) end
    while z ~= tz do fwd() end
end

moveTo = function(tx, ty, tz)
    moveToY(ty)
    moveToX(tx)
    moveToZ(tz)
end

ascendToHome = function()
    -- Move to shaft column at current Y, then ascend
    moveToX(SHAFT_X)
    moveToZ(SHAFT_Z)
    moveToY(HOME_Y)
end

---------------------------------------------
-- LIQUID HANDLING
---------------------------------------------

local LIQUIDS = {
    ["minecraft:water"] = true,
    ["minecraft:flowing_water"] = true,
    ["minecraft:lava"] = true,
    ["minecraft:flowing_lava"] = true,
}

local function isLiquid(inspectFn)
    local ok, data = inspectFn()
    return ok and LIQUIDS[data.name]
end

local function findStone()
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and d.name == SMOOTH_STONE then return s end
    end
    return nil
end

local function handleLiquid(direction)
    local inspect, place, dig
    if direction == "up" then
        inspect, place, dig = turtle.inspectUp, turtle.placeUp, turtle.digUp
    elseif direction == "down" then
        inspect, place, dig = turtle.inspectDown, turtle.placeDown, turtle.digDown
    else
        inspect, place, dig = turtle.inspect, turtle.place, turtle.dig
    end

    if not isLiquid(inspect) then return false end

    -- Must have stone — if not, go home and wait for restock
    while not findStone() do
        print("  LIQUID detected but no smooth stone!")
        print("  Returning home to restock...")
        local rx, ry, rz, rf = x, y, z, facing
        ascendToHome()
        face(0) -- east toward stone chest
        while not turtle.suck(64) do
            print("  Stone chest empty! Restock and press any key...")
            os.pullEvent("key")
        end
        moveTo(rx, ry, rz)
        face(rf)
    end

    local s = findStone()
    turtle.select(s)
    place() -- place stone into the liquid source to destroy it
    dig()   -- break the stone back
    turtle.select(1)
    return true
end

local function checkLiquids()
    handleLiquid("forward")
    handleLiquid("up")
    handleLiquid("down")
end

---------------------------------------------
-- INVENTORY
---------------------------------------------

local function countFreeSlots()
    local n = 0
    for s = 1, 16 do
        if turtle.getItemCount(s) == 0 then n = n + 1 end
    end
    return n
end

local function needsDump()
    return (16 - countFreeSlots()) >= DUMP_THRESHOLD
end

local function findItem(name)
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and d.name == name then return s end
    end
    return nil
end

local function selectItem(name)
    local s = findItem(name)
    if s then
        turtle.select(s); return true
    end
    return false
end

-- Select an item, going home to restock if not in inventory.
-- restockFn should be goHomeAndGetStone or goHomeAndGetLights.
-- Waits for the player to refill the chest if it's empty.
local function requireItem(name, restockFn, chestLabel)
    if selectItem(name) then return true end

    -- Not in inventory — go home and restock
    local rx, ry, rz, rf = x, y, z, facing
    while true do
        restockFn()
        if selectItem(name) then
            moveTo(rx, ry, rz)
            face(rf)
            return true
        end
        print("  " .. chestLabel .. " chest is empty!")
        print("  Need: " .. name)
        print("  Restock and press any key...")
        os.pullEvent("key")
    end
end

---------------------------------------------
-- CHEST INTERACTION
---------------------------------------------

-- All chest ops start by ascending to home.
-- Front (east): stone at Y=22, lights at Y=23
-- Right (south): dump at Y=22, coal at Y=23

local function goHomeAndDump()
    local rx, ry, rz, rf = x, y, z, facing
    ascendToHome()
    face(1) -- south toward dump chest
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and d.name ~= FUEL_ITEM and d.name ~= SMOOTH_STONE then
            turtle.select(s)
            turtle.drop()
        end
        -- Also dump excess stone (keep max 1 stack)
        if d and d.name == SMOOTH_STONE and d.count > 64 then
            turtle.select(s)
            turtle.drop(d.count - 64)
        end
    end
    turtle.select(1)
    return rx, ry, rz, rf
end

local function goHomeAndRefuel()
    ascendToHome()
    moveToY(HOME_Y + 1) -- coal chest is at Y=23 (above dump chest)
    face(1)             -- south
    for _ = 1, 4 do
        turtle.suck(64)
    end
    moveToY(HOME_Y)
    -- Consume all coal
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and d.name == FUEL_ITEM then
            turtle.select(s)
            turtle.refuel(64)
        end
    end
    turtle.select(1)
end

local function goHomeAndGetStone()
    ascendToHome()
    face(0) -- east toward stone chest
    for s = 1, 15 do
        if turtle.getItemCount(s) == 0 then
            turtle.select(s)
            if not turtle.suck(64) then break end
        end
    end
    turtle.select(1)
end

local function goHomeAndGetLights()
    ascendToHome()
    moveToY(HOME_Y + 1) -- lights chest is at Y=23 (above stone chest)
    face(0)             -- east
    for s = 1, 15 do
        if turtle.getItemCount(s) == 0 then
            turtle.select(s)
            if not turtle.suck(64) then break end
        end
    end
    moveToY(HOME_Y)
    turtle.select(1)
end

local function checkAndRefuel()
    if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < MIN_FUEL then
        local rx, ry, rz, rf = x, y, z, facing
        goHomeAndRefuel()
        moveTo(rx, ry, rz)
        face(rf)
    end
end

---------------------------------------------
-- LIGHT COORDINATE BUILDERS
---------------------------------------------

local function buildFloorLightTargets()
    local list = {}
    -- Row A: z step 8 from 2576, x step 8 from -3396
    for tz = 2576, 2672, 8 do
        for tx = -3396, -3300, 8 do
            if not (tx == CENTER_X and tz == CENTER_Z) then
                list[#list + 1] = { x = tx, z = tz }
            end
        end
    end
    -- Row B: z step 8 from 2580, x step 8 from -3392
    for tz = 2580, 2668, 8 do
        for tx = -3392, -3304, 8 do
            list[#list + 1] = { x = tx, z = tz }
        end
    end
    return list
end

local function buildCeilingLightTargets()
    local list = {}
    -- Row A': Row A x-list with Row B z-list
    for tz = 2580, 2668, 8 do
        for tx = -3396, -3300, 8 do
            list[#list + 1] = { x = tx, z = tz }
        end
    end
    -- Row B': Row B x-list with Row A z-list
    for tz = 2576, 2672, 8 do
        for tx = -3392, -3304, 8 do
            list[#list + 1] = { x = tx, z = tz }
        end
    end
    return list
end

-- Wall lights form an X-pattern (5 lights in a 3×3 box) at each center.
-- Offsets are (along-wall horizontal, vertical Y), ordered bottom→top for
-- smooth turtle motion between patterns.
local WALL_LIGHT_MARGIN    = 2 -- no lights in first N blocks of any wall edge
local WALL_LIGHT_STEP      = 8 -- spacing between pattern centers
local WALL_PATTERN_OFFSETS = {
    { -1, -1 }, { 1, -1 },
    { 0,  0 },
    { -1, 1 }, { 1, 1 },
}

local function wallPatternCenters(lo, hi)
    -- Centers must be ≥ MARGIN+1 inside so tips at ±1 stay ≥ MARGIN from edge
    local first_ok = lo + WALL_LIGHT_MARGIN + 1
    local last_ok = hi - WALL_LIGHT_MARGIN - 1
    if first_ok > last_ok then return {} end
    local span = last_ok - first_ok
    local n = math.floor(span / WALL_LIGHT_STEP) + 1
    local slack = span - (n - 1) * WALL_LIGHT_STEP
    local first = first_ok + math.floor(slack / 2)
    local out = {}
    for i = 0, n - 1 do out[#out + 1] = first + i * WALL_LIGHT_STEP end
    return out
end

local function buildWallLightTargets()
    local list = {}
    local y_min = FLOOR_Y + 1 + WALL_LIGHT_MARGIN
    local y_max = CEILING_Y - 1 - WALL_LIGHT_MARGIN

    local function addPattern(centers, axis, fixed_val, dir)
        for _, c in ipairs(centers) do
            for _, o in ipairs(WALL_PATTERN_OFFSETS) do
                local h = c + o[1]
                local ly = WALL_LIGHT_Y + o[2]
                if ly >= y_min and ly <= y_max then
                    local lx, lz
                    if axis == "x" then
                        lx, lz = h, fixed_val
                    else
                        lx, lz = fixed_val, h
                    end
                    -- Per-tip margin check (defense in depth)
                    if lx >= INT_X_MIN + WALL_LIGHT_MARGIN
                        and lx <= INT_X_MAX - WALL_LIGHT_MARGIN
                        and lz >= INT_Z_MIN + WALL_LIGHT_MARGIN
                        and lz <= INT_Z_MAX - WALL_LIGHT_MARGIN then
                        list[#list + 1] = { x = lx, y = ly, z = lz, dir = dir }
                    end
                end
            end
        end
    end

    local x_centers = wallPatternCenters(INT_X_MIN, INT_X_MAX)
    local z_centers = wallPatternCenters(INT_Z_MIN, INT_Z_MAX)
    addPattern(x_centers, "x", INT_Z_MIN, 3) -- north wall, face north
    addPattern(x_centers, "x", INT_Z_MAX, 1) -- south wall, face south
    addPattern(z_centers, "z", INT_X_MIN, 2) -- west wall, face west
    addPattern(z_centers, "z", INT_X_MAX, 0) -- east wall, face east
    return list
end

---------------------------------------------
-- SERPENTINE HELPER
---------------------------------------------

-- Call fn(rx, rz) for each position in a 103x103 serpentine, resumable from start_z
local function serpentine(nav_y, start_z, fn)
    for rz = start_z, AREA_Z_MAX do
        local row_idx = rz - AREA_Z_MIN
        local going_east = (row_idx % 2 == 0)
        local x_from = going_east and AREA_X_MIN or AREA_X_MAX
        local x_to = going_east and AREA_X_MAX or AREA_X_MIN
        local x_step = going_east and 1 or -1

        moveToZ(rz)
        for rx = x_from, x_to, x_step do
            moveToX(rx)
            fn(rx, rz)
        end

        -- Update and save progress after each row
        state.row_z = rz + 1
        saveState()
        broadcast()
    end
end

---------------------------------------------
-- PHASE 1: DIG
---------------------------------------------

local function phaseDig()
    print("=== Phase: DIG ===")
    print("  Passes: " .. #DIG_PASSES .. ", layers " .. DIG_TOP_Y .. " to " .. DIG_BOT_Y)

    local start_pass = state.dig_pass or 1
    local start_row = state.row_z or AREA_Z_MIN
    local area_w = AREA_X_MAX - AREA_X_MIN + 1
    local area_d = AREA_Z_MAX - AREA_Z_MIN + 1
    local blocks_per_pass = area_w * area_d -- positions per pass (each digs up to 2 blocks)

    -- Estimate total blocks: each pass position digs 1 (nav) + dig_up + dig_down
    local total_blocks = 0
    for _, p in ipairs(DIG_PASSES) do
        local layers = 1 -- nav layer
        if p.dig_up then layers = layers + 1 end
        if p.dig_down then layers = layers + 1 end
        total_blocks = total_blocks + blocks_per_pass * layers
    end
    stats.blocks_total = total_blocks
    -- Estimate already done from resume
    local done_blocks = 0
    for pi = 1, start_pass - 1 do
        local p = DIG_PASSES[pi]
        local layers = 1
        if p.dig_up then layers = layers + 1 end
        if p.dig_down then layers = layers + 1 end
        done_blocks = done_blocks + blocks_per_pass * layers
    end
    -- Partial pass: estimate from rows completed
    if start_pass <= #DIG_PASSES then
        local p = DIG_PASSES[start_pass]
        local layers = 1
        if p.dig_up then layers = layers + 1 end
        if p.dig_down then layers = layers + 1 end
        done_blocks = done_blocks + (start_row - AREA_Z_MIN) * area_w * layers
    end
    stats.blocks_broken = done_blocks
    stats.phase_start = os.clock()

    for pi = start_pass, #DIG_PASSES do
        local pass = DIG_PASSES[pi]
        print("  Pass " .. pi .. "/" .. #DIG_PASSES .. " at Y=" .. pass.nav_y)

        -- Navigate to shaft, descend to working Y
        moveToX(SHAFT_X)
        moveToZ(SHAFT_Z)
        moveToY(pass.nav_y)

        local z_start = (pi == start_pass) and start_row or AREA_Z_MIN

        -- Helper: dig up and down at current position
        local function digColumn()
            local dug = 0
            if pass.dig_up then
                handleLiquid("up")
                while turtle.detectUp() do
                    turtle.digUp(); sleep(0.05)
                end
                dug = dug + 1
            end
            if pass.dig_down then
                handleLiquid("down")
                while turtle.detectDown() do
                    turtle.digDown(); sleep(0.05)
                end
                dug = dug + 1
            end
            return dug
        end

        for rz = z_start, AREA_Z_MAX do
            local row_idx = rz - AREA_Z_MIN
            local going_east = (row_idx % 2 == 0)
            local x_from = going_east and AREA_X_MIN or AREA_X_MAX
            local x_to = going_east and AREA_X_MAX or AREA_X_MIN
            local x_step = going_east and 1 or -1

            moveToZ(rz)
            -- Clear the column at the row-start position before entering for loop
            stats.blocks_broken = stats.blocks_broken + digColumn() + 1

            for rx = x_from, x_to, x_step do
                moveToX(rx)

                -- Clear above and below (nav layer already cleared by fwd movement)
                local dug = digColumn() + 1
                -- Also check forward for liquids before next move
                handleLiquid("forward")
                stats.blocks_broken = stats.blocks_broken + dug

                -- Dump if inventory is getting full
                if needsDump() then
                    local rx2, ry2, rz2, rf2 = goHomeAndDump()
                    checkAndRefuel()
                    moveTo(rx2, ry2, rz2)
                    face(rf2)
                    -- Re-clear column after dump trip — return path may have passed
                    -- through undug caves leaving stale blocks above/below
                    digColumn()
                end
            end

            -- Row done
            state.dig_pass = pi
            state.row_z = rz + 1
            saveState()
            broadcast()
        end

        -- Pass complete
        state.row_z = AREA_Z_MIN
    end

    state.phase = "ceiling"
    state.dig_pass = 1
    state.row_z = AREA_Z_MIN
    saveState()
    broadcast({ event = "phase_complete", completed = "dig" })
    print("  Dig complete!")
end

---------------------------------------------
-- PHASE 2: CEILING
---------------------------------------------

local function phaseCeiling()
    print("=== Phase: CEILING at Y=" .. CEILING_Y .. " ===")
    local nav_y = CEILING_Y + 1
    local start_z = state.row_z or AREA_Z_MIN
    local placed = 0
    local area_w = AREA_X_MAX - AREA_X_MIN + 1

    stats.place_total = (AREA_X_MAX - AREA_X_MIN + 1) * (AREA_Z_MAX - AREA_Z_MIN + 1) - 1 -- minus shaft
    stats.blocks_placed = (start_z - AREA_Z_MIN) * area_w                                 -- estimate from resume
    stats.phase_start = os.clock()

    -- Initial stone restock
    goHomeAndGetStone()
    moveToX(SHAFT_X)
    moveToZ(SHAFT_Z)
    moveToY(nav_y)

    serpentine(nav_y, start_z, function(rx, rz)
        -- Skip shaft hole
        if rx == SHAFT_X and rz == SHAFT_Z then return end

        if not turtle.detectDown() then
            requireItem(SMOOTH_STONE, goHomeAndGetStone, "Stone")
            turtle.placeDown()
            placed = placed + 1
        end
        stats.blocks_placed = stats.blocks_placed + 1
    end)

    state.phase = "floor_place"
    state.row_z = AREA_Z_MIN
    saveState()
    broadcast({ event = "phase_complete", completed = "ceiling" })
    print("  Ceiling complete! Placed " .. placed .. " blocks")
end

---------------------------------------------
-- PHASE 3: FLOOR
---------------------------------------------

local function phaseFloor()
    print("=== Phase: FLOOR at Y=" .. FLOOR_Y .. " ===")
    local nav_y = FLOOR_Y + 1
    local start_z = state.row_z or AREA_Z_MIN
    local placed = 0
    local area_w = AREA_X_MAX - AREA_X_MIN + 1

    stats.place_total = (AREA_X_MAX - AREA_X_MIN + 1) * (AREA_Z_MAX - AREA_Z_MIN + 1) - 1
    stats.blocks_placed = (start_z - AREA_Z_MIN) * area_w
    stats.phase_start = os.clock()

    goHomeAndGetStone()
    moveToX(SHAFT_X)
    moveToZ(SHAFT_Z)
    moveToY(nav_y)

    serpentine(nav_y, start_z, function(rx, rz)
        if rx == SHAFT_X and rz == SHAFT_Z then return end

        if not turtle.detectDown() then
            requireItem(SMOOTH_STONE, goHomeAndGetStone, "Stone")
            turtle.placeDown()
            placed = placed + 1
        end
        stats.blocks_placed = stats.blocks_placed + 1
    end)

    state.phase = "walls"
    state.row_z = AREA_Z_MIN
    saveState()
    broadcast({ event = "phase_complete", completed = "floor_place" })
    print("  Floor complete! Placed " .. placed .. " blocks")
end

---------------------------------------------
-- PHASE 4: WALLS
---------------------------------------------

local function phaseWalls()
    print("=== Phase: WALLS Y=" .. (FLOOR_Y + 1) .. " to " .. (CEILING_Y - 1) .. " ===")
    local start_wy = state.wall_y or (FLOOR_Y + 1)
    local area_w = AREA_X_MAX - AREA_X_MIN + 1
    local area_d = AREA_Z_MAX - AREA_Z_MIN + 1
    -- Each layer places perimeter blocks; corners are placed once by the wall
    -- that reaches them first, so subtract 4 shared corners.
    local perimeter = (area_w + area_d) * 2 - 4
    local total_layers = CEILING_Y - 1 - FLOOR_Y
    local done_layers = start_wy - (FLOOR_Y + 1)

    stats.place_total = perimeter * total_layers
    stats.blocks_placed = perimeter * done_layers
    stats.phase_start = os.clock()

    local function placeWall(dir)
        if not turtle.detect() then
            requireItem(SMOOTH_STONE, goHomeAndGetStone, "Stone")
            face(dir)
            turtle.place()
        end
        stats.blocks_placed = stats.blocks_placed + 1
    end

    for wy = start_wy, CEILING_Y - 1 do
        print("  Wall layer Y=" .. wy)
        goHomeAndGetStone()
        moveToX(SHAFT_X)
        moveToZ(SHAFT_Z)
        moveToY(wy)

        -- North wall: full width including both corners
        moveToZ(INT_Z_MIN)
        for wx = AREA_X_MIN, AREA_X_MAX do
            moveToX(wx)
            face(3)
            placeWall(3)
        end

        -- East wall: skip NE corner (already placed by north). Start one block
        -- inside so we don't dig through the freshly-placed north wall row.
        moveToX(INT_X_MAX)
        for wz = INT_Z_MIN, AREA_Z_MAX do
            moveToZ(wz)
            face(0)
            placeWall(0)
        end

        -- South wall: skip SE corner (already placed by east).
        moveToZ(INT_Z_MAX)
        for wx = INT_X_MAX, AREA_X_MIN, -1 do
            moveToX(wx)
            face(1)
            placeWall(1)
        end

        -- West wall: skip SW corner (already placed by south) AND NW corner
        -- (already placed by north).
        moveToX(INT_X_MIN)
        for wz = INT_Z_MAX, INT_Z_MIN, -1 do
            moveToZ(wz)
            face(2)
            placeWall(2)
        end

        state.wall_y = wy + 1
        saveState()
        broadcast()
    end

    state.phase = "floor_lights"
    state.wall_y = FLOOR_Y + 1
    state.light_idx = 1
    saveState()
    broadcast({ event = "phase_complete", completed = "walls" })
    print("  Walls complete!")
end

---------------------------------------------
-- PHASE 5: FLOOR LIGHTS
---------------------------------------------

local function phaseFloorLights()
    print("=== Phase: FLOOR LIGHTS at Y=" .. FLOOR_Y .. " ===")
    local targets = buildFloorLightTargets()
    local nav_y = FLOOR_Y + 1
    local start_idx = state.light_idx or 1

    stats.lights_total = #targets
    stats.lights_placed = start_idx - 1
    stats.phase_start = os.clock()

    goHomeAndGetLights()
    moveToX(SHAFT_X)
    moveToZ(SHAFT_Z)
    moveToY(nav_y)

    for i = start_idx, #targets do
        local t = targets[i]
        moveTo(t.x, nav_y, t.z)

        -- Dig the smooth stone floor block, replace with light
        if turtle.detectDown() then
            local ok, data = turtle.inspectDown()
            if ok and data.name == SMOOTH_STONE then
                turtle.digDown()
                requireItem(LIGHT_NAME, goHomeAndGetLights, "Lights")
                turtle.placeDown()
            end
        end

        stats.lights_placed = i
        state.light_idx = i + 1
        if i % 20 == 0 then
            saveState(); broadcast()
        end
    end

    state.phase = "ceiling_lights"
    state.light_idx = 1
    saveState()
    broadcast({ event = "phase_complete", completed = "floor_lights" })
    print("  Floor lights complete! (" .. #targets .. " lights)")
end

---------------------------------------------
-- PHASE 6: CEILING LIGHTS
---------------------------------------------

local function phaseCeilingLights()
    print("=== Phase: CEILING LIGHTS at Y=" .. CEILING_Y .. " ===")
    local targets = buildCeilingLightTargets()
    local nav_y = CEILING_Y - 1
    local start_idx = state.light_idx or 1

    stats.lights_total = #targets
    stats.lights_placed = start_idx - 1
    stats.phase_start = os.clock()

    goHomeAndGetLights()
    moveToX(SHAFT_X)
    moveToZ(SHAFT_Z)
    moveToY(nav_y)

    for i = start_idx, #targets do
        local t = targets[i]
        moveTo(t.x, nav_y, t.z)

        if turtle.detectUp() then
            local ok, data = turtle.inspectUp()
            if ok and data.name == SMOOTH_STONE then
                turtle.digUp()
                requireItem(LIGHT_NAME, goHomeAndGetLights, "Lights")
                turtle.placeUp()
            end
        end

        stats.lights_placed = i
        state.light_idx = i + 1
        if i % 20 == 0 then
            saveState(); broadcast()
        end
    end

    state.phase = "wall_lights"
    state.light_idx = 1
    saveState()
    broadcast({ event = "phase_complete", completed = "ceiling_lights" })
    print("  Ceiling lights complete! (" .. #targets .. " lights)")
end

---------------------------------------------
-- PHASE 7: WALL LIGHTS
---------------------------------------------

local function phaseWallLights()
    print("=== Phase: WALL LIGHTS at Y=" .. WALL_LIGHT_Y .. " ===")
    local targets = buildWallLightTargets()
    local start_idx = state.light_idx or 1

    stats.lights_total = #targets
    stats.lights_placed = start_idx - 1
    stats.phase_start = os.clock()

    goHomeAndGetLights()
    moveToX(SHAFT_X)
    moveToZ(SHAFT_Z)
    moveToY(WALL_LIGHT_Y)

    for i = start_idx, #targets do
        local t = targets[i]
        moveTo(t.x, t.y, t.z)
        face(t.dir)

        if turtle.detect() then
            local ok, data = turtle.inspect()
            if ok and data.name == SMOOTH_STONE then
                turtle.dig()
                requireItem(LIGHT_NAME, goHomeAndGetLights, "Lights")
                turtle.place()
            end
        end

        stats.lights_placed = i
        state.light_idx = i + 1
        if i % 10 == 0 then
            saveState(); broadcast()
        end
    end

    state.phase = "done"
    saveState()
    broadcast({ event = "phase_complete", completed = "wall_lights" })
    print("  Wall lights complete! (" .. #targets .. " lights)")
end

---------------------------------------------
-- STATUS DISPLAY
---------------------------------------------

local function printStatus()
    if not loadState() then
        print("No progress file found. Fresh start.")
        return
    end
    print("Floor Builder Status:")
    print("  Phase:     " .. state.phase)
    print("  Dig pass:  " .. (state.dig_pass or "-"))
    print("  Row Z:     " .. (state.row_z or "-"))
    print("  Wall Y:    " .. (state.wall_y or "-"))
    print("  Light idx: " .. (state.light_idx or "-"))
    print("  Position:  " .. state.x .. "," .. state.y .. "," .. state.z)
    print("  Facing:    " .. state.facing)
    print("")
    print("Y levels: ceiling=" .. CEILING_Y .. " floor=" .. FLOOR_Y)
    print("Dig: Y=" .. DIG_TOP_Y .. " to " .. DIG_BOT_Y .. " (" .. #DIG_PASSES .. " passes)")
end

---------------------------------------------
-- PHASE ORDERING
---------------------------------------------

local PHASES = {
    { name = "dig",            fn = phaseDig },
    { name = "ceiling",        fn = phaseCeiling },
    { name = "floor_place",    fn = phaseFloor },
    { name = "walls",          fn = phaseWalls },
    { name = "floor_lights",   fn = phaseFloorLights },
    { name = "ceiling_lights", fn = phaseCeilingLights },
    { name = "wall_lights",    fn = phaseWallLights },
}

local function phaseIndex(name)
    for i, p in ipairs(PHASES) do
        if p.name == name then return i end
    end
    return #PHASES + 1
end

local function runFromPhase(fromName, toName)
    stats.program_start = os.clock()
    local from = phaseIndex(fromName or state.phase)
    local to = toName and phaseIndex(toName) or #PHASES
    for i = from, to do
        if phaseIndex(state.phase) <= i then
            -- Reset per-phase counters; each phase sets phase_start itself
            stats.blocks_broken = 0
            stats.blocks_total = 0
            stats.blocks_placed = 0
            stats.place_total = 0
            stats.lights_placed = 0
            stats.lights_total = 0
            saveUptime(stats.program_start)
            PHASES[i].fn()
        end
    end
end

---------------------------------------------
-- MAIN
---------------------------------------------

local args = { ... }

local function main()
    if args[1] == "status" then
        printStatus()
        return
    end

    loadUptime()

    -- Load saved progress (or start fresh)
    local resumed = loadState()

    -- Determine mode: explicit arg > saved mode > "build"
    local mode = args[1] or (resumed and state.mode) or "build"
    state.mode = mode

    -- Determine HOME_Y. On fresh start, the turtle must be sitting at home
    -- (on top of the floor above the one to dig) so GPS gives us that Y.
    -- On resume, HOME_Y comes from persisted state since the turtle may be
    -- anywhere in the dig area.
    if resumed and state.home_y and state.home_y ~= 0 then
        HOME_Y = state.home_y
    else
        local _, gy, _ = gpsLocate()
        if not gy then
            error("GPS unavailable on fresh start — cannot determine HOME_Y. " ..
                "Ensure an ender modem is equipped and a GPS constellation is in range.")
        end
        HOME_Y = gy
        state.home_y = HOME_Y
    end
    initLevels()
    state.wall_y = FLOOR_Y + 1

    print("==========================================")
    print("  Underground Floor Builder")
    print("  Home Y=" .. HOME_Y)
    print("  Ceiling Y=" .. CEILING_Y .. "  Floor Y=" .. FLOOR_Y)
    print("  Interior: " .. INTERIOR_HEIGHT .. " blocks")
    print("  Buffer: " .. BUFFER_LAYERS .. " blocks")
    print("  Dig passes: " .. #DIG_PASSES)
    print("  Wall light Y=" .. WALL_LIGHT_Y)
    print("  Mode: " .. mode)
    print("==========================================")
    print()

    if resumed then
        print("Resuming from: phase=" .. state.phase ..
            " pos=" .. state.x .. "," .. state.y .. "," .. state.z)
    end

    -- Verify actual position via GPS (falls back to saved state if unavailable)
    localizeGPS()

    -- Bootstrap fuel: if turtle can't reach the fuel chest, ask for manual fuel
    if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < MIN_FUEL then
        -- Try inventory fuel first
        for s = 1, 16 do
            local d = turtle.getItemDetail(s)
            if d and d.name == FUEL_ITEM then
                turtle.select(s); turtle.refuel(64)
            end
        end
        turtle.select(1)
        while turtle.getFuelLevel() < MIN_FUEL do
            print("Not enough fuel to reach the fuel chest!")
            print("  Current: " .. turtle.getFuelLevel() .. " / " .. MIN_FUEL)
            print("  Place fuel in the turtle inventory")
            print("  and press any key...")
            os.pullEvent("key")
            for s = 1, 16 do
                local d = turtle.getItemDetail(s)
                if d and d.name == FUEL_ITEM then
                    turtle.select(s); turtle.refuel(64)
                end
            end
            turtle.select(1)
        end
        print("  Fuel OK: " .. turtle.getFuelLevel())
    end

    initRednet()

    if mode == "build" then
        runFromPhase("dig", "wall_lights")
    elseif mode == "dig" then
        runFromPhase("dig", "dig")
    elseif mode == "shell" then
        runFromPhase("ceiling", "walls")
    elseif mode == "lights" then
        runFromPhase("floor_lights", "wall_lights")
    else
        print("Unknown mode: " .. mode)
        print("Usage: floor [build|dig|shell|lights|status]")
        return
    end

    -- Done — go home
    ascendToHome()
    face(HOME_FACING)
    clearState()
    saveUptime(stats.program_start)
    broadcast({ event = "all_complete" })
    print()
    print("==========================================")
    print("  Floor complete! (floor Y=" .. FLOOR_Y .. ")")
    print("==========================================")
end

local ok, err = pcall(main)
if not ok then
    print("ERROR: " .. tostring(err))
    -- Save state on crash so we can resume
    pcall(saveState)
    pcall(saveUptime, stats.program_start)
    pcall(broadcast, { event = "error", message = tostring(err) })
end
