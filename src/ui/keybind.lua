-- The optional shortcut that shows or hides markers. Reused from the author's Skill
-- Tips plugin (src/ui/keybind.lua there): PrettyUI's KeybindField.IsDown already
-- ignores presses while the player is typing (chat, the bank search box) or while a
-- keybind field is capturing keys, so we only add "once per press".
--
-- Unbound by default. Owns one Logic subscription, and only while a key is bound.

local Log = require("src/log")

local Keybind = {}

local SUBSCRIPTION = "quest-item-marker-keybind"

-- getBinding() returns the saved keys; onPress() runs once per press.
function Keybind.new(getBinding, onPress)
    local self = {}
    local subscribed = false
    local wasDown = false

    local function onLogic()
        local down = prettyui.KeybindField.IsDown(getBinding())
        local pressed = down and not wasDown

        -- Record the press before acting on it, so an error in onPress can't make
        -- it fire again on every tick the keys stay held.
        wasDown = down

        if pressed and Player.IsAvailable() then
            onPress()
        end
    end

    -- Call after start and whenever the binding changes. Polls the keyboard (50 times
    -- a second, a few table reads) only while a key is actually bound.
    function self:update()
        local bound = #getBinding() > 0

        if bound and not subscribed then
            subscribed = true
            wasDown = false
            Event.Logic.Subscribe(SUBSCRIPTION, function()
                local ok, problem = pcall(onLogic)

                if not ok then
                    Log.write("keybind failed:", problem)
                end
            end)
        elseif not bound and subscribed then
            subscribed = false
            Event.Logic.Unsubscribe(SUBSCRIPTION)
        end
    end

    function self:stop()
        if subscribed then
            subscribed = false
            Event.Logic.Unsubscribe(SUBSCRIPTION)
        end
    end

    return self
end

return Keybind
