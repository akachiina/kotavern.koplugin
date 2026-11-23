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

function Launcher.close()
    if instance then
        instance:close()
        instance = nil
    end
end

return Launcher
