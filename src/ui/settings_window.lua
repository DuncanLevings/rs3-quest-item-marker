-- The plugin's ribbon panel: the on/off checkbox, which quest types to mark (M5), the
-- shortcut and "Move quest box". Nothing else (author, 2026-11-16): status and
-- diagnostics go to the console log.
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
--   preferences     Preferences instance
--   categories      the quest types offered, in order (QuestData.CATEGORIES)
--   setCategory(category, on)  turns one quest type on or off
--   setEnabled(on)  shared with the keybind
--   onKeyChanged()  called after the shortcut is saved
--   moveBox()       opens the window that moves the quest box
function SettingsWindow.new(options)
    local self = {}

    local view = nil
    local checkbox = nil
    local layerInterfaceId = nil

    local function destroyView()
        checkbox = nil

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
        layerInterfaceId = layer.interfaceID

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

        checkbox = current:AddCheckboxButton({
            { text = "Show quest item markers", value = "enabled", selected = options.preferences:isEnabled() },
        }, {
            onChange = function(_, _, _, selected)
                if alive() then
                    options.setEnabled(selected)
                end
            end,
        })

        -- Which quest types count (CUJ 6). Both on by default.
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
                    Log.write("shortcut not saved, unexpected value:", tostring(value))
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

    -- Brings an open panel's checkbox up to date (the shortcut may have changed it).
    function self:refresh()
        if not view then
            return
        end

        -- Only while the panel is on screen. A closed panel is rebuilt from scratch the
        -- next time the ribbon icon is selected, and its handles may no longer be ours.
        local onScreen = false

        pcall(function()
            onScreen = ui.Interfaces:GetInterface(layerInterfaceId) ~= nil and view.root.visibleGlobal == true
        end)

        if not onScreen then
            return
        end

        Log.safe("refresh settings", function()
            if checkbox and checkbox:IsSelected("enabled") ~= options.preferences:isEnabled() then
                checkbox:SetSelected("enabled", options.preferences:isEnabled(), false)
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
