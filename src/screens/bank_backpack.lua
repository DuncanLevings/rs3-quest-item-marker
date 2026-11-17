-- The backpack panel inside the bank window. It's a second view of the same backpack
-- inventory INV (93), drawn in interface 517 (BANK) under static component 15. The
-- reading logic is shared and lives in slot_screen.lua.

local SlotScreen = require("src/screens/slot_screen")

return SlotScreen.new({
    name = "Bank backpack",
    label = "bank backpack",
    inventory = "INV",
    interfaceId = 517,
    staticId = 15,
})
