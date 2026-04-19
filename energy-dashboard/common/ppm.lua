-- energy-dashboard/common/ppm.lua
--
-- Protected peripheral manager. Thin wrapper that:
--   - enumerates peripherals by type (find_all, find_one)
--   - wraps method calls in pcall so mid-tick disconnects don't crash us
--   - reports liveness via is_live()
--
-- Not a full scada-mek ppm (no event bus, no unmount events). Enough to
-- survive a drive being broken or a modem being removed.

local M = {}

-- Find every peripheral of a given type. Returns { [name] = wrapped, ... }.
function M.find_all(ptype)
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == ptype then
            out[name] = peripheral.wrap(name)
        end
    end
    return out
end

-- First peripheral of the given type, or nil. Optional filter(name, device) -> bool.
function M.find_one(ptype, filter)
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == ptype then
            local dev = peripheral.wrap(name)
            if dev and (not filter or filter(name, dev)) then
                return dev, name
            end
        end
    end
    return nil, nil
end

-- Safe method call. Returns (ok, result_or_error).
--
--   local ok, stored = ppm.call(accessor, "getEnergyLong")
--   if ok then ... else log.warn(stored) end
--
function M.call(device, method, ...)
    if not device or type(device[method]) ~= "function" then
        return false, "method not found: " .. tostring(method)
    end
    local ok, result = pcall(device[method], ...)
    if not ok then return false, result end
    return true, result
end

-- Is a previously-wrapped peripheral still attached? We check by seeing if
-- its name is still in peripheral.getNames() - this catches the common case
-- of the block being broken or the modem yanked.
function M.is_live(name)
    if not name then return false end
    for _, n in ipairs(peripheral.getNames()) do
        if n == name then return true end
    end
    return false
end

return M
