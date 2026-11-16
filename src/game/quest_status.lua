-- Knows the state of every quest in the data (finished, in progress, ...) and keeps
-- it up to date from game events, so nothing else ever has to read quest status.
--
-- How it stays fresh (author decision, 2026-11-16; design doc Technical Plan §5):
--   * After login, every quest in the data is read once, a few per logic tick so a
--     login never stalls a frame.
--   * While reading, each quest's progress variables (config.Quest masterQuestVars)
--     are mapped back to the quest. When the server sends a new value for one of
--     them (Event.VarTransmit), only the quests using that variable are re-read.
--   * A quest with no variable we can watch is re-read when a screen opens, at most
--     once every ~30 seconds (refreshUnwatched).
--   * Turning markers on or off reads nothing. The marker code only ever asks get().
--
-- Owns: the GameStateChanged and VarTransmit subscriptions, the Logic subscription
-- that works through the read queue (only while there's something to read), the
-- cached states, and the variable-to-quest map.

local QuestState = require("src/game/quest_state")
local Log = require("src/log")

local QuestStatus = {}

-- How many quests to read per logic tick (50 ticks a second). 227 quests take about
-- ten ticks, a fifth of a second. M0 and Skill Tips read 50-100 configs per tick
-- without hitting the client's execution limit.
local QUESTS_PER_TICK = 25

-- Unwatched quests are re-read at most once per this many server ticks (~0.6 s
-- each), so about every 30 seconds, however often screens open (author, 2026-11-16).
-- Longer never delays an icon: icons always draw from the cache. It only means a
-- finished unwatched quest can keep its icon up to 30 s longer.
local UNWATCHED_COOLDOWN_TICKS = 50

local SUBSCRIPTION = "quest-item-marker-quest-status"

-- quests: the list from QuestData. onChanged(reason, changedIds) is called after the
-- first full read ("ready"), after a re-read that changed at least one state
-- ("changed"), and when everything was forgotten at logout ("reset").
function QuestStatus.new(quests, onChanged)
    local self = {
        active = true,

        -- [questId] = state (see quest_state.lua). Empty until the first read is done.
        states = {},

        -- True once the first full read after login has finished. Until then no icons
        -- are drawn: an unread quest would count as "unknown", which marks everything.
        ready = false,

        -- [varId] = { questId, ... }: which quests to re-read when that variable changes.
        questsByVar = {},

        -- { questId, ... }: quests with no variable we can watch.
        unwatched = {},

        -- Counts for the log, also used by the in-game test that toggling markers
        -- reads nothing.
        counts = { quests = #quests, read = 0, unwatched = 0, missing = 0 },
    }

    local questById = {}

    for _, quest in ipairs(quests) do
        questById[quest.id] = quest
    end

    -- Quests waiting to be read: a list in order, plus a set so nothing is queued twice.
    local queue, queued = {}, {}

    -- True while the queue holds the first full read after login.
    local fullRead = false

    -- Quest ids whose state changed during the current batch of re-reads.
    local changed = {}

    local logicSubscribed = false
    local lastUnwatchedTick = nil

    -- The full read has only just read the unwatched quests too, so the first
    -- screen-open after it (right after login) doesn't need to read them again.
    local unwatchedFresh = false

    local function notify(reason, ids)
        if self.active then
            onChanged(reason, ids)
        end
    end

    -- Remembers which variables hold this quest's progress. A varbit is watched by
    -- both its own id and its base variable's id, because the client can send the
    -- whole base variable instead of the bit (the Profit Path tool-belt finding).
    -- Returns true if at least one variable was mapped.
    local function mapVariables(questId, questConfig)
        local mapped = false

        local ok = pcall(function()
            for _, descriptor in pairs(questConfig.masterQuestVars or {}) do
                local variable = descriptor.varPlayer

                if variable then
                    local ids = { variable.id }

                    if variable.isVarBit and variable.baseVar then
                        ids[#ids + 1] = variable.baseVar.id
                    end

                    for _, varId in ipairs(ids) do
                        if type(varId) == "number" then
                            local list = self.questsByVar[varId] or {}
                            self.questsByVar[varId] = list
                            list[#list + 1] = questId
                            mapped = true
                        end
                    end
                end
            end
        end)

        return ok and mapped
    end

    -- Reads one quest's state from the client. On the first full read it also maps
    -- the quest's variables.
    local function readQuest(questId)
        local questConfig = nil

        pcall(function()
            questConfig = config.Quest.FromID(questId)
        end)

        local state = QuestState.fromConfig(questConfig)
        self.counts.read = self.counts.read + 1

        if fullRead then
            if state == "missing" then
                self.counts.missing = self.counts.missing + 1
            elseif not mapVariables(questId, questConfig) then
                self.unwatched[#self.unwatched + 1] = questId
                self.counts.unwatched = self.counts.unwatched + 1
            end
        end

        local before = self.states[questId]
        self.states[questId] = state

        -- During the full read everything is "new"; only re-reads report changes.
        if not fullRead and before ~= state then
            changed[#changed + 1] = questId

            local quest = questById[questId]
            Log.write(quest and quest.name or questId, "is now", state, "(was " .. tostring(before) .. ")")
        end
    end

    local function stopReading()
        if logicSubscribed then
            Event.Logic.Unsubscribe(SUBSCRIPTION)
            logicSubscribed = false
        end
    end

    -- Called when the queue runs dry.
    local function finishBatch()
        stopReading()

        if fullRead then
            fullRead = false
            unwatchedFresh = true
            self.ready = true

            Log.write(
                "quest status read:", self.counts.quests, "quests |",
                self.counts.unwatched, "with no watchable variable (re-read when a screen opens) |",
                self.counts.missing, "unknown to this client (not marked)"
            )

            notify("ready")
            return
        end

        if #changed > 0 then
            local ids = changed
            changed = {}
            notify("changed", ids)
        end
    end

    -- One logic tick's worth of reading. Waits while the player isn't loaded yet:
    -- quest flags read before that can't be trusted.
    local function readSome()
        if not self.active then
            return
        end

        local available = false

        pcall(function()
            available = Player.IsAvailable()
        end)

        if not available then
            return
        end

        for _ = 1, QUESTS_PER_TICK do
            local questId = table.remove(queue, 1)

            if questId == nil then
                break
            end

            queued[questId] = nil
            readQuest(questId)
        end

        if #queue == 0 then
            finishBatch()
        end
    end

    local function enqueue(questId)
        if queued[questId] then
            return
        end

        queued[questId] = true
        queue[#queue + 1] = questId

        if not logicSubscribed then
            logicSubscribed = true
            Event.Logic.Subscribe(SUBSCRIPTION, readSome)
        end
    end

    -- Forgets everything we read: states, variable map, queue.
    local function forget()
        stopReading()

        self.ready = false
        self.states = {}
        self.questsByVar = {}
        self.unwatched = {}
        self.counts.read = 0
        self.counts.unwatched = 0
        self.counts.missing = 0

        queue, queued, changed = {}, {}, {}
        fullRead = false
        lastUnwatchedTick = nil
        unwatchedFresh = false
    end

    -- Queues every quest in the data. Its results become the cache; the variable map
    -- is built along the way.
    local function startFullRead()
        forget()
        fullRead = true

        for _, quest in ipairs(quests) do
            enqueue(quest.id)
        end
    end

    -- Re-reads quests without a watchable variable. Markers call this when a screen
    -- opens. serverTick is their ServerLogic counter, used as the clock (the sandbox
    -- has no os.clock). Inside the cooldown the cached states are used as they are.
    function self:refreshUnwatched(serverTick)
        if not self.active or not self.ready or #self.unwatched == 0 then
            return false
        end

        if lastUnwatchedTick and serverTick - lastUnwatchedTick < UNWATCHED_COOLDOWN_TICKS then
            return false
        end

        lastUnwatchedTick = serverTick

        if unwatchedFresh then
            unwatchedFresh = false
            return false
        end

        for _, questId in ipairs(self.unwatched) do
            enqueue(questId)
        end

        return true
    end

    -- The cached state for one quest. nil before the first read.
    function self:get(questId)
        return self.states[questId]
    end

    -- A game variable changed. Re-read only the quests that store progress in it.
    local function onVarTransmit(event)
        if not self.active or not self.ready then
            return
        end

        local varId = event.var and event.var.id
        local questIds = varId and self.questsByVar[varId]

        -- The server sometimes re-sends a value without changing it.
        if not questIds or event.oldValue == event.newValue then
            return
        end

        local names = {}

        for _, questId in ipairs(questIds) do
            local quest = questById[questId]
            names[#names + 1] = quest and quest.name or tostring(questId)
            enqueue(questId)
        end

        -- Kept in the log on purpose: quest variables change rarely, and this line is
        -- how the M2 in-game check confirms the event fires on quest progress.
        Log.write(
            "quest variable", varId, "changed", tostring(event.oldValue), "->", tostring(event.newValue),
            "| re-reading", table.concat(names, ", ")
        )
    end

    -- Login, logout, world hop... Logging out (or reaching the lobby) may mean a
    -- different character next, so forget every state. Coming into the game starts
    -- a fresh full read.
    local function onGameStateChanged(event)
        if not self.active then
            return
        end

        local newState = event.newState

        if newState == GameState.LOGINSCREEN or newState == GameState.LOBBY then
            forget()
            notify("reset")
        elseif newState == GameState.GAME and not self.ready and not fullRead then
            startFullRead()
        end
    end

    function self:start()
        Event.VarTransmit.Subscribe(SUBSCRIPTION, function(event)
            local ok, problem = pcall(onVarTransmit, event)

            if not ok then
                Log.write("VarTransmit handler failed:", problem)
            end
        end)

        Event.GameStateChanged.Subscribe(SUBSCRIPTION, function(event)
            local ok, problem = pcall(onGameStateChanged, event)

            if not ok then
                Log.write("GameStateChanged handler failed:", problem)
            end
        end)

        -- Plugin turned on (or reloaded) while already in game: read now. Otherwise
        -- the GAME state change above starts the read after login.
        local inGame = false

        pcall(function()
            inGame = Player.IsAvailable()
        end)

        if inGame then
            startFullRead()
        end
    end

    -- Safe to call twice. Unsubscribes everything; late callbacks see active = false.
    function self:stop()
        if not self.active then
            return
        end

        self.active = false
        stopReading()
        Event.VarTransmit.Unsubscribe(SUBSCRIPTION)
        Event.GameStateChanged.Unsubscribe(SUBSCRIPTION)
        forget()
    end

    return self
end

return QuestStatus
