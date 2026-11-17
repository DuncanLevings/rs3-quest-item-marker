-- Runs every spec in tests/. From the plugin folder:
--     lua tests/run.lua
-- LuaUnit isn't installed on this machine, so this is a tiny runner with the same
-- idea: each spec file returns { ["test name"] = function() ... end }, a test fails
-- by raising an error, and the exit code is the number of failures.

local root = arg[0]:match("^(.*)[/\\]tests[/\\][^/\\]+$") or "."
package.path = root .. "/?.lua;" .. package.path

local SPECS = {
    "tests/quest_data_spec",
    "tests/quest_state_spec",
    "tests/required_items_spec",
    "tests/preferences_spec",
    "tests/quest_status_spec",
    "tests/backpack_spec",
    "tests/bank_spec",
    "tests/markers_spec",
    "tests/box_mover_spec",
    "tests/main_spec",
}

local passed, failed = 0, 0

for _, specName in ipairs(SPECS) do
    local spec = require(specName)
    local names = {}

    for name in pairs(spec) do
        names[#names + 1] = name
    end

    table.sort(names)

    for _, name in ipairs(names) do
        -- Fresh modules for every test: some keep state between calls.
        for loaded in pairs(package.loaded) do
            if loaded:match("^src/") then
                package.loaded[loaded] = nil
            end
        end

        local ok, problem = xpcall(spec[name], debug.traceback)

        if ok then
            passed = passed + 1
        else
            failed = failed + 1
            print("FAIL " .. specName .. ": " .. name .. "\n" .. tostring(problem) .. "\n")
        end
    end
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed)
