-- Reads the shop screen: which item each stock slot component shows, cross-checked
-- against the inventory behind it.
--
-- Client facts (design doc, Technical Plan §0): shop slots are interface 1265
-- (SHOP_MAIN), static component 24 in the default (icon) display mode, one dynamic
-- child per slot with dynamicID = slot - 1, and associatedObjectID is the item. M0
-- found the general store's stock in inventory 24 (GENERALSHOP5); in M4 a herblore
-- shop's stock was inventory 635, and the Sell tab showed the backpack (93) in the
-- same component.
--
-- Unlike the backpack and bank, the stock inventory differs from shop to shop, and
-- the Buy and Sell tabs show different inventories in the same components. So this
-- adapter:
--   * remembers which inventories the server has sent or updated (markers pass every
--     inventory event to noteInventory), and
--   * on each read, uses the one inventory whose items match what the components show
--     exactly, both ways: every filled inventory slot shows its item, and no
--     component shows an item the inventory doesn't have there.
-- If none matches, the read is "unreliable" and the shop gets no new icons.
--
-- Other display modes ("full name" in the shop's Item display mode) draw the slots
-- in another component of 1265. When 1265:24 isn't showing but a shop stock list is
-- live, the adapter looks through 1265's static components for a visible one whose
-- children match a remembered inventory the same exact way, and remembers it. The
-- exact match is what makes the search safe.
--
-- A Buy/Sell tab switch changes what the components show with no inventory event,
-- and the game rebuilds the slots on every stock change, deleting our icons. So the
-- adapter offers signature(), a cheap checksum markers polls every few frames while
-- the shop is open; a full read only happens when it changes.
--
-- Not stateless like the other adapters: it owns the inventory ids it has seen and
-- the slot components it has found, so each plugin start makes its own (Shop.new()).

local SlotScreen = require("src/screens/slot_screen")
local Log = require("src/log")

local Shop = {}

local INTERFACE_ID = 1265
local DEFAULT_STATIC_ID = 24

-- The bank's empty-slot object (M0). Not expected in a shop, but if a shop draws its
-- empty slots the same way, they mustn't count as items.
local EMPTY_SLOT_OBJECT = 48447

-- Inventory ids remembered at most. The newest are kept; a shop's stock arrives when
-- the shop opens, so it is always among them.
local MAX_REMEMBERED = 16

-- The search for slots in another display mode: static ids 0 to this, at most once
-- every SEARCH_EVERY reads (about 3 s at one read per server tick).
local SEARCH_LAST_STATIC = 400
local SEARCH_EVERY = 5

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
    local lastSearchSummary = nil

    local function inventoryId(name)
        return Log.field(Log.field(config.Inv, name), "id")
    end

    -- Called by markers for every inventory event. The bank's inventory is never shop
    -- stock, and reading its 1920 slots every tick would be wasted work.
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

    -- Every remembered inventory can be on show, so an event on any of them makes the
    -- shop re-check.
    function self.inventoryIds()
        local ids = {}

        for _, invId in ipairs(remembered) do
            ids[invId] = true
        end

        -- The Sell tab shows the backpack.
        local backpackId = inventoryId("INV")

        if backpackId then
            ids[backpackId] = true
        end

        return ids
    end

    local function isVisible(component)
        return component ~= nil and Log.field(component, "visibleGlobal") == true
    end

    -- The first known slot component that's on screen, and its static id.
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

    -- Is a shop's stock list live (a remembered inventory that isn't the backpack)?
    local function stockSent()
        local backpackId = inventoryId("INV")

        for _, invId in ipairs(remembered) do
            if invId ~= backpackId and SlotScreen.findInventory(invId) then
                return true
            end
        end

        return false
    end

    -- Cheap check run every server tick: a known slot component is on screen, or the
    -- shop interface is loaded with stock sent (another display mode, still to find).
    function self.isOpen()
        if visibleContainer() then
            return true
        end

        return interfaceLoaded() and stockSent()
    end

    -- A cheap checksum of what the shop slots show, for markers to poll every few
    -- frames while the shop is open: the visible slot component, how many children it
    -- has (our icons count, so the game deleting them changes it) and their item ids
    -- in order. One pcall, one field read per child, no tables. A Buy/Sell tab switch,
    -- a restock or a rebuild changes it; markers then does a full read(). nil when no
    -- known slot component is on screen.
    local MODULUS = 2147483647

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

    -- The item each component shows, as { [dynamicID] = itemId }, empty ones left out.
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

    -- Compares one inventory's items with what the components show. Returns true, or
    -- false and how many filled slots matched plus the first difference.
    local function compare(items, count, shown)
        local matched = 0
        local problem = nil

        for slot = 1, count do
            local want = items[slot]
            local got = shown[slot - 1] or false

            if want ~= got then
                problem = problem or ("slot " .. slot .. " shows " .. tostring(got) .. ", inventory has " .. tostring(want))
            elseif want then
                matched = matched + 1
            end
        end

        for dynamicId, itemId in pairs(shown) do
            if dynamicId >= count then
                problem = problem or ("slot " .. (dynamicId + 1) .. " shows " .. itemId .. ", past the inventory's end")
            end
        end

        return problem == nil, matched, problem
    end

    -- The newest remembered inventory that matches `shown` exactly. Returns
    -- { inv, invId, items, count }, or nil plus how many were checked and the closest.
    local function findMatch(shown)
        local checked = 0
        local best = { matched = -1 }

        -- Newest first: the stock of the shop just opened is the latest one sent. The
        -- backpack always goes last, even if no event for it came yet (the Sell tab
        -- shows it; after a reload it was never matched in game, 2026-11-16).
        local candidates = {}
        local backpackId = inventoryId("INV")

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

            if items then
                checked = checked + 1

                local same, matched, problem = compare(items, count, shown)

                if same then
                    return { inv = inv, invId = invId, items = items, count = count }
                end

                if matched > best.matched then
                    best = { matched = matched, invId = invId, problem = problem }
                end
            end
        end

        return nil, checked, best
    end

    -- Looks through 1265's static components for visible slots that match a stock
    -- list. Remembers and returns the first one found.
    local function search()
        local withItems = {}

        for staticId = 0, SEARCH_LAST_STATIC do
            local container = SlotScreen.findContainer(INTERFACE_ID, staticId)

            if isVisible(container) then
                local byDynamic = SlotScreen.componentsByDynamicId(container)
                local shown = byDynamic and shownItems(byDynamic)

                if shown and next(shown) ~= nil then
                    local found = findMatch(shown)
                    local shownCount = 0

                    for _ in pairs(shown) do
                        shownCount = shownCount + 1
                    end

                    withItems[#withItems + 1] = staticId .. " (" .. shownCount .. " items)"

                    if found then
                        knownStatics[#knownStatics + 1] = staticId
                        Log.write("Shop: found shop slots at " .. INTERFACE_ID .. ":" .. staticId
                            .. " (inventory " .. found.invId .. ")")
                        lastSearchSummary = nil
                        return container, staticId
                    end
                end
            end
        end

        -- Only logged when it changes, for the M4 in-game check.
        local summary = "Shop: no matching slots in " .. INTERFACE_ID .. "; visible components with items: "
            .. (#withItems > 0 and table.concat(withItems, ", ") or "none")

        if summary ~= lastSearchSummary then
            lastSearchSummary = summary
            Log.write(summary)
        end

        return nil
    end

    -- Reads the screen. Same results as slot_screen.lua's read, plus `detail` for the
    -- status line and `present` (see SlotScreen.componentsByDynamicId).
    function self.read()
        local container, staticId = visibleContainer()

        if container == nil then
            if not (interfaceLoaded() and stockSent()) then
                return { state = "ok", open = false, reason = "no shop on screen" }
            end

            -- The same reason whether or not a search ran, so the status line (and
            -- console) doesn't change every few ticks.
            readsSinceSearch = readsSinceSearch + 1

            if readsSinceSearch >= SEARCH_EVERY then
                readsSinceSearch = 0
                container, staticId = search()
            end

            if container == nil then
                -- retry: the slots may still be found (another display mode), so read again
                -- next tick even though nothing changed.
                return { state = "ok", open = false, retry = true, reason = "no shop slots found on screen" }
            end
        end

        local containerName = INTERFACE_ID .. ":" .. staticId
        local byDynamic, present = SlotScreen.componentsByDynamicId(container)

        if byDynamic == nil then
            return { state = "unreliable", reason = "couldn't list the shop slots at " .. containerName }
        end

        if next(byDynamic) == nil then
            return { state = "ok", open = false, reason = "slot container " .. containerName .. " has no slots" }
        end

        local shown = shownItems(byDynamic)
        local slotCount, shownCount = 0, 0

        for _ in pairs(byDynamic) do
            slotCount = slotCount + 1
        end

        for _ in pairs(shown) do
            shownCount = shownCount + 1
        end

        -- For the status line, so the console shows what the shop slots held when the
        -- marked count changes (M4 in-game debugging).
        local function detail(invId)
            -- Sorted, so the line only changes when the set does, not on each event.
            local seen = { table.unpack(remembered) }
            table.sort(seen)

            return containerName .. ", " .. slotCount .. " children, " .. shownCount .. " showing an item, inv "
                .. tostring(invId) .. ", seen invs " .. table.concat(seen, " ")
        end

        -- Nothing on show (an empty tab, or the stock not drawn yet): nothing to mark.
        if next(shown) == nil then
            return { state = "ok", open = true, slots = {}, present = present, containerKey = staticId, detail = detail(nil) }
        end

        local found, checked, best = findMatch(shown)

        if found == nil then
            if not stockSent() then
                return { state = "unreliable", reason = "no stock inventory seen yet (reopen the shop)" }
            end

            return {
                state = "unreliable",
                reason = "no inventory matches the shop slots at " .. containerName .. " (" .. checked
                    .. " checked; closest, inv " .. tostring(best.invId) .. ": " .. tostring(best.problem) .. ")",
            }
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
            detail = detail(found.invId),
        }
    end

    return self
end

return Shop
