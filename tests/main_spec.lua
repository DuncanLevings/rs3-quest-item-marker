-- The whole plugin (src/main.lua) on the real data and a fake client: the M2 exit
-- checks that can run outside the game.

local check = require("tests/support/check")
local FakeClient = require("tests/support/fake_client")

local spec = {}

local PRIEST_IN_PERIL = 276
local RUNE_ESSENCE = 1436
local COINS = 995
local HAMMER = 2347
local JUNK = 1 -- not in the data

-- Every quest in the data exists in the fake client, not started, each with its own
-- progress variable (id 10000 + quest id).
-- saved: settings already in PersistentDB before the plugin starts.
-- finished: quest names already finished on this fake account.
local function setup(saved, finished)
    local client = FakeClient.install()
    client.db["quest-item-marker.settings.v1"] = saved
    local data = dofile("data/quest_items.lua")

    for _, quest in ipairs(data.quests) do
        local done = finished and finished[quest.name] or false

        client.addQuest(quest.id, {
            name = quest.name,
            started = done,
            finished = done,
            -- Goblin Diplomacy stands in for a quest with no watchable variable.
            vars = quest.name ~= "Goblin Diplomacy" and { { varPlayer = { id = 10000 + quest.id } } } or {},
        })
    end

    client.setSlot(1, RUNE_ESSENCE)
    client.setSlot(2, COINS)
    client.setSlot(3, HAMMER)
    client.setSlot(4, JUNK)

    local shutdown = require("src/main").start()

    return client, shutdown
end

-- Finishes the quest read, then lets the marker check run.
local function settle(client)
    client.runLogic(20)
    client.fire("ServerLogic")
    client.fire("Draw", { timeDeltaSecs = 0.016 })
end

spec["only the required item gets an icon and a tooltip; common items get neither"] = function()
    local client, shutdown = setup()

    settle(client)

    check.equal(#client.liveIcons(), 1, "icons")
    check.equal(#client.liveTooltips(), 1, "tooltips")
    -- The tooltip hangs off our icon; no game slot is hooked, and the icon still lets
    -- clicks through to the item.
    local icon = client.liveIcons()[1]

    check.truthy(icon.hooks.tooltip, "icon hooked")
    check.truthy(icon.clickthrough, "icon lets clicks through")
    check.equal(client.hookedSlots(), 0, "game slots hooked")
    check.contains(client.liveTooltips()[1].text, "Priest in Peril")

    shutdown()
end

-- Opens the ribbon panel and returns its "Mark items needed for" checkboxes.
local function openFilter(client)
    client.fire("ContentLayerReady", { component = { interfaceID = 1477 } })

    for _, button in ipairs(client.view.checkboxes) do
        if button.choices[1].value == "quest" then
            return button
        end
    end
end

local DORICS_TASK_V_ITEM = 45526 -- needed only by a miniquest

spec["turning Miniquests off drops a miniquest's icon at once, reads no quest, and is kept (CUJ 6)"] = function()
    local client, shutdown = setup()

    client.setSlot(5, DORICS_TASK_V_ITEM)
    client.fire("InventoryUpdated", { inv = { id = 93 } })
    settle(client)
    check.equal(#client.liveIcons(), 2)

    local filter = openFilter(client)

    check.equal(filter.choices[1].text, "Quests")
    check.equal(filter.choices[2].text, "Miniquests")
    check.truthy(filter:IsSelected("miniquest"), "on by default")

    local reads = client.questReads

    filter:click("miniquest")

    -- No server tick needed, and only the miniquest item lost its icon.
    check.equal(#client.liveIcons(), 1)
    check.contains(client.liveTooltips()[1].text, "Priest in Peril")
    check.equal(client.questReads, reads, "no quest read")
    check.equal(client.db["quest-item-marker.settings.v1"].filter.miniquest, false)

    shutdown()

    -- Next start: still off, and the panel shows it.
    local saved = client.db["quest-item-marker.settings.v1"]
    local client2, shutdown2 = setup(saved)

    client2.setSlot(5, DORICS_TASK_V_ITEM)
    settle(client2)
    check.equal(#client2.liveIcons(), 1)
    check.falsy(openFilter(client2):IsSelected("miniquest"))

    -- Back on: the icon returns at once.
    openFilter(client2):click("miniquest")
    check.equal(#client2.liveIcons(), 2)
    shutdown2()
end

spec["no icons before the first quest read finishes"] = function()
    local client, shutdown = setup()

    client.fire("ServerLogic")

    check.equal(#client.liveIcons(), 0)

    shutdown()
end

spec["finishing a quest removes its icon within a few ticks, without a full re-read (CUJ 4)"] = function()
    -- Rune essence is also on two other quests' lists; with those done, the icon is
    -- there only because of Priest in Peril.
    local client, shutdown = setup(nil, { ["The Slug Menace"] = true, ["Garden of Tranquillity"] = true })

    settle(client)
    check.equal(#client.liveIcons(), 1)

    local before = client.questReads
    client.quests[PRIEST_IN_PERIL].hasStartedQuest = true
    client.quests[PRIEST_IN_PERIL].hasFinishedQuest = true
    client.fire("VarTransmit", { var = { id = 10000 + PRIEST_IN_PERIL }, oldValue = 1, newValue = 60 })
    settle(client)

    check.equal(client.questReads - before, 1, "only Priest in Peril was read")
    check.equal(#client.liveIcons(), 0)
    check.equal(client.hookedSlots(), 0)

    shutdown()
end

spec["a quest finishing updates the tooltip text in place"] = function()
    local client, shutdown = setup()

    settle(client)
    check.contains(client.liveTooltips()[1].text, "Priest in Peril")

    -- Rune essence stays marked for its other quests; Priest in Peril leaves the text.
    client.quests[PRIEST_IN_PERIL].hasStartedQuest = true
    client.quests[PRIEST_IN_PERIL].hasFinishedQuest = true
    client.fire("VarTransmit", { var = { id = 10000 + PRIEST_IN_PERIL }, oldValue = 0, newValue = 1 })
    settle(client)

    check.equal(#client.liveTooltips(), 1)
    check.falsy(client.liveTooltips()[1].text:find("Priest in Peril", 1, true))

    shutdown()
end

spec["spamming the shortcut reads no quest status and off leaves nothing of ours (CUJ 5)"] = function()
    -- A shortcut the player bound earlier in the settings window.
    local client, shutdown = setup({ enabled = true, key = { 81 } })

    settle(client)

    local before = client.questReads

    for _ = 1, 9 do
        client.keyDown = true
        client.fire("Logic")
        client.keyDown = false
        client.fire("Logic")
        client.fire("ServerLogic")
    end

    check.equal(client.questReads, before, "quest reads while toggling")

    -- Nine presses from on: now off.
    check.equal(#client.liveIcons(), 0, "icons")
    check.equal(#client.liveTooltips(), 0, "tooltips")
    check.equal(client.hookedSlots(), 0, "hooks on game slots")
    check.equal(client.chat[#client.chat], "Quest Item Marker: Markers hidden")

    -- What's left subscribed is only what turns markers back on and keeps the
    -- cache fresh: the shortcut, the quest watch and the ribbon panel.
    check.falsy(client.subscribed("ServerLogic", "quest-item-marker-markers"))
    check.falsy(client.subscribed("InventoryUpdated", "quest-item-marker-markers"))
    check.falsy(client.subscribed("Draw", "quest-item-marker-sync"))

    -- One more press: back on, drawn from the cache at once, not on the next
    -- server tick (the toggle lag found in game).
    client.keyDown = true
    client.fire("Logic")
    client.keyDown = false

    check.equal(#client.liveIcons(), 1, "icon back before any server tick")
    check.equal(client.questReads, before, "quest reads after turning back on")

    -- Closing and reopening the backpack is a real screen open: it re-reads only the
    -- quests with no variable (here, Goblin Diplomacy), at most once per cooldown.
    -- The first open after login needs none (the login read just did it).
    local function reopen()
        client.container.visibleGlobal = false
        client.fire("ServerLogic")
        client.container.visibleGlobal = true
        client.fire("ServerLogic")
        client.runLogic(3)
    end

    reopen()
    check.equal(client.questReads, before, "first open after login")

    for _ = 1, 50 do
        client.fire("ServerLogic")
    end

    reopen()
    reopen()
    check.equal(client.questReads - before, 1, "one unwatched re-read for two opens in the cooldown")
    check.equal(#client.liveIcons(), 1)

    shutdown()
end

spec["shutdown leaves zero icons, tooltips, hooks and subscriptions"] = function()
    local client, shutdown = setup()

    settle(client)
    shutdown()

    check.equal(#client.liveIcons(), 0)
    check.equal(#client.liveTooltips(), 0)
    check.equal(client.hookedSlots(), 0)
    check.equal(client.subscriptionCount(), 0)
end

spec["the off setting is respected at the next start"] = function()
    local client, shutdown = setup({ enabled = false })

    settle(client)

    check.equal(#client.liveIcons(), 0)
    check.falsy(client.subscribed("ServerLogic", "quest-item-marker-markers"))

    shutdown()
end

return spec
