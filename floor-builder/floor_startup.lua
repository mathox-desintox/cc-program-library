-- ============================================
-- Floor Builder Auto-Resume
-- ============================================
--
-- Install to startup/floor_resume.lua on the builder turtle.
-- On boot, checks for an in-progress build and resumes it.
-- If no progress file exists, exits silently so you can use the
-- turtle normally.
--

if not fs.exists("floor_progress") then
    -- No build in progress — don't auto-run
    return
end

if not fs.exists("floor.lua") then
    print("floor_progress found but floor.lua is missing!")
    print("Re-install the Floor Builder via the installer.")
    return
end

-- Brief countdown so the user can cancel if needed
print("==========================================")
print("  Floor Builder: resuming in 5 seconds...")
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

-- Run with no args so main() uses the saved mode from floor_progress
shell.run("floor")
