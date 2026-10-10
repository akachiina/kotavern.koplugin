local source = debug.getinfo(1, "S").source or ""
-- Match the dirname of this file whatever it is named (survives renames;
-- keep module files kt_-prefixed so they never collide with other plugins').
local plugin_dir = source:match("^@(.+)/[^/]+%.lua$") or "plugins/kotavern.koplugin"

-- require() paths are cwd-relative on device ("plugins/kotavern.koplugin/..."),
-- but crengine only accepts absolute font paths: a relative one makes
-- cre.registerFont fail at every boot ("failed to register crengine font").
if plugin_dir:sub(1, 1) ~= "/" then
    plugin_dir = require("ffi/util").realpath(plugin_dir) or plugin_dir
end

return {
    PLUGIN_DIR = plugin_dir,
    ASSET_DIR = plugin_dir .. "/assets",
    DATA_DIR = nil, -- resolved at runtime via storage

    VERSION = "0.1.1",

    DAEMON_UNAVAILABLE_MESSAGE = "Cannot connect to API. Check your connection settings.",
}
