-- Builds a screen adapter for a grid of item slots backed by one inventory (the
-- backpack, the bank, the bank's backpack panel). Slot N is dynamic child N - 1 of the
-- container, and its associatedObjectID is the item it shows.
--
-- A read only succeeds if every filled slot shows exactly the inventory's item;
-- otherwise it's "unreliable" and markers draw nothing new, since an icon on the
-- wrong item is worse than a missing one. Adapters are stateless. The helpers are
-- shared with shop.lua.

local Log = require("src/log")

local SlotScreen = {}

-- The item id in every slot of an inventory, as { [slot] = id or false }, plus the
-- slot count. nil if the read failed.
function SlotScreen.fingerprint(inv)
    local ok, slots = pcall(function()
        return inv:GetSlots()
    end)

    if not ok or type(slots) ~= "table" then
        return nil
    end

    local count = Log.field(inv, "slotCount") or #slots
    local items = {}

    for index = 1, count do
        local itemId = Log.field(Log.field(slots[index], "obj"), "id")

        if type(itemId) == "number" and itemId >= 0 then
            items[index] = itemId
        else
            items[index] = false
        end
    end

    return items, count
end

function SlotScreen.sameFingerprint(a, b, count)
    for index = 1, count do
        if a[index] ~= b[index] then
            return false
        end
    end

    return true
end

-- Identifies a component among its siblings: "categoryID:dynamicID".
function SlotScreen.childKey(component)
    local categoryId = Log.field(component, "categoryID")
    local dynamicId = Log.field(component, "dynamicID")

    if type(categoryId) == "number" and type(dynamicId) == "number" then
        return categoryId .. ":" .. dynamicId
    end

    return nil
end

-- Every slot component under a container by dynamicID, plus every child by its
-- childKey (our icons are children too; markers use it to spot the game deleting
-- them). Keys aren't unique: a game slot can get the key a deleted icon had.
-- nil if listing failed.
function SlotScreen.componentsByDynamicId(container)
    local byDynamic = {}
    local present = {}

    local ok = pcall(function()
        container:IterateDynamicComponents(function(child)
            local dynamicId = Log.field(child, "dynamicID")
            local key = SlotScreen.childKey(child)

            if key then
                present[key] = child
            end

            if type(dynamicId) == "number" and byDynamic[dynamicId] == nil then
                byDynamic[dynamicId] = child
            end

            -- false = keep iterating.
            return false
        end)
    end)

    if not ok then
        return nil
    end

    return byDynamic, present
end

-- The component at interfaceId:staticId, or nil if it isn't loaded.
function SlotScreen.findContainer(interfaceId, staticId)
    local ok, container = pcall(function()
        return ui.Interfaces:GetComponent(interfaceId, staticId)
    end)

    if ok then
        return container
    end

    return nil
end

-- The live inventory for a config.Inv entry or id, or nil until the server sends it.
function SlotScreen.findInventory(invConfigOrId)
    if invConfigOrId == nil then
        return nil
    end

    local ok, inv = pcall(function()
        return Inventory.Find(invConfigOrId)
    end)

    if not ok or inv == nil or Log.field(inv, "isValid") == false then
        return nil
    end

    return inv
end

-- spec:
--   name         adapter name, used in error logs
--   label        lower-case word used in read reasons ("bank slot 3 ...")
--   inventory    config.Inv field name ("INV", "BANK")
--   interfaceId  interface holding the slot container
--   staticId     static id of the slot container
function SlotScreen.new(spec)
    local Screen = {}

    Screen.NAME = spec.name

    -- Markers watch this interface to notice it unloading under the icons.
    Screen.INTERFACE_ID = spec.interfaceId

    local function inventoryConfig()
        return Log.field(config.Inv, spec.inventory)
    end

    -- Inventory ids whose events should make this screen re-check: { [id] = true }.
    function Screen.inventoryIds()
        local ids = {}
        local invId = Log.field(inventoryConfig(), "id")

        if invId then
            ids[invId] = true
        end

        return ids
    end

    local function findInventory()
        return SlotScreen.findInventory(inventoryConfig())
    end

    local function findContainer()
        return SlotScreen.findContainer(spec.interfaceId, spec.staticId)
    end

    -- Cheap check run every server tick. Needs the container visible, not just
    -- loaded: interface 517 stays loaded after the bank closes.
    function Screen.isOpen()
        if findInventory() == nil then
            return false
        end

        local container = findContainer()

        return container ~= nil and Log.field(container, "visibleGlobal") == true
    end

    -- Returns one of:
    --   { state = "ok", open = false, reason }                screen closed: no icons
    --   { state = "ok", open = true, slots = { { slot, itemId, component }, ... }, present }
    --   { state = "unreliable", reason }                      draw nothing new here
    -- `slots` lists filled slots only (placeholders included).
    function Screen.read()
        local inv = findInventory()
        local container = findContainer()

        if inv == nil then
            return { state = "ok", open = false, reason = "inventory not sent" }
        end

        if container == nil or Log.field(container, "visibleGlobal") ~= true then
            return { state = "ok", open = false, reason = "slot container not showing" }
        end

        local before, count = SlotScreen.fingerprint(inv)

        if before == nil then
            return { state = "unreliable", reason = "couldn't read the " .. spec.label .. " inventory" }
        end

        local byDynamic, present = SlotScreen.componentsByDynamicId(container)

        if byDynamic == nil then
            return { state = "unreliable", reason = "couldn't list the " .. spec.label .. " slots" }
        end

        -- At a shop with the bank closed, 517:15 reads as visible with no children:
        -- that's closed, not unreadable.
        if next(byDynamic) == nil then
            return { state = "ok", open = false, reason = "slot container has no slots" }
        end

        local slots = {}

        for slot = 1, count do
            local itemId = before[slot]

            if itemId then
                local component = byDynamic[slot - 1]

                if component == nil or Log.field(component, "associatedObjectID") ~= itemId then
                    return { state = "unreliable", reason = spec.label .. " slot " .. slot .. " doesn't match" }
                end

                slots[#slots + 1] = { slot = slot, itemId = itemId, component = component }
            end
        end

        -- A change mid-read could mix two states; the change also set the dirty flag,
        -- so the next check reads again.
        local after = SlotScreen.fingerprint(inv)

        if after == nil or not SlotScreen.sameFingerprint(before, after, count) then
            return { state = "unreliable", reason = "the " .. spec.label .. " changed while it was being read" }
        end

        return { state = "ok", open = true, slots = slots, present = present }
    end

    return Screen
end

return SlotScreen
