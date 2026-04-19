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

-- Network ID — a per-world "team" string that isolates independent dashboards
-- broadcasting on the same ender-modem channel. Every outgoing packet is
-- stamped with this value; every incoming packet whose id doesn't match is
-- silently dropped. Each component sets it once at startup from config.
local _network_id = "default"

function M.set_network_id(id)
    _network_id = (id ~= nil and tostring(id)) or "default"
end

function M.get_network_id() return _network_id end

-- Build a packet with the standard envelope.
function M.packet(kind, role, payload)
    return {
        version    = M.VERSION,
        kind       = kind,
        network_id = _network_id,
        src        = { id = os.getComputerID(), role = role },
        ts         = os.epoch("utc"),
        payload    = payload or {},
    }
end

-- Returns (true) for valid packets, (false, reason) otherwise.
-- Callers should drop invalid packets silently.
function M.valid(msg)
    if type(msg) ~= "table"           then return false, "not a table" end
    if msg.version ~= M.VERSION       then return false, "version " .. tostring(msg.version) end
    if msg.network_id ~= _network_id  then return false, "network_id " .. tostring(msg.network_id) end
    if type(msg.kind) ~= "string"     then return false, "missing kind" end
    if type(msg.src) ~= "table"       then return false, "missing src" end
    if type(msg.src.id) ~= "number"   then return false, "bad src.id" end
    if type(msg.src.role) ~= "string" then return false, "bad src.role" end
    if type(msg.ts) ~= "number"       then return false, "missing ts" end
    if type(msg.payload) ~= "table"   then return false, "missing payload" end
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
