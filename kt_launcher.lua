-- Singleton launcher for the KOTavern App instance.
-- Ensures only one UI session exists at a time.

local Launcher = {}
local instance = nil

function Launcher.open(plugin)
    if not instance then
        -- The app graph (23 plugin modules + the KOReader UI modules) loads
        -- here, not while KOReader boots: the plugin is only opened on demand.
        local App = require("kt_app")
        instance = App:new(plugin)
    end
    instance:show()
    return instance
end

-- Close the app and DROP the singleton.
--
-- The app instance is not a cheap thing to keep: it owns the chat caches
-- (a MuPDF document + a tall bitmap per live message) and the whole
-- session state. A Quit that only closed the view left it alive in the
-- launcher, so the memory piled up from session to session and the next
-- open started from the stale state (the frozen screen on the Kindle).
--
-- `app` (optional): close THIS app even when the launcher holds another
-- one (a detached view). Returns true when the launcher owned the app.
function Launcher.close(app)
    if instance then
        if app and instance ~= app then
            app:close()
            return false
        end
        local target = instance
        instance = nil
        target:close()
        return true
    end
    if app then
        app:close()
    end
    return false
end

return Launcher
