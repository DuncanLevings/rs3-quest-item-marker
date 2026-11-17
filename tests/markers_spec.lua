-- Markers on their own: unreliable screens, the per-frame sync, and an interface
-- unloading under the icons.

local check = require("tests/support/check")
local FakeClient = require("tests/support/fake_client")

local spec = {}

-- Markers with a fake "required items" that marks item 100 only, and a quest status
-- that is already ready.
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
        screens = { (require("src/screens/backpack")) },
        questStatus = { ready = true, refreshUnwatched = function() end },
        iconSprite = 26112,
        requiredItems = required,
    })

    client.setSlot(2, 100)
    markers:setEnabled(true)

    return client, markers
end

spec["an unreliable screen loses its icons at once and gets them back once it reads"] = function()
    local client, markers = setup()

    client.fire("ServerLogic")
    check.equal(#client.liveIcons(), 1)

    client.slots[2].associatedObjectID = 999
    client.fire("InventoryUpdated", { inv = { id = 93 } })
    client.fire("ServerLogic")

    check.equal(#client.liveIcons(), 0, "icons removed on the first failure")

    client.fire("ServerLogic")
    client.fire("ServerLogic")

    client.slots[2].associatedObjectID = 100
    client.fire("ServerLogic")

    check.equal(#client.liveIcons(), 1, "back once it reads correctly")
    markers:stop()
end

spec["a slot that disagrees for a tick leaves the other icons alone (picking an item up)"] = function()
    local client, markers = setup()

    client.fire("ServerLogic")

    local icon = client.liveIcons()[1]

    -- The inventory already holds the new item in slot 5; its slot component doesn't
    -- show it yet.
    client.setSlot(5, 100)
    client.slots[5].associatedObjectID = -1
    client.fire("InventoryUpdated", { inv = { id = 93 } })
    client.fire("ServerLogic")

    check.falsy(icon.destroyed, "slot 2's icon stays")
    check.equal(#client.liveIcons(), 1, "no icon on slot 5 until it reads correctly")

    client.slots[5].associatedObjectID = 100
    client.fire("ServerLogic")

    check.equal(#client.liveIcons(), 2)
    markers:stop()
end

spec["icons follow their slot every frame and hide with it"] = function()
    local client, markers = setup()

    client.fire("ServerLogic")

    local icon = client.liveIcons()[1]

    client.slots[2].x = 200
    client.fire("Draw")
    check.equal(icon.x, 200 + 36 - 12)

    client.slots[2].visibleGlobal = false
    client.fire("Draw")
    check.truthy(icon.hidden)

    markers:stop()
end

spec["icons of an unloaded interface are forgotten, not touched, and redrawn"] = function()
    local client, markers = setup()

    client.fire("ServerLogic")

    local icon = client.liveIcons()[1]

    client.loadedInterfaces[1473] = nil
    client.fire("Draw")

    check.falsy(icon.destroyed, "old handle left alone")
    check.equal(#client.liveTooltips(), 0, "its tooltip is gone")
    check.falsy(client.subscribed("Draw", "quest-item-marker-sync"), "sync stops with no icons")

    client.loadedInterfaces[1473] = true
    client.fire("ServerLogic")

    check.equal(#client.liveTooltips(), 1)
    markers:stop()
end

spec["the icon cap stops drawing"] = function()
    local client, markers = setup()

    for slot = 1, 28 do
        client.setSlot(slot, 100)
    end

    -- Slot 2's icon was drawn when markers were turned on; room for 4 more.
    markers.iconCount = 1996
    client.fire("InventoryUpdated", { inv = { id = 93 } })
    client.fire("ServerLogic")

    check.equal(#client.liveIcons(), 5)
    markers:stop()
end

spec["the tooltip goes to the saved spot, or top centre, and stays on screen"] = function()
    local ItemTooltip = require("src/ui/item_tooltip")
    local screen = { width = 1000, height = 800 }

    -- Nothing saved: centred, 15% down.
    local x, y = ItemTooltip.place(nil, screen, 200, 60)
    check.equal(x, 400)
    check.equal(y, 120)

    -- Saved: its top-left corner goes there.
    x, y = ItemTooltip.place({ x = 50, y = 600 }, screen, 200, 60)
    check.equal(x, 50)
    check.equal(y, 600)

    -- A tall tooltip at a spot near the bottom right is moved back on screen.
    x, y = ItemTooltip.place({ x = 900, y = 780 }, screen, 200, 120)
    check.equal(x, 1000 - 6 - 200)
    check.equal(y, 800 - 6 - 120)

    -- A spot saved on a bigger screen (or a smaller window now) still lands on screen.
    x, y = ItemTooltip.place({ x = -40, y = 5000 }, screen, 200, 60)
    check.equal(x, 6)
    check.equal(y, 800 - 6 - 60)
end

spec["each quest line gets a top, wrapped lines push the next one down"] = function()
    local ItemTooltip = require("src/ui/item_tooltip")

    -- No font in tests: 7 px a character, 18 px a row.
    local short = "<col=c8c8c8>Quest</col>"
    local long = "<col=c8c8c8>" .. string.rep("x", 60) .. "</col>"
    local width, height, tops = ItemTooltip.layout(short .. "<br>" .. long .. "<br>" .. short)

    check.equal(width, 320, "capped")
    check.equal(tops[1], 5)
    check.equal(tops[2], 5 + 18)
    check.equal(tops[3], 5 + 18 + 36, "the long line took two rows")
    check.equal(height, 5 + 18 + 36 + 18 + 5)
end

return spec
