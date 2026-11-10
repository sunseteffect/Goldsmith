-- Forever: Crafts rows show the profession window's skill-up arrow while a
-- recipe still gives skill (orange, yellow, green), nothing once grey. The
-- color is read from relativeDifficulty when the window updates (user,
-- 2026-11-09: Rough Sharpening Stone 3, Rough Bronze Boots 0).
local bench = dofile(BENCH_DIR .. "bench.lua")
local CHAR = "Mysticmead"
local db = bench.LoadSaved()
WOW_PROJECT_ID = 18

local addon = bench.Login(CHAR, { db = db })
local c = GoldsmithDB.characters[addon.charKey]
local orange, grey
for id, r in pairs(GoldsmithDB.recipes) do
    if r.profession == "Alchemy" and c.knownRecipes[id] then
        if not orange then orange = id elseif not grey then grey = id break end
    end
end
bench.Check("two known Alchemy recipes (what this tests)", orange and grey)
bench.world.recipeInfo[orange] = { recipeID = orange, learned = true, craftable = true, categoryID = 0, relativeDifficulty = 0 }
bench.world.recipeInfo[grey] = { recipeID = grey, learned = true, craftable = true, categoryID = 0, relativeDifficulty = 3 }
bench.OpenProfession("Alchemy")
bench.Advance(5)
bench.Equal("orange saved", c.skillUps and c.skillUps[orange], 0)
bench.Equal("grey saved", c.skillUps and c.skillUps[grey], 3)

local function Row(id) return { recipe = GoldsmithDB.recipes[id], charKey = addon.charKey } end
bench.Check("orange row has an arrow", addon:SkillUpLabel(Row(orange)) ~= "")
bench.Equal("grey row has none", addon:SkillUpLabel(Row(grey)), "")
bench.Equal("not learned rows have none", addon:SkillUpLabel({ unlearned = true, recipe = GoldsmithDB.recipes[orange], charKey = addon.charKey }), "")

-- A skill point turns it yellow: read again on the next list update
bench.world.recipeInfo[orange].relativeDifficulty = 1
bench.Fire("SKILL_LINES_CHANGED")
bench.Advance(5)
bench.Equal("yellow after the skill went up", c.skillUps[orange], 1)
bench.Check("yellow row still has an arrow", addon:SkillUpLabel(Row(orange)) ~= "")
bench.Done()
