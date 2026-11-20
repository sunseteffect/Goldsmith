-- A material used only by a recipe you haven't learned: its page listed
-- nothing to craft it into, and one in your bank read "none on any
-- character" (Raw Slitherskin Mackerel, user 2026-11-17)
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
local FISH, MEAL = 990031, 990032
db.unlearned = db.unlearned or {}
db.unlearned[990030] = { recipeID = 990030, name = "Bench Fried Fish", profession = "Cooking",
    outputItemID = MEAL, outputName = "Bench Fried Fish", outputQty = 1, outputMin = 1, outputMax = 1,
    reagents = { { quantity = 1, itemIDs = { FISH }, names = { "Bench Raw Fish" } } },
    learners = { ["Mysticmead-Sargeras"] = true } }
db.viewedItems = db.viewedItems or {}
db.viewedItems[FISH] = nil
local addon = bench.Login("Mysticmead", { db = db })
bench.AddItem(FISH, "Bench Raw Fish", { stack = 20 })
bench.AddItem(MEAL, "Bench Fried Fish", { stack = 20 })
GoldsmithDB.ownScan = { time = time() - 60, method = "full", items = 2, group = addon:RealmGroup(),
    prices = { [FISH] = { 13, 13, 500 }, [MEAL] = { 60, 60, 300 } } }
addon:DataChanged()

local list = addon:GetRecipesUsingAll(FISH)
local found
for _, e in ipairs(list) do if e.recipe.recipeID == 990030 then found = e end end
bench.Check("not-learned recipe listed", found ~= nil)
bench.Check("marked not learned", found and found.unlearned == true)
bench.Check("priced", found and found.profit ~= nil, found and found.profit)
bench.Equal("after the ones you know", list[#list] == found, true)

-- In the bank, page opened: counted
bench.SetBags({ [FISH] = 7 })
bench.Equal("not counted before its page", addon:GetStock(FISH), 0)
addon:ToggleWindow()
addon:OpenItem("Bench Raw Fish", FISH)
bench.Advance(5)
bench.Equal("counted once its page opened", (addon:GetStock(FISH)), 7)
local screen = bench.Screen()
bench.Has("Craft it into tab", screen, "Craft it into (", true)
-- Nothing makes it: what uses it, not one profession as its own (Pristine
-- Leather read "Blacksmithing", user 2026-11-17)
bench.Has("says what uses it", screen, "Used in Cooking", true)
local details = addon:GetItemDetails("Bench Raw Fish", FISH)
bench.Equal("one profession listed", details.usedIn and #details.usedIn, 1)
bench.Equal("a crafted item has none", addon:GetItemDetails("Bench Fried Fish", MEAL).usedIn, nil)
bench.Done()
