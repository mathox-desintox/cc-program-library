-- energy-dashboard/collector/collector.lua
--
-- RTU-style leaf program. Wraps a single flux_accessor_ext peripheral
-- (provided by the appflux-cc-patch server mod) and broadcasts its
-- readings to whichever core listens on PROTO_DATA.
--
-- Run on a computer next to (or wired-modem'd to) a flux accessor, with a
-- wireless/ender modem attached. Configuration via `configure` writes
-- /edash_config.lua — values not set there fall back to defaults.

local comms    = require("common.comms")
local log      = require("common.log")
local ppm      = require("common.ppm")
local configlib = require("common.config")

-- First-run wizard: auto-launch `configure` on first boot so the user
-- picks their flux_accessor_ext and tick rate before anything broadcasts.
-- No-op on subsequent boots (sentinel at /.edash_first_run_done).
configlib.run_first_run_wizard("collector")

-- ─── config ──────────────────────────────────────────────────────────────

local cfg = configlib.load("collector")
local TICK_SECONDS    = cfg.tick_seconds or 1
local RETRY_SECONDS   = 5
local PERIPHERAL_TYPE = "flux_accessor_ext"
local NETWORK_ID      = cfg.network_id or "default"
local PREFERRED_PNAME = cfg.peripheral  -- nil = auto-pick first

-- ─── helpers ─────────────────────────────────────────────────────────────

local function find_accessor()
    if PREFERRED_PNAME then
        if ppm.is_live(PREFERRED_PNAME) and peripheral.getType(PREFERRED_PNAME) == PERIPHERAL_TYPE then
            return peripheral.wrap(PREFERRED_PNAME), PREFERRED_PNAME
        end
        log.warn("configured peripheral '" .. PREFERRED_PNAME .. "' not found / wrong type; falling back to auto")
    end
    return ppm.find_one(PERIPHERAL_TYPE)
end

local function snapshot(accessor)
    local function safe(method)
        local ok, v = ppm.call(accessor, method)
        return ok and v or nil
    end
    return {
        stored         = safe("getEnergyLong")         or 0,
        storedString   = safe("getEnergyString")       or "0",
        capacity       = safe("getEnergyCapacityLong") or 0,
        capacityString = safe("getEnergyCapacityString") or "0",
        online         = safe("isOnline") == true,
        cellCount      = safe("getNetworkFluxCellCount") or 0,
        networkId      = NETWORK_ID,
    }
end

local function broadcast(state)
    local pkt = comms.packet(comms.KIND.COLLECTOR_STATE, comms.ROLE.COLLECTOR, state)
    rednet.broadcast(pkt, comms.PROTO_DATA)
end

-- ─── main ────────────────────────────────────────────────────────────────

log.init("collector", log.LEVEL.INFO)
log.info("starting")
log.info(string.format("config: tick=%ds network_id=%s peripheral=%s",
    TICK_SECONDS, NETWORK_ID, tostring(PREFERRED_PNAME or "auto")))

local sides = comms.open_all_modems()
if #sides == 0 then log.error("no modem found — attach a wireless/ender modem"); error("no modem", 0) end
log.info("opened modems on: " .. table.concat(sides, ", "))

while true do
    local accessor, name = find_accessor()
    if not accessor then
        log.warn("no " .. PERIPHERAL_TYPE .. " peripheral found; retrying in " .. RETRY_SECONDS .. "s")
        log.warn("  - appflux-cc-patch installed on the server?")
        log.warn("  - accessor adjacent or on a wired modem network?")
        sleep(RETRY_SECONDS)
    else
        log.info("peripheral wrapped at " .. tostring(name))
        while ppm.is_live(name) do
            local ok, state = pcall(snapshot, accessor)
            if ok and state then
                broadcast(state)
                io.write(string.format("\r[collector] online=%s stored=%s cells=%d   ",
                    tostring(state.online), state.storedString, state.cellCount))
            else
                log.warn("snapshot error: " .. tostring(state))
            end
            sleep(TICK_SECONDS)
        end
        log.warn("peripheral disconnected; rescanning")
    end
end
