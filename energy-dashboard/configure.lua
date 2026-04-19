-- energy-dashboard/configure.lua
--
-- Interactive config editor. Reads /.edi_state (from edi) to know which
-- components are installed locally, autodetects attached peripherals, and
-- writes /edash_config.lua. Run this on each computer after installing
-- its component.
--
-- Dependencies: common/config.lua (on disk via edi).

local config = require("common.config")

-- ─── terminal helpers ───────────────────────────────────────────────────

local has_color = term.isColor and term.isColor()
local function set_fg(c) if has_color then term.setTextColor(c) end end
local function set_bg(c) if has_color then term.setBackgroundColor(c) end end

local function clear_screen()
    set_bg(colors.black); set_fg(colors.white)
    term.clear(); term.setCursorPos(1, 1)
end

local function header(title, subtitle)
    clear_screen()
    set_fg(colors.yellow); print("== " .. title .. " ==")
    if subtitle then set_fg(colors.lightGray); print(subtitle) end
    set_fg(colors.white); print()
end

local function footer(text)
    local _, h = term.getSize()
    term.setCursorPos(1, h)
    set_fg(colors.lightGray); term.clearLine(); write(text)
    set_fg(colors.white)
end

local function pause_and_return()
    set_fg(colors.lightGray); print(); print("Press any key to continue...")
    set_fg(colors.white); os.pullEvent("key")
end

-- ─── arrow-key menu ─────────────────────────────────────────────────────

local function arrow_menu(items, opts)
    opts = opts or {}
    local sel = opts.initial or 1
    while true do
        header(opts.title or "configure", opts.subtitle)
        local _, h = term.getSize()
        local max_visible = h - 5
        local offset = 0
        if #items > max_visible then offset = math.min(sel - 1, #items - max_visible) end

        for i = 1, math.min(max_visible, #items) do
            local idx = i + offset
            local it = items[idx]
            if idx == sel then set_fg(colors.black); set_bg(colors.white)
            else set_fg(colors.white); set_bg(colors.black) end
            term.clearLine(); write(" " .. (it.label or tostring(it)))
            if it.tag then
                set_fg(idx == sel and colors.gray or colors.lightGray)
                write("  " .. it.tag)
            end
            print()
        end
        set_bg(colors.black)

        footer(opts.footer or "Up/Down  Enter=select  Q=quit")
        local _, key = os.pullEvent("key")
        if     key == keys.up   and sel > 1       then sel = sel - 1
        elseif key == keys.down and sel < #items  then sel = sel + 1
        elseif key == keys.enter then set_bg(colors.black); return items[sel], sel
        elseif key == keys.q    then return nil end
    end
end

-- ─── prompts ────────────────────────────────────────────────────────────

local function prompt_number(label, current)
    header("Edit: " .. label, "current: " .. tostring(current))
    set_fg(colors.white); write("New value (blank=keep): ")
    local input = read()
    if input == "" or input == nil then return current end
    local n = tonumber(input)
    if not n then
        set_fg(colors.red); print("not a number; keeping current")
        pause_and_return()
        return current
    end
    return n
end

local function prompt_text(label, current)
    header("Edit: " .. label, "current: " .. tostring(current))
    set_fg(colors.white); write("New value (blank=keep): ")
    local input = read()
    if input == "" or input == nil then return current end
    return input
end

local function prompt_enum(label, current, options)
    local items = {}
    for _, o in ipairs(options) do
        items[#items + 1] = { label = tostring(o), value = o, tag = (o == current) and "[current]" or nil }
    end
    items[#items + 1] = { label = "[cancel]", value = nil, cancel = true }
    local sel = arrow_menu(items, { title = "Edit: " .. label, subtitle = "current: " .. tostring(current) })
    if not sel or sel.cancel then return current end
    return sel.value
end

-- ─── peripheral picker ──────────────────────────────────────────────────

local function list_peripherals_of_type(ptype)
    local out = {}
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.getType(name) == ptype then
            out[#out + 1] = name
        end
    end
    return out
end

local function prompt_peripheral(label, current, ptype)
    local names = list_peripherals_of_type(ptype)
    if #names == 0 then
        header("Peripheral: " .. label, "no " .. ptype .. " peripheral attached")
        pause_and_return()
        return current
    end
    local items = {}
    for _, name in ipairs(names) do
        items[#items + 1] = {
            label = name,
            tag   = (name == current) and "[current]" or nil,
            value = name,
        }
    end
    items[#items + 1] = { label = "(auto-pick first available)", value = nil }
    items[#items + 1] = { label = "[cancel]", cancel = true }
    local sel = arrow_menu(items, {
        title    = "Peripheral: " .. label,
        subtitle = "attached " .. ptype .. " peripherals:",
    })
    if not sel or sel.cancel then return current end
    return sel.value
end

-- ─── component editors ──────────────────────────────────────────────────

local function edit_collector(cfg)
    while true do
        local items = {
            { label = "peripheral   ", tag = tostring(cfg.peripheral or "auto"),    key = "peripheral" },
            { label = "tick_seconds ", tag = tostring(cfg.tick_seconds),            key = "tick_seconds" },
            { label = "network_id   ", tag = tostring(cfg.network_id),              key = "network_id" },
            { label = "[back]",                                                     back = true },
        }
        local sel = arrow_menu(items, { title = "configure collector" })
        if not sel or sel.back then return cfg end
        if     sel.key == "peripheral"   then cfg.peripheral   = prompt_peripheral("flux_accessor_ext", cfg.peripheral, "flux_accessor_ext")
        elseif sel.key == "tick_seconds" then cfg.tick_seconds = prompt_number("tick_seconds", cfg.tick_seconds)
        elseif sel.key == "network_id"   then cfg.network_id   = prompt_text("network_id", cfg.network_id)
        end
    end
end

local function edit_core(cfg)
    while true do
        local items = {
            { label = "broadcast_interval_ms ", tag = tostring(cfg.broadcast_interval_ms), key = "broadcast_interval_ms" },
            { label = "persist_interval_ms   ", tag = tostring(cfg.persist_interval_ms),   key = "persist_interval_ms" },
            { label = "stale_ms              ", tag = tostring(cfg.stale_ms),              key = "stale_ms" },
            { label = "state_file            ", tag = tostring(cfg.state_file),            key = "state_file" },
            { label = "log_file              ", tag = tostring(cfg.log_file),              key = "log_file" },
            { label = "[back]",                                                            back = true },
        }
        local sel = arrow_menu(items, { title = "configure core" })
        if not sel or sel.back then return cfg end
        if     sel.key == "broadcast_interval_ms" then cfg.broadcast_interval_ms = prompt_number(sel.key, cfg.broadcast_interval_ms)
        elseif sel.key == "persist_interval_ms"   then cfg.persist_interval_ms   = prompt_number(sel.key, cfg.persist_interval_ms)
        elseif sel.key == "stale_ms"              then cfg.stale_ms              = prompt_number(sel.key, cfg.stale_ms)
        elseif sel.key == "state_file"            then cfg.state_file            = prompt_text(sel.key, cfg.state_file)
        elseif sel.key == "log_file"              then cfg.log_file              = prompt_text(sel.key, cfg.log_file)
        end
    end
end

local function edit_panel(cfg)
    while true do
        local items = {
            { label = "monitor     ", tag = tostring(cfg.monitor or "auto"), key = "monitor" },
            { label = "rate_unit   ", tag = tostring(cfg.rate_unit),         key = "rate_unit" },
            { label = "redraw_ms   ", tag = tostring(cfg.redraw_ms),         key = "redraw_ms" },
            { label = "stale_ms    ", tag = tostring(cfg.stale_ms),          key = "stale_ms" },
            { label = "theme       ", tag = tostring(cfg.theme),             key = "theme" },
            { label = "[back]",                                              back = true },
        }
        local sel = arrow_menu(items, { title = "configure panel" })
        if not sel or sel.back then return cfg end
        if     sel.key == "monitor"   then cfg.monitor   = prompt_peripheral("monitor", cfg.monitor, "monitor")
        elseif sel.key == "rate_unit" then cfg.rate_unit = prompt_enum("rate_unit", cfg.rate_unit, { "t", "s" })
        elseif sel.key == "redraw_ms" then cfg.redraw_ms = prompt_number(sel.key, cfg.redraw_ms)
        elseif sel.key == "stale_ms"  then cfg.stale_ms  = prompt_number(sel.key, cfg.stale_ms)
        elseif sel.key == "theme"     then cfg.theme     = prompt_text("theme", cfg.theme)
        end
    end
end

-- ─── which components exist here? ───────────────────────────────────────

local function load_edi_state()
    if not fs.exists("/.edi_state") then return { installed = {} } end
    local f = fs.open("/.edi_state", "r")
    if not f then return { installed = {} } end
    local data = f.readAll(); f.close()
    local ok, s = pcall(textutils.unserialise, data)
    if not ok or type(s) ~= "table" then return { installed = {} } end
    s.installed = s.installed or {}
    return s
end

local function installed_components()
    local state = load_edi_state()
    local out = {}
    for n in pairs(state.installed) do out[#out + 1] = n end
    -- Also offer to configure any component whose files are present even
    -- if .edi_state is missing (e.g. someone wiped the state file).
    if fs.exists("collector.lua") and not state.installed.collector then out[#out + 1] = "collector" end
    if fs.exists("core.lua")      and not state.installed.core      then out[#out + 1] = "core"      end
    if fs.exists("panel.lua")     and not state.installed.panel     then out[#out + 1] = "panel"     end
    table.sort(out)
    return out
end

-- ─── main ───────────────────────────────────────────────────────────────

local function main()
    local all = config.load_all()
    local comps = installed_components()

    if #comps == 0 then
        header("configure", "nothing appears to be installed on this computer")
        set_fg(colors.lightGray)
        print("Run 'pastebin run F3bHqTDi' first to install collector / core / panel.")
        pause_and_return()
        return
    end

    while true do
        local items = {}
        for _, name in ipairs(comps) do
            local summary
            if name == "collector" then
                summary = string.format("peripheral=%s tick=%ds",
                    tostring(all.collector.peripheral or "auto"),
                    tonumber(all.collector.tick_seconds) or 1)
            elseif name == "core" then
                summary = string.format("broadcast=%dms persist=%dms",
                    tonumber(all.core.broadcast_interval_ms) or 1000,
                    tonumber(all.core.persist_interval_ms) or 30000)
            elseif name == "panel" then
                summary = string.format("monitor=%s rate=/%s",
                    tostring(all.panel.monitor or "auto"),
                    tostring(all.panel.rate_unit or "t"))
            end
            items[#items + 1] = { label = name, tag = summary, component = name }
        end
        items[#items + 1] = { label = "[save and exit]",    save = true }
        items[#items + 1] = { label = "[discard and exit]", discard = true }

        local sel = arrow_menu(items, {
            title    = "Energy Dashboard Configure",
            subtitle = "installed: " .. table.concat(comps, ", "),
        })
        if not sel then return end
        if sel.discard then
            clear_screen(); set_fg(colors.lightGray); print("discarded."); set_fg(colors.white)
            return
        end
        if sel.save then
            local ok, err = config.save_all(all)
            clear_screen()
            if ok then
                set_fg(colors.lime); print("saved to " .. config.FILE)
                set_fg(colors.lightGray); print("Restart the component(s) to apply.")
            else
                set_fg(colors.red); print("save failed: " .. tostring(err))
            end
            set_fg(colors.white)
            return
        end
        if sel.component == "collector" then edit_collector(all.collector)
        elseif sel.component == "core"  then edit_core(all.core)
        elseif sel.component == "panel" then edit_panel(all.panel)
        end
    end
end

local ok, err = pcall(main)
set_bg(colors.black); set_fg(colors.white)
if not ok then print("configure crashed: " .. tostring(err)) end
