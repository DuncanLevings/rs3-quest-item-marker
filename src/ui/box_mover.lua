-- The "Move quest box" window (author, 2026-11-16: the quest tooltip shows in one
-- spot the player picks, not next to the item; see item_tooltip.lua, Placement).
--
-- A PrettyUI Window stands in for the quest box while it's open: drag it by its
-- title bar, and wherever its top-left corner is dropped becomes the quest box's
-- top-left corner. It saves on every drop; closing it just closes it. It ignores the
-- game's interface lock, because the player opened it on purpose to move something.
--
-- Owns: the window, while it's open.

local ItemTooltip = require("src/ui/item_tooltip")
local Log = require("src/log")

local BoxMover = {}

-- About the size of a quest box with a few lines, so the player sees how much room
-- it takes.
local WIDTH = 280
local HEIGHT = 150

-- The layer the quest tooltips are drawn in: the game area's top ancestor (1477
-- TOPLEVEL_V2), the same holder markers.lua uses, so both share coordinates.
local function findHolder()
    local ok, gameArea = pcall(function()
        return ui.Interfaces:GetComponent(id.Component.TOPLEVEL_V2__GAME_AREA)
    end)

    if not ok or gameArea == nil then
        return nil
    end

    return ItemTooltip.topAncestor(gameArea)
end

-- preferences: Preferences instance (getBox / setBox).
function BoxMover.new(preferences)
    local self = {}

    local window = nil

    local function close()
        if window then
            local old = window
            window = nil
            Log.safe("close quest box mover", function()
                old:Destroy()
            end)
        end
    end

    -- Opens the window at the quest box's current spot, or brings it to the front.
    function self:open()
        if window then
            Log.safe("show quest box mover", function()
                window:Show()
            end)
            return
        end

        local holder = findHolder()

        if holder == nil then
            Log.write("couldn't open the quest box mover: game area not found")
            return
        end

        local x, y = ItemTooltip.place(preferences:getBox(), { width = holder.width, height = holder.height }, WIDTH, HEIGHT)

        Log.safe("open quest box mover", function()
            local current
            current = prettyui.Window.new(holder, {
                title = "Quest box",
                x = x,
                y = y,
                width = WIDTH,
                height = HEIGHT,
                respectInterfaceLock = false,
                onPositionChange = function(_, newX, newY)
                    if window == current and not preferences:setBox(newX, newY) then
                        Log.write("quest box spot not saved, unexpected value:", tostring(newX), tostring(newY))
                    end
                end,
                onClose = function()
                    if window == current then
                        close()
                    end
                end,
            })

            current:AddText("Drag this window by its title. Its top-left corner is where the quest list shows when you hover a marker icon. Close it when you're done.")
            window = current
        end)
    end

    function self:stop()
        close()
    end

    return self
end

return BoxMover
