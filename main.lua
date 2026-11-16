-- The client requires main.lua at the plugin root. All the real work lives in src/.
local shutdown = require("src/main").start()

-- The client calls this when the plugin is turned off or reloaded.
function PluginShutdown()
    shutdown()
end
