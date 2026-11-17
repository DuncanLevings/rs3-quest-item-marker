-- Preferences: defaults, per-field recovery, and the category rules.

local check = require("tests/support/check")
local FakeClient = require("tests/support/fake_client")

local spec = {}

local KEY = "quest-item-marker.settings.v1"
local CATEGORIES = { "quest", "miniquest" }

spec["defaults: on, no shortcut, Quest and Miniquest on, no tutorial option"] = function()
    FakeClient.install()
    local preferences = require("src/storage/preferences").new(PersistentDB, CATEGORIES)

    check.truthy(preferences:isEnabled())
    check.equal(#preferences:getKey(), 0)

    local filter = preferences:getFilter()

    check.truthy(filter.quest)
    check.truthy(filter.miniquest)
    check.equal(filter.tutorial, nil)
end

spec["one bad field doesn't reset the others"] = function()
    local client = FakeClient.install()
    client.db[KEY] = { enabled = false, key = { "not a key" }, filter = { quest = false, miniquest = "yes", tutorial = true }, extra = 1 }

    local preferences = require("src/storage/preferences").new(PersistentDB, CATEGORIES)

    check.falsy(preferences:isEnabled(), "kept enabled = false")
    check.equal(#preferences:getKey(), 0, "bad key reset")
    check.falsy(preferences:getFilter().quest, "kept quest = false")
    check.truthy(preferences:getFilter().miniquest, "bad miniquest value back to default")
    check.equal(preferences:getFilter().tutorial, nil, "old tutorial setting dropped")
end

spec["a removed category is dropped and a new one defaults to included"] = function()
    local client = FakeClient.install()
    client.db[KEY] = { filter = { quest = true, seasonal = false } }

    local preferences = require("src/storage/preferences").new(PersistentDB, { "quest", "saga" })
    local filter = preferences:getFilter()

    check.equal(filter.seasonal, nil)
    check.truthy(filter.saga)
end

spec["a quest type turned off is saved; unknown types and non-booleans are refused (M5)"] = function()
    local client = FakeClient.install()
    local Preferences = require("src/storage/preferences")
    local first = Preferences.new(PersistentDB, CATEGORIES)

    check.truthy(first:setFilter("miniquest", false))
    check.falsy(first:setFilter("miniquest", false), "no change, no save")
    check.falsy(first:setFilter("tutorial", false), "not offered")
    check.falsy(first:setFilter("quest", "no"), "not a boolean")
    check.equal(client.db[KEY].filter.tutorial, nil)

    local second = Preferences.new(PersistentDB, CATEGORIES)

    check.falsy(second:getFilter().miniquest)
    check.truthy(second:getFilter().quest)
end

spec["changes are saved and survive a reload"] = function()
    local client = FakeClient.install()
    local Preferences = require("src/storage/preferences")
    local first = Preferences.new(PersistentDB, CATEGORIES)

    check.truthy(first:setEnabled(false))
    check.falsy(first:setEnabled(false), "no change, no save")
    check.truthy(first:setKey({ 17, 65 }))
    check.falsy(first:setKey({ 1, 1 }), "repeated key refused")

    local second = Preferences.new(PersistentDB, CATEGORIES)

    check.falsy(second:isEnabled())
    check.equal(second:getKey()[2], 65)
    check.equal(client.db[KEY].filter.miniquest, true)
end

spec["the quest box spot: none by default, saved whole, bad values refused"] = function()
    local client = FakeClient.install()
    local Preferences = require("src/storage/preferences")
    local first = Preferences.new(PersistentDB, CATEGORIES)

    check.equal(first:getBox(), nil)
    check.truthy(first:setBox(120.7, 80))
    check.falsy(first:setBox(0 / 0, 5), "NaN refused")
    check.falsy(first:setBox("left", 5), "text refused")

    local second = Preferences.new(PersistentDB, CATEGORIES)
    check.equal(second:getBox().x, 120)
    check.equal(second:getBox().y, 80)
    check.truthy(second:isEnabled(), "the other fields kept")

    client.db[KEY].box = { x = "far" }
    check.equal(Preferences.new(PersistentDB, CATEGORIES):getBox(), nil, "a bad saved spot is dropped alone")
end

return spec
