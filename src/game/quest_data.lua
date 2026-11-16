-- Loads the generated quest data (data/quest_items.lua), checks it, and builds the
-- lookup the rest of the plugin uses: "which quest lines need this item ID?".
--
-- Pure: no client calls, owns nothing. The file's shape is the data contract in
-- docs/designs/quest_item_marker.md, Technical Plan §1. tools/build_quest_items.py is
-- the only thing that writes it.

local QuestData = {}

-- The only data layout this plugin understands. A file with any other `schema` is
-- refused as a whole: guessing at a new layout could put icons on the wrong items.
QuestData.SCHEMA = 1

-- The quest types the plugin marks and the filter offers. Tutorial isn't one of them
-- (author, 2026-11-16): the data has no tutorial quests, and tutorial items are
-- handed out as you go. The generated file still lists "tutorial" in `categories`;
-- any quest in a type not listed here is skipped and counted, never marked.
QuestData.CATEGORIES = { "quest", "miniquest" }

local function isPositiveInteger(value)
    return math.type(value) == "integer" and value >= 0
end

-- `sets` on an "any one of" need: the alternatives when some of them are several items
-- together, eg { { 101 }, { 259, 227 } } for "irit potion (unf), or clean irit and vial
-- of water". Each id must be one of the need's items. Only used for tooltip wording,
-- so a broken value is dropped (the need shows as a flat choice) rather than the need.
local function checkSets(sets, items)
    if type(sets) ~= "table" or #sets < 2 then
        return nil
    end

    local known = {}

    for _, itemId in ipairs(items) do
        known[itemId] = true
    end

    for _, set in ipairs(sets) do
        if type(set) ~= "table" or #set == 0 then
            return nil
        end

        for _, itemId in ipairs(set) do
            if not known[itemId] then
                return nil
            end
        end
    end

    return sets
end

-- One `needs` entry: { items = { ids }, amounts = { [id] = n or "4-6" }?, anyOf = true?,
-- sets = { { ids }, ... }? }. Returns the cleaned entry, or nil if it's broken.
local function checkNeed(need)
    if type(need) ~= "table" or type(need.items) ~= "table" or #need.items == 0 then
        return nil
    end

    for _, itemId in ipairs(need.items) do
        if not isPositiveInteger(itemId) then
            return nil
        end
    end

    if need.amounts ~= nil and type(need.amounts) ~= "table" then
        return nil
    end

    return {
        items = need.items,
        amounts = need.amounts or {},
        anyOf = need.anyOf == true,
        sets = need.anyOf == true and need.sets ~= nil and checkSets(need.sets, need.items) or nil,
    }
end

-- One quest. Returns the cleaned quest, or nil if it's broken. A broken need inside
-- an otherwise fine quest is dropped on its own and counted.
local function checkQuest(quest, knownCategories, counts)
    if type(quest) ~= "table" or not isPositiveInteger(quest.id) or type(quest.name) ~= "string" then
        return nil
    end

    if not knownCategories[quest.category] then
        return nil
    end

    if type(quest.needs) ~= "table" then
        return nil
    end

    local needs = {}

    for _, need in ipairs(quest.needs) do
        local checked = checkNeed(need)

        if checked then
            needs[#needs + 1] = checked
        else
            counts.badNeeds = counts.badNeeds + 1
        end
    end

    return {
        id = quest.id,
        name = quest.name,
        category = quest.category,
        needs = needs,
    }
end

-- Takes the table data/quest_items.lua returned and gives back either
--   { status = "ok", quests, questById, byItem, common, categories, snapshot,
--     coverage, attribution, counts }
-- or
--   { status = "incompatible", message = "..." }
--
-- byItem[itemId] is a list of { quest = <quest>, need = <need> }: every quest line
-- that lists this item. Common items (coins, hammer, runes...) are left out of byItem
-- on purpose, because they're never marked: no icon, no tooltip (author, 2026-11-16).
function QuestData.build(raw)
    if type(raw) ~= "table" then
        return { status = "incompatible", message = "The quest data file didn't load." }
    end

    if raw.schema ~= QuestData.SCHEMA then
        return {
            status = "incompatible",
            message = "Quest data schema " .. tostring(raw.schema) .. " isn't supported (expected "
                .. QuestData.SCHEMA .. ").",
        }
    end

    if type(raw.quests) ~= "table" or type(raw.categories) ~= "table" or type(raw.common) ~= "table" then
        return { status = "incompatible", message = "The quest data file is missing a section." }
    end

    -- The types we mark. The filter is saved by these names, so they're part of the
    -- storage contract too.
    local knownCategories = {}

    for _, name in ipairs(QuestData.CATEGORIES) do
        knownCategories[name] = true
    end

    local counts = { quests = 0, badQuests = 0, badNeeds = 0, items = 0, otherCategory = 0 }
    local quests, questById, byItem = {}, {}, {}

    for _, rawQuest in ipairs(raw.quests) do
        -- A quest of a type we don't mark (tutorial) isn't broken, just not ours.
        local otherType = type(rawQuest) == "table" and type(rawQuest.category) == "string"
            and not knownCategories[rawQuest.category]
        local quest = nil

        if otherType then
            counts.otherCategory = counts.otherCategory + 1
        else
            quest = checkQuest(rawQuest, knownCategories, counts)
        end

        -- A second quest with the same id would make statuses ambiguous; keep the first.
        if quest and not questById[quest.id] then
            quests[#quests + 1] = quest
            questById[quest.id] = quest
            counts.quests = counts.quests + 1

            for _, need in ipairs(quest.needs) do
                for _, itemId in ipairs(need.items) do
                    if not raw.common[itemId] then
                        local lines = byItem[itemId]

                        if not lines then
                            lines = {}
                            byItem[itemId] = lines
                            counts.items = counts.items + 1
                        end

                        lines[#lines + 1] = { quest = quest, need = need }
                    end
                end
            end
        elseif not otherType then
            counts.badQuests = counts.badQuests + 1
        end
    end

    return {
        status = "ok",
        quests = quests,
        questById = questById,
        byItem = byItem,
        common = raw.common,
        categories = QuestData.CATEGORIES,
        snapshot = type(raw.snapshot) == "string" and raw.snapshot or "unknown",
        coverage = type(raw.coverage) == "table" and raw.coverage or {},
        attribution = type(raw.attribution) == "string" and raw.attribution or "RuneScape Wiki",
        counts = counts,
    }
end

-- Loads and builds the bundled file. A file that throws while loading counts as
-- incompatible, so the plugin shows a message instead of failing to start.
function QuestData.load()
    local ok, raw = pcall(function()
        return require("data/quest_items")
    end)

    if not ok then
        return { status = "incompatible", message = "The quest data file failed to load: " .. tostring(raw) }
    end

    return QuestData.build(raw)
end

return QuestData
