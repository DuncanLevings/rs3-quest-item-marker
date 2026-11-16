-- BoxMover: opens at the quest box's spot and saves where the window is dropped.

local check = require("tests/support/check")
local FakeClient = require("tests/support/fake_client")

local spec = {}

-- Adds the game area and a fake PrettyUI Window to the fake client.
local function install()
    local client = FakeClient.install()
    local gameArea = { parent = client.root, width = 1920, height = 1080 }
    local getComponent = ui.Interfaces.GetComponent

    _G.id = { Component = { TOPLEVEL_V2__GAME_AREA = "game area" } }
    ui.Interfaces.GetComponent = function(interfaces, first, ...)
        if first == "game area" then
            return gameArea
        end

        return getComponent(interfaces, first, ...)
    end

    client.windows = {}
    prettyui.Window = {
        new = function(parent, options)
            local window = { parent = parent, options = options, texts = {}, destroyed = false, shown = 0 }

            function window:AddText(text)
                self.texts[#self.texts + 1] = text
            end

            function window:Show()
                self.shown = self.shown + 1
            end

            function window:Destroy()
                self.destroyed = true
            end

            client.windows[#client.windows + 1] = window

            return window
        end,
    }

    return client
end

spec["opens at the saved spot, saves each drop, and reopens instead of stacking"] = function()
    local client = install()
    local preferences = require("src/storage/preferences").new(PersistentDB, { "quest" })
    local mover = require("src/ui/box_mover").new(preferences)

    preferences:setBox(100, 200)
    mover:open()

    local window = client.windows[1]
    check.equal(window.parent, client.root, "drawn in the tooltips' layer")
    check.equal(window.options.x, 100)
    check.equal(window.options.y, 200)
    check.falsy(window.options.respectInterfaceLock, "moves even with the interface locked")

    window.options.onPositionChange(window, 640, 90)
    check.equal(preferences:getBox().x, 640)
    check.equal(preferences:getBox().y, 90)

    mover:open()
    check.equal(#client.windows, 1, "the open window comes to the front")
    check.equal(window.shown, 1)

    window.options.onClose(window)
    check.truthy(window.destroyed)

    mover:open()
    check.equal(#client.windows, 2, "a new one after closing")
    mover:stop()
    check.truthy(client.windows[2].destroyed)
end

return spec
