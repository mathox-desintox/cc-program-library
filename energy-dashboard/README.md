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

All three components install via **`edi`** (Energy Dashboard Installer). Run this one command on each computer; arrow-key menu picks the component, `edi` downloads the right files from this repo into the right paths.

```
pastebin run F3bHqTDi
```

Menu actions:

- `[install]   collector`  — for the computer next to a flux accessor
- `[install]   core`       — for the middle-tier aggregator (any computer)
- `[install]   panel`      — for the computer with the monitor
- `[update]    all installed` — re-fetch every installed component (run this after repo changes)
- `[uninstall] ...`        — list + remove any component's files

After install the component auto-runs on every boot — `edi` writes a `/startup.lua` that launches whichever component is installed on this computer. The very first time it runs, the component prints *"first run detected"* and auto-launches `configure` so you can pick your peripheral / rate unit / whatever before anything broadcasts. After configure exits (save or discard), a sentinel at `/.edash_first_run_done` prevents the prompt from recurring.

To update later, just re-run `pastebin run F3bHqTDi` → `[update]    all installed`.

## Configure

Every component reads `/edash_config.lua` at startup. If the file is missing or a key is unset, sensible defaults are used — so you can skip this step entirely and everything still works. Run `configure` to change anything:

```
configure
```

Arrow-key menu; it auto-detects which components are installed on this computer (by reading `/.edi_state`) and shows only those. Inside each component you can:

**collector**
- `peripheral` — pick the `flux_accessor_ext` to use (autodetect lists attached accessors)
- `tick_seconds` — broadcast cadence (default 1)
- `network_id` — reserved for future multi-network deployments

**core**
- `broadcast_interval_ms` — aggregate rebroadcast cadence (default 1000)
- `persist_interval_ms` — disk-save cadence (default 30000)
- `stale_ms` — when to flag a collector as stale (default 5000)
- `state_file` / `log_file` — paths (rarely need changing)

**panel**
- `monitor` — pick which monitor to use (autodetect lists attached monitors)
- `rate_unit` — `t` (per Minecraft tick, default) or `s` (per real-time second)
- `redraw_ms` — screen refresh cadence
- `stale_ms` / `theme` — as above

Saving writes `/edash_config.lua` (human-readable Lua — you can hand-edit it if you prefer). **Restart the component** to pick up new values.

### State files

The installer writes a few small marker files:

| File | Owner | Purpose |
|---|---|---|
| `/.edi_state` | `edi` | list of installed components + file paths, for update/uninstall |
| `/startup.lua` | `edi` | boot autorun — launches the first component present on disk |
| `/.edash_first_run_done` | components | first-run wizard sentinel — prevents re-prompting `configure` |
| `/edash_config.lua` | `configure` | human-readable settings |

All safe to delete for a clean slate. Deleting `/.edash_first_run_done` re-arms the first-run prompt. Deleting `/startup.lua` disables autorun (the component still works if you run it manually).

### Core's data file

The core (separately from the installer) writes `/edash_core.dat` every 30 s with lifetime produced/consumed totals and uptime. Safe to delete to reset counters — histories are kept only in RAM anyway.

### Re-publishing the installer

The pastebin entry above (`F3bHqTDi`) is the stable entry point. If you fork this repo or want your own, upload your modified [`edi.lua`](edi.lua) to pastebin once via `pastebin put edi.lua` and update the command above with your code.

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

Rate defaults to **per-tick** (`/t`) — Minecraft's native time unit. Toggle to `/s` via `configure` (panel → rate_unit) or by editing `/edash_config.lua` directly.

## Troubleshooting

**Panel says "NO DATA":** no core aggregate received yet. Verify the core is running and its modem is open, and that both computers are in ender-modem range (or both using wireless with line-of-sight).

**Panel shows numbers but rates are 0:** rates need at least 2 samples inside a window. Instant rate appears after ~2 s; 5 min rate needs 5 minutes of data; 24 hr rate needs the full day.

**"STALE" on the panel:** core or collector stopped. Check both are still running.

**Lifetime counters reset on restart:** `/edash_core.dat` was deleted or the core can't write to disk. Check `/edash_core.log`.

## What's intentionally missing (coming in later milestones)

- **M5**: Enhanced main display — clickable horizon-switcher on a rate graph, volatility, watermarks.
- **M6**: Drive display — per-cell heatmap.
- **M7**: Lifetime display — production/consumption projections.
- **M8**: Alarms + speaker + event log.
- **M9**: Pocket-computer remote.
- **M10**: Cross-component self-tests + simulator mode.
