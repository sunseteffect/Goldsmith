-- A German client: skill lines end with the expansion ("Alchemie aus
-- Midnight"), so 2.7.5's last word of the skill line saved every recipe
-- as "Midnight". The button said "Open Midnight" and crafting never
-- started (Lokir, 2026-11-04). Now the skill line's parent names the
-- profession; recipes already saved as "Midnight" are put right at login
-- when the game can say, else when their profession window opens.
local bench = dofile(BENCH_DIR .. "bench.lua")
local CHAR = "Mysticmead"
local db = bench.LoadSaved()

-- Two recipes this character knows, of one profession
local charKey
for key in pairs(db.characters) do
    if key:match("^" .. CHAR .. "%-") then charKey = key end
end
local c = db.characters[charKey]
local profession, A, B, C
for id, r in pairs(db.recipes) do
    if c.knownRecipes and c.knownRecipes[id] and r.profession == "Alchemy" then
        if not A then A = id elseif not B then B = id elseif not C then C = id break end
    end
end
profession = "Alchemy"
bench.Check("three Alchemy recipes this character knows (what this tests)", A and B and C)
for _, id in ipairs({ A, B, C }) do db.recipes[id].profession = "Midnight" end
-- Their saved skill lines as a German client saved them (C's stays English)
db.recipes[A].skillLine, db.recipes[B].skillLine = "Alchemie aus Midnight", "Alchemie aus Midnight"

-- The game, as on a German client: A's skill line has a parent the game
-- names; B's says nothing at login; C's is English with no parent
local PARENT = 171
C_TradeSkillUI.GetTradeSkillLineForRecipe = function(id)
    if id == A then return 2906, "Alchemie aus Midnight", PARENT end
    if id == C then return 2906, "Midnight Alchemy" end
    return nil
end
C_TradeSkillUI.GetTradeSkillDisplayName = function(id)
    if id == PARENT then return profession end
end

local addon = bench.Login(CHAR, { db = db })
bench.Equal("A: put right at login from the skill line's parent", GoldsmithDB.recipes[A].profession, profession)
bench.Equal("C: an English skill line's last word still works", GoldsmithDB.recipes[C].profession, profession)
bench.Equal("B: the game can't say yet, so left for now", GoldsmithDB.recipes[B].profession, "Midnight")

-- B in the Alchemy window: put right from the open window
local r = GoldsmithDB.recipes[B]
bench.world.recipeInfo[B] = { recipeID = B, learned = true, name = r.name, craftable = true, categoryID = 0 }
bench.world.schematics[B] = { recipeID = B, outputItemID = r.outputItemID, quantityMin = 1, quantityMax = 1,
    reagentSlotSchematics = {} }
bench.OpenProfession(profession)
bench.Advance(5)
bench.Equal("B: put right when its window opens", GoldsmithDB.recipes[B].profession, profession)

-- No recipe anywhere is left as "Midnight"
local left = 0
for _, recipe in pairs(GoldsmithDB.recipes) do
    if recipe.profession == "Midnight" then left = left + 1 end
end
bench.Equal("none left as Midnight", left, 0)

bench.Done()
