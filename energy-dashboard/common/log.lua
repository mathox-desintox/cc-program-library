-- energy-dashboard/common/log.lua
--
-- Leveled logger. Writes to terminal (coloured) and optionally a file.
-- Every component calls log.init(name, level, file) at startup so output
-- prefixes show who logged what.

local M = {}

M.LEVEL = { DEBUG = 1, INFO = 2, WARN = 3, ERROR = 4 }

local NAME  = { [1] = "DEBUG", [2] = "INFO", [3] = "WARN", [4] = "ERROR" }
local COLOR = {
    [1] = colors.lightGray,
    [2] = colors.white,
    [3] = colors.yellow,
    [4] = colors.red,
}

-- State set by init().
local _component = "?"
local _threshold = M.LEVEL.INFO
local _file      = nil
local _silent    = false   -- when true, only file output; terminal untouched

function M.init(component, threshold, file)
    _component = component or "?"
    _threshold = threshold or M.LEVEL.INFO
    _file      = file
end

-- Enable this when a status canvas owns the terminal. Log still writes to
-- the file (if configured) so you get a full trace - the terminal just
-- isn't clobbered by stray prints.
function M.silence_terminal(b) _silent = b and true or false end

local function emit(level, msg)
    if level < _threshold then return end
    local ts = textutils.formatTime(os.time(), true)
    local line = string.format("[%s] %s %s: %s", ts, NAME[level], _component, tostring(msg))

    -- terminal (coloured) - suppressed when a status canvas owns the terminal
    if not _silent then
        local prev_fg = term.getTextColor and term.getTextColor() or colors.white
        if term.setTextColor then term.setTextColor(COLOR[level] or colors.white) end
        print(line)
        if term.setTextColor then term.setTextColor(prev_fg) end
    end

    -- file
    if _file then
        local f = fs.open(_file, "a")
        if f then
            f.writeLine(line)
            f.close()
        end
    end
end

function M.debug(msg) emit(M.LEVEL.DEBUG, msg) end
function M.info(msg)  emit(M.LEVEL.INFO, msg)  end
function M.warn(msg)  emit(M.LEVEL.WARN, msg)  end
function M.error(msg) emit(M.LEVEL.ERROR, msg) end

return M
