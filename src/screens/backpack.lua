-- Reads the backpack screen: which item each slot component shows, cross-checked
-- against the backpack inventory. Stateless: every call reads fresh, owns nothing.
--
-- Client facts from the M0 probe (design doc, Technical Plan §0):
--   * the backpack is inventory INV (93), 28 slots;
--   * its slots are drawn by interface 1473 (TOPLEVEL_V2_INVENTORY), static
--     component 5, one dynamic child per slot with dynamicID = slot - 1;
--   * each slot component's associatedObjectID is the item it shows;
--   * an empty inventory slot comes back from GetSlots() as object id -1.
--
-- Matching is by identity, never by counting (design §4): every filled inventory slot
-- must have a component showing that same item, and the inventory must not change
-- while we read it. Anything else is "unreliable", and the marker code then draws no
-- icons on this screen rather than risk one on the wrong item.

local Log = require("src/log")

local Backpack = {}

Backpack.NAME = "Backpack"

-- The interface the icons live in. Markers use it to notice the interface unloading.
Backpack.INTERFACE_ID = 1473
local CONTAINER_STATIC_ID = 5

-- The backpack inventory config, or nil if the client doesn't have it.
local function inventoryConfig()
    return Log.field(config.Inv, "INV")
end

-- Inventory ids whose events should make this screen re-check: { [93] = true }.
function Backpack.inventoryIds()
    local ids = {}
    local invId = Log.field(inventoryConfig(), "id")

    if invId then
        ids[invId] = true
    end

    return ids
end

-- The live inventory, or nil while the server hasn't sent it.
local function findInventory()
    local invConfig = inventoryConfig()

    if invConfig == nil then
        return nil
    end

    local ok, inv = pcall(function()
        return Inventory.Find(invConfig)
    end)

    if not ok or inv == nil or Log.field(inv, "isValid") == false then
        return nil
    end

    return inv
end

-- The component holding the 28 slot components, or nil if it isn't loaded.
local function findContainer()
    local ok, container = pcall(function()
        return ui.Interfaces:GetComponent(Backpack.INTERFACE_ID, CONTAINER_STATIC_ID)
    end)

    if ok then
        return container
    end

    return nil
end

-- Cheap check run every server tick: is the backpack on screen? "Open" needs both
-- the inventory and a visible slot container (M0: an interface can stay loaded
-- after its screen closes, so loaded alone doesn't mean open).
function Backpack.isOpen()
    if findInventory() == nil then
        return false
    end

    local container = findContainer()

    return container ~= nil and Log.field(container, "visibleGlobal") == true
end

-- The item id in every slot, as { [slot] = id or false }, plus how many slots there
-- are. Returns nil if the read failed.
local function fingerprint(inv)
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

local function sameFingerprint(a, b, count)
    for index = 1, count do
        if a[index] ~= b[index] then
            return false
        end
    end

    return true
end

-- Every slot component under the container, by dynamicID.
local function componentsByDynamicId(container)
    local byDynamic = {}

    local ok = pcall(function()
        container:IterateDynamicComponents(function(child)
            local dynamicId = Log.field(child, "dynamicID")

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

    return byDynamic
end

-- Reads the screen. Returns one of:
--   { state = "ok", open = false, reason = "..." }          screen closed: no icons
--   { state = "ok", open = true, slots = { { slot, itemId, component }, ... } }
--   { state = "unreliable", reason = "..." }               draw nothing here
-- `slots` only lists filled slots.
function Backpack.read()
    local inv = findInventory()
    local container = findContainer()

    -- Closed. The reason only goes into the status line and log, to tell "not sent"
    -- apart from "not loaded" and "hidden" when something looks wrong.
    if inv == nil then
        return { state = "ok", open = false, reason = "inventory not sent" }
    end

    if container == nil then
        return { state = "ok", open = false, reason = "slot container 1473:5 not loaded" }
    end

    local visible = Log.field(container, "visibleGlobal")

    if visible ~= true then
        return { state = "ok", open = false, reason = "slot container hidden (visibleGlobal " .. tostring(visible) .. ")" }
    end

    local before, count = fingerprint(inv)

    if before == nil then
        return { state = "unreliable", reason = "couldn't read the backpack inventory" }
    end

    local byDynamic = componentsByDynamicId(container)

    if byDynamic == nil then
        return { state = "unreliable", reason = "couldn't list the backpack slots" }
    end

    local slots = {}

    for slot = 1, count do
        local itemId = before[slot]

        if itemId then
            local component = byDynamic[slot - 1]
            local shown = Log.field(component, "associatedObjectID")

            -- The slot must show exactly the item the inventory says it holds.
            if component == nil then
                return { state = "unreliable", reason = "backpack slot " .. slot .. " has no component" }
            end

            if shown ~= itemId then
                return {
                    state = "unreliable",
                    reason = "backpack slot " .. slot .. " shows item " .. tostring(shown) .. ", inventory has " .. itemId,
                }
            end

            slots[#slots + 1] = { slot = slot, itemId = itemId, component = component }
        end
    end

    -- If the backpack changed while we were reading, the pairs above may be mixed
    -- from two states. Don't draw from it; the change also set the dirty flag, so
    -- the next check reads again.
    local after = fingerprint(inv)

    if after == nil or not sameFingerprint(before, after, count) then
        return { state = "unreliable", reason = "the backpack changed while it was being read" }
    end

    return { state = "ok", open = true, slots = slots }
end

return Backpack
