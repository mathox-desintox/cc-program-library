# energy-dashboard (MVP)

Two-program dashboard for AE2 networks running AppliedFlux. Reads network-total FE via the `flux_accessor_ext` peripheral (provided by the [appflux-cc-patch](https://github.com/mathox-desintox/appflux-cc-patch) server mod), broadcasts over rednet, renders on a monitor.

Minimum-viable scope: single collector, single panel, single monitor. Rate + ETA are derived on the panel. This is the "see it works" version — the scada-style architecture (core tier, configure UI, installer, multi-monitor, graphs, pocket client) comes next.

## Prerequisites

- Server has `appflux-cc-patch` mod installed (jar in `mods/`).
- At least one AppliedFlux flux accessor block/part connected to a live AE2 network.
- Two advanced computers with **ender modems** (wireless modem works short-range; ender covers chunk-unloaded distance).
- One advanced monitor (any size; larger is better).

## Layout

```
AE2 network  →  flux accessor  →  [computer 1: collector]  ─rednet─→  [computer 2: panel]  →  monitor
```

## Install

### Computer 1 — collector

Place adjacent to (or wired-modem'd to) a flux accessor. Attach an ender modem.

```
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/collector/collector.lua collector.lua
collector
```

Expected output: a rolling status line showing `online=true stored=<real-number> cells=<N>`.

### Computer 2 — panel

Place adjacent to an advanced monitor. Attach an ender modem.

```
wget https://raw.githubusercontent.com/mathox-desintox/cc-program-library/main/energy-dashboard/panel/panel.lua panel.lua
panel
```

The monitor should light up within ~1 second showing stored/capacity/rate/ETA/fill-bar.

## Rednet protocol

One protocol, one message type. Collectors broadcast state periodically; whatever listens on `edash_v1` (currently the panel; later a `core` tier) reads it.

```
protocol = "edash_v1"
message  = { type = "flux_state", src = <computer id>, ts = <ms epoch>, data = { stored, storedString, capacity, capacityString, online, cellCount } }
```

Messages are sent every ~1 second via `rednet.broadcast`.

## What the panel shows

- **Stored** — current FE in the network, SI-prefixed (GFE/TFE/PFE).
- **Cap** — total capacity (stored + free).
- **Rate** — derived from diffing `stored` between collector samples. Green = charging, orange = draining.
- **ETA** — time to full (if charging) or to empty (if draining) at the current rate.
- **Fill bar** — green/gray, width scales to monitor.
- **Status** — "ONLINE" / "STALE" (no update >5 s) / "OFFLINE" (AE2 grid down) / "NO DATA" (no collector seen yet).
- **Footer** — total FE cell count across the network.

## What's deliberately missing (coming later)

- `core` tier — collectors currently broadcast straight to panels. A core will sit between them for history, multi-network aggregation, and disk-backed state.
- `edi` installer — right now you wget each program manually. An installer with component selection + autoupdate is the next scada-style layer.
- Configure UI — peripheral autodetect with role assignment (rather than `peripheral.find` with hardcoded types).
- Multi-monitor composition, graphs, pocket-computer client — all after the three-tier architecture is in place.

## Troubleshooting

**Panel says "NO DATA":** the panel isn't receiving any `edash_v1` broadcasts. Check:
- Both computers have modems open (collector/panel startup logs confirm).
- Ender modems on both sides (wireless modems have limited range and don't span chunk unloads).
- Collector's accessor is actually attached to an online AE2 grid (`isOnline` in the log).

**Panel says "STALE":** last message is older than 5 s. Collector has stopped or the modem link broke.

**Panel says "OFFLINE":** the collector is running but its flux accessor reports `isOnline = false`. The AE2 network lost power or the accessor is disconnected.
