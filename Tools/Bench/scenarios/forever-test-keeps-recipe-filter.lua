-- The Forever test on retail (/gsm forever) keeps retail's recipes: an
-- old recipe not learned stays out of Not learned yet, unlike real Forever.
local bench = dofile(BENCH_DIR .. "bench.lua")
local CHAR = "Mysticmead"
local db = bench.LoadSaved()
db.foreverTest = true

-- A recipe with a plain skill line, as Forever has, that nobody has learned
local id, recipe
for rid, r in pairs(db.recipes) do
    if r.profession == "Alchemy" and r.outputItemID then id, recipe = rid, r break end
end
bench.Check("an Alchemy recipe to use (what this tests)", id)
db.recipes[id] = nil
for _, c in pairs(db.characters) do
    if c.knownRecipes then c.knownRecipes[id] = nil end
end
db.unlearned = {}
C_TradeSkillUI.GetTradeSkillLineForRecipe = function(rid)
    if rid == id then return 2906, "Alchemy", 171 end
end

local addon = bench.Login(CHAR, { db = db })
bench.world.recipeInfo[id] = { recipeID = id, learned = false, name = recipe.name, craftable = true, categoryID = 0 }
bench.world.schematics[id] = { recipeID = id, outputItemID = recipe.outputItemID, name = recipe.name,
    quantityMin = 1, quantityMax = 1, reagentSlotSchematics = {} }
bench.OpenProfession("Alchemy")
bench.Advance(10)
bench.Check("Forever mode on", addon.isForever == true)
bench.Check("not saved: only the real game lists all of them", GoldsmithDB.unlearned[id] == nil)
bench.Done()
