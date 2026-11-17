-- The backpack screen (design doc, Technical Plan §0): inventory INV (93), 28 slots,
-- drawn by interface 1473 (TOPLEVEL_V2_INVENTORY), static component 5, one dynamic
-- child per slot with dynamicID = slot - 1. The read itself is in slot_screen.lua.

local SlotScreen = require("src/screens/slot_screen")

return SlotScreen.new({
    name = "Backpack",
    label = "backpack",
    inventory = "INV",
    interfaceId = 1473,
    staticId = 5,
})
