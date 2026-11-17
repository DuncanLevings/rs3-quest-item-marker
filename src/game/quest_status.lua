-- Caches the state of every quest in the data so nothing else reads quest status.
-- All quests are read once after login; after that only the quests whose progress
-- variable changed are re-read, plus quests with no such variable when a screen opens.
--
-- Owns the cached states, the variable-to-quest map, the GameStateChanged and
-- VarTransmit subscriptions, and a Logic subscription while reads are queued.

local QuestState = require("src/game/quest_state")
local Log = require("src/log")

local QuestStatus = {}

-- Quests read per Logic tick (50 a second): ~300 quests take about twelve ticks.
local QUESTS_PER_TICK = 25

-- ~30 s in server ticks. Icons always draw from the cache, so this only bounds how
-- long a finished unwatched quest can keep its icon.
local UNWATCHED_COOLDOWN_TICKS = 50

local SUBSCRIPTION = "quest-item-marker-quest-status"

-- quests: { { id }, ... }, every quest either data file mentions (main.lua merges
-- them). onChanged(reason, changedIds) runs after the first
-- full read ("ready"), after re-reads that changed a state ("changed"), and when
-- everything is forgotten at logout ("reset").
function QuestStatus.new(quests, onChanged)
    local self = {
        active = true,

        -- [questId] = state (see quest_state.lua).
        states = {},

        -- False until the first full read finishes. Markers draw nothing before that:
        -- an unread quest counts as "unknown", which would mark everything.
        ready = false,

        -- [varId] = { questId, ... }: quests to re-read when that variable changes.
        questsByVar = {},

        -- { questId, ... }: quests with no variable we can watch.
        unwatched = {},
    }

    -- The read queue: quest ids in order, read from `head` and added at `tail`, plus a
    -- set so nothing is queued twice. Indexes instead of table.remove(queue, 1), which
    -- would shift the whole list (~300 quests) on every read.
    local queue, queued = {}, {}
    local head, tail = 1, 0

    -- True while the queue holds the first full read after login.
    local fullRead = false

    -- Quest ids whose state changed during the current batch of re-reads.
    local changed = {}

    local logicSubscribed = false
    local lastUnwatchedTick = nil

    -- The full read just covered the unwatched quests, so the first screen-open after
    -- it can skip them.
    local unwatchedFresh = false

    local function notify(reason, ids)
        if self.active then
            onChanged(reason, ids)
        end
    end

    -- Maps this quest's progress variables to it. A varbit is watched by its own id
    -- and its base variable's id, because the server may send the whole base variable.
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

    -- Reads one quest's state. During the full read it also maps its variables.
    local function readQuest(questId)
        local questConfig = nil

        pcall(function()
            questConfig = config.Quest.FromID(questId)
        end)

        local state = QuestState.fromConfig(questConfig)

        if fullRead and state ~= "missing" and not mapVariables(questId, questConfig) then
            self.unwatched[#self.unwatched + 1] = questId
        end

        local before = self.states[questId]
        self.states[questId] = state

        if not fullRead and before ~= state then
            changed[#changed + 1] = questId
        end
    end

    local function stopReading()
        if logicSubscribed then
            Event.Logic.Unsubscribe(SUBSCRIPTION)
            logicSubscribed = false
        end
    end

    -- The queue ran dry.
    local function finishBatch()
        stopReading()

        if fullRead then
            fullRead = false
            unwatchedFresh = true
            self.ready = true
            notify("ready")
            return
        end

        if #changed > 0 then
            local ids = changed
            changed = {}
            notify("changed", ids)
        end
    end

    -- One Logic tick of reading. Waits until the player is loaded: quest flags read
    -- before that can't be trusted.
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
            if head > tail then
                break
            end

            local questId = queue[head]
            queue[head] = nil
            head = head + 1

            queued[questId] = nil
            readQuest(questId)
        end

        -- Ran dry: start the next batch from a fresh, empty list.
        if head > tail then
            queue, head, tail = {}, 1, 0
            finishBatch()
        end
    end

    local function enqueue(questId)
        if queued[questId] then
            return
        end

        queued[questId] = true
        tail = tail + 1
        queue[tail] = questId

        if not logicSubscribed then
            logicSubscribed = true
            Event.Logic.Subscribe(SUBSCRIPTION, readSome)
        end
    end

    local function forget()
        stopReading()

        self.ready = false
        self.states = {}
        self.questsByVar = {}
        self.unwatched = {}

        queue, queued, changed = {}, {}, {}
        head, tail = 1, 0
        fullRead = false
        lastUnwatchedTick = nil
        unwatchedFresh = false
    end

    local function startFullRead()
        forget()
        fullRead = true

        for _, quest in ipairs(quests) do
            enqueue(quest.id)
        end
    end

    -- Re-reads the unwatched quests unless inside the cooldown. Markers call this
    -- when a screen opens; serverTick is their ServerLogic counter (the sandbox has
    -- no clock). Returns true if a re-read was queued.
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

    -- The cached state for one quest; nil before the first read.
    function self:get(questId)
        return self.states[questId]
    end

    local function onVarTransmit(event)
        if not self.active or not self.ready then
            return
        end

        local varId = event.var and event.var.id
        local questIds = varId and self.questsByVar[varId]

        -- The server sometimes re-sends a value unchanged.
        if not questIds or event.oldValue == event.newValue then
            return
        end

        for _, questId in ipairs(questIds) do
            enqueue(questId)
        end
    end

    -- Logout or the lobby may mean another character next, so forget everything;
    -- entering the game starts a fresh full read.
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
                Log.error("VarTransmit handler failed:", problem)
            end
        end)

        Event.GameStateChanged.Subscribe(SUBSCRIPTION, function(event)
            local ok, problem = pcall(onGameStateChanged, event)

            if not ok then
                Log.error("GameStateChanged handler failed:", problem)
            end
        end)

        -- Started (or reloaded) while already in game: read now. Otherwise the GAME
        -- state change starts it after login.
        local inGame = false

        pcall(function()
            inGame = Player.IsAvailable()
        end)

        if inGame then
            startFullRead()
        end
    end

    -- Safe to call twice; late callbacks see active = false.
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
