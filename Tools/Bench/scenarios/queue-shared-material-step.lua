-- One material step for the whole queue (user, 2026-11-10): Big Bronze
-- Knife, Silvered Bronze Breastplate and the like all need Bronze Bars.
-- Craft next smelted 2 for the first entry, crafted it, then smelted 4 for
-- the next. Now the first step smelts all of them at once.
local bench = dofile(BENCH_DIR .. "bench.lua")
local ORE, BAR, KNIFE, PLATE = 990051, 990052, 990053, 990054
local SMELT, FORGE_KNIFE, FORGE_PLATE = 990151, 990152, 990153
local db = bench.LoadSaved()
local function Recipe(id, name, out, prof, reagentID, reagentName, qty)
    db.recipes[id] = { recipeID = id, name = name, outputName = name, outputItemID = out,
        outputQty = 1, outputMin = 1, outputMax = 1, profession = prof, skillLine = prof,
        reagents = { { itemIDs = { reagentID }, names = { reagentName }, quantity = qty } } }
end
Recipe(SMELT, "Bench Bronze Bar", BAR, "Mining", ORE, "Bench Ore", 1)
Recipe(FORGE_KNIFE, "Bench Knife", KNIFE, "Blacksmithing", BAR, "Bench Bronze Bar", 2)
Recipe(FORGE_PLATE, "Bench Plate", PLATE, "Blacksmithing", BAR, "Bench Bronze Bar", 4)
db.ownScan.prices[ORE] = { 10 }
db.ownScan.prices[BAR] = { bench.Gold(1) }
db.ownScan.prices[KNIFE] = { bench.Gold(9) }
db.ownScan.prices[PLATE] = { bench.Gold(19) }
local myst = db.characters["Mysticmead-Sargeras"]
myst.knownRecipes[SMELT], myst.knownRecipes[FORGE_KNIFE], myst.knownRecipes[FORGE_PLATE] = true, true, true
myst.stock[ORE] = 6
db.queues["Mysticmead-Sargeras"] = {
    { recipeID = FORGE_KNIFE, quantity = 1, made = 0, added = os.time() },
    { recipeID = FORGE_PLATE, quantity = 1, made = 0, added = os.time() },
}
bench.AddItem(ORE, "Bench Ore", { stack = 20 })
bench.AddItem(BAR, "Bench Bronze Bar", { stack = 20 })
bench.AddItem(KNIFE, "Bench Knife", { stack = 1 })
bench.AddItem(PLATE, "Bench Plate", { stack = 1 })
local addon = bench.Login("Mysticmead", { db = db })
bench.SetBags({ [ORE] = 6 })
ProfessionsFrame.CraftingPage.SchematicForm.GetRecipeInfo = function() return nil end

local function State()
    local q = addon:BuildQueue(addon.charKey)
    local row = addon:QueueNextRow(q)
    return row and row.state or {}, q
end

bench.OpenProfession("Mining")
local s = State()
bench.Equal("the step is the bars", s.recipeID, SMELT)
bench.Equal("smelts for both entries", s.crafts, 6)
bench.Has("says it's for the whole queue", table.concat(s.notes or {}, " "), "whole queue", true)

-- Ore for only 4: smelts the 4 it can
bench.SetBags({ [ORE] = 4 })
s = State()
bench.Equal("short on ore: what it can", s.crafts, 4)

-- One entry alone: just its own 2, no note
bench.SetBags({ [ORE] = 6 })
db.queues["Mysticmead-Sargeras"][2].made = 1
s = State()
bench.Equal("one entry: its own bars", s.crafts, 2)
bench.HasNot("no whole-queue note", table.concat(s.notes or {}, " "), "whole queue", true)
db.queues["Mysticmead-Sargeras"][2].made = 0

-- All smelted: both entries go on to Blacksmithing
bench.SetBags({ [ORE] = 0, [BAR] = 6 })
s = State()
bench.Equal("bars made: Blacksmithing next", s.label, "Open Blacksmithing")
bench.Done()
