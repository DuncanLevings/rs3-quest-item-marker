-- The bank: inventory BANK (95), 1920 slots, drawn in interface 517 (BANK) under
-- static component 201. The reading logic is shared and lives in slot_screen.lua.
-- Placeholders read like their item, so they get marked too.

local SlotScreen = require("src/screens/slot_screen")

return SlotScreen.new({
    name = "Bank",
    label = "bank",
    inventory = "BANK",
    interfaceId = 517,
    staticId = 201,
})
