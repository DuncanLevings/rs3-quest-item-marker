-- Entry point: builds every module, wires them together, and returns the shutdown
-- function that root main.lua hands to PluginShutdown.
--
-- How the pieces fit:
--   data/quest_items.lua --QuestData--> item index ----+
--   config.Quest --QuestStatus--> cached quest states --+--> RequiredItems
--   Preferences (on/off, shortcut, filter, box spot) ---+        |
--   screen adapters (slot reads) ---> Markers (icons + tooltips) <+
--   Keybind calls setEnabled(); SettingsWindow sets the filter and shortcut, and its
--   "Move quest box" button opens BoxMover.

local QuestData = require("src/game/quest_data")
local QuestStatus = require("src/game/quest_status")
local RequiredItems = require("src/game/required_items")
local Preferences = require("src/storage/preferences")
local Backpack = require("src/screens/backpack")
local Bank = require("src/screens/bank")
local BankBackpack = require("src/screens/bank_backpack")
local Shop = require("src/screens/shop")
local Markers = require("src/ui/markers")
local Keybind = require("src/ui/keybind")
local SettingsWindow = require("src/ui/settings_window")
local BoxMover = require("src/ui/box_mover")
local Log = require("src/log")

local App = {}

-- The marker icon is the blue quest-list icon. Looked up by name so a client update
-- that renumbers sprites still finds it; the id is the fallback.
local ICON_SPRITE_NAME = "RS3_ICON_QUEST_LIST"
local ICON_SPRITE_FALLBACK = 17130

local function questIconSprite()
    local ok, sprite = pcall(function()
        return id.Sprite[ICON_SPRITE_NAME]
    end)

    if ok and type(sprite) == "number" then
        return sprite
    end

    return ICON_SPRITE_FALLBACK
end

-- Builds fresh state on every start, even if the client cached these modules.
function App.start()
    local questData = QuestData.load()
    local dataOk = questData.status == "ok"

    -- Bad data means nothing gets marked, but the panel still works so the plugin
    -- doesn't look broken.
    if not dataOk then
        Log.error("quest data incompatible:", questData.message)
    end

    local preferences = Preferences.new(PersistentDB, QuestData.CATEGORIES)

    -- Assigned below; the callbacks created first close over them.
    local questStatus, requiredItems, markers, keybind
    local boxMover = BoxMover.new(preferences)

    -- Shows or hides markers and remembers it. Showing them again draws from cached
    -- quest states; no quest is read.
    local function setEnabled(enabled)
        preferences:setEnabled(enabled)

        if markers then
            markers:setEnabled(enabled)
        end
    end

    -- The shortcut is the only way to bring hidden markers back, so with no shortcut
    -- bound they must be showing, or the player would be stuck without them.
    local function showIfNoShortcut()
        if #preferences:getKey() == 0 and not preferences:isEnabled() then
            setEnabled(true)
        end
    end

    showIfNoShortcut()

    if dataOk then
        questStatus = QuestStatus.new(questData.quests, function()
            if markers then
                markers:markAllDirty()
            end
        end)

        requiredItems = RequiredItems.new(questData, function(questId)
            return questStatus:get(questId)
        end, preferences:getFilter())

        markers = Markers.new({
            -- The shop adapter keeps state, so each start gets its own.
            screens = { Backpack, Bank, BankBackpack, Shop.new() },
            questStatus = questStatus,
            iconSprite = questIconSprite(),
            requiredItems = requiredItems,
            boxPosition = function()
                return preferences:getBox()
            end,
        })
    end

    keybind = Keybind.new(function()
        return preferences:getKey()
    end, function()
        setEnabled(not preferences:isEnabled())
    end)

    -- A quest type was ticked or unticked: save it and redraw open screens straight
    -- away instead of waiting for the next server tick.
    local function setCategory(category, included)
        if not preferences:setFilter(category, included) then
            return
        end

        if requiredItems then
            requiredItems:setFilter(preferences:getFilter())
            markers:refreshNow()
        end
    end

    local settings = SettingsWindow.new({
        preferences = preferences,
        categories = QuestData.CATEGORIES,
        setCategory = setCategory,
        onKeyChanged = function()
            keybind:update()
            showIfNoShortcut()
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

    local stopped = false

    return function()
        if stopped then
            return
        end

        stopped = true

        -- Input first, so nothing can turn markers back on mid-shutdown.
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
    end
end

return App
