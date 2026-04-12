-- ============================================
-- Mystical Agriculture Farm Builder
-- ATM10 Modpack - ComputerCraft Turtle
-- ============================================
--
-- Setup:
--   1. Place turtle on the outside bottom-left corner of the first chunk
--      (one block south and west of the chunk, facing into the chunk)
--   2. Place a netherite chest (Sophisticated Storage) directly BEHIND the turtle
--   3. Place a small buffer chest to the LEFT of the turtle (for item transfer)
--   4. Place a trash can BELOW the turtle (for voiding dug materials)
--   5. Stock the supply chest with all required materials (see ITEMS table)
--   6. Equip BOTH tools in the turtle's tool slots:
--      - Allthemodium PICKAXE (for breaking blocks)
--      - Allthemodium HOE (for tilling)
--      No need to specify sides — digDown() auto-selects the right tool:
--        * From py=0 (ground block directly below): pickaxe breaks it
--        * From py=1 (air below, ground 2 down): hoe tills it
--   7. Run: farm          (full build)
--      Run: farm accel    (only place MA growth accelerators on existing farms)
--
-- Y-level reference (py=0 is turtle start height, ground surface is below):
--   ground  Dirt/farmland checkerboard, water center, smooth stone perimeter
--   py=0    Crops on farmland, growth accelerators on dirt, harvester pylon
--   py=1    ME glass cables (full 9x9 grid), chest above pylon
--
-- Materials per farm:
--   60  smooth stone           (chunk perimeter)
--   1   water bucket
--   40  red fertilizer         (Farming for Blockheads)
--   40  seeds (one type, or "EMPTY" for no seeds)
--   40  growth accelerators    (AE2)
--   1   harvester pylon        (Pylons)
--   80  fluix ME glass cables  (AE2)
--   1   chest
--   fuel (coal/charcoal)
--   If MA_GROWTH_TIER > 0, per tier per farm:
--     360 MA growth accelerators (40 farmland blocks * 9 blocks per tier)
--     e.g. tier 3 = 360 inferium + 360 prudentium + 360 tertium = 1080 total
--

---------------------------------------------
-- CONFIGURATION
---------------------------------------------

-- One 9x9 farm per seed type. Edit this list to match your needs.
-- Use "EMPTY" for a plot with no seeds (farmland is tilled and fertilized but not planted).
local SEEDS            = {
    "mysticalagriculture:gold_seeds",
    -- "EMPTY",
    -- "mysticalagriculture:prudentium_seeds",
    -- "mysticalagriculture:tertium_seeds",
    -- "mysticalagriculture:imperium_seeds",
    -- "mysticalagriculture:supremium_seeds",
    -- "mysticalagriculture:iron_seeds",
    -- "mysticalagriculture:diamond_seeds",
    -- "mysticalagriculture:netherite_seeds",
    -- "mysticalagriculture:redstone_seeds",
    -- "mysticalagriculture:coal_seeds",
    -- "mysticalagriculture:copper_seeds",
}

-- Item registry names. Verify in-game with JEI or /ct hand.
local ITEMS            = {
    smooth_stone = "minecraft:smooth_stone",
    water_bucket = "minecraft:water_bucket",
    fertilizer   = "farmingforblockheads:red_fertilizer",
    accelerator  = "ae2:growth_accelerator",
    pylon        = "pylons:harvester_pylon",
    me_cable     = "ae2:fluix_glass_cable",
    chest        = "minecraft:chest",
    fuel         = "minecraft:coal",
}

-- Mystical Agriculture growth accelerator tiers (placed under farmland).
-- Set to 0 to disable, 1-6 for tier level.
-- All tiers up to and including this level are placed.
-- Each tier is a 9-block layer. E.g. tier 3 = 27 blocks deep per farmland block:
--   farmland -> 9x inferium -> 9x prudentium -> 9x tertium (deepest)
local MA_GROWTH_TIER   = 3
-- If extending from a previous run, set this to the tier already placed.
-- E.g. previously ran with tier 3, now want tier 5: set MA_GROWTH_TIER=5, MA_EXISTING_TIER=3
-- The program will only place tiers 4 and 5, digging below the existing accelerators.
local MA_EXISTING_TIER = 0

local MA_ACCELERATORS  = {
    "mysticalagriculture:inferium_growth_accelerator",           -- tier 1
    "mysticalagriculture:prudentium_growth_accelerator",         -- tier 2
    "mysticalagriculture:tertium_growth_accelerator",            -- tier 3
    "mysticalagriculture:imperium_growth_accelerator",           -- tier 4
    "mysticalagriculture:supremium_growth_accelerator",          -- tier 5
    "mysticalagriculture:awakened_supremium_growth_accelerator", -- tier 6
}

---------------------------------------------
-- CONSTANTS
---------------------------------------------

local FARM_SIZE        = 9
local CHUNK_SIZE       = 16
local FARM_OFFSET      = 4 -- farm starts at chunk position 4 (0-indexed)
local FARM_CENTER      = 4 -- center of the 9x9 (0-indexed within farm)
local TRAVEL_Y         = 3 -- safe height for long-distance navigation (above cables at py=1)

---------------------------------------------
-- TURTLE STATE
---------------------------------------------

local px, py, pz       = 0, 0, 0
-- 0 = +z (forward/into chunk), 1 = +x (right), 2 = -z (back), 3 = -x (left)
local facing           = 0

local DX               = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local DZ               = { [0] = 1, [1] = 0, [2] = -1, [3] = 0 }

---------------------------------------------
-- MOVEMENT
---------------------------------------------

local function turnRight()
    turtle.turnRight()
    facing = (facing + 1) % 4
end

local function turnLeft()
    turtle.turnLeft()
    facing = (facing - 1) % 4
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

local function tryRefuel()
    if turtle.getFuelLevel() == "unlimited" then return end
    if turtle.getFuelLevel() > 200 then return end
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and d.name == ITEMS.fuel then
            turtle.select(s)
            turtle.refuel(math.min(d.count, 32))
            if turtle.getFuelLevel() > 200 then return end
        end
    end
end

local function forward()
    tryRefuel()
    for _ = 1, 30 do
        if turtle.forward() then
            px = px + DX[facing]
            pz = pz + DZ[facing]
            return true
        end
        turtle.dig()
        turtle.attack()
        sleep(0.3)
    end
    error("Stuck moving forward at (" .. px .. "," .. py .. "," .. pz .. ")")
end

local function up()
    tryRefuel()
    for _ = 1, 30 do
        if turtle.up() then
            py = py + 1
            return true
        end
        turtle.digUp()
        sleep(0.3)
    end
    error("Stuck moving up at (" .. px .. "," .. py .. "," .. pz .. ")")
end

local function down()
    tryRefuel()
    for _ = 1, 30 do
        if turtle.down() then
            py = py - 1
            return true
        end
        turtle.digDown()
        sleep(0.3)
    end
    error("Stuck moving down at (" .. px .. "," .. py .. "," .. pz .. ")")
end

-- Direct movement (no safety height, for local sweeps)
local function moveTo(tx, ty, tz)
    while py < ty do up() end
    while py > ty do down() end
    if px ~= tx then
        face(px < tx and 1 or 3)
        while px ~= tx do forward() end
    end
    if pz ~= tz then
        face(pz < tz and 0 or 2)
        while pz ~= tz do forward() end
    end
end

-- Safe navigation: rises to TRAVEL_Y to clear all structures
local function goTo(tx, ty, tz)
    while py < TRAVEL_Y do up() end
    if px ~= tx then
        face(px < tx and 1 or 3)
        while px ~= tx do forward() end
    end
    if pz ~= tz then
        face(pz < tz and 0 or 2)
        while pz ~= tz do forward() end
    end
    while py > ty do down() end
end

---------------------------------------------
-- INVENTORY
---------------------------------------------

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
        turtle.select(s)
        return true
    end
    print("  WARN: missing " .. name)
    return false
end

-- Peripheral names for the two chests, discovered at startup.
local supplyName = nil
local bufferName = nil

-- Called once at startup while turtle is at home facing forward (toward chunk).
local function initPeripherals()
    face(0) -- face forward for consistent sides
    local supply = peripheral.wrap("back")
    local buffer = peripheral.wrap("left")

    local names = table.concat(peripheral.getNames(), ", ")

    if not supply or not supply.list then
        error("No supply chest found BEHIND turtle.\n  Visible peripherals: " .. names)
    end
    if not buffer or not buffer.list then
        error("No buffer chest found to the LEFT of turtle.\n  Visible peripherals: " .. names)
    end

    supplyName = peripheral.getName(supply)
    bufferName = peripheral.getName(buffer)
    print("  Supply chest: " .. supplyName)
    print("  Buffer chest: " .. bufferName)
end

-- Go home and void all non-fuel items into trash can below
local function voidWaste()
    goTo(0, 0, 0)
    face(0)
    for s = 1, 16 do
        local d = turtle.getItemDetail(s)
        if d and d.name ~= ITEMS.fuel then
            turtle.select(s)
            turtle.dropDown() -- into trash can below turtle
        end
    end
    turtle.select(1)
end

-- Go home, dump inventory, pull exact items for next phase using peripheral API.
local function restock(list)
    goTo(0, 0, 0)
    face(0) -- face forward first for consistent sides

    -- Step 1: Dump current inventory into supply chest
    face(2)
    for s = 1, 16 do
        if turtle.getItemCount(s) > 0 then
            turtle.select(s)
            turtle.drop()
        end
    end

    -- Step 2: Build full needs list (fuel + phase items)
    face(0)
    local needs = {}
    if turtle.getFuelLevel() ~= "unlimited" and turtle.getFuelLevel() < 1000 then
        needs[#needs + 1] = { ITEMS.fuel, 32 }
    end
    for _, req in ipairs(list) do
        needs[#needs + 1] = req
    end

    -- Step 3: Push target items from supply to buffer, retry until all found
    while true do
        local supply = peripheral.wrap(supplyName)
        if not supply then
            error("Lost connection to supply chest '" .. supplyName .. "'")
        end

        local missing = {}
        for _, req in ipairs(needs) do
            local name, count = req[1], req[2]
            local remaining = count
            local items = supply.list()
            for slot, item in pairs(items) do
                if item.name == name and remaining > 0 then
                    local moved = supply.pushItems(bufferName, slot, remaining)
                    remaining = remaining - moved
                    if remaining <= 0 then break end
                end
            end
            if remaining > 0 then
                missing[#missing + 1] = name .. " x" .. remaining
            end
        end

        if #missing == 0 then
            break
        end

        -- Items missing — return partial pulls to supply, wait for player
        face(3)
        while turtle.suck() do end
        face(2)
        for s = 1, 16 do
            if turtle.getItemCount(s) > 0 then
                turtle.select(s)
                turtle.drop()
            end
        end
        face(0)

        print("  MISSING ITEMS in supply chest:")
        for _, m in ipairs(missing) do
            print("    - " .. m)
        end
        print("  Stock the chest and press any key to retry...")
        os.pullEvent("key")
    end

    -- Step 4: Suck everything from buffer into turtle
    face(3)
    while turtle.suck() do end
    face(0)

    turtle.select(1)
end

---------------------------------------------
-- FARM HELPERS
---------------------------------------------

-- Convert farm-local (fx, fz) to world coordinates
-- farmIdx is 0-indexed, farms extend in +x direction
local function farmWorld(farmIdx, fx, fz)
    local wx = 1 + farmIdx * CHUNK_SIZE + FARM_OFFSET + fx
    local wz = 1 + FARM_OFFSET + fz
    return wx, wz
end

-- Checkerboard: even parity = farmland (seeds), odd = dirt (accelerators)
-- Center is water, not farmland
local function isFarmland(fx, fz)
    if fx == FARM_CENTER and fz == FARM_CENTER then return false end
    return (fx + fz) % 2 == 0
end

local function isCenter(fx, fz)
    return fx == FARM_CENTER and fz == FARM_CENTER
end

-- All 9x9 positions in snake (boustrophedon) order for efficient sweeping
local function snakePositions()
    local list = {}
    for fx = 0, FARM_SIZE - 1 do
        if fx % 2 == 0 then
            for fz = 0, FARM_SIZE - 1 do
                list[#list + 1] = { fx, fz }
            end
        else
            for fz = FARM_SIZE - 1, 0, -1 do
                list[#list + 1] = { fx, fz }
            end
        end
    end
    return list
end

-- Get only farmland positions from the snake pattern
local function farmlandPositions()
    local list = {}
    for _, p in ipairs(snakePositions()) do
        if isFarmland(p[1], p[2]) then
            list[#list + 1] = p
        end
    end
    return list
end

---------------------------------------------
-- BUILD PHASES
---------------------------------------------

--
-- Phase 1: Smooth stone perimeter around the chunk border
-- Turtle at py=0, digDown breaks ground below (pickaxe), placeDown replaces it
--
local function phase_perimeter(fi)
    print("[Farm " .. (fi + 1) .. "] Perimeter (smooth stone)")
    restock({ { ITEMS.smooth_stone, 64 } })

    local x0 = 1 + fi * CHUNK_SIZE
    local x1 = x0 + CHUNK_SIZE - 1
    local z0 = 1
    local z1 = CHUNK_SIZE

    -- Build ring path: south -> east -> north -> west
    local ring = {}
    for x = x0, x1 do ring[#ring + 1] = { x, z0 } end
    for z = z0 + 1, z1 do ring[#ring + 1] = { x1, z } end
    for x = x1 - 1, x0, -1 do ring[#ring + 1] = { x, z1 } end
    for z = z1 - 1, z0 + 1, -1 do ring[#ring + 1] = { x0, z } end

    goTo(ring[1][1], 0, ring[1][2])

    for _, pos in ipairs(ring) do
        moveTo(pos[1], 0, pos[2])
        turtle.digDown()
        if selectItem(ITEMS.smooth_stone) then
            turtle.placeDown()
        end
    end
end

--
-- Phase 2: Water + till + fertilize + plant
-- Supports "EMPTY" seed name — builds everything but skips planting.
--
local function phase_ground_and_plant(fi, seedName)
    print("[Farm " .. (fi + 1) .. "] Water + till + fertilize" ..
        (seedName ~= "EMPTY" and (" + " .. seedName) or " (empty plot)"))

    local restockList = {
        { ITEMS.water_bucket, 1 },
        { ITEMS.fertilizer,   40 },
    }
    if seedName ~= "EMPTY" then
        restockList[#restockList + 1] = { seedName, 40 }
    end
    restock(restockList)

    -- Step 1: Dig center hole and place water (from py=0)
    local cx, cz = farmWorld(fi, FARM_CENTER, FARM_CENTER)
    goTo(cx, 0, cz)
    turtle.digDown()
    if selectItem(ITEMS.water_bucket) then
        turtle.placeDown()
    end

    -- Step 2: Sweep at py=1 — till, fertilize, plant
    local positions = snakePositions()
    local sx, sz = farmWorld(fi, positions[1][1], positions[1][2])
    moveTo(sx, 1, sz)

    for _, p in ipairs(positions) do
        local fx, fz = p[1], p[2]
        if isFarmland(fx, fz) then
            local wx, wz = farmWorld(fi, fx, fz)
            moveTo(wx, 1, wz)
            turtle.digDown()
            if selectItem(ITEMS.fertilizer) then
                turtle.placeDown()
            end
            if seedName ~= "EMPTY" then
                if selectItem(seedName) then
                    turtle.placeDown()
                end
            end
        end
    end
end

--
-- Phase 3: MA growth accelerators under farmland
-- Digs deep shafts under each farmland block and fills with tiered accelerators.
-- Processes deepest tier first (digs the shaft), then works upward.
-- Tier layout under farmland (e.g. MA_GROWTH_TIER=3):
--   py=-1  farmland (ground level, below turtle start py=0)
--   py=-2  to py=-10:  inferium (tier 1, directly under farmland)
--   py=-11 to py=-19:  prudentium (tier 2)
--   py=-20 to py=-28:  tertium (tier 3, deepest)
--
local function phase_ma_accelerators(fi)
    if MA_GROWTH_TIER <= 0 then return end
    if MA_GROWTH_TIER <= MA_EXISTING_TIER then return end

    print("[Farm " .. (fi + 1) .. "] MA growth accelerators (tier " ..
        (MA_EXISTING_TIER + 1) .. " to " .. MA_GROWTH_TIER .. ")")

    local positions = farmlandPositions()

    -- Shaft position: one block west of the farm area.
    -- Safe to dig vertically — no farm structures here.
    local shaftX, shaftZ = farmWorld(fi, -1, 0)

    -- Helper: return to surface via shaft. NEVER ascend at a farmland column.
    local function returnToSurface()
        moveTo(shaftX, py, shaftZ)
        while py < 0 do up() end
    end

    -- Process tiers from SHALLOWEST to DEEPEST.
    -- For each tier:
    --   Tier t occupies py = -(9*(t-1)+1) down to py = -(9*t)
    --   Navigation layer (navY) = one below the tier bottom = -(9*t + 1)
    --   Turtle navigates horizontally at navY (always clear dirt, no MA GAs).
    --   At each column: dig up 9 blocks to clear, then descend placing via placeUp.
    for t = MA_EXISTING_TIER + 1, MA_GROWTH_TIER do
        local blockName = MA_ACCELERATORS[t]

        -- Tier t: top block at py = -(9*(t-1) + 2), bottom at py = -(9*t + 1)
        -- Navigation layer: one below the tier bottom, always clear
        local navY = -(9 * t + 2)

        -- Batch sizing: 9 dug blocks per column (the tier space) + horizontal travel.
        -- Accelerator blocks: 9 per position. Dug waste: ~15 per position.
        local digPerPos = 15
        local accelSlots = math.ceil(9 / 64) + 1
        local freeSlots = 16 - accelSlots - 1
        local batchSize = math.floor((freeSlots * 64) / math.max(digPerPos, 1))
        batchSize = math.max(1, math.min(batchSize, 20, #positions))

        print("  Tier " .. t .. ": " .. blockName .. " (batch=" .. batchSize .. ")")

        for batchStart = 1, #positions, batchSize do
            local batchEnd = math.min(batchStart + batchSize - 1, #positions)
            local batchCount = batchEnd - batchStart + 1

            -- Return to surface and restock
            if py < 0 then returnToSurface() end
            voidWaste()
            restock({ { blockName, batchCount * 9 } })

            -- Descend through shaft to navigation layer
            goTo(shaftX, 0, shaftZ)
            while py > navY do down() end

            for i = batchStart, batchEnd do
                local fx, fz = positions[i][1], positions[i][2]
                local wx, wz = farmWorld(fi, fx, fz)

                -- Move horizontally at navY to under the farmland column
                moveTo(wx, navY, wz)

                -- Dig up 9 blocks to clear the tier space for this column
                for _ = 1, 9 do up() end
                -- Turtle now at navY + 9 = tier top (e.g. py=-2 for tier 1)

                -- Descend back down, placing blocks via placeUp.
                -- Each iteration: move down, then placeUp fills the space above.
                for _ = 1, 9 do
                    down()
                    if selectItem(blockName) then
                        turtle.placeUp()
                    end
                end
                -- Turtle back at navY, ready to move to next column
            end

            -- Return to shaft at navY before next batch
            moveTo(shaftX, navY, shaftZ)
        end
    end

    -- Return to surface via shaft
    if py < 0 then returnToSurface() end
    voidWaste()
end

--
-- Phase 4: AE2 Growth accelerators on dirt blocks + harvester pylon at center
-- Turtle at py=1, placeDown puts blocks at py=0
--
local function phase_structures(fi)
    print("[Farm " .. (fi + 1) .. "] Growth accelerators + pylon")
    restock({
        { ITEMS.accelerator, 40 },
        { ITEMS.pylon,       1 },
    })

    local positions = snakePositions()
    local sx, sz = farmWorld(fi, positions[1][1], positions[1][2])
    goTo(sx, 1, sz)

    for _, p in ipairs(positions) do
        local fx, fz = p[1], p[2]
        local wx, wz = farmWorld(fi, fx, fz)
        moveTo(wx, 1, wz)

        if isCenter(fx, fz) then
            if selectItem(ITEMS.pylon) then
                turtle.placeDown()
            end
        elseif not isFarmland(fx, fz) then
            if selectItem(ITEMS.accelerator) then
                turtle.placeDown()
            end
        end
    end
end

--
-- Phase 5: ME glass cables across entire 9x9 + chest above pylon
-- Turtle at py=2, placeDown puts blocks at py=1
--
local function phase_upper(fi)
    print("[Farm " .. (fi + 1) .. "] ME cables + chest")
    restock({
        { ITEMS.me_cable, 80 },
        { ITEMS.chest,    1 },
    })

    local positions = snakePositions()
    local sx, sz = farmWorld(fi, positions[1][1], positions[1][2])
    goTo(sx, 2, sz)

    for _, p in ipairs(positions) do
        local wx, wz = farmWorld(fi, p[1], p[2])
        moveTo(wx, 2, wz)

        if isCenter(p[1], p[2]) then
            if selectItem(ITEMS.chest) then
                turtle.placeDown()
            end
        else
            if selectItem(ITEMS.me_cable) then
                turtle.placeDown()
            end
        end
    end
end

---------------------------------------------
-- ORCHESTRATION
---------------------------------------------

local function buildFarm(fi, seedName)
    print("========================================")
    print("  Building Farm " .. (fi + 1) .. " / " .. #SEEDS)
    print("  Seed: " .. seedName)
    print("========================================")

    phase_perimeter(fi)
    phase_ground_and_plant(fi, seedName)
    phase_ma_accelerators(fi)
    phase_structures(fi)
    phase_upper(fi)

    print("[Farm " .. (fi + 1) .. "] Complete!")
    print()
end

---------------------------------------------
-- MAIN
---------------------------------------------

local args = { ... }

local function main()
    local mode = args[1] or "build"

    if mode == "accel" then
        -- Standalone mode: only place MA growth accelerators on existing farms
        print("==========================================")
        print("  MA Growth Accelerator Placement")
        print("  Farms: " .. #SEEDS .. "  |  Tier: " .. MA_GROWTH_TIER)
        print("==========================================")
        print()

        if #SEEDS == 0 then
            print("No seeds configured! SEEDS list determines farm count.")
            return
        end
        if MA_GROWTH_TIER <= 0 then
            print("MA_GROWTH_TIER is 0. Nothing to do.")
            return
        end

        initPeripherals()

        for i = 1, #SEEDS do
            print("[Farm " .. i .. "] Placing accelerators...")
            phase_ma_accelerators(i - 1)
        end

        goTo(0, 0, 0)
        face(0)
        print()
        print("==========================================")
        print("  Accelerator placement complete!")
        print("==========================================")
        return
    end

    -- Default: full build mode
    print("==========================================")
    print("  Mystical Agriculture Farm Builder")
    print("  Farms to build: " .. #SEEDS)
    if MA_GROWTH_TIER > 0 then
        print("  MA Growth Tier: " .. MA_GROWTH_TIER)
    end
    print("==========================================")
    print()

    if #SEEDS == 0 then
        print("No seeds configured! Edit the SEEDS table.")
        return
    end

    initPeripherals()

    local fuel = turtle.getFuelLevel()
    if fuel ~= "unlimited" and fuel < 100 then
        print("WARNING: Low fuel (" .. fuel .. "). Stock fuel in the chest.")
    end

    for i, seed in ipairs(SEEDS) do
        buildFarm(i - 1, seed)
    end

    -- Return home and dump everything
    goTo(0, 0, 0)
    face(0)
    face(2)
    for s = 1, 16 do
        if turtle.getItemCount(s) > 0 then
            turtle.select(s)
            turtle.drop()
        end
    end
    face(0)

    print("==========================================")
    print("  All " .. #SEEDS .. " farm(s) complete!")
    print("==========================================")
end

main()
