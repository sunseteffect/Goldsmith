-- A material from another profession: Heavy Copper Maul needs Copper Bar
-- from Mining. The button was a greyed-out "Open Mining", and with Mining
-- open it said Open Blacksmithing, so the bars could never be made (user,
-- 2026-11-06).
local bench = dofile(BENCH_DIR .. "bench.lua")
local ORE, BAR, MAUL = 990041, 990042, 990043
local SMELT, FORGE = 990141, 990142
local db = bench.LoadSaved()
db.recipes[SMELT] = { recipeID = SMELT, name = "Smelt Bench", outputName = "Bench Bar", outputItemID = BAR,
    outputQty = 1, outputMin = 1, outputMax = 1, profession = "Mining", skillLine = "Mining",
    reagents = { { itemIDs = { ORE }, names = { "Bench Ore" }, quantity = 1 } } }
db.recipes[FORGE] = { recipeID = FORGE, name = "Bench Maul", outputName = "Bench Maul", outputItemID = MAUL,
    outputQty = 1, outputMin = 1, outputMax = 1, profession = "Blacksmithing", skillLine = "Blacksmithing",
    reagents = { { itemIDs = { BAR }, names = { "Bench Bar" }, quantity = 2 } } }
db.ownScan.prices[ORE] = { 10 }
db.ownScan.prices[BAR] = { bench.Gold(1) }
db.ownScan.prices[MAUL] = { bench.Gold(9) }
local myst = db.characters["Mysticmead-Sargeras"]
myst.knownRecipes[SMELT], myst.knownRecipes[FORGE] = true, true
myst.stock[ORE] = 2
db.queues["Mysticmead-Sargeras"] = { { recipeID = FORGE, quantity = 1, made = 0, added = os.time() } }
bench.AddItem(ORE, "Bench Ore", { stack = 20 })
bench.AddItem(BAR, "Bench Bar", { stack = 20 })
bench.AddItem(MAUL, "Bench Maul", { stack = 1 })
local addon = bench.Login("Mysticmead", { db = db })
bench.SetBags({ [ORE] = 2 })
-- The stand-in form answers with a number; the real one a recipe or nil
ProfessionsFrame.CraftingPage.SchematicForm.GetRecipeInfo = function() return nil end

local function State()
    local q = addon:BuildQueue(addon.charKey)
    local row = addon:QueueNextRow(q)
    return row and row.state or {}, q
end

-- Nothing open: straight to Mining, not via Blacksmithing
local s = State()
bench.Equal("nothing open: opens Mining", s.label, "Open Mining")
bench.Check("the button works", s.enabled == true)

bench.OpenProfession("Blacksmithing")
s = State()
bench.Equal("Blacksmithing open: opens Mining", s.label, "Open Mining")
bench.Check("the button works there too", s.enabled == true)
bench.Calls()
addon:CraftNext()
bench.Advance(1)
bench.Has("it opens the smelting recipe", bench.Calls(), "OpenRecipe(" .. SMELT, true)

bench.CloseProfession()
bench.OpenProfession("Mining")
s = State()
bench.Has("Mining open: smelts", s.label or "", "Craft")
bench.Equal("the step is the bars", s.recipeID, SMELT)
bench.Check("no way back to Blacksmithing yet", s.open ~= true)

-- Bars made: now the maul
bench.SetBags({ [ORE] = 0, [BAR] = 2 })
s = State()
bench.Equal("bars made: back to Blacksmithing", s.label, "Open Blacksmithing")

-- A character without Mining can't open it
db.characters["Mysticmead-Sargeras"].knownRecipes[SMELT] = nil
bench.SetBags({ [ORE] = 2, [BAR] = 0 })
s = State()
bench.Check("doesn't know it: no Open button", not (s.open and s.label == "Open Mining"))
bench.Done()
