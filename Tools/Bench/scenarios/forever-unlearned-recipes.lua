-- Real Forever: recipes not learned yet are saved and listed. Its skill lines
-- name no expansion, so the current-expansion check dropped all of them and
-- Show: Not learned yet stayed empty (user, 2026-11-06).
local bench = dofile(BENCH_DIR .. "bench.lua")
local CHAR = "Mysticmead"
local db = bench.LoadSaved()
WOW_PROJECT_ID = 18

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
bench.world.recipeInfo[id] = { recipeID = id, learned = false, name = recipe.name, craftable = true, categoryID = 0, maxTrivialLevel = 180 }
bench.world.schematics[id] = { recipeID = id, outputItemID = recipe.outputItemID, name = recipe.name,
    quantityMin = 1, quantityMax = 1, reagentSlotSchematics = {} }
bench.OpenProfession("Alchemy")
bench.Advance(10)
bench.Check("saved as not learned", GoldsmithDB.unlearned[id] ~= nil)
bench.Equal("grey level saved", GoldsmithDB.unlearned[id].grayLevel, 180)
local shown = false
for _, row in ipairs(addon:GetUnlearnedRows("Alchemy", {})) do
    if row.recipe.recipeID == id then shown = true end
end
bench.Check("listed under Not learned yet", shown)

-- The skill it needs, read from a trainer window; other services are skipped
IsTradeskillTrainer = function() return true end
GetNumTrainerServices = function() return 2 end
GetTrainerServiceItemLink = function(i)
    if i == 1 then return "|Hitem:" .. recipe.outputItemID .. "::|h[x]|h" end
end
GetTrainerServiceSkillReq = function(i) return "Alchemy", i == 1 and 75 or 90, false end
bench.Fire("TRAINER_SHOW")
bench.Equal("skill needed saved for the item it makes", GoldsmithDB.trainerSkill[recipe.outputItemID], 75)
bench.Equal("no expansion in sentences", addon:CurrentExpansionPrefix(), "")
bench.Equal("no expansion on cooldowns", addon:CooldownsLabel(), "Cooldowns")

-- On the row: green once this character has the skill, nothing if unknown
local row = { unlearned = true, recipe = GoldsmithDB.unlearned[id], charKey = addon.charKey }
local professions = GoldsmithDB.characters[addon.charKey].professions
professions.Alchemy = { skill = 74 }
local short = addon:SkillNeededLabel(row)
professions.Alchemy = { skill = 75 }
local enough = addon:SkillNeededLabel(row)
bench.Has("row says what it needs", enough, "Needs 75")
bench.Check("colour changes at the skill", short ~= enough)
bench.Equal("learned rows say nothing", addon:SkillNeededLabel({ recipe = row.recipe, charKey = addon.charKey }), "")
GoldsmithDB.trainerSkill[recipe.outputItemID] = nil
row.recipe.grayLevel = nil
bench.Equal("no trainer seen: nothing", addon:SkillNeededLabel(row), "")

-- No trainer: estimated from the grey level, and never green
row.recipe.grayLevel = 180
professions.Alchemy = { skill = 80 }
bench.Has("estimate is marked", addon:SkillNeededLabel(row), "Needs ~120")
local notYet = addon:SkillNeededLabel(row)
professions.Alchemy = { skill = 130 }
bench.Check("estimate you may have isn't the red", addon:SkillNeededLabel(row) ~= notYet)
GoldsmithDB.trainerSkill[recipe.outputItemID] = 145
bench.Has("a trainer's number wins", addon:SkillNeededLabel(row), "Needs 145")

-- The list: what you can learn now that makes gold, trainer's first
local function Row(need, gray, skill, profit, partial)
    return { unlearned = true, charKey = addon.charKey, info = { profit = profit, partial = partial },
        recipe = { outputItemID = need and 990200 + need or 990300, grayLevel = gray, profession = "Alchemy" } }
end
professions.Alchemy = { skill = 80 }
GoldsmithDB.trainerSkill[990250] = 50
GoldsmithDB.trainerSkill[990290] = 90
local trainer = Row(50, nil, 80, 100)
local estimate = Row(nil, 120, 80, 100)
local kept = addon:KeepWorthLearning({ trainer, estimate, Row(nil, nil, 80, 100), Row(90, nil, 80, 100), Row(nil, 180, 80, 100),
    Row(50, nil, 80, -5), Row(50, nil, 80, 100, true) })
bench.Equal("only the two worth learning", #kept, 2)
bench.Equal("a trainer's goes first", trainer.pinned, true)
bench.Check("an estimate doesn't", not estimate.pinned)
bench.Done()
