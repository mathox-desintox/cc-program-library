-- energy-dashboard/common/config.lua
--
-- Single-source-of-truth for runtime configuration. Defaults live here;
-- user overrides are written to /edash_config.lua by the configure UI.
-- Every component's startup path is:
--
--   local config = require("common.config").load("collector")
--
-- which returns a component-scoped table with defaults filled in for any
-- keys the user hasn't touched.

local M = {}

M.FILE           = "/edash_config.lua"
M.FIRST_RUN_FLAG = "/.edash_first_run_done"

-- Structure mirrors the on-disk file: config[component][key] = value.
-- Keep the schema flat and well-named; configure.lua drives its UI from
-- this table, so adding a new knob here also adds it to the UI.
M.DEFAULTS = {
    -- Shared across every component on this computer. network_id is the
    -- per-world "team" identifier - lets multiple independent dashboards
    -- coexist on the same ender-modem broadcast domain. All packets are
    -- stamped with it and receivers silently drop mismatches.
    network_id = "default",

    collector = {
        peripheral   = nil,   -- auto-pick first flux_accessor_ext if nil
        tick_seconds = 1,     -- broadcast cadence
    },
    core = {
        broadcast_interval_ms = 1000,
        persist_interval_ms   = 30000,
        stale_ms              = 5000,
        state_file            = "/edash_core.dat",
        log_file              = "/edash_core.log",
    },
    panel = {
        monitor          = nil,        -- auto-pick first monitor if nil
        rate_unit        = "t",        -- "t" (ticks, MC native) or "s"
        redraw_ms        = 250,
        stale_ms         = 5000,
        theme            = "default",
        default_horizon  = "m5",       -- m1/m5/m15/h1/h8/h24 (clickable tab)
    },
}

-- Deep-copy to protect defaults from mutation by callers.
local function deepcopy(t)
    if type(t) ~= "table" then return t end
    local out = {}
    for k, v in pairs(t) do out[k] = deepcopy(v) end
    return out
end

-- Merge src over dst (in-place on dst). Nested tables merged recursively;
-- scalars in src overwrite scalars in dst.
local function merge(dst, src)
    if type(src) ~= "table" then return dst end
    for k, v in pairs(src) do
        if type(v) == "table" and type(dst[k]) == "table" then
            merge(dst[k], v)
        else
            dst[k] = v
        end
    end
    return dst
end

-- Load the on-disk config (or an empty table if missing/corrupt). Merging
-- with defaults happens at get() time.
local function load_file()
    if not fs.exists(M.FILE) then return {} end
    local ok, v = pcall(dofile, M.FILE)
    if not ok or type(v) ~= "table" then return {} end
    return v
end

-- Return the full config (every component scope, defaults merged with
-- user overrides). Used by the configure UI.
function M.load_all()
    local out = deepcopy(M.DEFAULTS)
    merge(out, load_file())
    return out
end

-- Return config for a single component (e.g. "collector"), with defaults
-- merged. This is what each component's startup calls.
function M.load(component)
    return M.load_all()[component] or deepcopy(M.DEFAULTS[component] or {})
end

-- Serialize a table as Lua so users can read and hand-edit it. Uses
-- textutils.serialise plus a small header so we emit "return {...}".
function M.save_all(full_config)
    local body = textutils.serialise(full_config)
    local f = fs.open(M.FILE, "w")
    if not f then return false, "cannot open " .. M.FILE .. " for writing" end
    f.writeLine("-- edash config - edit via `configure`, or by hand. Regenerated as needed.")
    f.write("return " .. body .. "\n")
    f.close()
    return true
end

-- First-run wizard. Called by each component at startup. If this is the
-- first time the component has run on this computer (sentinel file
-- missing), print a short notice and launch `configure`. Regardless of
-- whether the user saves or discards inside configure, we touch the
-- sentinel so subsequent boots don't re-prompt.
--
-- Intentionally idempotent - safe to call on every start.
function M.run_first_run_wizard(component_name)
    if fs.exists(M.FIRST_RUN_FLAG) then return false end
    if term and term.isColor and term.isColor() then term.setTextColor(colors.yellow) end
    print("")
    print("-- first run detected for " .. tostring(component_name or "edash") .. " --")
    if term and term.setTextColor then term.setTextColor(colors.white) end
    print("launching `configure` - save your settings, then this program will resume.")
    print("(press Ctrl+T in configure to skip; you can always run `configure` later)")
    sleep(1.5)
    -- Write the sentinel BEFORE launching configure. If the user clicks
    -- 'reboot now' inside configure we never return from shell.run, so any
    -- post-launch bookkeeping would be skipped and the wizard would
    -- re-trigger on every boot.
    local f = fs.open(M.FIRST_RUN_FLAG, "w")
    if f then f.writeLine(tostring(os.epoch("utc"))); f.close() end
    if fs.exists("configure") or fs.exists("configure.lua") then
        shell.run("configure")
    else
        print("(configure not installed - continuing with defaults)")
    end
    return true
end

return M
