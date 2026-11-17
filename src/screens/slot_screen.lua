-- Builds a screen adapter for one grid of item slots: which item each slot component
-- shows, cross-checked against the inventory behind it. Every adapter is stateless:
-- each call reads fresh and owns nothing.
--
-- The backpack, the bank and the backpack panel inside the bank all work the same way
-- (design doc, Technical Plan §0 and §4); only these facts differ:
--   * the inventory (config.Inv name),
--   * the interface and static component holding the slots,
--   * one dynamic child per slot with dynamicID = slot - 1,
--   * each slot component's associatedObjectID is the item it shows.
-- An empty inventory slot comes back from GetSlots() as object id -1. A bank
-- placeholder is the real item id with count 0, in both the inventory and the
-- component, so it reads (and is marked) like the item it holds a place for.
--
-- Matching is by identity, never by counting (design §4): every filled inventory slot
-- must have a component showing that same item, and the inventory must not change
-- while we read it. Anything else is "unreliable", and the marker code then draws no
-- new icons on this screen rather than risk one on the wrong item.
--
-- The helpers below are also used by shop.lua, whose inventory isn't fixed.

local Log = require("src/log")

local SlotScreen = {}

-- The item id in every slot of an inventory, as { [slot] = id or false }, plus how
-- many slots there are. Returns nil if the read failed.
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
        local slot = slots[index]
        local itemId = Log.field(Log.field(slot, "obj"), "id")

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

-- The key markers use to find one of its icons among a container's children.
function SlotScreen.childKey(component)
    local categoryId = Log.field(component, "categoryID")
    local dynamicId = Log.field(component, "dynamicID")

    if type(categoryId) == "number" and type(dynamicId) == "number" then
        return categoryId .. ":" .. dynamicId
    end

    return nil
end

-- Every slot component under a container, by dynamicID, plus the set of every
-- child's childKey (our own icons are children of the same container; markers uses
-- this to notice the game deleting them). nil if listing failed.
function SlotScreen.componentsByDynamicId(container)
    local byDynamic = {}
    local present = {}

    local ok = pcall(function()
        container:IterateDynamicComponents(function(child)
            local dynamicId = Log.field(child, "dynamicID")
            local key = SlotScreen.childKey(child)

            if key then
                present[key] = true
            end

            if type(dynamicId) == "number" and byDynamic[dynamicId] == nil then
                byDynamic[dynamicId] = child
            end

            -- false = keep going through the children.
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

-- The live inventory for a config.Inv entry or an inventory id, or nil while the
-- server hasn't sent it.
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
--   name         shown to the player ("Couldn't read <name>") and in the log
--   label        lower-case word for read problems ("bank slot 3 ...")
--   inventory    config.Inv field name ("INV", "BANK")
--   interfaceId  interface holding the slot container
--   staticId     static id of the slot container
function SlotScreen.new(spec)
    local Screen = {}

    Screen.NAME = spec.name

    -- The interface the icons live in. Markers use it to notice the interface unloading.
    Screen.INTERFACE_ID = spec.interfaceId

    local containerName = spec.interfaceId .. ":" .. spec.staticId

    -- The inventory config, or nil if the client doesn't have it.
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

    -- Cheap check run every server tick: is the screen showing? "Open" needs both the
    -- inventory and a visible slot container (M0: the bank interface can stay loaded
    -- after the bank closes, so loaded alone doesn't mean open).
    function Screen.isOpen()
        if findInventory() == nil then
            return false
        end

        local container = findContainer()

        return container ~= nil and Log.field(container, "visibleGlobal") == true
    end

    -- Reads the screen. Returns one of:
    --   { state = "ok", open = false, reason = "..." }          screen closed: no icons
    --   { state = "ok", open = true, slots = { { slot, itemId, component }, ... } }
    --   { state = "unreliable", reason = "..." }               draw nothing new here
    -- `slots` only lists filled slots (placeholders included).
    function Screen.read()
        local inv = findInventory()
        local container = findContainer()

        -- Closed. The reason only goes into the status line and log, to tell "not
        -- sent" apart from "not loaded" and "hidden" when something looks wrong.
        if inv == nil then
            return { state = "ok", open = false, reason = "inventory not sent" }
        end

        if container == nil then
            return { state = "ok", open = false, reason = "slot container " .. containerName .. " not loaded" }
        end

        local visible = Log.field(container, "visibleGlobal")

        if visible ~= true then
            return { state = "ok", open = false, reason = "slot container hidden (visibleGlobal " .. tostring(visible) .. ")" }
        end

        local before, count = SlotScreen.fingerprint(inv)

        if before == nil then
            return { state = "unreliable", reason = "couldn't read the " .. spec.label .. " inventory" }
        end

        local byDynamic, present = SlotScreen.componentsByDynamicId(container)

        if byDynamic == nil then
            return { state = "unreliable", reason = "couldn't list the " .. spec.label .. " slots" }
        end

        -- Seen in game (2026-11-16): at a shop, with the bank closed, 517:15 read as
        -- visible but had no slot components. A container with no slots isn't showing
        -- this screen, so it counts as closed rather than unreadable.
        if next(byDynamic) == nil then
            return { state = "ok", open = false, reason = "slot container " .. containerName .. " has no slots" }
        end

        local slots = {}

        for slot = 1, count do
            local itemId = before[slot]

            if itemId then
                local component = byDynamic[slot - 1]

                -- The slot must show exactly the item the inventory says it holds.
                if component == nil then
                    return { state = "unreliable", reason = spec.label .. " slot " .. slot .. " has no component" }
                end

                local shown = Log.field(component, "associatedObjectID")

                if shown ~= itemId then
                    return {
                        state = "unreliable",
                        reason = spec.label .. " slot " .. slot .. " shows item " .. tostring(shown)
                            .. ", inventory has " .. itemId,
                    }
                end

                slots[#slots + 1] = { slot = slot, itemId = itemId, component = component }
            end
        end

        -- If the inventory changed while we were reading, the pairs above may be mixed
        -- from two states. Don't draw from it; the change also set the dirty flag, so
        -- the next check reads again.
        local after = SlotScreen.fingerprint(inv)

        if after == nil or not SlotScreen.sameFingerprint(before, after, count) then
            return { state = "unreliable", reason = "the " .. spec.label .. " changed while it was being read" }
        end

        return { state = "ok", open = true, slots = slots, present = present }
    end

    return Screen
end

return SlotScreen
