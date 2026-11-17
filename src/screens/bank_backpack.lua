-- The backpack panel inside the bank screen (design doc, Technical Plan §0): a second
-- view of the backpack inventory INV (93), drawn by interface 517 (BANK), static
-- component 15, one dynamic child per slot with dynamicID = slot - 1. The read itself
-- is in slot_screen.lua. Interface 517 can stay loaded after the bank closes, so
-- "open" also needs this container to be visible.

local SlotScreen = require("src/screens/slot_screen")

return SlotScreen.new({
    name = "Bank backpack",
    label = "bank backpack",
    inventory = "INV",
    interfaceId = 517,
    staticId = 15,
})
