-- energy-dashboard/panel/panel.lua
--
-- Render the core's aggregate state on an advanced monitor. Listens only
-- for CORE_AGGREGATE packets on PROTO_DATA — collectors never talk to the
-- panel directly in the three-tier architecture.
--
-- Run on an advanced computer with a monitor attached and a modem.

local comms  = require("common.comms")
local log    = require("common.log")
local ppm    = require("common.ppm")
local util   = require("common.util")
local gfx    = require("graphics.core")
local themes = require("graphics.themes")

-- ─── config ──────────────────────────────────────────────────────────────

local REDRAW_MS   = 250
local STALE_MS    = 5000
local RATE_UNIT   = "t"    -- "t" = FE/tick (MC native), "s" = FE/second
local THEME       = themes.default
local P           = themes.pairs(THEME)

-- ─── state ───────────────────────────────────────────────────────────────

-- Most recent aggregate received, plus when we received it.
local latest        = nil
local latest_rx_ms  = 0

-- ─── helpers ─────────────────────────────────────────────────────────────

local function status_for(agg, now_ms)
    if not agg then return "NO DATA", P.critical end
    if now_ms - latest_rx_ms >= STALE_MS then return "STALE", P.warn end
    if agg.network_stale then return "STALE", P.warn end
    if not agg.network_online then return "OFFLINE", P.critical end
    return "ONLINE", P.ok
end

local function rate_color(rate_per_s)
    if rate_per_s > 0 then return P.charging end
    if rate_per_s < 0 then return P.draining end
    return P.value
end

-- ─── rendering ───────────────────────────────────────────────────────────

local function render(mon)
    local now_ms = os.epoch("utc")
    local w, h = mon.getSize()
    gfx.clear(mon, THEME.bg)

    -- Title + status
    gfx.write(mon, 2, 1, "FLUX NETWORK", P.title)
    local st_text, st_color = status_for(latest, now_ms)
    gfx.write(mon, w - #st_text, 1, st_text, st_color)

    if not latest then
        gfx.write(mon, 2, 3, "waiting for core aggregate on " .. comms.PROTO_DATA .. "...", P.label)
        return
    end

    local agg  = latest
    local cap  = agg.network_capacity or 0
    local stored = agg.network_stored or 0
    local fill = cap > 0 and (stored * 100 / cap) or 0

    -- Top numbers block
    local label_w = 10
    gfx.indicator(mon, 2, 3, "Stored",    label_w, util.fmtFE(stored),   P.label, P.value)
    gfx.indicator(mon, 2, 4, "Capacity",  label_w, util.fmtFE(cap),      P.label, P.value)
    gfx.indicator(mon, 2, 5, "Fill",      label_w, string.format("%.1f%%", fill), P.label, P.value)

    -- Rates (four key horizons; the future UI will let you pick others)
    local rates = agg.rates or {}
    local row = 7
    gfx.write(mon, 2, row, "Rate", P.accent); row = row + 1
    local function rate_row(r, label, name)
        local rs = rates[name] or 0
        gfx.indicator(mon, 2, r, "  " .. label, label_w, util.fmtRate(rs, RATE_UNIT), P.label, rate_color(rs))
    end
    rate_row(row,     "instant", "instant"); row = row + 1
    rate_row(row,     "5 min",   "m5");      row = row + 1
    rate_row(row,     "1 hr",    "h1");      row = row + 1
    rate_row(row,     "24 hr",   "h24");     row = row + 1

    -- ETA (based on instant rate — matches the "Rate instant" line)
    row = row + 1
    local eta_text = "idle"
    if agg.eta_to_full_s  then eta_text = "to full: "  .. util.fmtDuration(agg.eta_to_full_s)
    elseif agg.eta_to_empty_s then eta_text = "to empty: " .. util.fmtDuration(agg.eta_to_empty_s) end
    gfx.indicator(mon, 2, row, "ETA", label_w, eta_text, P.label, P.value); row = row + 2

    -- Fill bar (full width, one row, with % label below)
    if row < h - 2 then
        local bar_w = w - 2
        gfx.hbar(mon, 2, row, bar_w, fill, THEME.bar_full, THEME.bar_empty)
        gfx.write(mon, 2, row + 1, string.format("%.1f%%", fill), P.value)
    end

    -- Footer: cells + uptime + lifetime produced/consumed
    if h >= 3 then
        local ncollectors = 0
        for _ in pairs(agg.per_collector or {}) do ncollectors = ncollectors + 1 end

        local uptime_s = ((agg.lifetime and agg.lifetime.uptime_current_ms) or 0) / 1000
        local line1 = string.format("cells: %d    collectors: %d    uptime: %s",
            agg.network_cells or 0, ncollectors, util.fmtDuration(uptime_s))
        gfx.write(mon, 2, h - 1, line1, P.label)

        if agg.lifetime then
            local line2 = string.format("lifetime  +%s  -%s",
                util.fmtFE(agg.lifetime.produced_fe or 0),
                util.fmtFE(agg.lifetime.consumed_fe or 0))
            gfx.write(mon, 2, h, line2, P.dim and P.label or P.label)
        end
    end
end

-- ─── main ────────────────────────────────────────────────────────────────

log.init("panel", log.LEVEL.INFO)
log.info("starting")

local sides = comms.open_all_modems()
if #sides == 0 then log.error("no modem found"); error("attach a modem", 0) end

local mon = ppm.find_one("monitor")
if not mon then log.error("no monitor found"); error("attach an advanced monitor", 0) end
mon.setTextScale(1)

local mw, mh = mon.getSize()
log.info(string.format("modem=%s monitor=%dx%d", sides[1], mw, mh))

parallel.waitForAny(
    -- receive loop
    function()
        while true do
            local _, msg = rednet.receive(comms.PROTO_DATA, 5)
            if msg then
                local ok = comms.valid(msg)
                if ok and msg.kind == comms.KIND.CORE_AGGREGATE then
                    latest = msg.payload
                    latest_rx_ms = os.epoch("utc")
                end
            end
        end
    end,

    -- redraw loop
    function()
        while true do
            pcall(render, mon)
            sleep(REDRAW_MS / 1000)
        end
    end
)
