-- Shop adapter: it learns inventory ids from events, uses the one whose items match
-- the shop slots exactly, follows a stock tab switch on the next tick, and is
-- unreliable when nothing matches. Then the marker manager with a shop.

local check = require("tests/support/check")
local FakeClient = require("tests/support/fake_client")

local spec = {}

-- A shop with two stock lists: 24 holds item 100 in slot 3, 25 holds item 200 and
-- item 100 in slots 1 and 2.
local function stockShop(client)
    client.setShopStock(24, 1, 300)
    client.setShopStock(24, 3, 100)
    client.setShopStock(25, 1, 200)
    client.setShopStock(25, 2, 100)
end

-- Adapter ----------------------------------------------------------------------------

spec["a closed shop is closed and reads nothing"] = function()
    local client = FakeClient.install()
    local shop = require("src/screens/shop").new()

    shop.noteInventory(24)

    check.falsy(shop.isOpen())
    check.falsy(shop.read().open)
    check.equal(client.slotReads, 0)
end

spec["the shop uses the inventory that matches its slots"] = function()
    local client = FakeClient.install()
    stockShop(client)
    client.openShop(24)

    local shop = require("src/screens/shop").new()

    shop.noteInventory(24)
    shop.noteInventory(25)

    local result = shop.read()

    check.truthy(shop.isOpen())
    check.equal(result.state, "ok")
    check.equal(result.inventoryId, 24, "25 was newer, but doesn't match")
    check.equal(#result.slots, 2)
    check.equal(result.slots[2].slot, 3)
    check.equal(result.slots[2].itemId, 100)
    check.equal(result.slots[2].component, client.shopSlots[3])
end

spec["a stock tab switch is matched to the other list"] = function()
    local client = FakeClient.install()
    stockShop(client)
    client.openShop(24)

    local shop = require("src/screens/shop").new()

    shop.noteInventory(24)
    shop.noteInventory(25)
    client.showShopList(25)

    local result = shop.read()

    check.equal(result.inventoryId, 25)
    check.equal(result.slots[2].component, client.shopSlots[2])
end

spec["the sell view (backpack items) matches the backpack"] = function()
    local client = FakeClient.install()
    stockShop(client)
    client.setSlot(4, 100)
    client.openShop(24)

    local shop = require("src/screens/shop").new()

    shop.noteInventory(93)
    shop.noteInventory(24)
    client.showShopList(93)

    local result = shop.read()

    check.equal(result.inventoryId, 93)
    check.equal(result.slots[1].component, client.shopSlots[4])
end

spec["slots that match no known list are unreliable"] = function()
    local client = FakeClient.install()
    stockShop(client)
    client.openShop(24)

    local shop = require("src/screens/shop").new()

    -- No stock list seen yet (markers turned on with the shop already open).
    local result = shop.read()

    check.equal(result.state, "unreliable")

    -- A list that holds the shown items plus one more doesn't count: both ways.
    shop.noteInventory(24)
    client.shopSlots[3].associatedObjectID = -1

    result = shop.read()

    check.equal(result.state, "unreliable")
end

spec["the bank is never taken for shop stock"] = function()
    FakeClient.install()

    local shop = require("src/screens/shop").new()

    shop.noteInventory(95)
    check.falsy(shop.inventoryIds()[95])
end

-- With the marker manager ------------------------------------------------------------

local function setup()
    local client = FakeClient.install()
    local required = {
        isMarked = function(_, itemId)
            return itemId == 100
        end,
        tooltipText = function()
            return "Priest in Peril"
        end,
    }

    local markers = require("src/ui/markers").new({
        screens = { (require("src/screens/backpack")), require("src/screens/shop").new() },
        questStatus = { ready = true, refreshUnwatched = function() end },
        iconSprite = 17130,
        requiredItems = required,
    })

    stockShop(client)
    markers:setEnabled(true)

    return client, markers
end

local function shopIcons(client)
    local list = {}

    for _, icon in ipairs(client.liveIcons()) do
        if icon.parent == client.shopContainer then
            list[#list + 1] = icon
        end
    end

    return list
end

spec["shop icons follow a stock tab switch within a tick and go on close"] = function()
    local client, markers = setup()

    client.openShop(24)
    client.fire("InventoryAdded", { inv = { id = 24 } })
    client.fire("InventoryAdded", { inv = { id = 25 } })
    client.fire("ServerLogic")

    local icons = shopIcons(client)

    check.equal(#icons, 1)
    check.equal(icons[1].y, client.shopSlots[3].y)

    -- Tab switch: no inventory event, the next tick re-reads anyway.
    client.showShopList(25)
    client.fire("ServerLogic")

    icons = shopIcons(client)
    check.equal(#icons, 1)
    check.equal(icons[1].x, client.shopSlots[2].x + 36 - 12)
    check.equal(icons[1].y, client.shopSlots[2].y)

    client.closeShop()
    client.fire("ServerLogic")

    check.equal(#shopIcons(client), 0)
    check.equal(#client.liveTooltips(), 0)
    markers:stop()
end

spec["icons the game deletes when it rebuilds the shop (a purchase) come back next tick"] = function()
    local client, markers = setup()

    client.setShopStock(24, 5, 100)
    client.openShop(24)
    client.fire("InventoryAdded", { inv = { id = 24 } })
    client.fire("ServerLogic")
    check.equal(#shopIcons(client), 2)

    -- Buying: the stock list changes and the game rebuilds the slots, deleting our
    -- icons with them. The plugin is told nothing about the icons.
    client.fire("ServerLogic") -- the shop is re-read every tick while open
    client.rebuildShop()
    client.fire("InventoryUpdated", { inv = { id = 24 } })
    client.fire("ServerLogic")

    local icons = shopIcons(client)

    check.equal(#icons, 2, "drawn again")
    check.equal(#client.liveTooltips(), 2, "the old tooltips went with them")

    -- The new icons follow the new slot components.
    client.shopSlots[3].x = 300
    client.fire("Draw")

    local moved = false

    for _, icon in ipairs(icons) do
        if icon.x == 300 + 36 - 12 then
            moved = true
        end
    end

    check.truthy(moved)

    -- A quiet tick with nothing rebuilt redraws nothing.
    local before = #client.components
    client.fire("ServerLogic")
    check.equal(#client.components, before)
    markers:stop()
end

spec["a stock change is read next frame, and deleted icons come back in the same frame"] = function()
    local client, markers = setup()

    client.openShop(24)
    client.fire("InventoryAdded", { inv = { id = 24 } })
    client.fire("ServerLogic")
    check.equal(#shopIcons(client), 1)

    -- Restock: a new marked item and an event, then the next frame. No server tick.
    client.setShopStock(24, 6, 100)
    client.showShopList(24)
    client.fire("InventoryUpdated", { inv = { id = 24 } })
    client.fire("Draw")
    check.equal(#shopIcons(client), 2, "read in the first frame")

    -- The game rebuilds the slots and deletes our icons: back within 3 frames.
    client.rebuildShop()

    for _ = 1, 3 do
        client.fire("Draw")
    end

    check.equal(#shopIcons(client), 2, "drawn again within 3 frames")
    markers:stop()
end

spec["opening a shop marks it in the frame its window appears, not at the next tick"] = function()
    local client, markers = setup()

    -- The stock arrives a moment before the window shows.
    client.shopStock[24].valid = true
    client.fire("InventoryAdded", { inv = { id = 24 } })
    client.fire("Draw")
    check.equal(#shopIcons(client), 0)

    client.openShop(24)
    client.fire("Draw")
    check.equal(#shopIcons(client), 1, "no server tick needed")
    markers:stop()
end

spec["a Buy/Sell tab switch (no event) is marked within 3 frames"] = function()
    local client, markers = setup()

    client.setSlot(4, 100)
    client.openShop(24)
    client.fire("InventoryAdded", { inv = { id = 24 } })
    client.fire("ServerLogic")
    check.equal(#shopIcons(client), 1)

    client.showShopList(93)

    for _ = 1, 3 do
        client.fire("Draw")
    end

    local icons = shopIcons(client)

    check.equal(#icons, 1)
    check.equal(icons[1].y, client.shopSlots[4].y, "on the backpack item now")
    markers:stop()
end

spec["an idle open shop costs one cheap listing every 3 frames and no full read"] = function()
    local client, markers = setup()

    client.openShop(24)
    client.fire("InventoryAdded", { inv = { id = 24 } })
    client.fire("ServerLogic")

    local listings = 0
    local iterate = client.shopContainer.IterateDynamicComponents

    client.shopContainer.IterateDynamicComponents = function(...)
        listings = listings + 1
        return iterate(...)
    end

    local reads = client.slotReads

    for _ = 1, 90 do
        client.fire("Draw")
    end

    check.equal(listings, 30, "one listing every 3 frames")
    check.equal(client.slotReads, reads, "no inventory read while nothing changes")

    -- Closed: the poll stops.
    client.closeShop()
    client.fire("ServerLogic")
    listings = 0

    for _ = 1, 30 do
        client.fire("Draw")
    end

    check.equal(listings, 0)
    markers:stop()
end

spec["the sell view matches the backpack with no backpack event seen"] = function()
    local client = FakeClient.install()
    stockShop(client)
    client.setSlot(4, 100)
    client.openShop(24)

    local shop = require("src/screens/shop").new()

    shop.noteInventory(24)
    client.showShopList(93)

    local result = shop.read()

    check.equal(result.inventoryId, 93)
    check.truthy(shop.inventoryIds()[93], "backpack events re-check the shop")
end

spec["the sell view keeps its icons after a sale rebuilds the slots"] = function()
    local client, markers = setup()

    client.setSlot(4, 100)
    client.fire("InventoryUpdated", { inv = { id = 93 } })
    client.openShop(24)
    client.fire("InventoryAdded", { inv = { id = 24 } })
    client.showShopList(93)
    client.fire("ServerLogic")
    check.equal(#shopIcons(client), 1)

    client.fire("ServerLogic") -- the shop is re-read every tick while open
    client.rebuildShop()
    client.fire("ServerLogic")
    check.equal(#shopIcons(client), 1)
    markers:stop()
end

spec["the full-name display mode is found and marked, and switching back moves icons"] = function()
    local client, markers = setup()

    client.openShop(24)
    client.fire("InventoryAdded", { inv = { id = 24 } })
    client.fire("ServerLogic")
    check.equal(#shopIcons(client), 1)

    client.setShopDisplay("list")
    client.fire("ServerLogic")

    local listIcons = {}

    for _, icon in ipairs(client.liveIcons()) do
        if icon.parent == client.shopListContainer then
            listIcons[#listIcons + 1] = icon
        end
    end

    check.equal(#listIcons, 1, "drawn in the list view")
    check.equal(#shopIcons(client), 0, "none left in the hidden icon view")
    check.equal(listIcons[1].y, client.shopListSlots[3].y)

    client.setShopDisplay("icons")
    client.fire("ServerLogic")

    check.equal(#shopIcons(client), 1)
    check.truthy(listIcons[1].destroyed)
    markers:stop()
end

spec["an unmatched shop shows no icons"] = function()
    local client, markers = setup()

    -- Opened with no inventory event heard.
    client.openShop(24)
    client.fire("ServerLogic")
    client.fire("ServerLogic")
    client.fire("ServerLogic")

    check.equal(#shopIcons(client), 0)

    -- A stock update tells it which inventory to use.
    client.fire("InventoryUpdated", { inv = { id = 24 } })
    client.fire("ServerLogic")

    check.equal(#shopIcons(client), 1)
    markers:stop()
end

return spec
