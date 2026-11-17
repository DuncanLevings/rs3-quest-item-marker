-- Attaches a hover tooltip to a marker icon. The tooltip shows at the spot the player
-- picked ("Move quest box"), with a quest sprite in front of each quest line.
--
-- Owns a weak table of per-tooltip layout details. The tooltip itself belongs to its
-- icon, and markers.lua destroys the two together.

local Log = require("src/log")

local ItemTooltip = {}

-- PrettyUI's tooltip padding (tooltip.lua PADDING_X / PADDING_Y), plus a little slack
-- so a measured line never wraps.
local PADDING_X = 8
local PADDING_Y = 5
local SLACK = 4

-- The quest sprite in front of a quest line, and the space after it.
local LINE_ICON_SIZE = 14
local LINE_ICON_GAP = 4
local INDENT = LINE_ICON_SIZE + LINE_ICON_GAP

-- Never wider than this; longer lines wrap under their quest sprite.
local MAX_WIDTH = 320

-- Used when the client can't measure text (and in tests).
local FALLBACK_LINE_HEIGHT = 18

-- Where the tooltip goes before the player moves it: centred, this share of the
-- screen down from the top.
local DEFAULT_TOP = 0.15

-- PrettyUI keeps a tooltip this far inside its parent (tooltip.lua OFFSET).
local EDGE_MARGIN = 6

-- [tooltip] = { kinds, tops, rowHeight, sprite, position, lineIcons, decoratedParts }
local details = setmetatable({}, { __mode = "k" })

-- The highest ancestor of a component (for game slots, interface 1477). Capped so a
-- strange parent loop can't hang the client.
function ItemTooltip.topAncestor(component)
    local current = component

    for _ = 1, 50 do
        local ok, parent = pcall(function()
            return current.parent
        end)

        if not ok or parent == nil then
            break
        end

        current = parent
    end

    return current
end

local function lines(text)
    local result = {}

    for line in (text .. "<br>"):gmatch("(.-)<br>") do
        result[#result + 1] = line
    end

    return result
end

local function textWidth(line)
    local plain = line:gsub("<[^>]*>", "")
    local ok, width = pcall(function()
        return config.Font.MUSEO_SANS_15PT_REGULAR:GetStringWidth(plain, false)
    end)

    if not ok or type(width) ~= "number" then
        width = #plain * 7
    end

    return width
end

-- Height of one line of text once wrapped to `width`.
local function textHeight(line, width)
    local ok, height = pcall(function()
        local font = config.Font.MUSEO_SANS_15PT_REGULAR
        return font:GetStringHeightAndLineCount(line, width, font.baseline, false, false, false)
    end)

    if ok and type(height) == "number" and height > 0 then
        return height
    end

    return FALLBACK_LINE_HEIGHT * math.max(1, math.ceil(textWidth(line) / math.max(1, width)))
end

-- Size of the tooltip for `text`, and where each line starts (y inside the tooltip).
-- PrettyUI measures the whole string as one line, which with <br> breaks gives the
-- width of every line added together, so we measure line by line instead.
function ItemTooltip.layout(text)
    local textLines = lines(text)
    local widest = 0

    for _, line in ipairs(textLines) do
        widest = math.max(widest, textWidth(line))
    end

    local width = math.min(MAX_WIDTH, widest + INDENT + PADDING_X * 2 + SLACK)
    local labelWidth = width - INDENT - PADDING_X * 2
    local tops, y = {}, PADDING_Y

    for index, line in ipairs(textLines) do
        tops[index] = y
        y = y + textHeight(line, labelWidth)
    end

    return width, y + PADDING_Y, tops, textHeight("Ag", labelWidth)
end

-- Where a tooltip `width` x `height` goes on a `screen` (holder) of that size: at
-- `saved` ({ x, y }, its top-left corner) or the default spot, moved back on screen
-- if it would run off. Pure, so it can be tested.
function ItemTooltip.place(saved, screen, width, height)
    local x, y

    if saved then
        x, y = saved.x, saved.y
    else
        x = math.floor((screen.width - width) / 2)
        y = math.floor(screen.height * DEFAULT_TOP)
    end

    x = math.max(EDGE_MARGIN, math.min(x, screen.width - EDGE_MARGIN - width))
    y = math.max(EDGE_MARGIN, math.min(y, screen.height - EDGE_MARGIN - height))

    return x, y
end

local function removeLineIcons(detail)
    for _, sprite in ipairs(detail.lineIcons) do
        pcall(function()
            sprite:Destroy()
        end)
    end

    detail.lineIcons = {}
end

-- Indents the label and puts a quest sprite in front of each quest line (PrettyUI
-- tooltips only take text). The sprites are children of the tooltip's root, so Hide
-- removes them. Safe to call again after a text change: old sprites go first.
local function decorate(tooltip)
    local detail = details[tooltip]
    local parts = rawget(tooltip, "_parts")

    if detail == nil or parts == nil or detail.sprite == nil or #detail.kinds == 0 then
        return
    end

    if detail.decoratedParts == parts then
        removeLineIcons(detail)
    else
        -- New parts: the old sprites went with the old root.
        detail.lineIcons = {}
    end

    detail.decoratedParts = parts

    parts.label:SetPos(PADDING_X + INDENT, PADDING_Y)
    parts.label:SetSize(-(PADDING_X * 2 + INDENT), -PADDING_Y * 2, 1.0, 1.0)

    -- Level with the first (or only) row of its line.
    local offset = math.floor((detail.rowHeight - LINE_ICON_SIZE) / 2 + 0.5)

    for index, kind in ipairs(detail.kinds) do
        local top = detail.tops[index]

        if kind == "quest" and top then
            local sprite = prettyui.NewComponent(ui.Sprite, parts.root, { categoryID = "auto" })
            sprite.sprite = detail.sprite
            sprite:SetSize(LINE_ICON_SIZE, LINE_ICON_SIZE)
            sprite:SetPos(PADDING_X, math.floor(top) + offset)
            sprite.clickthrough = true
            detail.lineIcons[#detail.lineIcons + 1] = sprite
        end
    end
end

-- Places the tooltip and shows it. We set x/y ourselves because PrettyUI positions
-- from the icon's local coordinates, which are wrong for a slot nested in a window.
local function show(tooltip, holder)
    local detail = details[tooltip]
    local saved = detail and detail.position and detail.position()
    local x, y = ItemTooltip.place(saved, { width = holder.width, height = holder.height }, tooltip.width, tooltip.height)

    tooltip.options.x = x
    tooltip.options.y = y
    tooltip:Show()

    -- The sprites are a nicety: if they fail, the text tooltip still stands.
    local ok, problem = pcall(decorate, tooltip)

    if not ok then
        Log.error("tooltip quest icons failed:", problem)
    end
end

-- Hooks a tooltip onto our `icon`. `holder` is the slot's top ancestor, so the
-- tooltip draws above windows like the bank. `kinds` says what each line of `text`
-- is ("quest" lines get a sprite). options: sprite (quest sprite id), position
-- (returns the saved { x, y } or nil). The caller must Destroy() it before the icon.
function ItemTooltip.attach(icon, holder, text, kinds, options)
    local width, height, tops, rowHeight = ItemTooltip.layout(text)
    local tooltip = prettyui.Tooltip.attach(icon, holder, {
        parent = holder,
        categoryID = "auto",
        text = text,
        width = width,
        height = height,
    }, {
        onMouseOver = function(tooltip)
            -- This runs inside a client hover hook, so log a failure here instead of
            -- letting it escape into the client.
            local ok, problem = pcall(show, tooltip, holder)

            if not ok then
                Log.error("tooltip failed to show:", problem)
            end
        end,
    })

    -- attach turns clickthrough off; turn it back on so clicks reach the item. Hover
    -- still fires on a click-through icon.
    icon.clickthrough = true

    if tooltip then
        details[tooltip] = {
            kinds = kinds or {},
            tops = tops,
            rowHeight = rowHeight,
            sprite = options and options.sprite,
            position = options and options.position,
            lineIcons = {},
        }
    end

    return tooltip
end

-- Changes the text of an attached tooltip, resizing it to the new lines.
function ItemTooltip.setText(tooltip, text, kinds)
    local detail = details[tooltip]
    local width, height, tops, rowHeight = ItemTooltip.layout(text)

    if detail then
        detail.kinds = kinds or {}
        detail.tops = tops
        detail.rowHeight = rowHeight
    end

    tooltip.options.width = width
    tooltip.options.height = height
    tooltip:SetText(text)

    -- If it's on screen right now, lay the sprites out for the new lines.
    if rawget(tooltip, "_parts") then
        pcall(decorate, tooltip)
    end
end

return ItemTooltip
