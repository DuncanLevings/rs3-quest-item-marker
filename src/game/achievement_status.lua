-- Answers "is this achievement complete?" from config.Achievement, caching each answer
-- until the next clear(). main.lua clears it when a screen opens (so a just-finished
-- achievement shows on the next bank or shop visit) and at logout (another character
-- may log in next).
--
-- Owns the cache only.

local AchievementStatus = {}

-- progress values: COMPLETE (-2), and GRACE (-3), which also counts as done.
local DONE = { [-2] = true, [-3] = true }

function AchievementStatus.new()
    local self = {}

    -- [achievementId] = true / false. Unreadable answers aren't cached.
    local cache = {}

    -- true / false, or nil when the client can't say (logged out, unknown id).
    function self:isDone(achievementId)
        local cached = cache[achievementId]

        if cached ~= nil then
            return cached
        end

        local ok, progress = pcall(function()
            local achievement = config.Achievement.FromID(achievementId)
            return achievement and achievement.progress
        end)

        if not ok or type(progress) ~= "number" then
            return nil
        end

        local done = DONE[progress] == true
        cache[achievementId] = done

        return done
    end

    function self:clear()
        cache = {}
    end

    return self
end

return AchievementStatus
