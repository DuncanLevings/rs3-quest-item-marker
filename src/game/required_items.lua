-- Answers the two questions the marker code asks about an item ID:
--   * isMarked: does at least one unfinished quest in the player's filter need it?
--   * tooltipText: which quests need it, and how many?
--
-- Pure: it's given the quest data, a function that returns a quest's cached state,
-- the filter, and (for tooltip text) a function that names an item. Owns nothing.
-- Common items never reach this module: QuestData leaves them out of its index.

local QuestState = require("src/game/quest_state")

local RequiredItems = {}

-- Longer quest lists end with "+N more".
local MAX_QUESTS = 5

-- Native text markup: <br> is a line break ("\n" draws as a box), <col> a colour.
-- Quest names light grey, the item part (amounts, groups, partners) yellow so what to
-- bring stands out, "+N more" darker grey so it never reads as another quest.
RequiredItems.LINE_BREAK = "<br>"
local QUEST_COLOUR = "c8c8c8"
local ITEM_COLOUR = "ebd38a"
local MORE_COLOUR = "8c8c8c"

local function colour(hex, text)
    return "<col=" .. hex .. ">" .. text .. "</col>"
end

-- questData: QuestData.build's result. getState(questId) -> state or nil.
-- filter: { quest = true, miniquest = true }. A type missing from it isn't marked.
function RequiredItems.new(questData, getState, filter)
    local self = {}

    -- Swaps in a new filter after the player changes it. We keep our own copy so the
    -- caller can't change it behind our back later.
    function self:setFilter(newFilter)
        local copy = {}

        for category, included in pairs(newFilter) do
            copy[category] = included
        end

        filter = copy
    end

    -- Should a line from this quest count right now?
    local function counts(quest)
        if not filter[quest.category] then
            return false
        end

        return QuestState.isUnfinished(getState(quest.id))
    end

    function self:isMarked(itemId)
        local lines = questData.byItem[itemId]

        if not lines then
            return false
        end

        for _, line in ipairs(lines) do
            if counts(line.quest) then
                return true
            end
        end

        return false
    end

    -- " x50", or "" for a single item (or no amount given): "x1" is just noise. Text
    -- amounts like "4-6" always show.
    local function amountText(amount)
        if amount == nil or amount == 1 then
            return ""
        end

        return " x" .. tostring(amount)
    end

    -- The other items that must come with `itemId` for this need: in "irit potion (unf),
    -- or clean irit and a vial of water", a clean irit comes with a vial of water.
    -- Names once each (noted and other versions share a name), with amounts. Empty
    -- when the item is a choice on its own, or the need has no combinations.
    local function partnersOf(itemId, need, nameOf)
        local partners = {}

        if not need.sets then
            return partners
        end

        for _, set in ipairs(need.sets) do
            local inSet = false

            for _, setItem in ipairs(set) do
                if setItem == itemId then
                    inSet = true
                    break
                end
            end

            if inSet then
                local ownName = nameOf(itemId)
                local seen = { [ownName or false] = true }

                for _, setItem in ipairs(set) do
                    local name = nameOf(setItem) or ("item #" .. setItem)

                    if not seen[name] then
                        seen[name] = true
                        partners[#partners + 1] = name .. amountText(need.amounts[setItem])
                    end
                end

                return partners
            end
        end

        return partners
    end

    -- The tooltip text for one item, or nil if it isn't marked. One line per quest
    -- with how many of THIS item it needs, plus optional detail lines: the group it
    -- counts for ("Any light source") and items that must come with it ("+ Vial of
    -- water"). Other alternatives aren't listed, so hovering rune essence doesn't
    -- mention pure essence. nameOf(itemId) names an item (the caller caches it).
    -- Returns the text and what each line is ({ "quest", "detail", ..., "more" }) so
    -- the tooltip knows which lines get a quest sprite.
    function self:tooltipText(itemId, nameOf)
        local lines = questData.byItem[itemId]

        if not lines then
            return nil
        end

        -- Gather per quest: the amounts of this item across its needs, its groups and
        -- its partner items. A quest that lists the item more than once gets one
        -- total, since that's how many the player has to bring (1 plank + 4 planks
        -- reads "x5"). A missing amount counts as one.
        local byQuest, order = {}, {}

        for _, line in ipairs(lines) do
            local quest, need = line.quest, line.need

            if counts(quest) then
                local entry = byQuest[quest]

                if entry == nil then
                    entry = { amounts = {}, partners = {}, seenPartner = {}, groups = {}, seenGroup = {} }
                    byQuest[quest] = entry
                    order[#order + 1] = quest
                end

                entry.amounts[#entry.amounts + 1] = need.amounts[itemId] or 1

                -- The item is one of an "any of a kind" group: name the group so a
                -- bronze hatchet doesn't read as "this exact hatchet".
                local group = need.groups and need.groups[itemId]

                if group and not entry.seenGroup[group] then
                    entry.seenGroup[group] = true
                    entry.groups[#entry.groups + 1] = group
                end

                for _, partner in ipairs(partnersOf(itemId, need, nameOf)) do
                    if not entry.seenPartner[partner] then
                        entry.seenPartner[partner] = true
                        entry.partners[#entry.partners + 1] = partner
                    end
                end
            end
        end

        local entries = {}

        local function add(quest, amount, partners, groups)
            local text = colour(QUEST_COLOUR, quest.name)
            local shown = amountText(amount)
            local kinds = { "quest" }

            if shown ~= "" then
                text = text .. colour(ITEM_COLOUR, shown)
            end

            if #groups > 0 then
                text = text .. RequiredItems.LINE_BREAK .. colour(ITEM_COLOUR, table.concat(groups, ", "))
                kinds[#kinds + 1] = "detail"
            end

            if #partners > 0 then
                text = text .. RequiredItems.LINE_BREAK .. colour(ITEM_COLOUR, "+ " .. table.concat(partners, " + "))
                kinds[#kinds + 1] = "detail"
            end

            entries[#entries + 1] = {
                text = text,
                kinds = kinds,
                order = QuestState.ORDER[getState(quest.id)],
                name = quest.name,
            }
        end

        for _, quest in ipairs(order) do
            local entry = byQuest[quest]
            local total = 0

            for _, amount in ipairs(entry.amounts) do
                total = type(amount) == "number" and total and total + amount or nil
            end

            if total then
                add(quest, total, entry.partners, entry.groups)
            else
                -- A text amount ("4-6") can't be added: one line per distinct amount.
                local shown = {}

                for _, amount in ipairs(entry.amounts) do
                    if not shown[amount] then
                        shown[amount] = true
                        add(quest, amount, entry.partners, entry.groups)
                    end
                end
            end
        end

        if #entries == 0 then
            return nil
        end

        -- Quests in progress first (the ones the player is working on), then A-Z.
        table.sort(entries, function(a, b)
            if a.order ~= b.order then
                return a.order < b.order
            end

            if a.name ~= b.name then
                return a.name < b.name
            end

            return a.text < b.text
        end)

        local out, kinds = {}, {}

        for index = 1, math.min(#entries, MAX_QUESTS) do
            out[#out + 1] = entries[index].text

            for _, kind in ipairs(entries[index].kinds) do
                kinds[#kinds + 1] = kind
            end
        end

        if #entries > MAX_QUESTS then
            out[#out + 1] = colour(MORE_COLOUR, "+" .. (#entries - MAX_QUESTS) .. " more")
            kinds[#kinds + 1] = "more"
        end

        return table.concat(out, RequiredItems.LINE_BREAK), kinds
    end

    return self
end

return RequiredItems
