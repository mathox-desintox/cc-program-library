# CC Program Library

ComputerCraft (CC:Tweaked) turtle programs for Minecraft ATM10 modpack.

> **Note:** These programs are heavily opinionated for my specific base layout, coordinate system, and mod setup. They will likely require updating (coordinates, dimensions, item names, chest positions, etc.) before use in a different world.

## Projects

### [Farm Builder](farm-builder/)

Automated Mystical Agriculture farm builder. A turtle constructs 9x9 farm plots with:
- Farmland tilling and seed planting
- AE2 growth accelerators and harvester pylons
- ME glass cable wiring
- Underground MA growth accelerator tiers (inferium, prudentium, tertium)

**Runs on:** Advanced Turtle (pickaxe + hoe)

### [Floor Builder](floor-builder/)

Automated underground floor excavation system. A turtle digs out and finishes large rooms (101x101) with:
- Full excavation with smooth stone shell (floor, ceiling, walls)
- Staggered diagonal lattice lighting for floor & ceiling
- Diamond-pattern wall lighting (scales with interior height)
- Per-floor `INTERIOR_HEIGHT` / `BUFFER_LAYERS` — `HOME_Y` is GPS'd at runtime, so each floor can have a different crawl-space and height
- Subcommands to run individual phases: `dig`, `shell`, `lights`, `floor_lights`, `ceiling_lights`, `wall_lights`, or `status`
- Crash recovery via progress file
- Real-time status broadcasting over rednet

**Runs on:** Advanced Turtle (pickaxe)

Includes companion programs (auto-run on boot when installed via the installer):
- `floor_monitor.lua` — status display for advanced monitors
- `floor_pocket.lua` — status display for pocket computers (multi-page, tap to navigate)
- `floor_startup.lua` — auto-resume for the builder turtle after reboot/crash (5s cancel window)

> **Important:** Use **ender modems** (not regular wireless modems) on both the turtle and monitor/pocket computers. Regular modems have a ~64 block range and will lose connection when you walk away, even in force-loaded chunks.

> **Recommended:** Set up a GPS constellation so the turtle can recover its exact position after a crash or unexpected reboot. On startup, the floor builder calls `gps.locate()` to get its actual world coordinates and detects its facing by moving one block. This prevents the turtle from getting "lost" if it stopped mid-navigation (going home to dump/refuel). See the [CC:Tweaked GPS setup guide](https://tweaked.cc/guide/gps_setup.html). If GPS is unavailable, the turtle falls back to its saved state file.

## Quick Install (In-Game)

1. On any CC computer/turtle, run:
   ```
   pastebin run hkJJFbTv
   ```
3. Select the program you want to install
4. Run the installed program

## Setup

### Hosting the installer

The installer is hosted on pastebin at `hkJJFbTv` (set to never expire). If you fork this repo and need to re-upload, update the `REPO` URL in [installer.lua](installer.lua) first.

### Manual install

Download any `.lua` file directly from GitHub and save it to the in-game computer:
```
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/farm-builder/farm.lua farm.lua
```

## Repo Structure

```
cc-program-library/
├── README.md
├── CLAUDE.md              # AI assistant context
├── installer.lua          # In-game pastebin installer
├── farm-builder/
│   └── farm.lua           # Mystical Agriculture farm builder
└── floor-builder/
    ├── floor.lua           # Underground floor excavator
    ├── floor_monitor.lua   # Monitor status display
    ├── floor_pocket.lua    # Pocket computer status display
    └── lighting-project.md # Floor 1 reference & lessons learned
```
