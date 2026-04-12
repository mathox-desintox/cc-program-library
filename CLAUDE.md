# MA Farm & Floor Builder — ComputerCraft Programs for ATM10

## Project Overview

ComputerCraft (CC:Tweaked) turtle programs for Minecraft ATM10 modpack. Two main programs plus supporting tools.

## Files

| File | Purpose |
|---|---|
| `farm.lua` | Builds 9x9 Mystical Agriculture farm plots with AE2 growth accelerators, pylons, ME cables. Supports underground MA growth accelerator tiers. |
| `floor.lua` | Excavates underground floors (101x101), builds smooth stone shell, installs staggered diagonal lattice lighting. |
| `floor_monitor.lua` | Advanced monitor display for floor builder status via rednet. |
| `floor_pocket.lua` | Advanced pocket computer display for floor builder status via rednet. |
| `installer.lua` | Pastebin-hosted installer that pulls files from GitHub. **Update REPO URL before use.** |
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
- Configurable: `FLOOR_NUM`, `INTERIOR_HEIGHT`, `BUFFER_LAYERS`
- Phases: dig → ceiling → floor → walls → floor_lights → ceiling_lights → wall_lights
- Progress saved to `floor_progress` file for crash recovery
- Broadcasts status via rednet protocol `mathox_base_floor_builder_v1`
- Chests: stone (front), lights (front+1Y), dump (right), coal (right+1Y)
- Shaft column at turtle home kept open for vertical travel
- Dig uses 3-layer passes (digUp + move + digDown)

### Error handling pattern
All programs wait-and-retry on missing supplies rather than crashing:
- Missing items → go home, print what's needed, wait for keypress
- Low fuel → go home, pull from coal chest, wait if empty
- Liquid encountered without stone → go home, restock, return to position
- No modem → fatal error (monitoring is required for floor.lua)

### Rednet protocol
- `mathox_base_floor_builder_v1` — unique to avoid conflicts on multiplayer server
- All advanced computers/monitors/pocket computers (full 16-color support)

## How to deploy in-game
1. Push repo to GitHub
2. Update `REPO` URL in `installer.lua`
3. Upload `installer.lua` to pastebin
4. In-game: `pastebin run <CODE>` — select which program to install
