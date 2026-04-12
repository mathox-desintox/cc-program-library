Minecraft Facility Lighting Project — Conversation Summary
Project Context
Building a multi-floor facility in modded Minecraft. First floor is complete. This summary captures all design decisions and code for continuation in Claude Code.
Room Geometry (Floor 1)

Interior: x = -3398..-3298 (101 wide), z = 2574..2674 (101 deep) — 101×101 interior
Walls: x ∈ {-3399, -3297}, z ∈ {2573, 2675}
Floor block Y: 21
Ceiling block Y: 30
Interior air: Y = 22..29 (8 blocks tall interior, 10 including floor/ceiling)
Center block: (-3348, 21, 2624) — true center because 101 is odd
Center 5×5 area: x -3350..-3346, z 2622..2626 (kept clear of lights)
All wall/floor/ceiling blocks: minecraft:smooth_stone

Lighting Design
Light block: simplylight:illuminant_black_block_on (SimplyLight mod, usable range 13 blocks; design target ≤9 for high light level).
Pattern: Staggered diagonal lattice with step 8, anchored on the center block. Two interleaved rows give max distance to nearest light ≈5.66 blocks. Symmetric across both axes and both diagonals.
Floor lights (Y=21)
Row A (z step 8 from 2576..2672, x step 8 from -3396..-3300):

z ∈ {2576, 2584, 2592, 2600, 2608, 2616, 2624, 2632, 2640, 2648, 2656, 2664, 2672}
x ∈ {-3300, -3308, -3316, -3324, -3332, -3340, -3348, -3356, -3364, -3372, -3380, -3388, -3396}
Skip (-3348, 2624) — the center block

Row B (z step 8 from 2580..2668, x step 8 from -3304..-3392):

z ∈ {2580, 2588, 2596, 2604, 2612, 2620, 2628, 2636, 2644, 2652, 2660, 2668}
x ∈ {-3304, -3312, -3320, -3328, -3336, -3344, -3352, -3360, -3368, -3376, -3384, -3392}

Ceiling lights (Y=30, replacing ceiling blocks)
Row A' (Row A's x-list with Row B's z-list): swapped z-rows so no ceiling light sits directly above a floor light.
Row B' (Row B's x-list with Row A's z-list)
Wall lights (Y=25)
13 lights per wall, centered on the wall midpoint, step 8:

North wall (z=2573): x = -3396, -3388, ..., -3348, ..., -3300; turtle stands at z=2574 facing north
South wall (z=2675): same x list; turtle at z=2674 facing south
West wall (x=-3399): z = 2576, 2584, ..., 2624, ..., 2672; turtle at x=-3398 facing west
East wall (x=-3297): same z list; turtle at x=-3298 facing east

Obstacles on Floor 1
Mekanism Induction Matrix (10×10×10): x:-3397..-3388, y:21..30, z:2664..2673. Has one-block walkable gaps on west (x=-3398) and south (z=2674) sides between matrix and walls.
Floor Row B lights skipped (corner regions, expanded for safety):

NE corner 3×3 from (-3304, 2580): x ∈ -3320..-3304, z ∈ 2580..2596
SE corner 4×4 from (-3304, 2668): x ∈ -3328..-3304, z ∈ 2644..2668
SW corner (matrix) 2×2 from (-3392, 2668): x ∈ -3392..-3384, z ∈ 2660..2668

Ceiling lights skipped (matrix occupies these): (-3396, 2664), (-3396, 2672), (-3388, 2664), (-3388, 2672).
Mob Spawning Prevention
Torchmaster Mega Torch (range 64 in modpack) covers a 129×129×129 cube. Placed at (-3348, 19, 2624) — 2 blocks under floor center, hidden. Single torch covers entire room with margin.
Computer Craft Turtle Programs
Two programs were used. Both share these conventions:

Facing: 0=E(+X), 1=S(+Z), 2=W(-X), 3=N(-Z)
Tracks position internally from a START_X/Y/Z/FACING constant
Safety: only breaks minecraft:smooth_stone; aborts on anything else
Turtle needs equipped pickaxe (turtle.equipLeft() with diamond pickaxe in slot 1) and fuel
Inventory holds lights pulled from a chest; refills automatically

Lessons learned during Floor 1

Turtle without a pickaxe can't dig — turtle.placeUp() fails silently because the ceiling block isn't broken. Equip pickaxe first.
Chest placement matters — chest above the turtle (suckUp) or beside (suck after facing) works; chest in walking path causes path collisions. Use Y-aware no-go boxes.
Server restarts can interrupt long runs. Programs are not idempotent — they re-place lights. Manual cleanup or skip lists may be needed for resumes.
Two-leg L-pathing (X then Z) needs no-go detour logic when obstacles are in the way.

Final program: floorplacer.lua
Used for Row B floor lights + walls. Setup: chest at (-3398, 22, 2575), turtle at (-3398, 22, 2574) facing east, pickaxe equipped, fuel in inventory.
lua-- floorplacer.lua
-- Places Row B floor lights at Y=21 with corner skips, then wall lights at Y=25.

local START_X, START_Y, START_Z, START_FACING = -3398, 22, 2574, 0
local LIGHT_NAME = "simplylight:illuminant_black_block_on"
local SAFE_BREAK = "minecraft:smooth_stone"
local Y_FLOOR, Y_NAV, Y_WALL = 21, 22, 25

local NOGOS = {
  { xmin=-3397, xmax=-3388, zmin=2664, zmax=2673, ymin=21, ymax=30 }, -- matrix
  { xmin=-3398, xmax=-3398, zmin=2575, zmax=2575, ymin=22, ymax=22 }, -- chest
}
local WALL_SKIP = {}

local function inFloorSkip(tx, tz)
  if tx >= -3320 and tx <= -3304 and tz >= 2580 and tz <= 2596 then return true end
  if tx >= -3328 and tx <= -3304 and tz >= 2644 and tz <= 2668 then return true end
  if tx >= -3392 and tx <= -3384 and tz >= 2660 and tz <= 2668 then return true end
  return false
end

local function buildFloorTargets()
  local list = {}
  for tz = 2580, 2668, 8 do
    for tx = -3392, -3304, 8 do
      if not inFloorSkip(tx, tz) then list[#list+1] = {x=tx, z=tz} end
    end
  end
  return list
end

local function buildWallTargets()
  local list = {}
  for tx = -3396, -3300, 8 do list[#list+1] = {x=tx, z=2574, dir=3} end
  for tx = -3396, -3300, 8 do list[#list+1] = {x=tx, z=2674, dir=1} end
  for tz = 2576, 2672, 8 do list[#list+1] = {x=-3398, z=tz, dir=2} end
  for tz = 2576, 2672, 8 do list[#list+1] = {x=-3298, z=tz, dir=0} end
  return list
end

local x, y, z = START_X, START_Y, START_Z
local facing = START_FACING
local home_x, home_y, home_z, home_facing = START_X, START_Y, START_Z, START_FACING
local moveTo, moveToY, moveToX, moveToZ, face

local function abort(reason)
  print("ABORT: " .. reason)
  print(("At %d,%d,%d facing %d"):format(x, y, z, facing))
  pcall(function() moveTo(home_x, home_y, home_z); face(home_facing) end)
  error("Aborted: " .. reason)
end

local function safeDig(direction)
  local inspect, dig
  if direction == "up" then inspect, dig = turtle.inspectUp, turtle.digUp
  elseif direction == "down" then inspect, dig = turtle.inspectDown, turtle.digDown
  else inspect, dig = turtle.inspect, turtle.dig end
  local ok, data = inspect()
  if not ok then return true end
  if data.name == SAFE_BREAK then dig(); return true end
  abort("Refused to break " .. tostring(data.name) .. " (" .. direction .. ")")
end

local function ensureFuel(min)
  if turtle.getFuelLevel() == "unlimited" then return end
  if turtle.getFuelLevel() >= min then return end
  for i = 1, 16 do
    turtle.select(i)
    if turtle.refuel(0) then turtle.refuel(64)
      if turtle.getFuelLevel() >= min then turtle.select(1); return end
    end
  end
  turtle.select(1)
  if turtle.getFuelLevel() < min then abort("Out of fuel") end
end

local DX = {[0]=1,[1]=0,[2]=-1,[3]=0}
local DZ = {[0]=0,[1]=1,[2]=0,[3]=-1}
local function turnRight() turtle.turnRight(); facing=(facing+1)%4 end
local function turnLeft()  turtle.turnLeft();  facing=(facing-1)%4 end
face = function(dir)
  while facing ~= dir do
    if (dir-facing)%4==1 then turnRight() else turnLeft() end
  end
end

local function fwd()
  ensureFuel(1); local t=0
  while not turtle.forward() do
    if turtle.detect() then safeDig("forward") else sleep(0.2) end
    t=t+1; if t>20 then abort("Stuck fwd") end
  end
  x=x+DX[facing]; z=z+DZ[facing]
end
local function up()
  ensureFuel(1); local t=0
  while not turtle.up() do
    if turtle.detectUp() then safeDig("up") else sleep(0.2) end
    t=t+1; if t>20 then abort("Stuck up") end
  end
  y=y+1
end
local function down()
  ensureFuel(1); local t=0
  while not turtle.down() do
    if turtle.detectDown() then safeDig("down") else sleep(0.2) end
    t=t+1; if t>20 then abort("Stuck down") end
  end
  y=y-1
end

moveToY = function(ty) while y<ty do up() end; while y>ty do down() end end
moveToX = function(tx)
  if tx>x then face(0) elseif tx<x then face(2) end
  while x~=tx do fwd() end
end
moveToZ = function(tz)
  if tz>z then face(1) elseif tz<z then face(3) end
  while z~=tz do fwd() end
end

local function pathCrossesAnyNogo(tx, ty, tz)
  for _, box in ipairs(NOGOS) do
    if ty >= box.ymin and ty <= box.ymax then
      local x1,x2 = math.min(x,tx), math.max(x,tx)
      if z>=box.zmin and z<=box.zmax and x2>=box.xmin and x1<=box.xmax then return box end
      local z1,z2 = math.min(z,tz), math.max(z,tz)
      if tx>=box.xmin and tx<=box.xmax and z2>=box.zmin and z1<=box.zmax then return box end
    end
  end
end

moveTo = function(tx, ty, tz)
  moveToY(ty)
  local box = pathCrossesAnyNogo(tx, ty, tz)
  if not box then moveToX(tx); moveToZ(tz); return end
  local skirtN, skirtS = box.zmin-1, box.zmax+1
  local distN = math.abs(z-skirtN) + math.abs(tz-skirtN)
  local distS = math.abs(z-skirtS) + math.abs(tz-skirtS)
  local skirtZ = (distN <= distS) and skirtN or skirtS
  moveToZ(skirtZ); moveToX(tx); moveToZ(tz)
end

local function selectLight()
  for i=1,16 do
    local d = turtle.getItemDetail(i)
    if d and d.name == LIGHT_NAME then turtle.select(i); return true end
  end
  return false
end

local function goHomeAndRefill()
  local rx,ry,rz,rf = x,y,z,facing
  moveTo(home_x, home_y, home_z)
  face(1)  -- chest is south at (-3398,22,2575)
  while not selectLight() do
    if not turtle.suck(64) then sleep(5) end
  end
  for i=1,16 do
    if turtle.getItemCount(i)==0 then turtle.select(i); turtle.suck(64) end
  end
  selectLight()
  if rx~=home_x or ry~=home_y or rz~=home_z then moveTo(rx,ry,rz); face(rf) end
end

local function placeDown()
  if not selectLight() then goHomeAndRefill()
    if not selectLight() then abort("No lights") end end
  if turtle.detectDown() then
    local ok,data = turtle.inspectDown()
    if ok and data.name~=SAFE_BREAK then abort("Refused break "..data.name.." down") end
    turtle.digDown()
  end
  if not turtle.placeDown() then abort("placeDown failed") end
end

local function placeForward()
  if not selectLight() then goHomeAndRefill()
    if not selectLight() then abort("No lights") end end
  if turtle.detect() then
    local ok,data = turtle.inspect()
    if ok and data.name~=SAFE_BREAK then abort("Refused break "..data.name.." fwd") end
    turtle.dig()
  end
  if not turtle.place() then abort("place failed") end
end

local function placeFloor()
  moveToY(Y_NAV)
  local targets = buildFloorTargets()
  local byZ, zs, seen = {}, {}, {}
  for _,p in ipairs(targets) do
    if not seen[p.z] then seen[p.z]=true; zs[#zs+1]=p.z; byZ[p.z]={} end
    table.insert(byZ[p.z], p.x)
  end
  table.sort(zs)
  for _,tz in ipairs(zs) do table.sort(byZ[tz]) end
  local flip = false
  for _,tz in ipairs(zs) do
    local order = {}
    for i=1,#byZ[tz] do order[i]=byZ[tz][i] end
    if flip then local r={}; for i=#order,1,-1 do r[#r+1]=order[i] end; order=r end
    for _,tx in ipairs(order) do moveTo(tx,Y_NAV,tz); placeDown() end
    flip = not flip
  end
end

local function placeWalls()
  moveToY(Y_WALL)
  local list = buildWallTargets()
  local function key(p)
    if p.dir==3 then return 1, p.x end
    if p.dir==0 then return 2, p.z end
    if p.dir==1 then return 3, -p.x end
    if p.dir==2 then return 4, -p.z end
  end
  table.sort(list, function(a,b)
    local ka1,ka2 = key(a); local kb1,kb2 = key(b)
    if ka1~=kb1 then return ka1<kb1 end
    return ka2<kb2
  end)
  for _,p in ipairs(list) do
    if not WALL_SKIP[p.x..":"..p.z] then
      moveTo(p.x, Y_WALL, p.z); face(p.dir); placeForward()
    end
  end
end

local function main()
  goHomeAndRefill()
  placeFloor()
  placeWalls()
  moveTo(home_x, home_y, home_z); face(home_facing)
end

local ok, err = pcall(main)
if not ok then print("Stopped: "..tostring(err)) else print("Success.") end
The earlier program lightplacer.lua did Row A ceiling + walls in a single run. Same structure, just placeUp instead of placeDown, navigates at Y=29 for the ceiling pass. Lost to a server restart mid-run; finished by hand.
What's Done on Floor 1

All floor lights (Row A and Row B) including matrix-area corners
All ceiling lights including the 4 that were under the matrix
All wall lights
Mega torch at (-3348, 19, 2624)