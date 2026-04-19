-- energy-dashboard/common/util.lua
--
-- Formatting helpers + a bounded ring buffer used by the core's history.

local M = {}

-- SI-prefixed FE formatter. Uses doubles (precision degrades by ~9 FE at
-- 40 PFE, imperceptible for display; use String variants for exactness).
function M.fmtFE(v)
    if not v or v ~= v then return "-" end
    local a = math.abs(v)
    local units = { "FE", "kFE", "MFE", "GFE", "TFE", "PFE", "EFE" }
    local i = 1
    while a >= 1000 and i < #units do
        a = a / 1000
        v = v / 1000
        i = i + 1
    end
    if i == 1 then return string.format("%d %s", v, units[i]) end
    return string.format("%.2f %s", v, units[i])
end

-- Signed rate. Argument is always FE/s; unit ("t" or "s") controls display.
-- 20 MC ticks per real-time second.
function M.fmtRate(ratePerSecond, unit)
    if not ratePerSecond or ratePerSecond ~= ratePerSecond then return "-" end
    unit = unit or "t"
    local display, suffix
    if unit == "t" then
        display, suffix = ratePerSecond / 20, "/t"
    else
        display, suffix = ratePerSecond, "/s"
    end
    local sign = display >= 0 and "+" or "-"
    return sign .. M.fmtFE(math.abs(display)) .. suffix
end

function M.fmtDuration(seconds)
    if not seconds or seconds ~= seconds or seconds == math.huge then return "-" end
    seconds = math.floor(seconds)
    if seconds < 0     then return "-" end
    if seconds < 60    then return string.format("%ds", seconds) end
    if seconds < 3600  then return string.format("%dm %ds", seconds / 60, seconds % 60) end
    if seconds < 86400 then return string.format("%dh %dm", seconds / 3600, (seconds % 3600) / 60) end
    return string.format("%dd %dh", seconds / 86400, (seconds % 86400) / 3600)
end

-- Clamp a value into [lo, hi].
function M.clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-- --- string helpers ----------------------------------------------------

-- Word-wrap `text` to fit within `width` columns. Returns array of lines.
-- Words longer than `width` are placed alone on a line (and overflow - we
-- don't hyphenate). A nil/empty input returns {}.
function M.wrap(text, width)
    if not text or text == "" or width < 1 then return {} end
    local lines, current = {}, ""
    for word in tostring(text):gmatch("%S+") do
        if current == "" then
            current = word
        elseif #current + 1 + #word <= width then
            current = current .. " " .. word
        else
            lines[#lines + 1] = current
            current = word
        end
    end
    if current ~= "" then lines[#lines + 1] = current end
    return lines
end

-- Truncate `text` to fit in `width` columns, appending `suffix` (default "..")
-- when it would be cut. Tries to cut at a word boundary if possible.
function M.truncate(text, width, suffix)
    text = tostring(text or "")
    suffix = suffix or ".."
    if #text <= width then return text end
    if width <= #suffix then return text:sub(1, width) end
    local budget = width - #suffix
    local cut = text:sub(1, budget)
    -- Prefer a word boundary if one exists in the last quarter of the cut.
    local ws = cut:find(" [^ ]*$")
    if ws and ws > math.floor(budget * 0.5) then
        cut = cut:sub(1, ws - 1)
    end
    return cut .. suffix
end

-- Pad `s` to exactly `w` columns with spaces on the right (default) or left.
function M.pad(s, w, align)
    s = tostring(s or "")
    if #s >= w then return s:sub(1, w) end
    local gap = w - #s
    if align == "right" then return string.rep(" ", gap) .. s end
    return s .. string.rep(" ", gap)
end

-- --- ring buffer -------------------------------------------------------

-- Fixed-capacity ring that overwrites oldest on push once full.
-- Indices are 1 = newest, 2 = next, ..., len() = oldest.

local Ring = {}
Ring.__index = Ring

function M.ring(capacity)
    return setmetatable({ cap = capacity, n = 0, head = 0, data = {} }, Ring)
end

function Ring:push(v)
    self.head = (self.head % self.cap) + 1
    self.data[self.head] = v
    if self.n < self.cap then self.n = self.n + 1 end
end

function Ring:len() return self.n end

function Ring:clear()
    self.n = 0
    self.head = 0
    self.data = {}
end

-- 1 = newest (just pushed), n = oldest retained.
function Ring:at(idx)
    if idx < 1 or idx > self.n then return nil end
    local i = ((self.head - idx) % self.cap) + 1
    return self.data[i]
end

function Ring:first() return self:at(1) end
function Ring:last()  return self:at(self.n) end

-- Iterate oldest -> newest.
function Ring:iter()
    local i = self.n + 1
    return function()
        i = i - 1
        if i < 1 then return end
        return self:at(i)
    end
end

-- Average of a numeric field across all retained samples. `extract` takes one
-- sample and returns the number to average (or pass nil for plain-number rings).
function Ring:avg(extract)
    if self.n == 0 then return 0 end
    local sum = 0
    for v in self:iter() do
        sum = sum + (extract and extract(v) or v)
    end
    return sum / self.n
end

return M
