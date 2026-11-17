-- Puts quest icons on item slots and keeps them right. Events mark screens dirty, a
-- ServerLogic check re-reads the dirty ones and adds or removes icons, and a Draw
-- pass keeps each icon on its slot. Icons are keyed by (screen, slot).
--
-- Owns every icon and its tooltip, plus the Inventory*, ServerLogic, GameStateChanged
-- and Draw subscriptions. With markers off it owns nothing.

local ItemTooltip = require("src/ui/item_tooltip")
local SlotScreen = require("src/screens/slot_screen")
local Log = require("src/log")

local Markers = {}

local SUBSCRIPTION = "quest-item-marker-markers"
local SYNC_SUBSCRIPTION = "quest-item-marker-sync"

-- 12 px, top-right corner of the slot.
local ICON_SIZE = 12

-- Most icons alive at once across all screens; covers a full 1920-slot bank.
local ICON_CAP = 2000

-- Polled screens compare their signature every this many frames (~50 ms).
local POLL_FRAMES = 3

-- After an inventory event for a polled screen that isn't open yet, check this many
-- frames for it appearing (a shop window shows a moment after its stock arrives).
local OPEN_WAIT_FRAMES = 60

-- options:
--   screens        list of screen adapters (src/screens/*.lua)
--   questStatus    QuestStatus (only .ready and :refreshUnwatched are used)
--   iconSprite     the quest icon sprite id
--   requiredItems  RequiredItems
--   boxPosition()  the saved tooltip spot { x, y }, or nil for the default
function Markers.new(options)
    local self = {
        enabled = false,
        iconCount = 0,
    }

    local required = options.requiredItems
    local screens = {}

    for _, adapter in ipairs(options.screens) do
        screens[#screens + 1] = {
            adapter = adapter,
            name = adapter.NAME,
            interfaceId = adapter.INTERFACE_ID,

            -- [slot] = { itemId, icon, tooltip, component, text, key, containerKey }
            icons = {},
            dirty = true,

            -- true / false once checked; nil until the first check after turning on.
            open = nil,

            polls = adapter.signature ~= nil,
            signature = nil,
            readNextFrame = false,
            openWaitFrames = 0,
        }
    end

    local subscribed = false
    local syncing = false
    local serverTick = 0
    local frameCount = 0
    local syncFailed = false

    -- The flat list the Draw pass walks; rebuilt only when icons change.
    local syncList = {}
    local syncListStale = false

    -- True once one of our icons has been seen among its container's children. Until
    -- then, an icon missing from that list isn't taken as deleted.
    local iconsListed = false

    -- Item names for "+ partner" tooltip lines; false = couldn't read.
    local itemNames = {}

    local startSync, stopSync

    local function nameOf(itemId)
        local name = itemNames[itemId]

        if name == nil then
            name = Log.field(Log.safe("item name", function()
                return config.Obj.FromID(itemId)
            end), "name") or false
            itemNames[itemId] = name
        end

        return name or nil
    end

    local function interfaceLoaded(screen)
        local ok, found = pcall(function()
            return ui.Interfaces:GetInterface(screen.interfaceId)
        end)

        return ok and found ~= nil
    end

    local function markAll()
        for _, screen in ipairs(screens) do
            screen.dirty = true
        end
    end

    -- Tooltip first: its Destroy() unhooks the hover hooks, so none outlives the icon.
    local function destroyIcon(record)
        Log.safe("remove tooltip", function()
            record.tooltip:Destroy()
        end)

        Log.safe("remove icon", function()
            record.icon:Destroy()
        end)

        self.iconCount = self.iconCount - 1
        syncListStale = true
    end

    -- For an icon the client already deleted: leave the dead handle alone, but still
    -- destroy the tooltip, which lives in another interface.
    local function forgetIcon(record)
        Log.safe("remove tooltip", function()
            record.tooltip:Destroy()
        end)

        self.iconCount = self.iconCount - 1
        syncListStale = true
    end

    -- Removes every icon on a screen. If its interface has unloaded, the icons went
    -- with it, and an old handle could now point at someone else's component.
    local function clearScreen(screen)
        if next(screen.icons) == nil then
            return
        end

        local loaded = interfaceLoaded(screen)

        for slot, record in pairs(screen.icons) do
            if loaded then
                destroyIcon(record)
            else
                forgetIcon(record)
            end

            screen.icons[slot] = nil
        end
    end

    local function clearAll()
        for _, screen in ipairs(screens) do
            clearScreen(screen)
        end
    end

    -- After an unreliable read, drop only the icons whose slot no longer shows their
    -- item, so a one-tick mismatch doesn't make every icon blink.
    local function pruneMismatched(screen)
        for slot, record in pairs(screen.icons) do
            if Log.field(record.component, "associatedObjectID") ~= record.itemId then
                destroyIcon(record)
                screen.icons[slot] = nil
            end
        end
    end

    -- Creates one slot's icon and tooltip. Returns the record, or nil.
    local function createIcon(slot, text, kinds, holder)
        local component = slot.component
        local icon = nil

        local built, problem = pcall(function()
            -- A slot can't have children, so the icon is its sibling; it still
            -- scrolls and clips with the slot.
            icon = prettyui.NewComponent(ui.Sprite, component.parent, { categoryID = "auto" })
            icon.sprite = options.iconSprite
            icon:SetSize(ICON_SIZE, ICON_SIZE)
            icon:SetPos(component.x + component.width - ICON_SIZE, component.y)

            -- Clicks pass through to the item underneath.
            icon.clickthrough = true
        end)

        local tooltip = nil

        if built then
            built, tooltip = pcall(ItemTooltip.attach, icon, holder, text, kinds, {
                sprite = options.iconSprite,
                position = options.boxPosition,
            })
            problem = tooltip
        end

        -- No tooltip, no icon.
        if not built or tooltip == nil then
            Log.error("marker failed:", tostring(problem))

            if icon then
                Log.safe("remove icon", function()
                    icon:Destroy()
                end)
            end

            return nil
        end

        self.iconCount = self.iconCount + 1
        syncListStale = true

        return {
            itemId = slot.itemId,
            icon = icon,
            tooltip = tooltip,
            component = component,
            text = text,
            key = SlotScreen.childKey(icon),
        }
    end

    -- Forgets icons the game deleted by rebuilding the slots (a shop does this on
    -- stock changes), so the caller draws them again. `present` = child keys of the
    -- container just read. Skipped until we know the client lists our icons at all.
    local function dropDeletedIcons(screen, present, containerKey)
        if not iconsListed then
            for _, record in pairs(screen.icons) do
                if record.key and present[record.key] then
                    iconsListed = true
                    break
                end
            end
        end

        if not iconsListed then
            return
        end

        for slotIndex, record in pairs(screen.icons) do
            if record.key and record.containerKey == containerKey and not present[record.key] then
                forgetIcon(record)
                screen.icons[slotIndex] = nil
            end
        end
    end

    -- Reads one screen and brings its icons in line with what should be marked.
    local function refreshScreen(screen)
        screen.dirty = false

        local result = Log.safe(screen.name .. " read", screen.adapter.read) or { state = "unreliable" }

        if result.state == "unreliable" then
            pruneMismatched(screen)
            screen.dirty = true
            return
        end

        if not result.open then
            clearScreen(screen)

            -- The shop may still find its slots in another display mode.
            screen.dirty = result.retry == true
            return
        end

        local wanted = {}

        for _, slot in ipairs(result.slots) do
            if required:isMarked(slot.itemId) then
                wanted[slot.slot] = slot
            end
        end

        if result.present then
            dropDeletedIcons(screen, result.present, result.containerKey)
        end

        -- Remove icons whose slot emptied, changed item, or sits in another container
        -- than the one just read (a shop display-mode switch).
        for slotIndex, record in pairs(screen.icons) do
            local slot = wanted[slotIndex]

            if slot == nil or slot.itemId ~= record.itemId or record.containerKey ~= result.containerKey then
                destroyIcon(record)
                screen.icons[slotIndex] = nil
            elseif record.component ~= slot.component then
                record.component = slot.component
                syncListStale = true
            end
        end

        -- Add missing icons; update the text on kept ones (a quest's state changed).
        local holder = nil

        for slotIndex, slot in pairs(wanted) do
            local text, kinds = required:tooltipText(slot.itemId, nameOf)
            local record = screen.icons[slotIndex]

            if record then
                if record.text ~= text then
                    Log.safe("update tooltip", function()
                        ItemTooltip.setText(record.tooltip, text, kinds)
                    end)
                    record.text = text
                end
            elseif self.iconCount < ICON_CAP then
                holder = holder or ItemTooltip.topAncestor(slot.component)

                local created = createIcon(slot, text, kinds, holder)

                if created then
                    created.containerKey = result.containerKey

                    -- First icon of the run: check whether the client lists our icons
                    -- among the slot container's children (see dropDeletedIcons).
                    if not iconsListed and created.key then
                        local _, present = SlotScreen.componentsByDynamicId(Log.field(slot.component, "parent"))
                        iconsListed = present ~= nil and present[created.key] == true
                    end
                end

                screen.icons[slotIndex] = created
            end
        end

        if self.iconCount > 0 then
            startSync()
        end
    end

    -- Records whether a screen is open. A real closed-to-open change re-reads the
    -- quests we can't watch (rate-limited in quest_status.lua); the first check after
    -- turning markers on doesn't count, so toggling never reads quests.
    local function updateOpen(screen, open)
        if open == screen.open then
            return
        end

        screen.dirty = true

        if open and screen.open == false then
            options.questStatus:refreshUnwatched(serverTick)
        end

        screen.open = open
    end

    -- A full read, then the signature as it now stands (our new icons included), so
    -- the poll only fires on the next real change.
    local function refreshPolled(screen)
        screen.readNextFrame = false
        refreshScreen(screen)
        screen.signature = screen.adapter.signature()
    end

    -- Positions and visibility are cached here so the per-frame pass never reads the
    -- icon back from the client.
    local function buildSyncList()
        syncList = {}

        for _, screen in ipairs(screens) do
            for _, record in pairs(screen.icons) do
                local slot = record.component

                syncList[#syncList + 1] = {
                    icon = record.icon,
                    slot = slot,
                    offset = (Log.field(slot, "width") or ICON_SIZE) - ICON_SIZE,
                    x = Log.field(record.icon, "x"),
                    y = Log.field(record.icon, "y"),
                    hidden = false,
                }
            end
        end

        syncListStale = false
    end

    -- Per frame, for polled screens: one visibility check while waiting for one to
    -- appear, and a signature compare every POLL_FRAMES while open. A change means a
    -- full read now. Returns true while any polled screen is open or awaited.
    local function pollScreens()
        frameCount = frameCount + 1

        local active = false

        for _, screen in ipairs(screens) do
            if screen.polls then
                if not screen.open and screen.openWaitFrames > 0 then
                    screen.openWaitFrames = screen.openWaitFrames - 1

                    if screen.adapter.isOpen() then
                        updateOpen(screen, true)
                        screen.readNextFrame = true
                    end
                end

                if screen.open then
                    active = true

                    if screen.readNextFrame
                        or (frameCount % POLL_FRAMES == 0 and screen.adapter.signature() ~= screen.signature) then
                        refreshPolled(screen)
                    end
                elseif screen.openWaitFrames > 0 then
                    active = true
                end
            end
        end

        return active
    end

    -- Every frame while icons exist or a polled screen is active.
    local function syncFrame()
        for _, screen in ipairs(screens) do
            if next(screen.icons) ~= nil and not interfaceLoaded(screen) then
                clearScreen(screen)
                screen.dirty = true
            end
        end

        local polling = pollScreens()

        if self.iconCount == 0 then
            if not polling then
                stopSync()
            end

            return
        end

        if syncListStale then
            buildSyncList()
        end

        -- One pcall around the whole pass rather than one per icon: pcall isn't free, and
        -- this runs every frame for up to 2000 icons.
        local ok, problem = pcall(function()
            for index = 1, #syncList do
                local entry = syncList[index]
                local slot = entry.slot

                if slot.visibleGlobal then
                    local x, y = slot.x + entry.offset, slot.y

                    if x ~= entry.x or y ~= entry.y then
                        entry.icon:SetPos(x, y)
                        entry.x, entry.y = x, y
                    end

                    if entry.hidden then
                        entry.icon.hidden = false
                        entry.hidden = false
                    end
                elseif not entry.hidden then
                    entry.icon.hidden = true
                    entry.hidden = true
                end
            end
        end)

        -- Usually a slot went away between checks; the next server tick rebuilds.
        if not ok then
            if not syncFailed then
                Log.error("icon position sync failed:", problem)
                syncFailed = true
            end

            markAll()
        else
            syncFailed = false
        end
    end

    function startSync()
        if not syncing then
            syncing = true
            Event.Draw.Subscribe(SYNC_SUBSCRIPTION, syncFrame)
        end
    end

    function stopSync()
        if syncing then
            syncing = false
            Event.Draw.Unsubscribe(SYNC_SUBSCRIPTION)
        end
    end

    -- The server-tick check. When nothing is dirty it costs one visibility read per
    -- screen (the backpack has no open/close event).
    local function onServerLogic()
        serverTick = serverTick + 1

        -- Until the first quest read is done every quest is "unknown", which would
        -- mark everything.
        if not options.questStatus.ready then
            clearAll()
            markAll()
            return
        end

        for _, screen in ipairs(screens) do
            local open = screen.adapter.isOpen()

            updateOpen(screen, open)

            if screen.polls then
                -- Backstop for the per-frame poll; also starts it when markers are
                -- turned on with a shop already open.
                if open then
                    if screen.adapter.signature() ~= screen.signature then
                        screen.dirty = true
                    end

                    startSync()
                end

                if screen.dirty then
                    refreshPolled(screen)
                end
            elseif screen.dirty then
                refreshScreen(screen)
            end
        end
    end

    local function onInventoryEvent(event)
        local invId = event.inv and event.inv.id

        for _, screen in ipairs(screens) do
            -- The shop learns its stock inventory ids from these events.
            if screen.adapter.noteInventory then
                screen.adapter.noteInventory(invId)
            end

            if screen.adapter.inventoryIds()[invId] then
                screen.dirty = true

                if screen.polls then
                    screen.readNextFrame = true

                    if not screen.open then
                        screen.openWaitFrames = OPEN_WAIT_FRAMES
                    end

                    startSync()
                end
            end
        end
    end

    -- Login, logout, world hop: screens may have been rebuilt, so drop and re-read.
    local function onGameStateChanged()
        clearAll()
        markAll()
    end

    -- Runs one server-tick check now, logging instead of throwing.
    local function checkNow()
        local ok, problem = pcall(onServerLogic)

        if not ok then
            Log.error("marker check failed:", problem)
        end
    end

    local function guarded(label, handler)
        return function(event)
            if not self.enabled then
                return
            end

            local ok, problem = pcall(handler, event)

            if not ok then
                Log.error(label, "failed:", problem)
            end
        end
    end

    local function subscribe()
        if subscribed then
            return
        end

        subscribed = true
        Event.InventoryAdded.Subscribe(SUBSCRIPTION, guarded("InventoryAdded", onInventoryEvent))
        Event.InventoryUpdated.Subscribe(SUBSCRIPTION, guarded("InventoryUpdated", onInventoryEvent))
        Event.InventoryRemoved.Subscribe(SUBSCRIPTION, guarded("InventoryRemoved", onInventoryEvent))
        Event.GameStateChanged.Subscribe(SUBSCRIPTION, guarded("GameStateChanged", onGameStateChanged))
        Event.ServerLogic.Subscribe(SUBSCRIPTION, guarded("ServerLogic", onServerLogic))
    end

    -- Unsubscribes before anything is destroyed, so no event lands mid-teardown.
    local function unsubscribe()
        stopSync()

        if not subscribed then
            return
        end

        subscribed = false
        Event.InventoryAdded.Unsubscribe(SUBSCRIPTION)
        Event.InventoryUpdated.Unsubscribe(SUBSCRIPTION)
        Event.InventoryRemoved.Unsubscribe(SUBSCRIPTION)
        Event.GameStateChanged.Unsubscribe(SUBSCRIPTION)
        Event.ServerLogic.Unsubscribe(SUBSCRIPTION)
    end

    -- Re-check every screen on the next server tick (quest status changed).
    function self:markAllDirty()
        markAll()
    end

    -- Re-check every screen now (the filter changed). Reads no quest status.
    function self:refreshNow()
        if self.enabled then
            markAll()
            checkNow()
        end
    end

    -- On: draw from cached quest states right away. Off: remove everything we own.
    function self:setEnabled(enabled)
        if enabled == self.enabled then
            return
        end

        self.enabled = enabled

        if enabled then
            for _, screen in ipairs(screens) do
                screen.open = nil
                screen.dirty = true
                screen.signature = nil
                screen.readNextFrame = false
                screen.openWaitFrames = 0
            end

            subscribe()
            checkNow()
        else
            unsubscribe()
            clearAll()
        end
    end

    function self:stop()
        self:setEnabled(false)
    end

    return self
end

return Markers
