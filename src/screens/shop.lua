-- Screen adapter for shops (interface 1265, slots under static component 24). Each
-- shop has its own stock inventory, and the Buy and Sell tabs share the same slots,
-- so there's no fixed inventory to read. Instead it remembers the inventories the
-- server sends and uses the one that matches the slots exactly.
--
-- Owns the remembered inventory ids and the slot containers it has found, so each
-- plugin start makes its own (Shop.new()).

local SlotScreen = require("src/screens/slot_screen")
local Log = require("src/log")

local Shop = {}

local INTERFACE_ID = 1265
local DEFAULT_STATIC_ID = 24

-- The bank's empty-slot object; never counted as an item if a shop draws it too.
local EMPTY_SLOT_OBJECT = 48447

-- Inventory ids remembered at most, newest kept. A shop's stock arrives as it opens.
local MAX_REMEMBERED = 16

-- The display-mode search covers static ids 0..SEARCH_LAST_STATIC, at most once every
-- SEARCH_EVERY reads (~3 s).
local SEARCH_LAST_STATIC = 400
local SEARCH_EVERY = 5

-- Keeps the signature inside an integer range.
local MODULUS = 2147483647

function Shop.new()
    local self = {
        NAME = "Shop",
        INTERFACE_ID = INTERFACE_ID,
    }

    -- Inventory ids seen in events, oldest first.
    local remembered = {}

    -- Static ids of 1265 known to hold shop slots, the default first.
    local knownStatics = { DEFAULT_STATIC_ID }
    local readsSinceSearch = SEARCH_EVERY

    local function inventoryId(name)
        return Log.field(Log.field(config.Inv, name), "id")
    end

    -- Called for every inventory event. The bank is never shop stock, and matching
    -- against its 1920 slots would be wasted work.
    function self.noteInventory(invId)
        if type(invId) ~= "number" or invId == inventoryId("BANK") then
            return
        end

        for index, known in ipairs(remembered) do
            if known == invId then
                table.remove(remembered, index)
                break
            end
        end

        remembered[#remembered + 1] = invId

        if #remembered > MAX_REMEMBERED then
            table.remove(remembered, 1)
        end
    end

    -- Any remembered inventory may be on show, plus the backpack (the Sell tab).
    function self.inventoryIds()
        local ids = {}

        for _, invId in ipairs(remembered) do
            ids[invId] = true
        end

        local backpackId = inventoryId("INV")

        if backpackId then
            ids[backpackId] = true
        end

        return ids
    end

    local function isVisible(component)
        return component ~= nil and Log.field(component, "visibleGlobal") == true
    end

    -- The first known slot component on screen, and its static id.
    local function visibleContainer()
        for _, staticId in ipairs(knownStatics) do
            local container = SlotScreen.findContainer(INTERFACE_ID, staticId)

            if isVisible(container) then
                return container, staticId
            end
        end

        return nil
    end

    local function interfaceLoaded()
        local ok, found = pcall(function()
            return ui.Interfaces:GetInterface(INTERFACE_ID)
        end)

        return ok and found ~= nil
    end

    -- Is a remembered inventory other than the backpack live?
    local function stockSent()
        local backpackId = inventoryId("INV")

        for _, invId in ipairs(remembered) do
            if invId ~= backpackId and SlotScreen.findInventory(invId) then
                return true
            end
        end

        return false
    end

    -- A known slot component is on screen, or the interface is loaded with stock
    -- sent (a display mode still to be found).
    function self.isOpen()
        if visibleContainer() then
            return true
        end

        return interfaceLoaded() and stockSent()
    end

    -- A cheap checksum of the visible slot component: its static id, child count (our
    -- icons included, so the game deleting them changes it) and item ids in order.
    -- One field read per child, no tables. nil when no known container is visible.
    function self.signature()
        local container, staticId = visibleContainer()

        if container == nil then
            return nil
        end

        local count, sum = 0, staticId

        local ok = pcall(function()
            container:IterateDynamicComponents(function(child)
                local itemId = child.associatedObjectID

                count = count + 1
                sum = (sum * 31 + (type(itemId) == "number" and itemId + 2 or 0)) % MODULUS

                return false
            end)
        end)

        if not ok then
            return nil
        end

        return count * MODULUS + sum
    end

    -- { [dynamicID] = itemId } for every component showing an item.
    local function shownItems(byDynamic)
        local shown = {}

        for dynamicId, component in pairs(byDynamic) do
            local itemId = Log.field(component, "associatedObjectID")

            if type(itemId) == "number" and itemId >= 0 and itemId ~= EMPTY_SLOT_OBJECT then
                shown[dynamicId] = itemId
            end
        end

        return shown
    end

    -- True if the inventory's items and the shown items agree exactly, both ways.
    local function matches(items, count, shown)
        for slot = 1, count do
            if items[slot] ~= (shown[slot - 1] or false) then
                return false
            end
        end

        for dynamicId in pairs(shown) do
            if dynamicId >= count then
                return false
            end
        end

        return true
    end

    -- The newest remembered inventory matching `shown`, as { inv, invId, items, count }.
    -- The backpack is tried last, even with no event for it yet (after a reload).
    local function findMatch(shown)
        local backpackId = inventoryId("INV")
        local candidates = {}

        for index = #remembered, 1, -1 do
            if remembered[index] ~= backpackId then
                candidates[#candidates + 1] = remembered[index]
            end
        end

        candidates[#candidates + 1] = backpackId

        for _, invId in ipairs(candidates) do
            local inv = SlotScreen.findInventory(invId)
            local items, count

            if inv then
                items, count = SlotScreen.fingerprint(inv)
            end

            if items and matches(items, count, shown) then
                return { inv = inv, invId = invId, items = items, count = count }
            end
        end

        return nil
    end

    -- Other display modes ("full name") draw the slots in a different component, so
    -- look through 1265 for visible slots that match a stock list and remember them.
    -- Requiring an exact match is what makes guessing at static ids safe.
    local function search()
        for staticId = 0, SEARCH_LAST_STATIC do
            local container = SlotScreen.findContainer(INTERFACE_ID, staticId)

            if isVisible(container) then
                local byDynamic = SlotScreen.componentsByDynamicId(container)
                local shown = byDynamic and shownItems(byDynamic)

                if shown and next(shown) ~= nil and findMatch(shown) then
                    knownStatics[#knownStatics + 1] = staticId
                    return container, staticId
                end
            end
        end

        return nil
    end

    -- Same results as slot_screen.lua's read, plus `containerKey` (the static id read),
    -- `retry` while a display mode is still being searched for, `inventoryId` (which
    -- inventory matched) and `buying` (true for shop stock, false for the Sell tab).
    function self.read()
        local container, staticId = visibleContainer()

        if container == nil then
            if not (interfaceLoaded() and stockSent()) then
                return { state = "ok", open = false, reason = "no shop on screen" }
            end

            readsSinceSearch = readsSinceSearch + 1

            if readsSinceSearch >= SEARCH_EVERY then
                readsSinceSearch = 0
                container, staticId = search()
            end

            if container == nil then
                return { state = "ok", open = false, retry = true, reason = "no shop slots found" }
            end
        end

        local byDynamic, present = SlotScreen.componentsByDynamicId(container)

        if byDynamic == nil then
            return { state = "unreliable", reason = "couldn't list the shop slots" }
        end

        if next(byDynamic) == nil then
            return { state = "ok", open = false, reason = "slot container has no slots" }
        end

        local shown = shownItems(byDynamic)

        -- An empty tab, or stock not drawn yet: nothing to mark.
        if next(shown) == nil then
            return { state = "ok", open = true, slots = {}, present = present, containerKey = staticId }
        end

        local found = findMatch(shown)

        if found == nil then
            return { state = "unreliable", reason = "no inventory matches the shop slots" }
        end

        -- If the inventory changed while we were reading, don't draw from it.
        local after = SlotScreen.fingerprint(found.inv)

        if after == nil or not SlotScreen.sameFingerprint(found.items, after, found.count) then
            return { state = "unreliable", reason = "the shop changed while it was being read" }
        end

        local slots = {}

        for slot = 1, found.count do
            if found.items[slot] then
                slots[#slots + 1] = { slot = slot, itemId = found.items[slot], component = byDynamic[slot - 1] }
            end
        end

        return {
            state = "ok",
            open = true,
            slots = slots,
            present = present,
            containerKey = staticId,
            inventoryId = found.invId,

            -- Shop stock (a Buy tab) rather than the backpack (the Sell tab).
            buying = found.invId ~= inventoryId("INV"),
        }
    end

    return self
end

return Shop
