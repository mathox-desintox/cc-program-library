# MA Farm & Floor Builder — ComputerCraft Programs for ATM10

## Project Overview

ComputerCraft (CC:Tweaked) turtle programs for Minecraft ATM10 modpack. Two main programs plus supporting tools.

## Files

| File | Purpose |
|---|---|
| `farm.lua` | Builds 9x9 Mystical Agriculture farm plots with AE2 growth accelerators, pylons, ME cables. Supports underground MA growth accelerator tiers. |
| `floor.lua` | Excavates underground floors (101x101), builds smooth stone shell, installs staggered diagonal lattice floor/ceiling lighting and diamond-pattern wall lighting. |
| `floor_monitor.lua` | Advanced monitor display for floor builder status via rednet. |
| `floor_pocket.lua` | Advanced pocket computer display for floor builder status via rednet. |
| `installer.lua` | Pastebin-hosted installer (`hkJJFbTv`) that pulls files from GitHub. Monitor/pocket programs install to `startup/` for auto-run on boot. |
| `lighting-project.md` | Reference doc: Floor 1 coordinates, lighting pattern math, lessons learned. |

## Key Technical Decisions (tested in-game)

### CC:Tweaked turtle behavior (ATM10 specific)
- `turtle.placeDown()` with hoe/seeds **FAILS from directly above ground** (py=0)
- `turtle.placeDown()` with hoe/seeds **WORKS with an air gap** (py=1, through air)
- `turtle.digDown()` with both pickaxe+hoe equipped: **pickaxe breaks the block below, hoe tills 2 blocks below** (auto-selects based on context)
- Turtles **cannot dig without a tool** equipped — errors out
- `peripheral.wrap("back")` etc. are **relative to the turtle's current facing**, not absolute. Always `face(0)` before wrapping.

### Inventory / Chest system (farm.lua)
- Two chests: supply (netherite, behind turtle) + buffer (left of turtle)
- Uses `peripheral.wrap()` + `chest.pushItems()` to move specific items from supply to buffer
- Turtle sucks from buffer — gets exactly what was requested
- Peripheral names discovered at startup via `initPeripherals()` and cached
- Missing items: turtle returns partial items to supply, prints what's missing, waits for keypress to retry

### Coordinate systems
- **farm.lua**: Relative coordinates. `px,py,pz = 0,0,0` is turtle start. `py=0` is turtle level (on top of ground). Ground block is below at `py=-1`. Facing: `0=+z(forward), 1=+x(right), 2=-z(back), 3=-x(left)`.
- **floor.lua**: Absolute world coordinates matching the facility. Facing: `0=E(+X), 1=S(+Z), 2=W(-X), 3=N(-Z)`. Matches `floorplacer.lua` convention from lighting-project.md.

### farm.lua Y-level reference
```
ground (py=-1): farmland, water, smooth stone perimeter
py=0:           crops, AE2 growth accelerators, harvester pylon  
py=1:           ME glass cables, chest above pylon
```

### farm.lua MA Growth Accelerator Y-levels
```
farmland at ground (py=-1)
Tier 1: py=-2  to py=-10   (inferium, directly under farmland)
Tier 2: py=-11 to py=-19   (prudentium)
Tier 3: py=-20 to py=-28   (tertium)
Nav layer for tier t: py=-(9*t + 2)
```
- Placed via shaft at `farmWorld(fi, -1, 0)` (one block west of farm area)
- Approach: descend shaft to navY, move horizontally, dig up 9 blocks, descend placing via `placeUp`
- Process shallowest tier first → deepest last (required for placeUp approach)

### floor.lua structure
- Floor 1 reference: floor Y=21, ceiling Y=30, interior 101x101
- Configurable: `INTERIOR_HEIGHT`, `BUFFER_LAYERS` — can differ per floor
- `HOME_Y` is GPS'd at runtime from the turtle's starting position (on top
  of the floor above the one being built), persisted in state for resume.
  All derived Y levels (`CEILING_Y`, `FLOOR_Y`, `DIG_TOP_Y`, `DIG_BOT_Y`,
  `WALL_LIGHT_Y`) are computed in `initLevels()` from `HOME_Y`.
- Phases: dig → ceiling → floor → walls → floor_lights → ceiling_lights → wall_lights
- Subcommands run slices: `dig`, `shell`, `lights`, or a single light phase
  via `floor_lights` / `ceiling_lights` / `wall_lights`
- Progress saved to `floor_progress` file for crash recovery
- Broadcasts status via rednet protocol `mathox_base_floor_builder_v1`
- Chests: stone (front), lights (front+1Y), dump (right), coal (right+1Y)
- Shaft column at turtle home kept open for vertical travel
- Dig uses 3-layer passes (digUp + move + digDown)

### Error handling pattern
All programs wait-and-retry on missing supplies rather than crashing:
- Missing items → go home, print what's needed, wait for keypress
- Low fuel → go home, pull from coal chest, wait if empty
- **Fuel bootstrap** → if turtle starts with insufficient fuel to reach chest, prompts user to manually insert fuel
- Liquid encountered without stone → go home, restock, return to position
- No modem → fatal error (monitoring is required for floor.lua)

### Position tracking & GPS recovery (both programs)
- Turtle tracks its own `x, y, z, facing` via relative movement (`turtle.forward()` + `DX/DZ` tables)
- `saveState()` is called after **every** successful movement (`forward`, `up`, `down`, `turnRight`, `turnLeft`) via `pcall(saveState)` so the state file always reflects actual physical position
- On startup, `localizeGPS()` calls `gps.locate(3)` to get ground-truth coordinates and overrides the saved x/y/z
- Facing detection: turtle tries `turtle.forward()`, compares GPS before/after to compute facing from Δx/Δz, then `turtle.back()`. Falls back to saved facing if GPS unavailable or forward is blocked
- Works with ender modems only (regular modems can't reach a GPS constellation from far away)

### farm.lua state persistence & resume
- State file: `farm_progress` (key=value format, same as floor.lua)
- Tracks: `mode`, `farm_idx`, `phase`, `home_x/y/z` (GPS home), `x/y/z/facing` (position)
- On fresh start: GPS is **required** — records home position for relative↔absolute conversion
- On resume: loads state, calls `localizeGPS()` to verify position via GPS delta from home
- Phases per farm: `perimeter`, `ground`, `accelerators`, `structures`, `upper`
- Resume restarts from the saved phase (phases are idempotent — replaying is safe)
- Mode mismatch (e.g. saved "accel" but running "build") warns and discards saved state
- `clearState()` deletes the progress file on completion

### farm.lua SKIP and SEEDS
- `"SKIP"` entries in SEEDS reserve a farm slot without building
- Turtle flies over SKIP farms at `SKIP_TRAVEL_Y=5` (above all structures) to the farm center
- Farm index still advances, so subsequent farms are positioned correctly
- Both `build` and `accel` modes respect SKIP

### Rednet protocol & broadcasting
- `mathox_base_floor_builder_v1` — unique to avoid conflicts on multiplayer server
- All advanced computers/monitors/pocket computers (full 16-color support)
- Broadcasts include `stats` table with block counts and ETA:
  - `blocks_broken`/`blocks_total` (dig phase)
  - `blocks_placed`/`place_total` (ceiling, floor, walls phases)
  - `lights_placed`/`lights_total` (light phases)
  - `eta` — seconds remaining, computed from average rate
  - `phase_start` — `os.clock()` when current phase began
- Time-throttled broadcasting via `tickBroadcast()` in movement functions (every 2s)
- Forced broadcast on row/layer completion and phase transitions

## How to deploy in-game
1. Push repo to GitHub
2. In-game: `pastebin run hkJJFbTv` — select which program to install
3. Monitor/pocket programs install to `startup/` folder and auto-run on boot
4. If repo URL changes, update `REPO` in `installer.lua` and re-upload to pastebin

### Lua forward declarations
Functions used before their definition (e.g. `ascendToHome`, `moveToY`, `moveTo` in `ensureFuel`) must be forward-declared with `local funcName` at the top of the movement section, then assigned later with `funcName = function() ... end` instead of `local function funcName()`.
