-- A small stand-in for the RS3 client API, enough to run the plugin's modules outside
-- the game. Every global the plugin touches is replaced by FakeClient.install(), and
-- the returned table lets a test drive events and look at what was created.
--
-- It only models what the M0 probe proved (see the design doc §0); it is not a test
-- of the real client. Real-client behaviour is checked by the in-game steps in
-- tests/M2_IN_GAME.txt.

local FakeClient = {}

function FakeClient.install()
    local client = {
        logs = {},
        chat = {},
        -- [eventName] = { [subscriptionName] = handler }
        handlers = {},
        components = {},
        quests = {},
        objects = {},
        inventory = { valid = true, slots = {} },
        playerAvailable = true,
        chatAllowed = true,
        db = {},
        loadedInterfaces = { [1473] = true, [1477] = true },
    }

    _G.log = function(text)
        client.logs[#client.logs + 1] = text
    end

    -- Events ------------------------------------------------------------------
    local function event(name)
        client.handlers[name] = {}

        return {
            Subscribe = function(subscription, handler)
                client.handlers[name][subscription] = handler
            end,
            Unsubscribe = function(subscription)
                client.handlers[name][subscription] = nil
            end,
        }
    end

    _G.Event = {}

    for _, name in ipairs({
        "Logic", "ServerLogic", "Draw", "VarTransmit", "GameStateChanged", "InventoryAdded",
        "InventoryUpdated", "InventoryRemoved", "ContentLayerReady",
    }) do
        Event[name] = event(name)
    end

    -- Fires every handler subscribed to an event.
    function client.fire(name, payload)
        local list = {}

        for _, handler in pairs(client.handlers[name]) do
            list[#list + 1] = handler
        end

        for _, handler in ipairs(list) do
            handler(payload or {})
        end
    end

    -- How many subscriptions exist right now, across all events.
    function client.subscriptionCount()
        local count = 0

        for _, handlers in pairs(client.handlers) do
            for _ in pairs(handlers) do
                count = count + 1
            end
        end

        return count
    end

    function client.subscribed(eventName, subscription)
        return client.handlers[eventName][subscription] ~= nil
    end

    _G.GameState = { LOGINSCREEN = 10, LOBBY = 20, GAME = 30, LOADING = 40 }

    _G.Player = {
        IsAvailable = function()
            return client.playerAvailable
        end,
    }

    _G.Plugin = {
        HasPermission = function()
            return client.chatAllowed
        end,
    }
    _G.PluginPermissions = { chatAccess = "chatAccess" }
    _G.Chat = {
        AddMessage = function(text)
            client.chat[#client.chat + 1] = text
        end,
    }

    -- Configs -----------------------------------------------------------------
    client.questReads = 0

    -- Adds a quest the fake config.Quest knows. vars: list of var descriptors.
    function client.addQuest(questId, flags)
        client.quests[questId] = {
            name = flags.name or ("Quest " .. questId),
            deprecated = flags.deprecated or false,
            hasStartedQuest = flags.started or false,
            hasFinishedQuest = flags.finished or false,
            canStartQuest = flags.canStart ~= false,
            iconID = flags.iconID or 26112,
            masterQuestVars = flags.vars or {},
        }

        return client.quests[questId]
    end

    _G.config = {
        Quest = {
            FromID = function(questId)
                client.questReads = client.questReads + 1
                return client.quests[questId]
            end,
        },
        Obj = {
            FromID = function(itemId)
                return { name = client.objects[itemId] or ("Item " .. itemId) }
            end,
        },
        Inv = { INV = { id = 93 } },
    }

    -- Inventory ---------------------------------------------------------------
    -- client.inventory.slots[slot] = item id (nil = empty).
    _G.Inventory = {
        Find = function()
            local inv = client.inventory

            if not inv.valid then
                return nil
            end

            return {
                isValid = true,
                slotCount = 28,
                GetSlots = function()
                    local slots = {}

                    for index = 1, 28 do
                        slots[index] = { obj = { id = inv.slots[index] or -1 }, count = inv.slots[index] and 1 or 0 }
                    end

                    return slots
                end,
            }
        end,
    }

    -- UI ----------------------------------------------------------------------
    local nextHandle = 0

    -- A fake native component. Destroy() marks it destroyed and counts it.
    local function newComponent(kind, parent, fields)
        nextHandle = nextHandle + 1

        local component = fields or {}
        component.kind = kind
        component.handle = nextHandle
        component.parent = parent
        component.x = component.x or 0
        component.y = component.y or 0
        component.width = component.width or 36
        component.height = component.height or 32
        component.interfaceID = component.interfaceID or (parent and parent.interfaceID)
        component.hooks = {}
        component.destroyed = false

        function component:SetSize(width, height)
            self.width, self.height = width, height
        end

        function component:SetPos(x, y)
            self.x, self.y = x, y
            self.moves = (self.moves or 0) + 1
        end

        function component:Destroy()
            self.destroyed = true
        end

        client.components[#client.components + 1] = component

        return component
    end

    client.root = newComponent("layer", nil, { interfaceID = 1477, xyGlobal = { x = 0, y = 0 }, width = 1920, height = 1080 })
    client.backpackWindow = newComponent("layer", client.root, { interfaceID = 1473, visibleGlobal = true })
    client.container = newComponent("layer", client.backpackWindow, { interfaceID = 1473, visibleGlobal = true })
    client.slots = {}

    for slot = 1, 28 do
        client.slots[slot] = newComponent("slot", client.container, {
            dynamicID = slot - 1,
            associatedObjectID = -1,
            visibleGlobal = true,
            x = ((slot - 1) % 4) * 40,
            y = math.floor((slot - 1) / 4) * 36,
            xyGlobal = { x = 1600 + ((slot - 1) % 4) * 40, y = 600 },
        })
    end

    function client.container:IterateDynamicComponents(callback)
        for _, slot in ipairs(client.slots) do
            if callback(slot, true) then
                break
            end
        end
    end

    -- Puts an item in a backpack slot: in the inventory and on its slot component,
    -- like the real client does once it has updated.
    function client.setSlot(slot, itemId)
        client.inventory.slots[slot] = itemId
        client.slots[slot].associatedObjectID = itemId or -1
    end

    _G.ui = {
        Sprite = { name = "Sprite" },
        Interfaces = {
            GetComponent = function(_, interfaceId, staticId)
                if interfaceId == 1473 and staticId == 5 and client.loadedInterfaces[1473] then
                    return client.container
                end

                return nil
            end,
            GetInterface = function(_, interfaceId)
                return client.loadedInterfaces[interfaceId] and {} or nil
            end,
        },
    }

    -- PrettyUI ----------------------------------------------------------------
    client.tooltips = {}

    _G.prettyui = {
        NewComponent = function(kind, parent)
            return newComponent(kind.name, parent)
        end,
        Tooltip = {
            attach = function(target, holder, options)
                local tooltip = { target = target, holder = holder, options = options, text = options.text, destroyed = false }
                target.hooks.tooltip = true
                -- Like PrettyUI: the target starts taking clicks.
                target.clickthrough = false

                function tooltip:SetText(text)
                    self.text = text
                end

                function tooltip:Destroy()
                    self.destroyed = true
                    target.hooks.tooltip = nil
                end

                client.tooltips[#client.tooltips + 1] = tooltip

                return tooltip
            end,
        },
        KeybindField = {
            IsDown = function(binding)
                return #binding > 0 and client.keyDown == true
            end,
        },
    }

    -- Live (not destroyed) plugin-made icons and tooltips.
    function client.liveIcons()
        local list = {}

        for _, component in ipairs(client.components) do
            if component.kind == "Sprite" and not component.destroyed then
                list[#list + 1] = component
            end
        end

        return list
    end

    function client.liveTooltips()
        local list = {}

        for _, tooltip in ipairs(client.tooltips) do
            if not tooltip.destroyed then
                list[#list + 1] = tooltip
            end
        end

        return list
    end

    function client.hookedSlots()
        local count = 0

        for _, slot in ipairs(client.slots) do
            if slot.hooks.tooltip then
                count = count + 1
            end
        end

        return count
    end

    -- Runs logic ticks until the quest-status read queue is empty (or `limit` ticks).
    function client.runLogic(limit)
        for _ = 1, limit or 50 do
            client.fire("Logic", {})
        end
    end

    _G.PersistentDB = {
        GetStructuredData = function(_, key)
            return client.db[key]
        end,
        SetStructuredData = function(_, key, value)
            client.db[key] = value
            return true
        end,
    }

    return client
end

return FakeClient
