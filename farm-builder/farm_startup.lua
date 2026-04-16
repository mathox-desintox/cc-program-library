-- ============================================
-- Farm Builder Auto-Resume
-- ============================================
--
-- Install to startup/farm_resume.lua on the builder turtle.
-- On boot, checks for an in-progress build and resumes it.
-- If no progress file exists, exits silently so you can use the
-- turtle normally.
--

if not fs.exists("farm_progress") then
    return
end

if not fs.exists("farm.lua") then
    print("farm_progress found but farm.lua is missing!")
    print("Re-install the Farm Builder via the installer.")
    return
end

-- Read saved mode so we can pass the right argument
local mode = "build"
local f = fs.open("farm_progress", "r")
while true do
    local line = f.readLine()
    if not line then break end
    local k, v = line:match("^([%w_]+)=(.+)$")
    if k == "mode" then
        mode = v
        break
    end
end
f.close()

print("==========================================")
print("  Farm Builder: resuming in 5 seconds...")
print("  Mode: " .. mode)
print("  Press any key to cancel.")
print("==========================================")

local timer = os.startTimer(5)
while true do
    local evt, param = os.pullEvent()
    if evt == "timer" and param == timer then
        break
    elseif evt == "key" then
        print("Auto-resume cancelled.")
        return
    end
end

if mode == "accel" then
    shell.run("farm", "accel")
else
    shell.run("farm")
end
