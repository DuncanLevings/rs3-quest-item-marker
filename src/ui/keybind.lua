-- The optional shortcut that shows or hides markers. PrettyUI's KeybindField.IsDown
-- already ignores presses while the player is typing or a keybind field is capturing
-- keys, so this only adds "once per press".
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

    -- The binding as of the last update(), so the per-tick check doesn't copy the saved
    -- one 50 times a second.
    local binding = {}

    local function onLogic()
        local down = prettyui.KeybindField.IsDown(binding)
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
        binding = getBinding()

        local bound = #binding > 0

        if bound and not subscribed then
            subscribed = true
            wasDown = false
            Event.Logic.Subscribe(SUBSCRIPTION, function()
                local ok, problem = pcall(onLogic)

                if not ok then
                    Log.error("keybind failed:", problem)
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
