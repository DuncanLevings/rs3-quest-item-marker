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
    local quests = {}

    for _, quest in ipairs(data.quests) do
        quests[quest.id] = quest.name
    end

    for questId, quest in pairs(dofile("data/post_quest_items.lua").quests) do
        quests[questId] = quests[questId] or quest.name
    end

    for questId, name in pairs(quests) do
        local done = finished and finished[name] or false

        client.addQuest(questId, {
            name = name,
            started = done,
            finished = done,
            -- Goblin Diplomacy stands in for a quest with no watchable variable.
            vars = name ~= "Goblin Diplomacy" and { { varPlayer = { id = 10000 + questId } } } or {},
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

spec["hidden markers stay hidden at the next start while a shortcut is bound"] = function()
    local client, shutdown = setup({ enabled = false, key = { 81 } })

    settle(client)

    check.equal(#client.liveIcons(), 0)
    check.falsy(client.subscribed("ServerLogic", "quest-item-marker-markers"))

    shutdown()
end

spec["with no shortcut bound, hidden markers come back (nothing else could show them)"] = function()
    local client, shutdown = setup({ enabled = false })

    settle(client)

    check.equal(#client.liveIcons(), 1)
    check.truthy(client.db["quest-item-marker.settings.v1"].enabled, "saved as shown")

    shutdown()
end

spec["the panel has no on/off checkbox: the quest type filter and the finished-quest markers"] = function()
    local client, shutdown = setup()

    client.fire("ContentLayerReady", { component = { interfaceID = 1477 } })

    check.equal(#client.view.checkboxes, 2)
    check.equal(client.view.checkboxes[1].choices[1].value, "quest")
    check.equal(client.view.checkboxes[2].choices[1].value, "keep")
    check.equal(client.view.checkboxes[2].choices[2].value, "done")
    check.truthy(client.view.checkboxes[2].choices[1].selected, "keep on by default")
    check.truthy(client.view.checkboxes[2].choices[2].selected, "done on by default")

    shutdown()
end

local INKY_QUILL = 13328 -- Rocking Out only
local WOLFBANE = 2952 -- Priest in Peril and River of Blood; two achievements
local ECTOPHIAL = 4251 -- Ghosts Ahoy; a lasting use, so never marked
local GREEN, RED = 0x40E040FF, 0xFF4040FF

-- The icon on backpack slot `slot`, or nil.
local function iconOn(client, itemId)
    for _, icon in ipairs(client.liveIcons()) do
        for slot, component in pairs(client.slots) do
            if component.associatedObjectID == itemId and icon.x == component.x + component.width - 12
                and icon.y == component.y then
                return icon, slot
            end
        end
    end

    return nil
end

spec["a quest-only item gets a red icon once its quest is finished, none before"] = function()
    local client, shutdown = setup(nil, {})

    client.setSlot(5, INKY_QUILL)
    settle(client)
    check.equal(iconOn(client, INKY_QUILL), nil, "Rocking Out not finished")
    shutdown()

    client, shutdown = setup(nil, { ["Rocking Out"] = true })
    client.setSlot(5, INKY_QUILL)
    settle(client)

    local icon = iconOn(client, INKY_QUILL)
    check.truthy(icon, "marked once finished")
    check.equal(icon.rgba, RED)

    local found = false

    for _, tooltip in ipairs(client.liveTooltips()) do
        found = found or (tooltip.text:find("(done)", 1, true) ~= nil
            and tooltip.text:find("Rocking Out", 1, true) ~= nil)
    end

    check.truthy(found, "tooltip says Rocking Out (done)")
    shutdown()
end

spec["an item kept for its achievements is green until they're done, then red"] = function()
    local finished = { ["Priest in Peril"] = true, ["River of Blood"] = true }
    local client, shutdown = setup(nil, finished)

    client.setSlot(5, WOLFBANE)
    settle(client)
    check.equal(iconOn(client, WOLFBANE).rgba, GREEN, "achievements left")
    shutdown()

    client, shutdown = setup(nil, finished)
    client.achievements[846] = -2
    client.achievements[4996] = -2
    client.setSlot(5, WOLFBANE)
    settle(client)
    check.equal(iconOn(client, WOLFBANE).rgba, RED, "both achievements done")
    shutdown()
end

spec["an item with a lasting use is never marked"] = function()
    local client, shutdown = setup(nil, { ["Ghosts Ahoy"] = true })

    client.setSlot(5, ECTOPHIAL)
    settle(client)
    check.equal(iconOn(client, ECTOPHIAL), nil)
    shutdown()
end

spec["unticking a finished-quest marker removes those icons and saves"] = function()
    local client, shutdown = setup(nil, { ["Priest in Peril"] = true, ["River of Blood"] = true,
        ["Rocking Out"] = true })

    client.setSlot(5, WOLFBANE)
    client.setSlot(6, INKY_QUILL)
    settle(client)
    check.equal(iconOn(client, WOLFBANE).rgba, GREEN)
    check.equal(iconOn(client, INKY_QUILL).rgba, RED)

    client.fire("ContentLayerReady", { component = { interfaceID = 1477 } })
    client.view.checkboxes[2]:click("keep")
    check.equal(iconOn(client, WOLFBANE), nil, "green removed straight away")
    check.truthy(iconOn(client, INKY_QUILL), "red stays")

    client.view.checkboxes[2]:click("done")
    check.equal(iconOn(client, INKY_QUILL), nil, "red removed")

    local saved = client.db["quest-item-marker.settings.v1"].postQuest
    check.falsy(saved.keep, "keep saved off")
    check.falsy(saved.done, "done saved off")
    shutdown()
end

return spec
