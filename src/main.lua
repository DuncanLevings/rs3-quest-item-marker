-- Entry point for Quest Item Marker. Builds every module in dependency order, wires
-- them together, and returns the shutdown function (root main.lua hands it to
-- PluginShutdown). Shutdown runs in reverse: unsubscribe first, then destroy.
--
-- How the pieces fit (design doc, Technical Plan §3):
--   data/quest_items.lua --QuestData--> item index ----+
--   config.Quest --QuestStatus--> cached quest states --+--> RequiredItems
--   Preferences (on/off, shortcut, filter, box spot) ---+        |
--   screen adapters (slot reads) ---> Markers (icons + tooltips) <+
--   SettingsWindow (ribbon) and Keybind both call setEnabled(); the panel's
--   "Move quest box" opens BoxMover, which saves the spot tooltips are drawn at.

local QuestData = require("src/game/quest_data")
local QuestStatus = require("src/game/quest_status")
local RequiredItems = require("src/game/required_items")
local Preferences = require("src/storage/preferences")
local Backpack = require("src/screens/backpack")
local Bank = require("src/screens/bank")
local BankBackpack = require("src/screens/bank_backpack")
local Markers = require("src/ui/markers")
local Keybind = require("src/ui/keybind")
local SettingsWindow = require("src/ui/settings_window")
local BoxMover = require("src/ui/box_mover")
local Messages = require("src/messages")
local Log = require("src/log")

local App = {}

-- The marker icon: the blue quest icon from the quest list (picked by the author in
-- the rsprite finder, 2026-11-16). By name, so a client update that renumbers sprites
-- still finds it; the id it had then is the fallback.
local ICON_SPRITE_NAME = "RS3_ICON_QUEST_LIST"
local ICON_SPRITE_FALLBACK = 17130

local function questIconSprite()
    local ok, sprite = pcall(function()
        return id.Sprite[ICON_SPRITE_NAME]
    end)

    if ok and type(sprite) == "number" then
        return sprite
    end

    Log.write("sprite", ICON_SPRITE_NAME, "not found by name, using id", ICON_SPRITE_FALLBACK)
    return ICON_SPRITE_FALLBACK
end

-- Each start gets fresh state, even if the client cached these modules.
function App.start()
    local messages = Messages.new()
    local questData = QuestData.load()
    local dataOk = questData.status == "ok"

    if dataOk then
        Log.write(
            "data loaded: snapshot", questData.snapshot, "|", questData.counts.quests, "quests |",
            questData.counts.items, "marked item ids |", questData.counts.badQuests, "bad quests,",
            questData.counts.badNeeds, "bad needs skipped"
        )
    else
        -- CUJ 7: nothing is marked, and the player hears about it once.
        Log.write("quest data incompatible:", questData.message)
        messages:once("data", "Quest data incompatible, so no items are marked. Please update the plugin.")
    end

    local preferences = Preferences.new(PersistentDB, QuestData.CATEGORIES)

    -- Filled in below; callbacks created first need to see them.
    local questStatus, markers, settings, keybind
    local boxMover = BoxMover.new(preferences)

    local function refreshSettings()
        if settings then
            settings:refresh()
        end
    end

    -- The checkbox and the shortcut share this one switch and one saved setting.
    -- Showing markers again draws from the cached quest states: no quest is read.
    local function setEnabled(enabled, fromShortcut)
        preferences:setEnabled(enabled)

        if markers then
            markers:setEnabled(enabled)
        end

        if fromShortcut then
            messages:show(enabled and "Markers shown" or "Markers hidden")
        end

        -- The in-game toggle check: this number must not grow while toggling.
        if questStatus then
            Log.write("markers", enabled and "on" or "off", "| quest reads since login:", questStatus.counts.read)
        end

        refreshSettings()
    end

    if dataOk then
        local filter = preferences:getFilter()

        questStatus = QuestStatus.new(questData.quests, function()
            -- Ready, changed or reset: every screen re-checks on the next server tick.
            if markers then
                markers:markAllDirty()
            end
        end)

        local requiredItems = RequiredItems.new(questData, function(questId)
            return questStatus:get(questId)
        end, filter)

        local iconSprite = questIconSprite()

        markers = Markers.new({
            -- The backpack, the bank, and the backpack panel inside the bank screen.
            screens = { Backpack, Bank, BankBackpack },
            questStatus = questStatus,
            iconSprite = function()
                return iconSprite
            end,
            requiredItems = function()
                return requiredItems
            end,
            boxPosition = function()
                return preferences:getBox()
            end,
            messages = messages,
        })
    end

    keybind = Keybind.new(function()
        return preferences:getKey()
    end, function()
        setEnabled(not preferences:isEnabled(), true)
    end)

    settings = SettingsWindow.new({
        preferences = preferences,
        setEnabled = function(enabled)
            setEnabled(enabled, false)
        end,
        onKeyChanged = function()
            keybind:update()
        end,
        moveBox = function()
            boxMover:open()
        end,
    })

    settings:start()

    if questStatus then
        questStatus:start()
        markers:setEnabled(preferences:isEnabled())
    end

    keybind:update()
    Log.write("started | markers", preferences:isEnabled() and "on" or "off")

    local stopped = false

    return function()
        if stopped then
            return
        end

        stopped = true

        -- Input first, so nothing can turn markers back on mid-shutdown; then the
        -- markers (icons, tooltips, hover hooks, their events); then quest status
        -- and the panel.
        Log.safe("stop keybind", function()
            keybind:stop()
        end)

        if markers then
            Log.safe("stop markers", function()
                markers:stop()
            end)
        end

        if questStatus then
            Log.safe("stop quest status", function()
                questStatus:stop()
            end)
        end

        Log.safe("stop settings", function()
            settings:stop()
        end)

        Log.safe("stop quest box mover", function()
            boxMover:stop()
        end)

        Log.write("stopped")
    end
end

return App
