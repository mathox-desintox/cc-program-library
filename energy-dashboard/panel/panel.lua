-- energy-dashboard panel (MVP).
--
-- Listens for "flux_state" messages from collectors on rednet protocol
-- "edash_v1" and renders the latest network state (stored / capacity / fill %
-- / rate) on an advanced monitor. Run on a computer that has:
--   - an advanced monitor attached (any side or via wired modem)
--   - a wireless/ender modem for receiving broadcasts
--
-- Rate is derived on the panel by diffing `stored` samples across time.
-- Stale data (no update in >5s) is flagged.

local PROTOCOL     = "edash_v1"
local MSG_TYPE     = "flux_state"
local STALE_MS     = 5000
local REDRAW_MS    = 200   -- redraw cadence independent of collector tick

-- ─── utilities ───────────────────────────────────────────────────────────

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

local function findMonitor()
    return peripheral.find("monitor")
end

-- SI-prefixed FE formatter. Uses doubles (adequate for display; precision
-- degrades by ~9 FE at 40 PFE, imperceptible visually).
local function fmtFE(v)
    if not v or v ~= v then return "—" end -- nan guard
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

-- Signed rate with SI prefix, e.g. "+2.34 MFE/s"
local function fmtRate(r)
    if not r or r ~= r then return "—" end
    local sign = r >= 0 and "+" or "-"
    return sign .. fmtFE(math.abs(r)) .. "/s"
end

local function fmtDuration(seconds)
    if not seconds or seconds ~= seconds or seconds == math.huge then return "—" end
    if seconds < 60    then return string.format("%ds", seconds) end
    if seconds < 3600  then return string.format("%dm %ds", seconds / 60, seconds % 60) end
    if seconds < 86400 then return string.format("%dh %dm", seconds / 3600, (seconds % 3600) / 60) end
    return string.format("%dd %dh", seconds / 86400, (seconds % 86400) / 3600)
end

-- ─── state held locally by the panel ─────────────────────────────────────

-- Only one collector for MVP, but we key by `src` so adding a "core" tier
-- later won't change the data structure.
local collectors = {}  -- src -> { last = <state msg>, prev = <older state msg> }

local function recordState(msg)
    local src = msg.src
    local entry = collectors[src] or {}
    entry.prev = entry.last
    entry.last = msg
    collectors[src] = entry
end

-- Returns stored, capacity, rate (FE/s), cells, online, stale
local function aggregate()
    local stored, capacity, cells = 0, 0, 0
    local rateSum = 0
    local online = true
    local stale = true
    local nowMs = os.epoch("utc")

    for _, entry in pairs(collectors) do
        local s = entry.last
        stored   = stored + (s.data.stored or 0)
        capacity = capacity + (s.data.capacity or 0)
        cells    = cells + (s.data.cellCount or 0)
        if not s.data.online then online = false end
        if nowMs - s.ts < STALE_MS then stale = false end

        if entry.prev then
            local dtMs = s.ts - entry.prev.ts
            if dtMs > 0 then
                local dFE = (s.data.stored or 0) - (entry.prev.data.stored or 0)
                rateSum = rateSum + dFE * 1000 / dtMs
            end
        end
    end

    return stored, capacity, rateSum, cells, online, stale
end

-- ─── rendering ───────────────────────────────────────────────────────────

local function writeAt(mon, x, y, s, fg, bg)
    if fg then mon.setTextColor(fg) end
    if bg then mon.setBackgroundColor(bg) end
    mon.setCursorPos(x, y)
    mon.write(s)
end

local function drawBar(mon, x, y, width, fillPct)
    fillPct = math.max(0, math.min(100, fillPct or 0))
    local filled = math.floor(width * fillPct / 100 + 0.5)
    mon.setCursorPos(x, y)
    for i = 1, width do
        if i <= filled then
            mon.setBackgroundColor(colors.lime)
        else
            mon.setBackgroundColor(colors.gray)
        end
        mon.write(" ")
    end
    mon.setBackgroundColor(colors.black)
end

local function render(mon)
    local w, h = mon.getSize()
    mon.setBackgroundColor(colors.black)
    mon.clear()

    local stored, capacity, rate, cells, online, stale = aggregate()
    local fillPct = capacity > 0 and (stored * 100 / capacity) or 0
    local eta
    if math.abs(rate) > 0 then
        if rate > 0 then
            eta = (capacity - stored) / rate   -- time to full
        else
            eta = stored / -rate                -- time to empty
        end
    end

    -- title
    writeAt(mon, 2, 1, "FLUX NETWORK", colors.white, colors.black)
    local statusText, statusColor
    if next(collectors) == nil then
        statusText, statusColor = "NO DATA", colors.red
    elseif stale then
        statusText, statusColor = "STALE", colors.yellow
    elseif not online then
        statusText, statusColor = "OFFLINE", colors.red
    else
        statusText, statusColor = "ONLINE", colors.lime
    end
    writeAt(mon, w - #statusText, 1, statusText, statusColor, colors.black)

    -- stored / capacity / rate
    writeAt(mon, 2, 3, "Stored  ", colors.lightGray, colors.black)
    writeAt(mon, 10, 3, fmtFE(stored), colors.white, colors.black)

    writeAt(mon, 2, 4, "Cap     ", colors.lightGray, colors.black)
    writeAt(mon, 10, 4, fmtFE(capacity), colors.white, colors.black)

    writeAt(mon, 2, 5, "Rate    ", colors.lightGray, colors.black)
    local rateColor = colors.white
    if rate > 0 then rateColor = colors.lime elseif rate < 0 then rateColor = colors.orange end
    writeAt(mon, 10, 5, fmtRate(rate), rateColor, colors.black)

    writeAt(mon, 2, 6, "ETA     ", colors.lightGray, colors.black)
    local etaText = rate == 0 and "idle" or (rate > 0 and ("to full: " .. fmtDuration(eta)) or ("to empty: " .. fmtDuration(eta)))
    writeAt(mon, 10, 6, etaText, colors.white, colors.black)

    -- fill bar
    local barY = 8
    local barW = w - 2
    drawBar(mon, 2, barY, barW, fillPct)
    writeAt(mon, 2, barY + 1, string.format("%.1f%%", fillPct), colors.white, colors.black)

    -- footer
    local footer = string.format("cells: %d", cells)
    writeAt(mon, 2, h, footer, colors.gray, colors.black)
end

-- ─── main ────────────────────────────────────────────────────────────────

local modemSide = openAnyModem()
local mon = findMonitor()
if not mon then fatal("no monitor found — attach an advanced monitor") end
mon.setTextScale(1)

local mw, mh = mon.getSize()
print(string.format("[panel] modem=%s monitor=%dx%d protocol=%s",
    modemSide, mw, mh, PROTOCOL))

local lastRedraw = 0

parallel.waitForAny(
    function()
        while true do
            local _, msg = rednet.receive(PROTOCOL, 1)
            if type(msg) == "table" and msg.type == MSG_TYPE and msg.src and msg.data then
                recordState(msg)
            end
        end
    end,
    function()
        while true do
            local now = os.epoch("utc")
            if now - lastRedraw >= REDRAW_MS then
                pcall(render, mon)
                lastRedraw = now
            end
            sleep(REDRAW_MS / 1000)
        end
    end
)
