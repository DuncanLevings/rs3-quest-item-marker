-- The player's settings, saved in PersistentDB under one key. Settings are global:
-- the same for every character on this computer.
--
-- Saved shape (a storage contract; change it only with a migration):
--   quest-item-marker.settings.v1 = {
--       enabled = true,                         -- markers shown
--       key = { gameKey, gameKey? },            -- toggle shortcut, empty = none
--       filter = { quest = true, miniquest = true },
--       box = { x = 120, y = 80 },              -- quest box top-left; absent = default
--   }
--
-- Each field is checked on its own, so one bad value (or a field from a newer
-- version) never resets the others. Unknown keys are ignored. A category the data
-- no longer has is dropped; a new one gets its default.
--
-- Owns the saved record.

local Log = require("src/log")

local Preferences = {}

Preferences.STORAGE_KEY = "quest-item-marker.settings.v1"

-- Defaults for the categories we know: everything is marked until the player opts out.
local FILTER_DEFAULTS = { quest = true, miniquest = true }

-- A category added to the data later starts included: an extra icon is safer than
-- a missing one.
local NEW_CATEGORY_DEFAULT = true

-- A keybind is up to two distinct key codes (PrettyUI KeybindField's own limit).
local function isBinding(value)
    if type(value) ~= "table" or #value > 2 then
        return false
    end

    local seen = {}

    for index, key in pairs(value) do
        if math.type(index) ~= "integer" or index < 1 or index > #value then
            return false
        end

        if math.type(key) ~= "integer" or key < 0 or seen[key] then
            return false
        end

        seen[key] = true
    end

    return true
end

-- A saved quest box spot: two whole, finite numbers. Off-screen values are fine here
-- (the window may be resized later); the tooltip moves itself back on screen.
local function isSpot(value)
    if type(value) ~= "table" then
        return false
    end

    for _, field in ipairs({ "x", "y" }) do
        local number = value[field]

        if type(number) ~= "number" or number ~= number or number == math.huge or number == -math.huge then
            return false
        end
    end

    return true
end

local function copyList(list)
    local result = {}

    for index, value in ipairs(list) do
        result[index] = value
    end

    return result
end

-- db: PersistentDB (a fake in tests). categories: QuestData.CATEGORIES.
function Preferences.new(db, categories)
    local self = {}

    -- Builds clean values from whatever was saved (or nothing).
    local function recover(saved)
        if type(saved) ~= "table" then
            saved = {}
        end

        local values = {
            enabled = true,
            key = {},
            filter = {},
        }

        if type(saved.enabled) == "boolean" then
            values.enabled = saved.enabled
        end

        if isBinding(saved.key) then
            values.key = copyList(saved.key)
        end

        if isSpot(saved.box) then
            values.box = { x = math.floor(saved.box.x), y = math.floor(saved.box.y) }
        end

        local savedFilter = type(saved.filter) == "table" and saved.filter or {}

        for _, category in ipairs(categories) do
            local default = FILTER_DEFAULTS[category]

            if default == nil then
                default = NEW_CATEGORY_DEFAULT
            end

            if type(savedFilter[category]) == "boolean" then
                values.filter[category] = savedFilter[category]
            else
                values.filter[category] = default
            end
        end

        return values
    end

    local ok, saved = pcall(function()
        return db:GetStructuredData(Preferences.STORAGE_KEY)
    end)

    if not ok then
        Log.error("couldn't read saved settings, using defaults:", saved)
        saved = nil
    end

    local values = recover(saved)

    -- Writes the whole record. A failed save keeps the change for this session.
    local function save()
        local written, result = pcall(function()
            return db:SetStructuredData(Preferences.STORAGE_KEY, {
                enabled = values.enabled,
                key = copyList(values.key),
                filter = values.filter,
                box = values.box and { x = values.box.x, y = values.box.y } or nil,
            })
        end)

        if not written or result ~= true then
            Log.error("couldn't save settings for next time:", tostring(result))
            return false
        end

        return true
    end

    function self:isEnabled()
        return values.enabled
    end

    -- Returns true if the value changed (and was saved).
    function self:setEnabled(enabled)
        if values.enabled == enabled then
            return false
        end

        values.enabled = enabled
        save()

        return true
    end

    function self:getKey()
        return copyList(values.key)
    end

    function self:setKey(binding)
        if not isBinding(binding) then
            return false
        end

        values.key = copyList(binding)
        save()

        return true
    end

    -- Where the quest box goes: { x, y } (its top-left corner), or nil for the
    -- default spot. Callers get a copy.
    function self:getBox()
        if values.box == nil then
            return nil
        end

        return { x = values.box.x, y = values.box.y }
    end

    -- Saves a new quest box spot. Returns false for a value that isn't one.
    function self:setBox(x, y)
        if not isSpot({ x = x, y = y }) then
            return false
        end

        values.box = { x = math.floor(x), y = math.floor(y) }
        save()

        return true
    end

    -- The filter as { category = bool }. Callers get a copy.
    function self:getFilter()
        local copy = {}

        for category, included in pairs(values.filter) do
            copy[category] = included
        end

        return copy
    end

    -- Turns one quest type on or off. Unknown types are refused, so a stale caller
    -- can't sneak an extra key into the saved record.
    -- Returns true if the value changed (and was saved).
    function self:setFilter(category, included)
        if values.filter[category] == nil or type(included) ~= "boolean" then
            return false
        end

        if values.filter[category] == included then
            return false
        end

        values.filter[category] = included
        save()

        return true
    end

    return self
end

return Preferences
