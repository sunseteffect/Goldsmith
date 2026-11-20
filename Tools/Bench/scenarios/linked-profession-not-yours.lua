-- Someone's profession linked in trade chat: the game says their recipes
-- are learned, and Goldsmith saved 69 of a maxed blacksmith's as yours
-- (user, 2026-11-18). A linked window is skipped, and marks it left are
-- cleaned up.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()

-- A character with professions, and a saved recipe of a profession it
-- doesn't have that another character does
local charKey, char, otherRecipe, otherProf
for key, c in pairs(db.characters) do
    if next(c.professions or {}) then
        for id, r in pairs(db.recipes) do
            if r.profession and not c.professions[r.profession] and r.outputItemID then
                for otherKey, o in pairs(db.characters) do
                    if otherKey ~= key and o.professions and o.professions[r.profession] then
                        charKey, char, otherRecipe, otherProf = key, c, id, r.profession
                        break
                    end
                end
            end
            if charKey then break end
        end
    end
    if charKey then break end
end
bench.Check("a character and another's recipe to use (what this tests)", charKey)

-- One of its own profession's recipes, marked known
local ownProf = next(char.professions)
local ownRecipe
for id in pairs(char.knownRecipes or {}) do
    local r = db.recipes[id]
    if r and r.profession == ownProf and r.outputItemID then ownRecipe = id break end
end
if not ownRecipe then
    for id, r in pairs(db.recipes) do
        if r.profession == ownProf and r.outputItemID then ownRecipe = id break end
    end
end
bench.Check("a recipe of its own profession", ownRecipe)

-- Left by the old bug: the other profession's recipe marked known
char.knownRecipes = char.knownRecipes or {}
char.knownRecipes[otherRecipe] = true
char.knownRecipes[ownRecipe] = true

-- The game lists this character's professions
local profNames = {}
for name in pairs(char.professions) do table.insert(profNames, name) end
GetProfessions = function()
    local t = {}
    for i = 1, #profNames do t[i] = i end
    return unpack(t)
end
GetProfessionInfo = function(i)
    local name = profNames[i]
    local p = name and char.professions[name]
    if p then return name, p.icon, p.skill or 1, p.maxSkill or 1, 0, 0, 0 end
end

local who = charKey:match("^(.-)%-") or charKey
local addon = bench.Login(who, { db = db })
bench.Equal("logged in as it", addon.charKey, charKey)
bench.Advance(5)
bench.Check("other profession's mark cleaned at login (" .. otherProf .. ")",
    not GoldsmithDB.characters[charKey].knownRecipes[otherRecipe])
bench.Check("own profession's mark kept", GoldsmithDB.characters[charKey].knownRecipes[ownRecipe])

-- Someone's linked window, every recipe learned, one Goldsmith has never seen
local NEW = 990001
local linked = true
C_TradeSkillUI.IsTradeSkillLinked = function() return linked end
bench.world.recipeInfo[NEW] = { recipeID = NEW, learned = true, name = "Someone Else's Helm", craftable = true, categoryID = 0 }
bench.world.schematics[NEW] = { recipeID = NEW, outputItemID = db.recipes[otherRecipe].outputItemID,
    name = "Someone Else's Helm", quantityMin = 1, quantityMax = 1, reagentSlotSchematics = {} }
bench.world.recipeInfo[otherRecipe] = { recipeID = otherRecipe, learned = true, name = "x", craftable = true, categoryID = 0 }
bench.world.openProfession = { professionName = otherProf, profession = 0, professionID = 0, skillLevel = 300, maxSkillLevel = 300 }
local recipesBefore = 0
for _ in pairs(GoldsmithDB.recipes) do recipesBefore = recipesBefore + 1 end
ProfessionsFrame:Show()
bench.Fire("TRADE_SKILL_SHOW")
bench.Fire("TRADE_SKILL_LIST_UPDATE")
bench.Advance(10)
local me = GoldsmithDB.characters[charKey]
bench.Check("linked: its recipe not marked yours", not me.knownRecipes[NEW])
bench.Check("linked: a saved one not marked yours", not me.knownRecipes[otherRecipe])
bench.Check("linked: nothing new saved", GoldsmithDB.recipes[NEW] == nil)
local recipesAfter = 0
for _ in pairs(GoldsmithDB.recipes) do recipesAfter = recipesAfter + 1 end
bench.Equal("linked: saved recipes unchanged", recipesAfter, recipesBefore)
bench.HasNot("linked: no 'Saved N learned recipes'", bench.Chat(), "learned recipes")
bench.CloseProfession()

-- Your own window again: a recipe marked known that it says isn't learned
-- is unmarked
linked = false
bench.world.recipeInfo = {}
bench.world.schematics = {}
bench.OpenProfession(ownProf)
bench.world.recipeInfo[ownRecipe].learned = false
bench.CloseProfession()
bench.Advance(3700) -- stats go stale, so the next open reads every recipe again
bench.world.openProfession = { professionName = ownProf, profession = 0, professionID = 0, skillLevel = 100, maxSkillLevel = 100 }
ProfessionsFrame:Show()
bench.Fire("TRADE_SKILL_SHOW")
bench.Fire("TRADE_SKILL_LIST_UPDATE")
bench.Advance(10)
bench.Check("own window: not learned, so unmarked", not GoldsmithDB.characters[charKey].knownRecipes[ownRecipe])

bench.Done()
