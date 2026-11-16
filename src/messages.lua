-- Short messages for the player ("Markers hidden", "Couldn't read Backpack").
--
-- Chat.AddMessage needs the optional chatAccess permission. If the player hasn't
-- granted it, the message only goes to the console log; the settings window's status
-- lines still show every problem, so nothing is lost.
--
-- Owns the "already said" flags, so a problem is announced once when it starts, not
-- on every check while it lasts.

local Log = require("src/log")

local Messages = {}

function Messages.new()
    local self = {
        -- { [key] = true } for problems we've already told the player about.
        said = {},
    }

    -- True when the player let us post to their chat box.
    local function canChat()
        local ok, allowed = pcall(function()
            return Plugin.HasPermission(PluginPermissions.chatAccess)
        end)

        return ok and allowed == true
    end

    -- Posts one line to the local chat box (only this player sees it), and always to
    -- the console log too.
    function self:show(text)
        Log.write(text)

        if not canChat() then
            return
        end

        local ok, problem = pcall(function()
            Chat.AddMessage("Quest Item Marker: " .. text)
        end)

        if not ok then
            Log.write("couldn't post to chat:", problem)
        end
    end

    -- Shows text only the first time this key comes up. Call clear(key) once the
    -- problem is over, so it's announced again if it comes back.
    function self:once(key, text)
        if self.said[key] then
            return
        end

        self.said[key] = true
        self:show(text)
    end

    function self:clear(key)
        self.said[key] = nil
    end

    return self
end

return Messages
