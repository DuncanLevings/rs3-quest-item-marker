-- The plugin's ribbon panel: which quest types to mark, the show/hide shortcut and
-- "Move quest box". There's no on/off checkbox: the shortcut hides markers, and
-- turning the plugin off removes them entirely.
--
-- The client hands us an empty layer (Event.ContentLayerReady) every time the ribbon
-- icon is selected; we fill it with a PrettyUI SimpleView.
--
-- Owns: the ContentLayerReady subscription, the view and its components.

local Log = require("src/log")

local SettingsWindow = {}

local SUBSCRIPTION = "quest-item-marker-settings"

-- How each quest type reads in the panel.
local CATEGORY_LABELS = { quest = "Quests", miniquest = "Miniquests" }

-- options:
--   preferences                Preferences instance
--   categories                 the quest types offered, in order (QuestData.CATEGORIES)
--   setCategory(category, on)  turns one quest type on or off
--   setShown(kind, on)         turns a finished-quest marker ("keep"/"done") on or off
--   onKeyChanged()             called after the shortcut is saved
--   moveBox()                  opens the window that moves the quest box
function SettingsWindow.new(options)
    local self = {}

    local view = nil

    local function destroyView()
        if view then
            local old = view
            view = nil
            Log.safe("close settings", function()
                old:Destroy()
            end)
        end
    end

    local function populate(layer)
        destroyView()

        view = prettyui.SimpleView.new(layer, {
            width = 0,
            height = 0,
            widthAnchor = 1,
            heightAnchor = 1,
            categoryID = "auto",
        })

        local current = view

        -- Callbacks from an old view (after a rebuild or shutdown) do nothing.
        local function alive()
            return view == current
        end

        current:AddTitle("Quest Item Marker")

        -- Which quest types get marked. Both start ticked.
        local filter = options.preferences:getFilter()
        local choices = {}

        for _, category in ipairs(options.categories) do
            choices[#choices + 1] = {
                text = CATEGORY_LABELS[category] or category,
                value = category,
                selected = filter[category] == true,
            }
        end

        current:AddText("Mark items needed for")
        current:AddCheckboxButton(choices, {
            onChange = function(_, _, category, selected)
                if alive() then
                    options.setCategory(category, selected)
                end
            end,
        })

        current:AddText("For finished quests, also mark")
        current:AddCheckboxButton({
            { text = "Items still used afterwards (green)", value = "keep",
              selected = options.preferences:isShown("keep") },
            { text = "Items no longer needed (red)", value = "done",
              selected = options.preferences:isShown("done") },
        }, {
            onChange = function(_, _, kind, selected)
                if alive() then
                    options.setShown(kind, selected)
                end
            end,
        })

        current:AddText("Shortcut to show or hide markers")
        current:AddKeybindField({
            value = options.preferences:getKey(),
            defaultValue = {},
            onChange = function(_, value)
                if not alive() then
                    return
                end

                if options.preferences:setKey(value) then
                    options.onKeyChanged()
                else
                    Log.error("shortcut not saved, unexpected value:", tostring(value))
                end
            end,
        })

        current:AddText("Hover a marker icon to see its quests in the quest box.")
        current:AddSimpleButton("Move quest box", function()
            if alive() then
                options.moveBox()
            end
        end)
    end

    function self:start()
        Event.ContentLayerReady.Subscribe(SUBSCRIPTION, function(event)
            Log.safe("open settings", function()
                populate(event.component)
            end)
        end)
    end

    function self:stop()
        Event.ContentLayerReady.Unsubscribe(SUBSCRIPTION)
        destroyView()
    end

    return self
end

return SettingsWindow
