-- RequiredItems on the real data: which items are marked, and tooltip text for the
-- M1 sample quests. Quest states come from a plain table instead of the client.

local check = require("tests/support/check")

local spec = {}

local NAMES = {
    [1436] = "Rune essence", [1437] = "Rune essence", [7936] = "Pure essence", [7937] = "Pure essence",
    [554] = "Fire rune", [1387] = "Staff of fire", [1388] = "Staff of fire",
    [995] = "Coins", [54830] = "Coins", [1767] = "Yellow dye", [1793] = "Onion", [1768] = "Yellow dye",
    [101] = "Irit potion (unfinished)", [102] = "Irit potion (unfinished)", [259] = "Clean irit",
    [260] = "Clean irit", [227] = "Vial of water", [228] = "Vial of water",
}

local function nameOf(itemId)
    return NAMES[itemId]
end

-- states: { [questId] = state }. Quests not listed are not started.
local function build(states, filter)
    local data = require("src/game/quest_data").build(dofile("data/quest_items.lua"))

    return require("src/game/required_items").new(data, function(questId)
        return states[questId] or "not_started"
    end, filter or { quest = true, miniquest = true })
end

spec["Priest in Peril: essence shows its own amount, not the other choice (CUJ 1)"] = function()
    local required = build({})

    check.truthy(required:isMarked(1436), "rune essence")
    check.truthy(required:isMarked(7937), "noted pure essence")

    local text = required:tooltipText(1436, nameOf)

    check.contains(text, "<col=c8c8c8>Priest in Peril</col><col=ebd38a> x50</col>")
    check.falsy(text:find("Pure essence", 1, true), "the other choice isn't named")
    check.contains(required:tooltipText(7936, nameOf), "<col=c8c8c8>Priest in Peril</col><col=ebd38a> x25</col>")
    check.falsy(text:find("\n", 1, true), "native text breaks lines with <br>, not a newline")
    check.falsy(text:find("not started", 1, true), "no quest states in the tooltip")
end

spec["a finished quest drops out of marking and tooltips (CUJ 4)"] = function()
    local required = build({ [276] = "finished" })

    -- Pure essence is only needed by Priest in Peril in the data.
    check.falsy(required:tooltipText(7936, nameOf) and required:tooltipText(7936, nameOf):find("Priest in Peril", 1, true))
end

spec["common items are never marked and have no tooltip"] = function()
    local required = build({})

    for _, itemId in ipairs({ 995, 54830, 2347, 590, 554, 563 }) do
        check.falsy(required:isMarked(itemId), "common item " .. itemId)
        check.equal(required:tooltipText(itemId, nameOf), nil, "tooltip for common item " .. itemId)
    end
end

spec["a choice with a common item marks the rest (Glorious Memories)"] = function()
    -- Glorious Memories: earth runes or a staff of earth.
    local required = build({})

    check.truthy(required:isMarked(1385))
    check.falsy(required:isMarked(557), "earth runes are common")

    local text = required:tooltipText(1385, nameOf)

    check.contains(text, "Glorious Memories</col>")
    check.falsy(text:find("rune", 1, true), "the other choice isn't named")
end

spec["Goblin Diplomacy: onions show the coins that go with them, coins stay unmarked"] = function()
    local required = build({ [137] = "in_progress" })

    -- Yellow dye, or 2 onions and 5 coins.
    check.falsy(required:tooltipText(1767, nameOf):find("Coins", 1, true), "the dye is a choice of its own")
    local _, kinds = required:tooltipText(1793, nameOf)
    check.equal(kinds[1], "quest")
    check.equal(kinds[2], "detail", "the + Coins line gets no quest sprite")
    check.contains(required:tooltipText(1793, nameOf), "<col=c8c8c8>Goblin Diplomacy</col><col=ebd38a> x2</col><br><col=ebd38a>+ Coins x5</col>")
    check.falsy(required:isMarked(995))
end

spec["an alternative of several items reads as a combination (A Guild of Our Own)"] = function()
    local required = build({})
    local text = required:tooltipText(259, nameOf)

    check.contains(text, "<col=c8c8c8>A Guild of Our Own (miniquest)</col><br><col=ebd38a>+ Vial of water</col>")
    check.falsy(text:find("Irit potion", 1, true), "the other choice isn't named")
end

spec["a quest needing an item twice shows one added-up amount (Hunt for Red Raktuber)"] = function()
    -- "1 plank" to make the clockwork suit, and "4 planks".
    local text = build({}):tooltipText(960, nameOf)

    check.contains(text, "<col=c8c8c8>Hunt for Red Raktuber</col><col=ebd38a> x5</col>")
    check.falsy(text:find("Hunt for Red Raktuber</col><col=ebd38a> x4", 1, true), "not listed per need")
end

spec["containers are common: never marked (vial of water, bucket)"] = function()
    local required = build({})

    for _, itemId in ipairs({ 227, 229, 1925, 1929, 1935, 1937, 1923, 1921, 1931 }) do
        check.falsy(required:isMarked(itemId), "container " .. itemId)
    end
end

spec["Cook's Assistant and all of Dimension of Disaster are left out of the data"] = function()
    local data = require("src/game/quest_data").build(dofile("data/quest_items.lua"))

    for _, quest in ipairs(data.quests) do
        check.falsy(quest.name == "Cook's Assistant", "Cook's Assistant has no items in the data")
        check.falsy(quest.name:find("Dimension of Disaster", 1, true), "skipped on purpose: " .. quest.name)
    end
end

spec["amounts per quest, plain lines (Murder on the Border, The Fremennik Isles)"] = function()
    local required = build({ [490] = "cant_start" })

    check.contains(required:tooltipText(54860, nameOf), "<col=c8c8c8>Murder on the Border</col><col=ebd38a> x144</col>")
    check.contains(required:tooltipText(438, nameOf), "<col=c8c8c8>The Fremennik Isles</col><col=ebd38a> x8</col>")
end

spec["the filter hides a miniquest's items (Doric's Task V)"] = function()
    local on = build({})
    local off = build({}, { quest = true, miniquest = false })

    check.contains(on:tooltipText(45526, nameOf), "Doric's Task V (miniquest)</col><col=ebd38a> x")
    check.falsy(off:isMarked(45526))
end

spec["quests in progress are listed first, and long lists are cut"] = function()
    -- Rope (954) is needed by many quests; give some of them different states.
    local data = require("src/game/quest_data").build(dofile("data/quest_items.lua"))
    local states, ids = {}, {}

    for _, line in ipairs(data.byItem[954]) do
        ids[#ids + 1] = line.quest.id
    end

    -- The last quest alphabetically, so only the in-progress rule can put it first.
    local last = data.byItem[954][1].quest

    for _, line in ipairs(data.byItem[954]) do
        if line.quest.name > last.name then
            last = line.quest
        end
    end

    states[last.id] = "in_progress"

    local text = build(states):tooltipText(954, nameOf)

    local first = "<col=c8c8c8>" .. last.name .. "</col>"

    check.equal(text:sub(1, #first), first, "in progress first")
    check.contains(text, "more</col>", "long list is cut")
end

spec["an item from an 'any of a kind' page names the group"] = function()
    local required = build({})

    -- Lit torch (594) counts as a light source; a bronze hatchet (1351) and its noted
    -- form (1352) as any hatchet.
    local torch, kinds = required:tooltipText(594, nameOf)

    check.contains(torch, "<br><col=ebd38a>Any light source</col>")
    check.equal(kinds[2], "detail", "the group line gets no quest sprite")
    check.contains(required:tooltipText(1351, nameOf), "<col=ebd38a>Any hatchet</col>")
    check.contains(required:tooltipText(1352, nameOf), "<col=ebd38a>Any hatchet</col>")

    -- A plainly named item doesn't.
    check.falsy(required:tooltipText(1436, nameOf):find("Any ", 1, true))
end

return spec
