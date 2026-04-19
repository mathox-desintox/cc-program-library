-- energy-dashboard collector (MVP).
--
-- Finds a flux_accessor_ext peripheral (provided by the appflux-cc-patch
-- server mod) and broadcasts its readings periodically on rednet protocol
-- "edash_v1". One collector per AE2 network; run on a computer adjacent to
-- (or wired-modem'd to) a flux accessor, with a wireless/ender modem.

local PROTOCOL     = "edash_v1"
local MSG_TYPE     = "flux_state"
local TICK_SECONDS = 1

local function fatal(fmt, ...) error(string.format(fmt, ...), 0) end

local function openAnyModem()
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            rednet.open(side)
            return side
        end
    end
    fatal("no modem found — attach a wireless/ender modem to any side")
end

local function findAccessor()
    -- peripheral.find returns the first wrapped match or nil
    return peripheral.find("flux_accessor_ext")
end

local function snapshot(a)
    return {
        stored         = a.getEnergyLong(),
        storedString   = a.getEnergyString(),
        capacity       = a.getEnergyCapacityLong(),
        capacityString = a.getEnergyCapacityString(),
        online         = a.isOnline(),
        cellCount      = a.getNetworkFluxCellCount(),
    }
end

local function broadcast(state)
    rednet.broadcast({
        type = MSG_TYPE,
        src  = os.getComputerID(),
        ts   = os.epoch("utc"),
        data = state,
    }, PROTOCOL)
end

-- ─── main ────────────────────────────────────────────────────────────────

local modemSide = openAnyModem()
print(string.format("[collector] modem on %s, protocol=%s", modemSide, PROTOCOL))

while true do
    local a = findAccessor()
    if not a then
        print("[collector] no flux_accessor_ext peripheral found; retrying in 5s")
        print("  - install appflux-cc-patch on the server")
        print("  - place/wire a flux accessor adjacent or via modem network")
        sleep(5)
    else
        local ok, state = pcall(snapshot, a)
        if ok then
            broadcast(state)
            io.write(string.format("\r[collector] online=%s stored=%s cells=%d   ",
                tostring(state.online), state.storedString, state.cellCount))
        else
            print("\n[collector] snapshot error: " .. tostring(state))
        end
        sleep(TICK_SECONDS)
    end
end
