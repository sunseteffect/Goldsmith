-- Items search finds a recipe's item you haven't learned (only its Plans
-- showed: Shadow Crescent Axe, user 2026-11-17), and in Forever anything
-- the last scan saw
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.foreverTest = true
local AXE, WAND = 990011, 990012
db.unlearned = db.unlearned or {}
db.unlearned[990010] = { recipeID = 990010, name = "Bench Crescent Axe", profession = "Blacksmithing",
    outputItemID = AXE, outputName = "Bench Crescent Axe", reagents = {}, learners = {} }
local addon = bench.Login("Mysticmead", { db = db })
bench.AddItem(AXE, "Bench Crescent Axe", {})
bench.AddItem(WAND, "Bench Scanned Wand", {})

local function Found(text)
    local names = {}
    for _, item in ipairs(addon:SearchItems(text, "All", 50)) do names[item.name] = item end
    return names
end
local axe = Found("crescent")["Bench Crescent Axe"]
bench.Check("not-learned recipe's item found", axe ~= nil)
bench.Equal("with its profession", axe and axe.profession, "Blacksmithing")
bench.Equal("profession filter keeps it", #addon:SearchItems("crescent", "Blacksmithing", 50), 1)

bench.Equal("unscanned item not found", Found("scanned wand")["Bench Scanned Wand"], nil)
GoldsmithDB.ownScan = { time = time(), method = "full", auctions = 1, items = 1, group = addon:RealmGroup(),
    realm = GetRealmName(), seconds = 1, prices = { [WAND] = { 44300, 44300, 3 } } }
addon:DataChanged()
bench.Check("scanned item found", Found("scanned wand")["Bench Scanned Wand"] ~= nil)

addon:ToggleWindow()
addon:OpenItem("Bench Crescent Axe", AXE)
bench.Advance(3)
bench.Has("its page opens", bench.Screen(), "Bench Crescent Axe", true)
bench.Done()
