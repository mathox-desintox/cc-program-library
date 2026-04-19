-- energy-dashboard/common/comms.lua
--
-- Protocol definitions + packet builder/validator.
-- Every inter-computer message goes through here so the wire format lives
-- in one place and version mismatches fail fast rather than silently.

local M = {}

-- Bump this on any packet-shape change. Peers whose version doesn't match
-- are ignored by valid().
M.VERSION = 1

-- Separate rednet protocol strings by purpose (channels, in scada parlance).
M.PROTO_DATA = "edash_data_v1"  -- state updates, aggregates
M.PROTO_MGMT = "edash_mgmt_v1"  -- heartbeats, discovery
M.PROTO_CMD  = "edash_cmd_v1"   -- commands (reset counters, set config, ...)

-- Packet kinds (values of msg.kind).
M.KIND = {
    COLLECTOR_STATE = "collector_state",  -- collector -> core
    CORE_AGGREGATE  = "core_aggregate",   -- core -> panel / remote
    HEARTBEAT       = "heartbeat",        -- any -> any, liveness
    DISCOVERY       = "discovery",        -- any -> any, find peers
    COMMAND         = "command",          -- panel/remote -> core / collector
}

-- Component roles (values of msg.src.role).
M.ROLE = {
    COLLECTOR = "collector",
    CORE      = "core",
    PANEL     = "panel",
    REMOTE    = "remote",
}

-- Build a packet with the standard envelope.
function M.packet(kind, role, payload)
    return {
        version = M.VERSION,
        kind    = kind,
        src     = { id = os.getComputerID(), role = role },
        ts      = os.epoch("utc"),
        payload = payload or {},
    }
end

-- Returns (true) for valid packets, (false, reason) otherwise.
-- Callers should drop invalid packets silently.
function M.valid(msg)
    if type(msg) ~= "table"                      then return false, "not a table" end
    if msg.version ~= M.VERSION                  then return false, "version " .. tostring(msg.version) end
    if type(msg.kind) ~= "string"                then return false, "missing kind" end
    if type(msg.src) ~= "table"                  then return false, "missing src" end
    if type(msg.src.id) ~= "number"              then return false, "bad src.id" end
    if type(msg.src.role) ~= "string"            then return false, "bad src.role" end
    if type(msg.ts) ~= "number"                  then return false, "missing ts" end
    if type(msg.payload) ~= "table"              then return false, "missing payload" end
    return true
end

-- Open the first modem we find on each side. Returns the list of sides opened.
function M.open_all_modems()
    local sides = {}
    for _, side in ipairs(peripheral.getNames()) do
        if peripheral.getType(side) == "modem" then
            rednet.open(side)
            sides[#sides + 1] = side
        end
    end
    return sides
end

return M
