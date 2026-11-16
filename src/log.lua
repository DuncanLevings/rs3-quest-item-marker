-- Console logging for the plugin, plus two tiny helpers for reading native objects
-- safely. Everything we print starts with the same prefix so it's easy to filter in
-- the console (Alt + `).
--
-- Owns nothing.

local Log = {}

local PREFIX = "[Quest Item Marker] "

-- Prints one line. Arguments are joined with spaces, like print().
function Log.write(...)
    local parts = {}

    for index = 1, select("#", ...) do
        parts[#parts + 1] = tostring((select(index, ...)))
    end

    log(PREFIX .. table.concat(parts, " "))
end

-- Reads one field from a native object (component, config, inventory) without
-- throwing. Native objects raise an error for a field their type doesn't have, or
-- once the thing behind them is gone, so "nil" here means "couldn't read it".
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

-- Runs fn in a protected call and logs the error with a label instead of throwing.
-- Returns fn's result, or nil if it failed. (We wrap fn in a closure rather than
-- passing a native function straight to pcall; that crashed a sibling plugin once.)
function Log.safe(label, fn)
    local ok, result = pcall(function()
        return fn()
    end)

    if not ok then
        Log.write(label, "failed:", result)
        return nil
    end

    return result
end

return Log
