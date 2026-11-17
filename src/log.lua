-- Error logging plus two helpers for touching native objects safely. Errors only
-- reach the console with Log.DEV on; a published build logs nothing.
--
-- Owns nothing.

local Log = {}

-- Set to true while developing to see caught errors in the console (Alt + `).
-- Must be false in a published build.
Log.DEV = false

local PREFIX = "[Quest Item Marker] "

-- Prints one error line when Log.DEV is on. Arguments are joined like print().
function Log.error(...)
    if not Log.DEV then
        return
    end

    local parts = {}

    for index = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(index, ...)))
    end

    log(PREFIX .. table.concat(parts, " "))
end

-- Reads one field from a native object without throwing. Native objects raise an
-- error for an unknown field or once the thing behind them is gone, so nil here
-- means "couldn't read it".
function Log.field(object, name)
    if object == nil then
        return nil
    end

    local ok, value = pcall(function()
        return object[name]
    end)

    if ok then
        return value
    end

    return nil
end

-- Runs fn protected; on failure logs "<label> failed: <error>" and returns nil.
-- fn is wrapped in a closure because passing a native function straight to pcall
-- can crash the client.
function Log.safe(label, fn)
    local ok, result = pcall(function()
        return fn()
    end)

    if not ok then
        Log.error(label, "failed:", result)
        return nil
    end

    return result
end

return Log
