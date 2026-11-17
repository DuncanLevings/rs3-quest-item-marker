-- Bank adapters: the bank grid (517:201) and the backpack panel inside the bank
-- (517:15). Open needs a visible container, placeholders read as their item, empty
-- slots ("Empty slot" components) are skipped, and anything that doesn't add up is
-- unreliable. Then the marker manager with all three screens: bank icons follow tab
-- switches and searches in the same frame and go when the bank closes.

local check = require("tests/support/check")
local FakeClient = require("tests/support/fake_client")

local spec = {}

-- Adapters -------------------------------------------------------------------------

spec["a closed bank reads as closed and isn't read"] = function()
    local client = FakeClient.install()
    local Bank = require("src/screens/bank")

    check.falsy(Bank.isOpen())
    check.falsy(Bank.read().open)
    check.equal(client.slotReads, 0)
end

spec["bank items and placeholders are read; empty slots are skipped"] = function()
    local client = FakeClient.install()
    client.openBank()
    client.setBankSlot(1, 1436, 500)
    client.setBankSlot(4, 954, 0) -- placeholder: real id, count 0

    local Bank = require("src/screens/bank")
    local result = Bank.read()

    check.truthy(Bank.isOpen())
    check.equal(result.state, "ok")
    check.truthy(result.open)
    check.equal(#result.slots, 2)
    check.equal(result.slots[2].slot, 4)
    check.equal(result.slots[2].itemId, 954, "a placeholder reads as its item")
    check.equal(result.slots[2].component, client.bankSlots[4])
    check.equal(client.bankSlots[2].associatedObjectID, client.EMPTY_BANK_SLOT)
end

spec["517 still loaded after the bank closes is not open"] = function()
    local client = FakeClient.install()
    client.openBank()
    client.setBankSlot(1, 1436)
    client.closeBank()

    local Bank = require("src/screens/bank")

    check.truthy(client.bank.valid, "the inventory can stay valid")
    check.falsy(Bank.isOpen())
    check.falsy(Bank.read().open)
    check.falsy(require("src/screens/bank_backpack").isOpen())
end

spec["a bank slot showing another item is unreliable"] = function()
    local client = FakeClient.install()
    client.openBank()
    client.setBankSlot(7, 1436)
    client.bankSlots[7].associatedObjectID = client.EMPTY_BANK_SLOT

    local result = require("src/screens/bank").read()

    check.equal(result.state, "unreliable")
    check.contains(result.reason, "bank slot 7")
end

spec["a bank that changes while being read is unreliable"] = function()
    local client = FakeClient.install()
    client.openBank()
    client.setBankSlot(1, 1436)

    local reads = 0

    client.bank.onRead = function()
        reads = reads + 1

        if reads == 2 then
            client.bank.slots[2] = 954
        end
    end

    local result = require("src/screens/bank").read()

    check.equal(result.state, "unreliable")
    check.contains(result.reason, "bank changed")
end

spec["the backpack panel in the bank reads the backpack inventory"] = function()
    local client = FakeClient.install()
    client.setSlot(3, 1436)

    local BankBackpack = require("src/screens/bank_backpack")

    check.falsy(BankBackpack.read().open, "closed with the bank")

    client.openBank()

    local result = BankBackpack.read()

    check.truthy(result.open)
    check.equal(#result.slots, 1)
    check.equal(result.slots[1].component, client.bankBackpackSlots[3])
    check.truthy(BankBackpack.inventoryIds()[93])
    check.truthy(require("src/screens/bank").inventoryIds()[95])
end

spec["a visible slot container with no slots is closed, not unreadable"] = function()
    local client = FakeClient.install()
    client.setSlot(1, 1436)
    client.openBank()
    client.bankWindow.visibleGlobal = false

    -- Seen in game at a shop: 517:15 read as visible with no slot components.
    for index = #client.bankBackpackSlots, 1, -1 do
        client.bankBackpackSlots[index] = nil
    end

    local result = require("src/screens/bank_backpack").read()

    check.equal(result.state, "ok")
    check.falsy(result.open)
    check.contains(result.reason, "has no slots")
end

-- With the marker manager ------------------------------------------------------------

-- Markers on all three screens, marking item 100 only, quest status ready.
local function setup()
    local client = FakeClient.install()
    local messages = require("src/messages").new()
    local required = {
        isMarked = function(_, itemId)
            return itemId == 100
        end,
        tooltipText = function()
            return "Priest in Peril"
        end,
    }

    local markers = require("src/ui/markers").new({
        screens = {
            (require("src/screens/backpack")),
            (require("src/screens/bank")),
            (require("src/screens/bank_backpack")),
        },
        questStatus = { ready = true, refreshUnwatched = function() end },
        iconSprite = function()
            return 17130
        end,
        requiredItems = function()
            return required
        end,
        messages = messages,
    })

    client.setSlot(2, 100)
    client.setBankSlot(1, 100, 3)
    client.setBankSlot(2, 200, 1)
    client.setBankSlot(5, 100, 0) -- placeholder
    markers:setEnabled(true)

    return client, markers
end

-- Live icons whose parent is the given container.
local function iconsIn(client, container)
    local list = {}

    for _, icon in ipairs(client.liveIcons()) do
        if icon.parent == container then
            list[#list + 1] = icon
        end
    end

    return list
end

spec["opening the bank marks items, placeholders and the bank's backpack panel"] = function()
    local client, markers = setup()

    check.equal(#client.liveIcons(), 1, "only the backpack while the bank is closed")

    client.openBank()
    client.fire("InventoryAdded", { inv = { id = 95 } })
    client.fire("ServerLogic")

    check.equal(#iconsIn(client, client.bankContainer), 2, "item and placeholder")
    check.equal(#iconsIn(client, client.bankBackpackContainer), 1)
    check.equal(#iconsIn(client, client.container), 1)

    -- Tooltips are drawn in 1477 so they show above the bank window (M0).
    for _, tooltip in ipairs(client.liveTooltips()) do
        check.equal(tooltip.holder, client.root)
    end

    markers:stop()
    check.equal(#client.liveIcons(), 0)
    check.equal(#client.liveTooltips(), 0)
end

spec["bank icons follow a tab switch or search in the same frame"] = function()
    local client, markers = setup()

    client.openBank()
    client.fire("ServerLogic")

    local placeholderIcon

    for _, icon in ipairs(iconsIn(client, client.bankContainer)) do
        if icon.y == client.bankSlots[5].y then
            placeholderIcon = icon
        end
    end

    check.truthy(placeholderIcon)

    -- Tab switch: slot 5 moves to the top, slot 1 is hidden. No server tick.
    client.bankSlots[5].x, client.bankSlots[5].y = 0, 5
    client.bankSlots[1].visibleGlobal = false
    client.fire("Draw")

    check.equal(placeholderIcon.x, 0 + 36 - 12)
    check.equal(placeholderIcon.y, 5)

    local hidden = 0

    for _, icon in ipairs(iconsIn(client, client.bankContainer)) do
        if icon.hidden then
            hidden = hidden + 1
        end
    end

    check.equal(hidden, 1, "the hidden slot's icon hides with it")

    -- Clearing the search shows it again.
    client.bankSlots[1].visibleGlobal = true
    client.fire("Draw")

    for _, icon in ipairs(iconsIn(client, client.bankContainer)) do
        check.falsy(icon.hidden)
    end

    markers:stop()
end

spec["closing the bank removes its icons, even with 517 still loaded"] = function()
    local client, markers = setup()

    client.openBank()
    client.fire("ServerLogic")
    check.equal(#client.liveIcons(), 4)

    client.closeBank()
    client.fire("ServerLogic")

    check.equal(#client.liveIcons(), 1, "only the backpack's icon is left")
    check.equal(#iconsIn(client, client.container), 1)
    markers:stop()
end

spec["a bank that unloads leaves its old handles alone"] = function()
    local client, markers = setup()

    client.openBank()
    client.fire("ServerLogic")

    local bankIcons = iconsIn(client, client.bankContainer)

    client.closeBank(true)
    client.fire("Draw")

    for _, icon in ipairs(bankIcons) do
        check.falsy(icon.destroyed, "old handle not touched")
    end

    check.equal(#client.liveTooltips(), 1, "only the backpack's tooltip is left")
    markers:stop()
end

spec["an unreadable bank shows no wrong icon and says 'Couldn't read Bank' once"] = function()
    local client, markers = setup()

    client.openBank()
    client.fire("ServerLogic")

    -- Slot 1 now shows something else while the inventory still has item 100.
    client.bankSlots[1].associatedObjectID = 200
    client.fire("InventoryUpdated", { inv = { id = 95 } })
    client.fire("ServerLogic")

    for _, icon in ipairs(iconsIn(client, client.bankContainer)) do
        check.falsy(icon.y == client.bankSlots[1].y and icon.x == client.bankSlots[1].x + 36 - 12,
            "no icon on the slot that disagrees")
    end

    check.equal(#iconsIn(client, client.container), 1, "the backpack is left alone")

    client.fire("ServerLogic")
    client.fire("ServerLogic")

    check.equal(#client.chat, 1)
    check.contains(client.chat[1], "Couldn't read Bank")

    client.bankSlots[1].associatedObjectID = 100
    client.fire("ServerLogic")

    check.equal(#iconsIn(client, client.bankContainer), 2, "back once it reads correctly")
    markers:stop()
end

return spec
