-- A small stand-in for the RS3 client API, enough to run the plugin's modules outside
-- the game. Every global the plugin touches is replaced by FakeClient.install(), and
-- the returned table lets a test drive events and look at what was created.
--
-- It only models what the M0 probe proved (see the design doc §0); it is not a test
-- of the real client. Real-client behaviour is checked by the in-game steps in
-- tests/M2_IN_GAME.txt and tests/M3_IN_GAME.txt.

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
        -- The backpack (93) and the bank (95). slots[slot] = item id (nil = empty);
        -- counts[slot] = how many (default 1; 0 for a bank placeholder).
        inventory = { valid = true, slotCount = 28, slots = {}, counts = {} },
        bank = { valid = false, slotCount = 1920, slots = {}, counts = {} },
        playerAvailable = true,
        chatAllowed = true,
        db = {},
        -- The bank interface (517) starts unloaded: the bank is closed.
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
        Inv = { INV = { id = 93 }, BANK = { id = 95 } },
    }

    -- Inventory ---------------------------------------------------------------
    -- Two shop stock lists, like a shop with two stock tabs (M0: the general store's
    -- stock is inventory 24, 40 slots). Sent when a shop opens.
    client.shopStock = {
        [24] = { valid = false, slotCount = 40, slots = {}, counts = {} },
        [25] = { valid = false, slotCount = 40, slots = {}, counts = {} },
    }

    local inventoriesById = {
        [93] = client.inventory,
        [95] = client.bank,
        [24] = client.shopStock[24],
        [25] = client.shopStock[25],
    }

    -- Count of slot reads, so a test can see a closed screen isn't read.
    client.slotReads = 0

    _G.Inventory = {
        -- Takes a config.Inv entry or a plain inventory id (the M0 probe used both).
        Find = function(invConfig)
            local invId = type(invConfig) == "number" and invConfig or (invConfig and invConfig.id)
            local inv = inventoriesById[invId]

            if inv == nil or not inv.valid then
                return nil
            end

            return {
                isValid = true,
                slotCount = inv.slotCount,
                GetSlots = function()
                    client.slotReads = client.slotReads + 1

                    -- A test hook: change the inventory in the middle of a read.
                    if inv.onRead then
                        inv.onRead()
                    end

                    local slots = {}

                    for index = 1, inv.slotCount do
                        local itemId = inv.slots[index]
                        local count = 0

                        if itemId then
                            count = inv.counts[index] or 1
                        end

                        slots[index] = { obj = { id = itemId or -1 }, count = count }
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

    local function iterateOver(container, slots)
        -- The game's slots, then any plugin-made children (our icons): the real client
        -- lists both (M4: a shop's 17 slots read as 22 children with 5 icons).
        function container:IterateDynamicComponents(callback)
            for _, slot in ipairs(slots) do
                if callback(slot, true) then
                    return
                end
            end

            for _, child in ipairs(container.pluginChildren or {}) do
                if not child.destroyed and callback(child, true) then
                    return
                end
            end
        end
    end

    iterateOver(client.container, client.slots)

    -- The bank window (517), drawn above the game like the real one, with the bank
    -- grid (static 201, 1920 slots) and its own backpack panel (static 15, 28 slots).
    -- Hidden until openBank().
    client.bankWindow = newComponent("layer", client.root, { interfaceID = 517, visibleGlobal = false })
    client.bankContainer = newComponent("layer", client.bankWindow, { interfaceID = 517, visibleGlobal = false })
    client.bankBackpackContainer = newComponent("layer", client.bankWindow, { interfaceID = 517, visibleGlobal = false })
    client.bankSlots = {}
    client.bankBackpackSlots = {}

    -- M0: an empty bank slot component shows object 48447 ("Empty slot").
    client.EMPTY_BANK_SLOT = 48447

    for slot = 1, client.bank.slotCount do
        client.bankSlots[slot] = newComponent("slot", client.bankContainer, {
            dynamicID = slot - 1,
            associatedObjectID = client.EMPTY_BANK_SLOT,
            visibleGlobal = true,
            x = ((slot - 1) % 10) * 44,
            y = math.floor((slot - 1) / 10) * 36,
        })
    end

    for slot = 1, 28 do
        client.bankBackpackSlots[slot] = newComponent("slot", client.bankBackpackContainer, {
            dynamicID = slot - 1,
            associatedObjectID = -1,
            visibleGlobal = true,
            x = ((slot - 1) % 4) * 40,
            y = math.floor((slot - 1) / 4) * 36,
        })
    end

    iterateOver(client.bankContainer, client.bankSlots)
    iterateOver(client.bankBackpackContainer, client.bankBackpackSlots)

    -- Puts an item in a backpack slot: in the inventory and on both views of it (the
    -- backpack and the bank's backpack panel), like the real client once updated.
    function client.setSlot(slot, itemId)
        client.inventory.slots[slot] = itemId
        client.slots[slot].associatedObjectID = itemId or -1
        client.bankBackpackSlots[slot].associatedObjectID = itemId or -1
    end

    -- Puts an item in a bank slot, in the inventory and on its component. count 0 is
    -- a placeholder: the real item id with nothing in it (M0). nil empties the slot.
    function client.setBankSlot(slot, itemId, count)
        client.bank.slots[slot] = itemId
        client.bank.counts[slot] = count
        client.bankSlots[slot].associatedObjectID = itemId or client.EMPTY_BANK_SLOT
    end

    -- Opens the bank: the inventory is sent, 517 loads, its containers show.
    function client.openBank()
        client.bank.valid = true
        client.loadedInterfaces[517] = true
        client.bankWindow.visibleGlobal = true
        client.bankContainer.visibleGlobal = true
        client.bankBackpackContainer.visibleGlobal = true
    end

    -- Closes the bank. M0: 517 doesn't always unload, and the bank inventory can
    -- stay valid, so by default only the containers hide.
    function client.closeBank(unload)
        client.bankWindow.visibleGlobal = false
        client.bankContainer.visibleGlobal = false
        client.bankBackpackContainer.visibleGlobal = false

        if unload then
            client.loadedInterfaces[517] = nil
        end
    end

    -- The shop window (1265) with its 40 stock slots (static 24). Hidden until
    -- openShop(). The slots show whichever stock list is on screen.
    client.shopWindow = newComponent("layer", client.root, { interfaceID = 1265, visibleGlobal = false })
    client.shopContainer = newComponent("layer", client.shopWindow, { interfaceID = 1265, visibleGlobal = false })
    client.shopSlots = {}

    for slot = 1, 40 do
        client.shopSlots[slot] = newComponent("slot", client.shopContainer, {
            dynamicID = slot - 1,
            associatedObjectID = -1,
            visibleGlobal = true,
            x = ((slot - 1) % 8) * 48,
            y = math.floor((slot - 1) / 8) * 48,
        })
    end

    iterateOver(client.shopContainer, client.shopSlots)

    -- The same 40 slots in the "full name" display mode, hidden until setShopDisplay.
    client.shopListContainer = newComponent("layer", client.shopWindow, { interfaceID = 1265, visibleGlobal = false })
    client.shopListSlots = {}

    for slot = 1, 40 do
        client.shopListSlots[slot] = newComponent("slot", client.shopListContainer, {
            dynamicID = slot - 1,
            associatedObjectID = -1,
            visibleGlobal = true,
            x = ((slot - 1) % 3) * 160,
            y = math.floor((slot - 1) / 3) * 50,
        })
    end

    iterateOver(client.shopListContainer, client.shopListSlots)

    -- Puts an item in a shop stock list (in the inventory only; showShopList draws it).
    function client.setShopStock(invId, slot, itemId)
        client.shopStock[invId].slots[slot] = itemId
    end

    -- Draws one inventory's items in the shop slots, like switching stock tab (or the
    -- sell view, with 93). No inventory event comes with it.
    function client.showShopList(invId)
        local inv = inventoriesById[invId]

        for slot = 1, 40 do
            client.shopSlots[slot].associatedObjectID = inv.slots[slot] or -1
            client.shopListSlots[slot].associatedObjectID = inv.slots[slot] or -1
        end
    end

    -- What the game does after a purchase (M4, in game): new slot components, and
    -- every other child of the container, our icons included, deleted. The deleted
    -- icons are marked `gone`, not `destroyed`: the plugin didn't destroy them.
    function client.rebuildShop()
        for slot = 1, 40 do
            local old = client.shopSlots[slot]

            client.shopSlots[slot] = newComponent("slot", client.shopContainer, {
                dynamicID = old.dynamicID,
                associatedObjectID = old.associatedObjectID,
                visibleGlobal = true,
                x = old.x,
                y = old.y,
            })
        end

        for _, child in ipairs(client.shopContainer.pluginChildren or {}) do
            child.gone = true
        end

        client.shopContainer.pluginChildren = {}
    end

    -- The shop's "Item display mode": "icons" (1265:24) or "list" (full names, drawn
    -- in another component; 1265:60 here, the real one is found by searching).
    function client.setShopDisplay(mode)
        client.shopContainer.visibleGlobal = mode ~= "list"
        client.shopListContainer.visibleGlobal = mode == "list"
    end

    -- Opens a shop: its stock lists are sent (with InventoryAdded through fire, if a
    -- test wants markers to hear it), 1265 loads, and the first list shows.
    function client.openShop(firstList)
        for _, stock in pairs(client.shopStock) do
            stock.valid = true
        end

        client.loadedInterfaces[1265] = true
        client.shopWindow.visibleGlobal = true
        client.shopContainer.visibleGlobal = true
        client.showShopList(firstList or 24)
    end

    function client.closeShop()
        for _, stock in pairs(client.shopStock) do
            stock.valid = false
        end

        client.shopWindow.visibleGlobal = false
        client.shopContainer.visibleGlobal = false
        client.shopListContainer.visibleGlobal = false
    end

    local containers = {
        ["1265:24"] = function()
            return client.shopContainer
        end,
        ["1265:60"] = function()
            return client.shopListContainer
        end,
        ["1473:5"] = function()
            return client.container
        end,
        ["517:201"] = function()
            return client.bankContainer
        end,
        ["517:15"] = function()
            return client.bankBackpackContainer
        end,
    }

    _G.ui = {
        Sprite = { name = "Sprite" },
        Interfaces = {
            GetComponent = function(_, interfaceId, staticId)
                local find = containers[interfaceId .. ":" .. staticId]

                if find and client.loadedInterfaces[interfaceId] then
                    return find()
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
        -- Like PrettyUI's automatic ids: its own category, a fresh dynamic id, and the
        -- component listed among its parent's children.
        NewComponent = function(kind, parent)
            client.nextPluginDynamicId = (client.nextPluginDynamicId or 9000) + 1

            local component = newComponent(kind.name, parent, { categoryID = 7, dynamicID = client.nextPluginDynamicId })

            if parent then
                parent.pluginChildren = parent.pluginChildren or {}
                parent.pluginChildren[#parent.pluginChildren + 1] = component
            end

            return component
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
        -- Just enough of a SimpleView for the settings panel: it records what was
        -- added, and each checkbox group can be clicked with button:click(value).
        SimpleView = {
            new = function()
                local view = { root = { visibleGlobal = true }, texts = {}, checkboxes = {} }

                function view:AddTitle(text)
                    self.title = text
                end

                function view:AddText(text)
                    self.texts[#self.texts + 1] = text
                end

                function view:AddCheckboxButton(choices, options)
                    local button = { choices = choices, onChange = options.onChange }

                    function button:IsSelected(value)
                        for _, choice in ipairs(self.choices) do
                            if choice.value == value then
                                return choice.selected
                            end
                        end
                    end

                    function button:SetSelected(value, selected, notify)
                        for _, choice in ipairs(self.choices) do
                            if choice.value == value then
                                choice.selected = selected
                            end
                        end

                        if notify ~= false and self.onChange then
                            self.onChange(self, {}, value, selected)
                        end
                    end

                    function button:click(value)
                        self:SetSelected(value, not self:IsSelected(value))
                    end

                    self.checkboxes[#self.checkboxes + 1] = button

                    return button
                end

                function view:AddKeybindField() end

                function view:AddSimpleButton() end

                function view:Destroy()
                    self.destroyed = true
                end

                client.view = view

                return view
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
            if component.kind == "Sprite" and not component.destroyed and not component.gone then
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
