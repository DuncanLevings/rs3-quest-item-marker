-- Decides which marker an item gets, in priority order:
--   "required"  an unfinished quest in the filter needs it (RequiredItems)
--   "keep"      used for achievements after a finished quest, until every one of
--               them is complete (post-quest data, setting on)
--   "done"      only used in its quests (or a keep item whose achievements are all
--               complete), and all of those quests are finished (setting on)
-- and builds the tooltip text for that marker.
--
-- Pure: given RequiredItems, the post-quest data, and functions returning a quest's
-- cached state and whether an achievement is complete. Owns nothing.

local RequiredItems = require("src/game/required_items")

local ItemMarks = {}

-- Sprite tints (0xRRGGBBAA) per marker kind; "required" keeps the icon's own colours.
ItemMarks.TINTS = {
    keep = 0x40E040FF,
    done = 0xFF4040FF,
}

-- Muted green for the keep achievements and "(done)": status text, softer than the
-- bright green icon tint.
local GREEN_TEXT = "8fbc8f"
local QUEST_COLOUR = "c8c8c8"
local MORE_COLOUR = "8c8c8c"

-- Longer quest lists end with "+N more".
local MAX_QUESTS = 5

local function colour(hex, text)
    return "<col=" .. hex .. ">" .. text .. "</col>"
end

-- required: RequiredItems. postData: PostQuestData.build's result (or nil).
-- getState(questId) -> quest state. achievementDone(id) -> true / false / nil.
-- options: { filter, keep = bool, done = bool }.
function ItemMarks.new(required, postData, getState, achievementDone, options)
    local self = {}

    local filter = options.filter or {}
    local shown = { keep = options.keep ~= false, done = options.done ~= false }
    local keepItems = postData and postData.keep or {}
    local keepUntil = postData and postData.keepUntil or {}
    local achievementNames = postData and postData.achievements or {}
    local doneItems = postData and postData.done or {}

    function self:setFilter(newFilter)
        local copy = {}

        for category, included in pairs(newFilter) do
            copy[category] = included
        end

        filter = copy
        required:setFilter(copy)
    end

    -- kind: "keep" or "done".
    function self:setShown(kind, on)
        shown[kind] = on
    end

    local function finished(quest)
        return getState(quest.id) == "finished"
    end

    -- `quests` if every one is finished and at least one is in the filter, else nil.
    local function allFinished(quests)
        local included = false

        for _, quest in ipairs(quests) do
            if not finished(quest) then
                return nil
            end

            included = included or filter[quest.category] == true
        end

        return included and quests or nil
    end

    -- True once every achievement a keep item is used for is complete. Unknown counts
    -- as not complete, so the item stays kept.
    local function usedUp(itemId)
        local ids = keepUntil[itemId]

        if not ids then
            return false
        end

        for _, achievementId in ipairs(ids) do
            if achievementDone(achievementId) ~= true then
                return false
            end
        end

        return true
    end

    -- True when one of the item's quests in the filter is finished and it still has
    -- achievements to do. Runs for every slot on every refresh, so it builds nothing.
    local function isKept(itemId)
        local quests = shown.keep and keepItems[itemId]

        if not quests then
            return false
        end

        local anyFinished = false

        for _, quest in ipairs(quests) do
            if filter[quest.category] and finished(quest) then
                anyFinished = true
                break
            end
        end

        return anyFinished and not usedUp(itemId)
    end

    -- The quests that make an item "done", or nil.
    local function doneQuests(itemId)
        if not shown.done then
            return nil
        end

        if doneItems[itemId] then
            return allFinished(doneItems[itemId])
        end

        if keepItems[itemId] and usedUp(itemId) then
            return allFinished(keepItems[itemId])
        end

        return nil
    end

    function self:kindOf(itemId)
        if required:isMarked(itemId) then
            return "required"
        end

        if isKept(itemId) then
            return "keep"
        end

        if doneQuests(itemId) then
            return "done"
        end

        return nil
    end

    -- One line per name (A-Z, capped at MAX_QUESTS), each with the tinted quest icon.
    -- format(name) gives the line's text.
    local function linesText(names, format)
        table.sort(names)

        local out, kinds = {}, {}

        for index = 1, math.min(#names, MAX_QUESTS) do
            out[#out + 1] = format(names[index])
            kinds[#kinds + 1] = "quest"
        end

        if #names > MAX_QUESTS then
            out[#out + 1] = colour(MORE_COLOUR, "+" .. (#names - MAX_QUESTS) .. " more")
            kinds[#kinds + 1] = "more"
        end

        return table.concat(out, RequiredItems.LINE_BREAK), kinds
    end

    local function achievementName(achievementId)
        return achievementNames[achievementId] or ("Achievement #" .. achievementId)
    end

    local function finishedLine(name)
        return colour(QUEST_COLOUR, name .. " ") .. colour(GREEN_TEXT, "(done)")
    end

    -- The text and line kinds for an item's marker of `kind` (from kindOf).
    --   keep: the achievements still to do, in green
    --   done: its quests (or, for a used-up keep item, its achievements) + " (done)"
    function self:tooltipText(itemId, kind, nameOf)
        if kind == "required" then
            return required:tooltipText(itemId, nameOf)
        end

        local names = {}

        if kind == "keep" then
            for _, achievementId in ipairs(keepUntil[itemId] or {}) do
                if achievementDone(achievementId) ~= true then
                    names[#names + 1] = achievementName(achievementId)
                end
            end

            return linesText(names, function(name)
                return colour(GREEN_TEXT, name)
            end)
        end

        if kind == "done" then
            if doneItems[itemId] then
                for _, quest in ipairs(doneQuests(itemId) or {}) do
                    names[#names + 1] = quest.name
                end
            else
                for _, achievementId in ipairs(keepUntil[itemId] or {}) do
                    names[#names + 1] = achievementName(achievementId)
                end
            end

            return linesText(names, finishedLine)
        end

        return nil
    end

    return self
end

return ItemMarks
