-- ItemMarks and PostQuestData on small hand-made data: marker priority, the "all quests
-- finished" rule, achievements ending a keep, the filter and the two settings.

local check = require("tests/support/check")
local ItemMarks = require("src/game/item_marks")
local PostQuestData = require("src/game/post_quest_data")

local spec = {}

local DATA = {
    schema = 1,
    quests = {
        [1] = { name = "Alpha", category = "quest" },
        [2] = { name = "Beta", category = "quest" },
        [3] = { name = "Gamma", category = "miniquest" },
    },
    achievements = { [500] = "First", [501] = "Second" },
    keep = { [10] = { 1 }, [11] = { 3 } },
    keepUntil = { [10] = { 500, 501 }, [11] = { 502 } },
    done = { [20] = { 1 }, [21] = { 1, 2 } },
}

-- states: { [questId] = state }; achievements: { [id] = true/false }; required: ids
-- the fake RequiredItems marks.
local function marks(states, achievements, options, required)
    local fakeRequired = {
        isMarked = function(_, itemId)
            return required ~= nil and required[itemId] == true
        end,
        tooltipText = function()
            return "needed", { "quest" }
        end,
        setFilter = function() end,
    }

    options = options or {}
    options.filter = options.filter or { quest = true, miniquest = true }

    return ItemMarks.new(fakeRequired, PostQuestData.build(DATA), function(questId)
        return states[questId] or "not_started"
    end, function(achievementId)
        return achievements[achievementId]
    end, options)
end

spec["done needs every one of its quests finished"] = function()
    local itemMarks = marks({ [1] = "finished" }, {})

    check.equal(itemMarks:kindOf(20), "done")
    check.equal(itemMarks:kindOf(21), nil, "Beta not finished")

    itemMarks = marks({ [1] = "finished", [2] = "finished" }, {})
    check.equal(itemMarks:kindOf(21), "done")
end

spec["keep shows after its quest until all its achievements are complete, then done"] = function()
    check.equal(marks({}, {}):kindOf(10), nil, "quest not finished")
    check.equal(marks({ [1] = "finished" }, {}):kindOf(10), "keep")
    check.equal(marks({ [1] = "finished" }, { [500] = true }):kindOf(10), "keep", "one left")
    check.equal(marks({ [1] = "finished" }, { [500] = true, [501] = true }):kindOf(10), "done")
end

spec["an unreadable achievement keeps the item"] = function()
    check.equal(marks({ [1] = "finished" }, { [500] = true, [501] = nil }):kindOf(10), "keep")
end

spec["needed for an unfinished quest wins over keep and done"] = function()
    local itemMarks = marks({ [1] = "finished" }, {}, nil, { [10] = true, [20] = true })

    check.equal(itemMarks:kindOf(10), "required")
    check.equal(itemMarks:kindOf(20), "required")
end

spec["the quest type filter and the two settings apply"] = function()
    local states = { [1] = "finished", [3] = "finished" }

    check.equal(marks(states, {}, { filter = { quest = true, miniquest = false } }):kindOf(11), nil)
    check.equal(marks(states, {}, { keep = false }):kindOf(10), nil)
    check.equal(marks(states, {}, { done = false }):kindOf(20), nil)

    local itemMarks = marks(states, {})
    itemMarks:setShown("done", false)
    check.equal(itemMarks:kindOf(20), nil, "turned off later")
end

spec["a done tooltip lists its quests, each marked (done), with no heading"] = function()
    local itemMarks = marks({ [1] = "finished", [2] = "finished" }, {})
    local text, kinds = itemMarks:tooltipText(21, "done")

    check.contains(text, "Alpha </col><col=8fbc8f>(done)")
    check.contains(text, "Beta </col><col=8fbc8f>(done)")
    check.lacks(text, "No longer needed")
    check.equal(#kinds, 2)
    check.equal(kinds[1], "quest")
end

spec["a used-up keep item's done tooltip lists its achievements as (done)"] = function()
    local itemMarks = marks({ [1] = "finished" }, { [500] = true, [501] = true })
    local text = itemMarks:tooltipText(10, "done")

    check.contains(text, "First </col><col=8fbc8f>(done)")
    check.contains(text, "Second </col><col=8fbc8f>(done)")
    check.lacks(text, "Alpha")
end

spec["a keep tooltip lists only the achievements still to do"] = function()
    local itemMarks = marks({ [1] = "finished" }, { [500] = true })
    local text, kinds = itemMarks:tooltipText(10, "keep")

    check.contains(text, "Second")
    check.lacks(text, "First", "done achievement left out")
    check.lacks(text, "Keep")
    check.lacks(text, "Alpha", "no quest line")
    check.equal(#kinds, 1)
    check.equal(kinds[1], "quest")
end

spec["broken post-quest entries are dropped, a wrong schema refused"] = function()
    local data = PostQuestData.build({
        schema = 1,
        quests = { [1] = { name = "Alpha", category = "quest" } },
        keep = { [10] = { 1 }, [11] = { 99 }, [12] = {} },
        keepUntil = { [10] = { "x" } },
        done = { [20] = { 1 } },
    })

    check.equal(data.status, "ok")
    check.truthy(data.keep[10])
    check.equal(data.keep[11], nil, "unknown quest")
    check.equal(data.keep[12], nil, "no quests")
    check.equal(data.keepUntil[10], nil, "bad achievement id")
    check.equal(PostQuestData.build({ schema = 2, quests = {} }).status, "incompatible")
end

spec["the bundled post-quest data loads"] = function()
    local data = PostQuestData.load()

    check.equal(data.status, "ok")
    check.truthy(next(data.keep), "has keep items")
    check.truthy(next(data.done), "has done items")
end

return spec
