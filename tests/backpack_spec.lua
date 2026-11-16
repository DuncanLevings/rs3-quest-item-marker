-- Backpack adapter: identity matching, closed screen, and mismatches.

local check = require("tests/support/check")
local FakeClient = require("tests/support/fake_client")

local spec = {}

spec["filled slots are read with their components"] = function()
    local client = FakeClient.install()
    client.setSlot(1, 1436)
    client.setSlot(5, 954)

    local result = require("src/screens/backpack").read()

    check.equal(result.state, "ok")
    check.truthy(result.open)
    check.equal(#result.slots, 2)
    check.equal(result.slots[2].slot, 5)
    check.equal(result.slots[2].itemId, 954)
    check.equal(result.slots[2].component, client.slots[5])
end

spec["a hidden container counts as closed"] = function()
    local client = FakeClient.install()
    client.setSlot(1, 1436)
    client.container.visibleGlobal = false

    local Backpack = require("src/screens/backpack")
    local result = Backpack.read()

    check.equal(result.state, "ok")
    check.falsy(result.open)
    check.falsy(Backpack.isOpen())
end

spec["a slot showing another item is unreliable, never a guess"] = function()
    local client = FakeClient.install()
    client.setSlot(3, 1436)
    client.slots[3].associatedObjectID = 1437

    local result = require("src/screens/backpack").read()

    check.equal(result.state, "unreliable")
    check.contains(result.reason, "slot 3")
end

spec["a missing inventory counts as closed"] = function()
    local client = FakeClient.install()
    client.inventory.valid = false

    check.falsy(require("src/screens/backpack").read().open)
end

return spec
