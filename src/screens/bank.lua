-- The bank screen (design doc, Technical Plan §0): inventory BANK (95), 1920 slots,
-- drawn by interface 517 (BANK), static component 201, one dynamic child per slot
-- with dynamicID = slot - 1. The read itself is in slot_screen.lua.
--
-- Bank facts from M0:
--   * Empty slot components show object 48447 ("Empty slot"); the inventory has -1
--     there, so empty slots are skipped before their component is looked at.
--   * Placeholders are the real item id with count 0. They are read like the item and
--     get marked too (design Goals, CUJ 2: a marked placeholder tells the player they
--     used up an item a quest still needs).
--   * Tab switches and searches don't change the slot-to-component mapping; they only
--     move and hide slot components, which the per-frame sync in markers.lua follows.
--   * Interface 517 can stay loaded after the bank closes, so "open" also needs the
--     slot container to be visible (slot_screen.lua's isOpen).

local SlotScreen = require("src/screens/slot_screen")

return SlotScreen.new({
    name = "Bank",
    label = "bank",
    inventory = "BANK",
    interfaceId = 517,
    staticId = 201,
})
