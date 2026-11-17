-- QuestData: the schema gate, the index, and that common items never get indexed.

local check = require("tests/support/check")

local spec = {}

local function load()
    return require("src/game/quest_data")
end

spec["the bundled data loads with no broken entries"] = function()
    local data = load().build(dofile("data/quest_items.lua"))

    check.equal(data.status, "ok")
    check.equal(data.counts.quests, 227, "quests")
    check.equal(data.counts.badQuests, 0, "broken quests")
    check.equal(data.counts.badNeeds, 0, "broken needs")
end

spec["an unknown schema is refused as a whole (CUJ 7)"] = function()
    local raw = dofile("data/quest_items.lua")
    raw.schema = 2

    local data = load().build(raw)

    check.equal(data.status, "incompatible")
    check.contains(data.message, "schema 2")
end

spec["common items are left out of the index"] = function()
    local raw = dofile("data/quest_items.lua")
    local data = load().build(raw)

    for itemId in pairs(raw.common) do
        check.equal(data.byItem[itemId], nil, "common item " .. itemId .. " indexed")
    end
end

spec["a broken need is dropped without losing its quest"] = function()
    local data = load().build({
        schema = 1,
        categories = { "quest" },
        common = {},
        quests = {
            { id = 5, name = "Test", category = "quest", needs = { { items = { 10 } }, { items = { "x" } } } },
            { id = 6, name = "No needs", category = "quest" },
            { id = 7, name = "A tutorial", category = "tutorial", needs = { { items = { 11 } } } },
        },
    })

    check.equal(data.counts.quests, 1)
    check.equal(data.counts.badNeeds, 1)
    check.equal(data.counts.badQuests, 1, "quest without needs")
    check.equal(data.counts.otherCategory, 1, "tutorial skipped, not broken")
    check.equal(data.byItem[11], nil, "tutorial items never indexed")
    check.truthy(data.byItem[10])
end

spec["sets are kept when they fit the need, and dropped (not the need) when they don't"] = function()
    local data = load().build({
        schema = 1,
        categories = { "quest" },
        common = {},
        quests = {
            { id = 5, name = "Good", category = "quest", needs = {
                { items = { 1, 2, 3 }, anyOf = true, sets = { { 1 }, { 2, 3 } } },
            } },
            { id = 6, name = "Bad", category = "quest", needs = {
                { items = { 4, 5 }, anyOf = true, sets = { { 4 }, { 99 } } },
            } },
        },
    })

    check.equal(data.counts.badNeeds, 0)
    check.equal(#data.questById[5].needs[1].sets, 2)
    check.equal(data.questById[6].needs[1].sets, nil, "a set naming an item the need lacks")
    check.truthy(data.byItem[4], "the need itself survives")
end

spec["group labels are kept when they fit the need, and dropped (not the need) when they don't"] = function()
    local data = load().build({
        schema = 1,
        categories = { "quest" },
        common = {},
        quests = {
            { id = 5, name = "Good", category = "quest", needs = {
                { items = { 1, 2 }, anyOf = true, groups = { [1] = "Any hatchet", [2] = "Any hatchet" } },
            } },
            { id = 6, name = "Bad", category = "quest", needs = {
                { items = { 4 }, groups = { [99] = "Any hatchet" } },
                { items = { 7 }, groups = { [7] = 3 } },
            } },
        },
    })

    check.equal(data.counts.badNeeds, 0)
    check.equal(data.questById[5].needs[1].groups[2], "Any hatchet")
    check.equal(data.questById[6].needs[1].groups, nil, "a label for an item the need lacks")
    check.equal(data.questById[6].needs[2].groups, nil, "a label that isn't text")
    check.truthy(data.byItem[4], "the need itself survives")
end

return spec
