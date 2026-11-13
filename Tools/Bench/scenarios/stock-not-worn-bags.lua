-- Bags you wear aren't stock: two Linen Reagent Bags in bag slots said
-- "You have 2" on the Crafts list (user, Forever, 2026-11-13). Worn gear
-- and profession tools were already left out (slots 1-30); bag slots come
-- after them. Bags in the bank's bag slots (Forever) too, kept as last seen
-- while the bank's closed.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local BAG = 990020
bench.AddItem(BAG, "Bench Reagent Bag", { stack = 1 })
-- A recipe makes it, so its stock is counted
GoldsmithDB.recipes[990021] = { recipeID = 990021, profession = "Tailoring", outputItemID = BAG,
    outputName = "Bench Reagent Bag", reagents = {} }

-- 3 held: one worn in bag slot 2, one in a bank bag slot, one spare
NUM_BANKBAGSLOTS = NUM_BANKBAGSLOTS or 7
local worn = NUM_TOTAL_EQUIPPED_BAG_SLOTS or 5
local slots = { [100 + 2] = BAG, [100 + worn + 1] = BAG }
local realToInv, realInv = C_Container.ContainerIDToInventoryID, GetInventoryItemID
C_Container.ContainerIDToInventoryID = function(bag) return 100 + bag end
GetInventoryItemID = function(_, slot) return slots[slot] end
bench.SetBags({ [BAG] = 3 })

local function Counted()
    bench.Fire("BAG_UPDATE_DELAYED")
    addon:CountStockIfStale()
    bench.Advance(3)
    return addon.char.stock[BAG]
end
bench.world.bankOpen = true
bench.Equal("worn and bank-slot bags left out", Counted(), 1)
bench.world.bankOpen = false

-- The bank closed: its bag slots can't be read, the one seen stays out
slots[100 + worn + 1] = nil
bench.SetBags({ [BAG] = 3 })
bench.Equal("bank closed: still left out", Counted(), 1)

-- Taken off: counted again
slots[100 + 2] = nil
bench.SetBags({ [BAG] = 3 })
bench.Equal("not worn: counted", Counted(), 2)

C_Container.ContainerIDToInventoryID, GetInventoryItemID = realToInv, realInv
bench.Done()
