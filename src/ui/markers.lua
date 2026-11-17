-- The marker manager: decides which item slots get a quest icon, draws and removes
-- the icons, gives each icon its own hover tooltip, and keeps icons on their slots.
--
-- Refresh cycle (design doc, Technical Plan §5):
--   * Events only set flags: an inventory event marks its screen dirty; a quest
--     status change or a settings change marks every screen dirty.
--   * A ServerLogic check (~every 600 ms) does the work: it reads each dirty screen
--     through its adapter, then destroys icons that aren't wanted any more and
--     creates the missing ones. Icons are keyed by (screen, slot).
--   * While icons exist, a lean pass on every Draw frame copies each slot's position
--     and visibility onto its icon, so icons follow slots that move (a resized
--     backpack, and later bank tabs and search) in the same frame.
--
-- Handles from a closed screen are never touched (M0: after the interface reloads, an
-- old handle can read as valid but point at someone else's component). If a screen's
-- interface unloads, its icons are forgotten without being destroyed (the client
-- already removed them) and redrawn when it's back.
--
-- Owns: every icon component and its tooltip (which owns the hover hooks on the game
-- slot), and the Inventory*, ServerLogic, GameStateChanged and Draw subscriptions.
-- With markers turned off it owns nothing at all: zero icons, tooltips, hooks and
-- subscriptions.

local ItemTooltip = require("src/ui/item_tooltip")
local SlotScreen = require("src/screens/slot_screen")
local Log = require("src/log")

local Markers = {}

local SUBSCRIPTION = "quest-item-marker-markers"
local SYNC_SUBSCRIPTION = "quest-item-marker-sync"

-- The icon: 12 px, top-right corner of the slot (M0).
local ICON_SIZE = 12

-- Most icons alive at once, across all screens. M0 created 3000 components without
-- trouble, and 2000 covers a full 1920-slot bank. Above it, no more are drawn.
local ICON_CAP = 2000

-- A screen has to fail this many checks in a row before the player is told. Its
-- icons go away on the first failure; this only stops a one-tick hiccup from
-- posting a chat message.
local FAILURES_BEFORE_MESSAGE = 2

-- Screens whose adapter has signature() (the shop) can change with no inventory event
-- (Buy/Sell tab switch) and get rebuilt by the game, deleting our icons. While one is
-- open, its cheap signature is compared every POLL_FRAMES frames (about 50 ms), and a
-- full read only happens when it changes.
local POLL_FRAMES = 3

-- After an inventory event for such a screen, how many frames to keep checking
-- whether it has appeared (a shop window shows a moment after its stock arrives).
local OPEN_WAIT_FRAMES = 60

-- options:
--   screens       list of screen adapters (src/screens/*.lua)
--   questStatus   QuestStatus instance (only :refreshUnwatched and .ready are used)
--   iconSprite()  the quest icon sprite id, or nil if none is known yet
--   boxPosition() where the tooltip goes: the saved { x, y }, or nil for the default
--   requiredItems function returning the current RequiredItems
--   messages      Messages instance
function Markers.new(options)
    local self = {
        enabled = false,

        -- How many icons are alive right now, across screens.
        iconCount = 0,
    }

    local screens = {}

    for _, adapter in ipairs(options.screens) do
        screens[#screens + 1] = {
            adapter = adapter,
            name = adapter.NAME,
            interfaceId = adapter.INTERFACE_ID,

            -- [slot] = { itemId, icon, tooltip, component, text }
            icons = {},
            dirty = true,
            -- true / false once seen; nil = not checked since markers were turned on.
            open = nil,
            failures = 0,
            status = "off",
            -- Polled every few frames while open (see POLL_FRAMES): the shop.
            polls = adapter.signature ~= nil,
            signature = nil,
            readNextFrame = false,
            openWaitFrames = 0,
        }
    end

    local subscribed = false
    local syncing = false
    local serverTick = 0

    -- The flat list the Draw pass walks. Rebuilt when icons are added or removed,
    -- never per frame.
    local syncList = {}
    local syncListStale = false

    -- True once any of our icons has been seen among its container's children (on
    -- any screen). Until then, an icon missing from that list isn't taken as gone.
    local iconsListed = false

    -- Item names for "+ partner" tooltip lines. Names never change, so cache them.
    local itemNames = {}

    -- Each screen's status goes to the console when it changes (brief §4, Logging),
    -- so what every screen is doing can be followed without any panel.
    local function setStatus(screen, status)
        if screen.status ~= status then
            screen.status = status
            Log.write(screen.name .. ":", status)
        end
    end

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

    -- Removes one icon and its tooltip. The tooltip goes first: its Destroy()
    -- unsubscribes the hover hooks on the game slot and restores the slot's
    -- clickthrough, so no hook outlives the icon.
    local function destroyIcon(record)
        if record.tooltip then
            Log.safe("remove tooltip", function()
                record.tooltip:Destroy()
            end)
        end

        Log.safe("remove icon", function()
            record.icon:Destroy()
        end)

        self.iconCount = self.iconCount - 1
        syncListStale = true
    end

    -- Drops an icon the client already removed (its interface unloaded, or the game
    -- rebuilt the slots around it). The icon handle isn't touched; the tooltip is
    -- destroyed, because its parts live in 1477, not in the screen.
    local function forgetIcon(record)
        Log.safe("remove tooltip", function()
            record.tooltip:Destroy()
        end)

        self.iconCount = self.iconCount - 1
        syncListStale = true
    end

    -- Removes every icon on one screen. If its interface has unloaded, the client
    -- already took the icons with it, and the old icon handles must not be touched.
    -- The tooltip is still destroyed: its parts live in 1477, not in the screen, so
    -- one being hovered would otherwise stay on screen. That's safe because
    -- PrettyUI's Destroy() itself skips the slot (unhook, clickthrough) when the
    -- slot's interface isn't loaded.
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

    -- After a read that didn't add up: keep each icon whose own slot still shows the
    -- item it was drawn for, and remove the rest. Picking an item up makes the
    -- backpack inventory change a moment before its slot components do, so one slot
    -- disagrees for a tick; clearing the whole screen then made every icon blink
    -- (seen in game, 2026-11-16). The identity check per icon is what keeps this safe:
    -- an icon never stays on a slot showing anything but its own item.
    local function pruneMismatched(screen)
        for slot, record in pairs(screen.icons) do
            if Log.field(record.component, "associatedObjectID") ~= record.itemId then
                destroyIcon(record)
                screen.icons[slot] = nil
            end
        end
    end

    local function clearAll()
        for _, screen in ipairs(screens) do
            clearScreen(screen)
        end
    end

    -- Creates the icon and its tooltip for one slot. Returns the record, or nil.
    local function createIcon(screen, slot, text, kinds, holder)
        local sprite = options.iconSprite()

        if not sprite then
            options.messages:once("sprite", "Couldn't find the quest icon, so no markers are drawn.")
            return nil
        end

        local component = slot.component
        local icon = nil

        local built, problem = pcall(function()
            -- M0: an icon can't be the slot's child (the client rejects a sprite as
            -- a parent), so it sits beside the slot in the slot's parent. There it
            -- scrolls and clips with the slot.
            icon = prettyui.NewComponent(ui.Sprite, component.parent, { categoryID = "auto" })
            icon.sprite = sprite
            icon:SetSize(ICON_SIZE, ICON_SIZE)
            icon:SetPos(component.x + component.width - ICON_SIZE, component.y)

            -- Clicks pass through to the item underneath: the icon never changes
            -- what clicking a slot does.
            icon.clickthrough = true
        end)

        -- If the tooltip can't be attached either, take the icon away again: an icon
        -- you can't hover for an explanation breaks the design's promise.
        local tooltip = nil

        if built then
            built, tooltip = pcall(ItemTooltip.attach, icon, holder, text, kinds, {
                sprite = sprite,
                position = options.boxPosition,
            })
            problem = tooltip
        end

        if not built or tooltip == nil then
            Log.write(screen.name, "slot", slot.slot, "marker failed:", tostring(problem))

            if icon then
                Log.safe("remove icon", function()
                    icon:Destroy()
                end)
            end

            return nil
        end

        local record = {
            itemId = slot.itemId,
            icon = icon,
            component = component,
            text = text,
            -- How to find this icon among its container's children later.
            key = SlotScreen.childKey(icon),
            -- The slot's container, which the icon is a child of.
            container = Log.field(component, "parent"),
        }

        record.tooltip = tooltip
        self.iconCount = self.iconCount + 1
        syncListStale = true

        return record
    end

    -- The game can rebuild a screen's slot components and delete our icons with them
    -- (a shop does on every stock change: seen in game, 2026-11-16). `present` is the
    -- set of SlotScreen.childKey of every child of the icons' container. An icon
    -- missing from it is gone: forget it (the caller then draws it again). Only
    -- trusted once one of our icons has been seen in such a list, so a client that
    -- doesn't list our icons never loses them. Returns how many were dropped.
    local function dropDeletedIcons(screen, present, containerKey)
        for _, record in pairs(screen.icons) do
            if record.key and present[record.key] then
                iconsListed = true
                break
            end
        end

        if not iconsListed then
            return 0
        end

        local gone = 0

        for slotIndex, record in pairs(screen.icons) do
            -- Only icons in the container just read; one in another (a shop display
            -- mode switch) is destroyed properly by the caller instead.
            if record.key and record.containerKey == containerKey and not present[record.key] then
                forgetIcon(record)
                screen.icons[slotIndex] = nil
                gone = gone + 1
            end
        end

        -- Once per screen: a shop restocking does this every few seconds.
        if gone > 0 and not screen.rebuildLogged then
            screen.rebuildLogged = true
            Log.write(screen.name .. ": the game removed " .. gone .. " icons with its slots; drawing them again"
                .. " (logged once)")
        end

        return gone
    end


    local startSync, stopSync

    -- Reads one screen and brings its icons in line with what should be marked.
    local function refreshScreen(screen)
        screen.dirty = false

        local result = Log.safe(screen.name .. " read", screen.adapter.read)
            or { state = "unreliable", reason = "the screen read failed" }

        if result.state == "unreliable" then
            pruneMismatched(screen)

            -- Keep trying every check until it reads correctly again.
            screen.dirty = true
            screen.failures = screen.failures + 1

            if screen.failures >= FAILURES_BEFORE_MESSAGE then
                if screen.status ~= "Couldn't read: " .. result.reason then
                    Log.write(screen.name, "unreliable:", result.reason)
                end

                setStatus(screen, "Couldn't read: " .. result.reason)
                options.messages:once(
                    "unreliable-" .. screen.name,
                    "Couldn't read " .. screen.name .. ", so its markers are off until it reads correctly."
                )
            end

            return
        end

        if screen.failures >= FAILURES_BEFORE_MESSAGE then
            Log.write(screen.name, "reads correctly again")
        end

        screen.failures = 0
        options.messages:clear("unreliable-" .. screen.name)

        if not result.open then
            clearScreen(screen)
            setStatus(screen, "closed (" .. tostring(result.reason) .. ")")

            -- The shop still looking for its slots in another display mode.
            if result.retry then
                screen.dirty = true
            end

            return
        end

        local required = options.requiredItems()

        -- Which slots should have an icon, and with what tooltip text.
        local wanted = {}

        for _, slot in ipairs(result.slots) do
            if required:isMarked(slot.itemId) then
                wanted[slot.slot] = slot
            end
        end

        -- Icons the game deleted with its slots are forgotten here and drawn again below.
        if result.present then
            dropDeletedIcons(screen, result.present, result.containerKey)
        end

        -- Remove icons whose slot emptied or now holds something else, or that sit in
        -- another container than the slots now read (a shop's other display mode).
        for slotIndex, record in pairs(screen.icons) do
            local slot = wanted[slotIndex]

            if slot == nil or slot.itemId ~= record.itemId or record.containerKey ~= result.containerKey then
                destroyIcon(record)
                screen.icons[slotIndex] = nil
            elseif record.component ~= slot.component then
                -- The same slot, read through a new handle: follow the new one.
                record.component = slot.component
                syncListStale = true
            end
        end

        -- Add missing icons; update the text on kept ones (a quest's state changed).
        local holder = nil
        local capped = false

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
            elseif self.iconCount >= ICON_CAP then
                capped = true
            else
                holder = holder or ItemTooltip.topAncestor(slot.component)
                local created = Log.safe("create icon", function()
                    return createIcon(screen, slot, text, kinds, holder)
                end)

                if created then
                    created.containerKey = result.containerKey

                    -- Once per run: does the client list our icons among the slots'
                    -- children? If so, an icon missing from that list later means the
                    -- game deleted it (see dropDeletedIcons).
                    if not iconsListed and created.key and created.container then
                        local _, present = SlotScreen.componentsByDynamicId(created.container)

                        iconsListed = present ~= nil and present[created.key] == true
                    end
                end

                screen.icons[slotIndex] = created
            end
        end

        if capped then
            options.messages:once("cap", "Too many marked items to show them all; some markers are missing.")
        end

        local marked = 0

        for _ in pairs(screen.icons) do
            marked = marked + 1
        end

        -- An adapter may add what it read (the shop does), so the console line says
        -- more than a count when something looks wrong.
        local detail = result.detail and (" (" .. result.detail .. ")") or ""

        setStatus(screen, "OK, " .. marked .. " marked" .. detail)

        if self.iconCount > 0 then
            startSync()
        end
    end

    -- Records whether a screen is open. A screen opening is when quests we can't watch
    -- get re-read (at most once every few seconds; see quest_status.lua). Only a real
    -- closed-to-open change counts: the first look after markers are turned on is not
    -- an opening, so the toggle never reads quests.
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

    -- A full read of a polled screen, then its signature as it now stands (our new
    -- icons included), so the poll only fires on the next real change.
    local function refreshPolled(screen)
        screen.readNextFrame = false
        refreshScreen(screen)
        screen.signature = screen.adapter.signature()
    end

    -- Builds the flat list for the Draw pass. Positions and visibility are cached in
    -- Lua so the per-frame pass never reads the icon back from the client (M0: that
    -- halved the cost).
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

    -- Every frame while icons exist: drop the icons of any screen whose interface
    -- unloaded, then move and show/hide each icon to match its slot. M0 measured no
    -- frame cost for this pass with 1920 icons.
    local syncFailed = false

    -- For polled screens (the shop), every frame: is one that should be appearing open
    -- yet (one visibility check, only for OPEN_WAIT_FRAMES after its inventory
    -- arrived), and has an open one changed (its signature every POLL_FRAMES frames:
    -- one field read per slot)? A change means a full read now, not at the next server
    -- tick. Returns true while a polled screen is open or being waited for.
    local frameCount = 0

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

        -- One pcall around the whole pass, not one per icon (M0: per-icon pcalls
        -- doubled the frame time).
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

        -- A failure here usually means a slot went away between checks. Have the next
        -- server tick re-read every screen, which rebuilds the icons.
        if not ok then
            if not syncFailed then
                Log.write("icon position sync failed:", problem)
                syncFailed = true
            end

            for _, screen in ipairs(screens) do
                screen.dirty = true
            end
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

    -- The server-tick check. Cheap when nothing is dirty: one visibility read per
    -- screen to notice it opening or closing (the backpack has no event for that).
    local function onServerLogic()
        serverTick = serverTick + 1

        -- No icons until the first quest read after login is done: until then every
        -- quest is "unknown", which would mark everything.
        if not options.questStatus.ready then
            clearAll()

            for _, screen in ipairs(screens) do
                screen.dirty = true
                setStatus(screen, "waiting for quest status")
            end

            return
        end

        for _, screen in ipairs(screens) do
            local open = screen.adapter.isOpen()

            updateOpen(screen, open)

            if screen.polls then
                -- The per-frame poll does this sooner; this is the backstop (and
                -- starts the poll when markers are turned on with a shop open).
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
            -- The shop doesn't know its stock inventory up front; it learns the ids
            -- from these events (shop.lua).
            if screen.adapter.noteInventory then
                screen.adapter.noteInventory(invId)
            end

            if screen.adapter.inventoryIds()[invId] then
                screen.dirty = true

                -- Read the shop in the next frame, and if it isn't on screen yet,
                -- look for it for a moment (see pollScreens).
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

    -- Login, logout, world hop: the screens may have been rebuilt, so drop every
    -- icon (clearScreen won't touch handles whose interface is gone) and re-read.
    local function onGameStateChanged()
        clearAll()
        self:markAllDirty()
    end

    -- Wraps a handler so an error is logged instead of breaking the event.
    local function guarded(label, handler)
        return function(event)
            if not self.enabled then
                return
            end

            local ok, problem = pcall(handler, event)

            if not ok then
                Log.write(label, "failed:", problem)
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

    -- Unsubscribe before destroying anything, so no event lands mid-teardown.
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

    -- Re-check every screen on the next server tick (quest status or settings changed).
    function self:markAllDirty()
        for _, screen in ipairs(screens) do
            screen.dirty = true
        end
    end

    -- Turning on draws from the cached quest states on the next server tick; it
    -- reads no quest status. Turning off removes everything we own.
    function self:setEnabled(enabled)
        if enabled == self.enabled then
            return
        end

        self.enabled = enabled

        if enabled then
            for _, screen in ipairs(screens) do
                screen.open = nil
                screen.failures = 0
                screen.dirty = true
                screen.signature = nil
                screen.readNextFrame = false
                screen.openWaitFrames = 0
            end

            subscribe()

            -- Draw now rather than on the next server tick (up to 0.6 s away), so
            -- turning markers on feels instant. Still only reads cached quest states.
            local ok, problem = pcall(onServerLogic)

            if not ok then
                Log.write("ServerLogic failed:", problem)
            end
        else
            unsubscribe()
            clearAll()

            for _, screen in ipairs(screens) do
                options.messages:clear("unreliable-" .. screen.name)
                setStatus(screen, "off")
            end
        end
    end

    function self:stop()
        self:setEnabled(false)
    end

    return self
end

return Markers
