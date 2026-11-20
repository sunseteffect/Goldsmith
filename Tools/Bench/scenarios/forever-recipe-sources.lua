-- Forever: where to learn a recipe you haven't, from the trainers and
-- vendors you've opened. The game doesn't say there (user, 2026-11-18:
-- "show how to acquire the not learned recipes").
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

-- Nothing seen yet: says so
bench.Equal("none seen", #addon:GetRecipeSources(GoldsmithDB.unlearned[id]), 0)

-- A trainer that teaches it
local npc
UnitName = function(unit) if unit == "npc" then return npc end if unit == "player" then return "Mysticmead" end end
npc = "Saru Steelfury"
IsTradeskillTrainer = function() return true end
GetNumTrainerServices = function() return 2 end
GetTrainerServiceItemLink = function(i)
    if i == 1 then return "|Hitem:" .. recipe.outputItemID .. "::|h[x]|h" end
end
GetTrainerServiceSkillReq = function(i) return "Alchemy", 75, false end
GetTrainerServiceCost = function(i) return 5000 end
bench.Fire("TRAINER_SHOW")
local sources = addon:GetRecipeSources(GoldsmithDB.unlearned[id])
bench.Equal("trainer saved", #sources, 1)
bench.Equal("its name", sources[1] and sources[1].npc, "Saru Steelfury")
bench.Equal("trainer", sources[1] and sources[1].kind, "trainer")
bench.Equal("its zone", sources[1] and sources[1].zone, "Silvermoon City")
bench.Equal("what it costs", sources[1] and sources[1].cost, 5000)
bench.Fire("TRAINER_UPDATE")
bench.Equal("opened again: not twice", #addon:GetRecipeSources(GoldsmithDB.unlearned[id]), 1)

-- A vendor selling its plans, cheaper
npc = "Jutak"
bench.OpenVendor({ { itemID = 990777, name = "Plans: " .. recipe.name, price = 4000 } })
bench.Advance(2)
sources = addon:GetRecipeSources(GoldsmithDB.unlearned[id])
bench.Equal("vendor saved too", #sources, 2)
bench.Equal("cheapest first", sources[1] and sources[1].kind, "vendor")
bench.Equal("vendor's name", sources[1] and sources[1].npc, "Jutak")
bench.CloseVendor()

-- A vendor item that isn't a recipe: nothing
bench.OpenVendor({ { itemID = 990778, name = "Plans: Nothing Anyone Knows", price = 100 } })
bench.Advance(2)
bench.Equal("unknown plans: nothing new", #addon:GetRecipeSources(GoldsmithDB.unlearned[id]), 2)
bench.CloseVendor()

-- Crafts, Not learned yet (searched, so it's listed whatever it earns)
GoldsmithDB.ui2.craftsShow = "unlearned"
GoldsmithDB.ui2.craftsOnlyMine, GoldsmithDB.ui2.profession = nil, "All"
addon:ToggleWindow()
addon:ShowTab("crafts")
bench.Advance(3)
local view = addon:GetTabScreen("crafts").view
view.search = recipe.outputName
addon.RefreshWindow()
bench.Advance(3)
for _, child in ipairs({ view.list:GetChildren() }) do child:SetHeight(600) end
view.list:Update()
local row
for _, r in ipairs(view.list.rows) do
    if r:IsShown() and r.data and r.data.unlearned and r.data.recipe.recipeID == id then row = r break end
end
bench.Check("its row", row ~= nil)
if row then
    bench.Has("row: where", row.who:GetText() or "", "vendor in Silvermoon City", true)
    local lines = {}
    local addLine, addDouble = GameTooltip.AddLine, GameTooltip.AddDoubleLine
    GameTooltip.AddDoubleLine = function(_, left, right) table.insert(lines, tostring(left) .. " " .. tostring(right)) end
    GameTooltip.AddLine = function(_, text) table.insert(lines, tostring(text)) end
    row:GetScript("OnEnter")(row)
    GameTooltip.AddLine, GameTooltip.AddDoubleLine = addLine, addDouble
    local tip = bench.wow.Strip(table.concat(lines, " | "))
    bench.Has("hover: heading", tip, "Where to learn it", true)
    bench.Has("hover: the trainer", tip, "Trainer: Saru Steelfury, Silvermoon City", true)
    bench.Has("hover: the vendor", tip, "Vendor: Jutak, Silvermoon City", true)
end
bench.Equal("no errors", #bench.TakeErrors(), 0)
bench.Done()
