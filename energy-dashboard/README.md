# energy-dashboard

Three-tier CC dashboard for AE2 networks running AppliedFlux. Reads FE totals via the `flux_accessor_ext` peripheral ([appflux-cc-patch](https://github.com/mathox-desintox/appflux-cc-patch) server mod), aggregates history + rates in a middle tier, renders on one or more monitors.

## Architecture

```
AE2 grid → flux_accessor →  [collector]  ─PROTO_DATA/COLLECTOR_STATE─▶  [core]  ─PROTO_DATA/CORE_AGGREGATE─▶  [panel]
                                                                         │
                                                                         ▼
                                                              /edash_core.dat  (lifetime counters, disk-backed)
```

- **collector** — wraps one flux accessor, broadcasts state once per second.
- **core** — listens to one or more collectors, maintains tiered ring-buffer history (1-second / 1-minute / 5-minute), computes rates at seven horizons (instant, 1m, 5m, 15m, 1h, 8h, 24h), persists lifetime produced/consumed counters, rebroadcasts an aggregate every second.
- **panel** — listens only for core aggregates, renders stored / capacity / fill% / multi-horizon rates / ETA / fill-bar / status / lifetime totals on an advanced monitor.

| Protocol string | Direction | Message kinds |
|---|---|---|
| `edash_data_v1` | collector → core, core → panel | `collector_state`, `core_aggregate` |
| `edash_mgmt_v1` | reserved | `heartbeat`, `discovery` |
| `edash_cmd_v1`  | reserved (panel/remote → core/collector) | `command` |

Packet envelope: `{ version, kind, src = {id, role}, ts, payload }`. Version mismatches are rejected at `comms.valid()`.

## Prerequisites

- `appflux-cc-patch` mod on the server (≥ v0.1.0).
- At least one AppliedFlux flux accessor connected to an online AE2 grid.
- Three advanced computers (CC:Tweaked), each with an **ender modem** (wireless modems work short-range, ender covers chunk-unloads).
- One advanced monitor (any size; layout adapts).

## Install

Every computer expects files under the `common/` + (module-specific) folder in its filesystem. Fetch with `wget` from the raw GitHub URLs. An installer (`edi`) is M3 — for now the manual wget list.

### Collector computer — next to a flux accessor

```
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/common/comms.lua common/comms.lua
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/common/log.lua common/log.lua
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/common/ppm.lua common/ppm.lua
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/common/util.lua common/util.lua
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/collector/collector.lua collector.lua
collector
```

### Core computer — anywhere with modem range

```
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/common/comms.lua common/comms.lua
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/common/log.lua common/log.lua
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/common/util.lua common/util.lua
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/core/core.lua core.lua
core
```

The core writes `/edash_core.dat` every 30 s with lifetime produced/consumed totals and uptime. Safe to delete if you want to reset counters.

### Panel computer — adjacent to an advanced monitor

```
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/common/comms.lua common/comms.lua
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/common/log.lua common/log.lua
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/common/ppm.lua common/ppm.lua
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/common/util.lua common/util.lua
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/graphics/core.lua graphics/core.lua
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/graphics/themes.lua graphics/themes.lua
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/panel/panel.lua panel.lua
panel
```

## What the panel shows

| Line | Meaning |
|---|---|
| **Stored** | FE currently on the grid, SI-prefixed (GFE/TFE/PFE). |
| **Capacity** | Network capacity (stored + free). |
| **Fill** | Percentage, one decimal. |
| **Rate instant** | ~2-second-window rate. Near-real-time. |
| **Rate 5 min** | 5-minute rolling rate. Smooths over brief spikes. |
| **Rate 1 hr** | 1-hour rolling rate. Medium-term trend. |
| **Rate 24 hr** | 24-hour rolling rate. Long-term baseline. |
| **ETA** | Time to full (charging) or empty (draining) at the instant rate. |
| **Fill bar** | Full-width visual, colour-coded. |
| **Status pill** | `ONLINE` / `STALE` (no update ≥5 s) / `OFFLINE` (grid down) / `NO DATA` (no core seen yet). |
| **Footer line 1** | cell count, collector count, uptime. |
| **Footer line 2** | lifetime produced / consumed (cumulative across restarts). |

Rate defaults to **per-tick** (`/t`) — Minecraft's native time unit. Toggle to `/s` via the `RATE_UNIT` constant at the top of `panel.lua` (will be configurable in M4).

## Troubleshooting

**Panel says "NO DATA":** no core aggregate received yet. Verify the core is running and its modem is open, and that both computers are in ender-modem range (or both using wireless with line-of-sight).

**Panel shows numbers but rates are 0:** rates need at least 2 samples inside a window. Instant rate appears after ~2 s; 5 min rate needs 5 minutes of data; 24 hr rate needs the full day.

**"STALE" on the panel:** core or collector stopped. Check both are still running.

**Lifetime counters reset on restart:** `/edash_core.dat` was deleted or the core can't write to disk. Check `/edash_core.log`.

## What's intentionally missing (coming in later milestones)

- **M3**: `edi` installer replacing the wget lists.
- **M4**: `configure.lua` per-component — peripheral autodetect + role assignment.
- **M5**: Enhanced main display — clickable horizon-switcher on a rate graph, volatility, watermarks.
- **M6**: Drive display — per-cell heatmap.
- **M7**: Lifetime display — production/consumption projections.
- **M8**: Alarms + speaker + event log.
- **M9**: Pocket-computer remote.
- **M10**: Cross-component self-tests + simulator mode.
