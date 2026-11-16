-- QuestStatus with a fake client: the spread-out first read, the variable watch,
-- the unwatched cooldown and logout.

local check = require("tests/support/check")
local FakeClient = require("tests/support/fake_client")

local spec = {}

-- Three quests: 1 watched by a plain variable, 2 by a varbit (whose base is 900),
-- 3 with no variable at all.
local function setup()
    local client = FakeClient.install()

    client.addQuest(1, { name = "Plain", vars = { { varPlayer = { id = 101, isVarBit = false } } } })
    client.addQuest(2, { name = "Bits", vars = { { varPlayer = { id = -5, isVarBit = true, baseVar = { id = 900 } } } } })
    client.addQuest(3, { name = "Unwatched", vars = {} })

    local events = {}
    local quests = { { id = 1, name = "Plain" }, { id = 2, name = "Bits" }, { id = 3, name = "Unwatched" }, { id = 4, name = "Gone" } }
    local status = require("src/game/quest_status").new(quests, function(reason, ids)
        events[#events + 1] = { reason = reason, ids = ids }
    end)

    return client, status, events
end

spec["the first read is spread over logic ticks, then reports ready"] = function()
    local client, status, events = setup()

    status:start()
    check.falsy(status.ready, "not ready before any tick")
    check.truthy(client.subscribed("Logic", "quest-item-marker-quest-status"))

    client.runLogic(5)

    check.truthy(status.ready)
    check.equal(events[1].reason, "ready")
    check.equal(status:get(1), "not_started")
    check.equal(status:get(4), "missing", "quest unknown to the client")
    check.equal(status.counts.unwatched, 1)
    check.equal(status.counts.missing, 1)
    check.falsy(client.subscribed("Logic", "quest-item-marker-quest-status"), "logic dropped once idle")
end

spec["it waits for the player before reading"] = function()
    local client, status = setup()

    -- Plugin started at the login screen: start() doesn't read.
    client.playerAvailable = false
    status:start()
    client.runLogic(5)
    check.falsy(status.ready, "nothing read while logged out")

    client.fire("GameStateChanged", { newState = GameState.GAME })
    client.runLogic(5)
    check.falsy(status.ready, "still waiting for the player")

    client.playerAvailable = true
    client.runLogic(5)
    check.truthy(status.ready)
end

spec["a watched variable re-reads only its quest"] = function()
    local client, status, events = setup()

    status:start()
    client.runLogic(5)

    local before = client.questReads
    client.quests[1].hasStartedQuest = true
    client.fire("VarTransmit", { var = { id = 101 }, oldValue = 0, newValue = 3 })
    client.runLogic(2)

    check.equal(client.questReads - before, 1, "one quest read")
    check.equal(status:get(1), "in_progress")
    check.equal(events[#events].reason, "changed")
    check.equal(events[#events].ids[1], 1)
end

spec["a varbit quest is watched through its base variable too"] = function()
    local client, status = setup()

    status:start()
    client.runLogic(5)

    client.quests[2].hasStartedQuest = true
    client.quests[2].hasFinishedQuest = true
    client.fire("VarTransmit", { var = { id = 900 }, oldValue = 1, newValue = 9 })
    client.runLogic(2)

    check.equal(status:get(2), "finished")
end

spec["unrelated or unchanged variables read nothing"] = function()
    local client, status = setup()

    status:start()
    client.runLogic(5)

    local before = client.questReads
    client.fire("VarTransmit", { var = { id = 555 }, oldValue = 0, newValue = 1 })
    client.fire("VarTransmit", { var = { id = 101 }, oldValue = 2, newValue = 2 })
    client.runLogic(2)

    check.equal(client.questReads, before)
end

spec["unwatched quests re-read on screen open at most every 50 server ticks (~30 s)"] = function()
    local client, status = setup()

    status:start()
    client.runLogic(5)

    local before = client.questReads

    -- Right after the full read, the first screen open needs no read.
    check.falsy(status:refreshUnwatched(1))
    check.falsy(status:refreshUnwatched(40), "inside the cooldown")
    check.truthy(status:refreshUnwatched(51))
    client.runLogic(2)
    check.equal(client.questReads - before, 1, "only the unwatched quest")
    check.falsy(status:refreshUnwatched(90))
end

spec["logging out forgets everything and stops reading"] = function()
    local client, status, events = setup()

    status:start()
    client.runLogic(5)
    client.fire("GameStateChanged", { newState = GameState.LOBBY })

    check.falsy(status.ready)
    check.equal(status:get(1), nil)
    check.equal(events[#events].reason, "reset")

    -- A teleport's loading screen keeps the cache.
    client.fire("GameStateChanged", { newState = GameState.GAME })
    client.runLogic(5)
    client.fire("GameStateChanged", { newState = GameState.LOADING })
    check.truthy(status.ready)
end

spec["stop leaves no subscriptions"] = function()
    local client, status = setup()

    status:start()
    client.runLogic(1)
    status:stop()

    check.equal(client.subscriptionCount(), 0)
end

return spec
