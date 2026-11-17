-- The backpack: inventory INV (93), 28 slots, drawn in interface 1473
-- (TOPLEVEL_V2_INVENTORY) under static component 5. The reading logic is shared and
-- lives in slot_screen.lua.

local SlotScreen = require("src/screens/slot_screen")

return SlotScreen.new({
    name = "Backpack",
    label = "backpack",
    inventory = "INV",
    interfaceId = 1473,
    staticId = 5,
})
