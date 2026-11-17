-- Turns the flags the client gives for one quest into a single state we can sort and
-- show. Pure: give it a quest config (or a fake one in tests).
--
-- States:
--   "finished"     done; its items aren't marked any more
--   "in_progress"  started, not finished
--   "not_started"  not started, and the player could start it now
--   "cant_start"   not started, and some requirement isn't met yet
--   "unknown"      the client didn't give a usable answer; counts as unfinished, so
--                  its items stay marked (an extra icon is safer than a missing one)
--   "missing"      the client doesn't know this quest (or retired it). Only guards
--                  against client updates; such a quest is dropped from marking

local QuestState = {}

-- The order quests are listed in a tooltip (most urgent first). Only unfinished
-- states are listed, so this also says which states are marked.
QuestState.ORDER = {
    in_progress = 1,
    not_started = 2,
    cant_start = 3,
    unknown = 4,
}

-- quest: a QuestType from config.Quest.FromID, or nil if the lookup failed.
function QuestState.fromConfig(quest)
    if quest == nil then
        return "missing"
    end

    -- Every field read can throw on a broken proxy, so read them all in one pcall.
    local ok, deprecated, finished, started, canStart = pcall(function()
        return quest.deprecated, quest.hasFinishedQuest, quest.hasStartedQuest, quest.canStartQuest
    end)

    if not ok then
        return "unknown"
    end

    -- A deprecated config's flags aren't kept up to date, so don't trust them.
    if deprecated == true then
        return "missing"
    end

    if type(finished) ~= "boolean" or type(started) ~= "boolean" then
        return "unknown"
    end

    if finished then
        return "finished"
    end

    -- hasStartedQuest is also true for finished quests, so it only means "in
    -- progress" once we know it isn't finished.
    if started then
        return "in_progress"
    end

    -- If canStartQuest is unreadable we still know the quest isn't started.
    if canStart == false then
        return "cant_start"
    end

    return "not_started"
end

-- True for the states whose items should be marked.
function QuestState.isUnfinished(state)
    return QuestState.ORDER[state] ~= nil
end

return QuestState
