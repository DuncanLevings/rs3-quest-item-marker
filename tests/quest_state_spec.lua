-- QuestState: client flags to one state.

local check = require("tests/support/check")

local spec = {}

local function state(flags)
    return require("src/game/quest_state").fromConfig(flags)
end

spec["flags map to states"] = function()
    check.equal(state(nil), "missing")
    check.equal(state({ deprecated = true, hasStartedQuest = false, hasFinishedQuest = false }), "missing")

    -- M0: hasStartedQuest is also true once finished.
    check.equal(state({ hasStartedQuest = true, hasFinishedQuest = true }), "finished")
    check.equal(state({ hasStartedQuest = true, hasFinishedQuest = false }), "in_progress")
    check.equal(state({ hasStartedQuest = false, hasFinishedQuest = false, canStartQuest = true }), "not_started")
    check.equal(state({ hasStartedQuest = false, hasFinishedQuest = false, canStartQuest = false }), "cant_start")
end

spec["unreadable flags are unknown, which still counts as unfinished"] = function()
    local QuestState = require("src/game/quest_state")
    local broken = setmetatable({}, {
        __index = function()
            error("proxy gone")
        end,
    })

    check.equal(QuestState.fromConfig(broken), "unknown")
    check.equal(QuestState.fromConfig({ hasStartedQuest = 1, hasFinishedQuest = false }), "unknown")
    check.truthy(QuestState.isUnfinished("unknown"))
    check.falsy(QuestState.isUnfinished("finished"))
    check.falsy(QuestState.isUnfinished("missing"))
end

return spec
