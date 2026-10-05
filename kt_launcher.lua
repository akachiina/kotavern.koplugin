-- Singleton launcher for the KOTavern App instance.
-- Ensures only one UI session exists at a time.

local App = require("kt_app")

local Launcher = {}
local instance = nil

function Launcher.open(plugin)
    if not instance then
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
