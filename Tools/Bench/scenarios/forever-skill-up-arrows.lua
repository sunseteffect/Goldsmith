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

-- Show > Has skill up: only crafts that still give a point (user,
-- 2026-11-18)
bench.CloseProfession()
local ui = GoldsmithDB.ui2
ui.craftsShow, ui.craftsOnlyMine, ui.profession, ui.craftsGear = "all", true, "Alchemy", nil
ui.expansions = {}
for e = 0, 12 do ui.expansions[e] = true end
addon:ToggleWindow()
addon:ShowTab("crafts")
bench.Advance(3)
local view = addon:GetTabScreen("crafts").view
local function Listed()
    for _, child in ipairs({ view.list:GetChildren() }) do child:SetHeight(4000) end
    view.list:Update()
    local ids, n = {}, 0
    for _, r in ipairs(view.list.rows) do
        if r:IsShown() and r.data and r.data.recipe and r.data.recipe.recipeID then ids[r.data.recipe.recipeID] = true n = n + 1 end
    end
    return ids, n
end
-- Two crafts the list shows: one still gives skill, one is grey
local before, all = Listed()
local listed = {}
for id in pairs(before) do table.insert(listed, id) end
table.sort(listed)
bench.Check("crafts listed (what this tests)", #listed >= 3, #listed)
for _, id in ipairs(listed) do c.skillUps[id] = 3 end
orange, grey = listed[1], listed[2]
c.skillUps[orange] = 1
addon:DataChanged()
ui.craftsSkillUp = true
addon.RefreshWindow()
bench.Advance(3)
local after, n = Listed()
bench.Check("has skill up: the yellow one", after[orange])
bench.Check("has skill up: not the grey one", not after[grey])
bench.Check("fewer rows", n < all, string.format("%d of %d", n, all))
ui.craftsSkillUp = nil
bench.Equal("no errors", #bench.TakeErrors(), 0)
bench.Done()
