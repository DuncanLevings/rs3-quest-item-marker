-- Assertions for the specs. Each raises an error with both values on failure.

local check = {}

function check.equal(actual, expected, message)
    if actual ~= expected then
        error((message or "values differ") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual), 2)
    end
end

function check.truthy(value, message)
    if not value then
        error(message or "expected a true value", 2)
    end
end

function check.falsy(value, message)
    if value then
        error((message or "expected a false value") .. ", got " .. tostring(value), 2)
    end
end

function check.contains(text, part, message)
    if type(text) ~= "string" or not text:find(part, 1, true) then
        error((message or "text is missing a part") .. ": " .. tostring(part) .. "\nin: " .. tostring(text), 2)
    end
end

function check.lacks(text, part, message)
    if type(text) == "string" and text:find(part, 1, true) then
        error((message or "text has an unwanted part") .. ": " .. tostring(part) .. "\nin: " .. tostring(text), 2)
    end
end

return check
