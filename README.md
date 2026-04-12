# CC Program Library

ComputerCraft (CC:Tweaked) turtle programs for Minecraft ATM10 modpack.

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
- Staggered diagonal lattice lighting pattern
- Crash recovery via progress file
- Real-time status broadcasting over rednet

**Runs on:** Advanced Turtle (pickaxe)

Includes companion display programs:
- `floor_monitor.lua` — status display for advanced monitors
- `floor_pocket.lua` — status display for pocket computers

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
