-- energy-dashboard/collector/collector.lua
--
-- RTU-style leaf program. Wraps a single flux_accessor_ext peripheral
-- (provided by the appflux-cc-patch server mod) and broadcasts its
-- readings once per second to whichever core listens on PROTO_DATA.
--
-- Run on a computer next to (or wired-modem'd to) a flux accessor, with a
-- wireless/ender modem attached.

local comms = require("common.comms")
local log   = require("common.log")
local ppm   = require("common.ppm")

-- ─── config ──────────────────────────────────────────────────────────────

local TICK_SECONDS    = 1     -- how often we read + broadcast
local RETRY_SECONDS   = 5     -- retry cadence when peripheral missing
local PERIPHERAL_TYPE = "flux_accessor_ext"

-- ─── helpers ─────────────────────────────────────────────────────────────

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
        -- Reserved for future multi-network support; for now a single
        -- logical network per collector.
        networkId      = "default",
    }
end

local function broadcast(state)
    local pkt = comms.packet(comms.KIND.COLLECTOR_STATE, comms.ROLE.COLLECTOR, state)
    rednet.broadcast(pkt, comms.PROTO_DATA)
end

-- ─── main ────────────────────────────────────────────────────────────────

log.init("collector", log.LEVEL.INFO)
log.info("starting")

local sides = comms.open_all_modems()
if #sides == 0 then log.error("no modem found — attach a wireless/ender modem"); error("no modem", 0) end
log.info("opened modems on: " .. table.concat(sides, ", "))

while true do
    local accessor, name = ppm.find_one(PERIPHERAL_TYPE)
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
