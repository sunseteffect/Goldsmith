-- Worth a try (Forever): profitable crafts with no proof they sell yet,
-- to make one or two of and list. Best crafts leaves them out, so on a
-- new server Do this next had little to say and testing new items was
-- done from the whole Crafts list (user, 2026-11-18: Moonsteel Broadsword
-- and Massive Iron Axe looked weak on TSM and sold fast).
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
local addon = bench.Login("Mysticmead", { db = db })

local function Find(list, name)
    for _, c in ipairs(list) do if c.recipe.outputName == name then return c end end
end
local list = addon:GetWorthATry("All")
bench.Check("finds untested crafts", #list > 0, #list)
local try
for _, c in ipairs(list) do if c.charKey == addon.charKey then try = try or c end end
bench.Check("one on this character", try ~= nil)
local name = try.recipe.outputName
bench.Check("says why it's unproven", try.why ~= nil and try.why ~= "", try.why)
bench.Check("profitable", try.profit > 0, try.profit)
bench.Equal("not gear: make 2", try.make, addon:IsGear(try.itemID) and 1 or 2)
bench.Equal("not also a Best craft", Find(addon:GetBestCrafts("All", math.huge), name), nil)
for _, c in ipairs(addon:GetBestCrafts("All", math.huge)) do
    bench.Equal("Best craft not repeated: " .. c.recipe.outputName, Find(list, c.recipe.outputName), nil)
end

-- On Forever, a card in Do this next
addon.isForever = true
addon:ToggleWindow()
addon:ShowTab("overview")
bench.Advance(5)
local screen = table.concat(bench.Screen(), "\n")
bench.Has("the card", screen, "Worth a try", true)
bench.Has("says how many to make", screen, "make " .. try.make, true)

-- Holding one: the test is running, not suggested again
local me = GoldsmithDB.characters[addon.charKey]
me.stock[try.itemID] = 1
addon:DataChanged()
bench.Equal("held: left out", Find(addon:GetWorthATry("All"), name), nil)
me.stock[try.itemID] = nil
addon:DataChanged()
bench.Check("back once gone", Find(addon:GetWorthATry("All"), name) ~= nil)

-- Listed lately and gone without an AH sale (vendored, sold cheap):
-- didn't pan out, off for 2 weeks
addon.ledger:addCost("Unassigned", name, 1, 100, "DEPOSIT", try.itemID)
addon:DataChanged()
bench.Equal("tried, didn't sell: left out", Find(addon:GetWorthATry("All"), name), nil)
bench.world.baseTime = bench.world.baseTime + 15 * 86400
addon:DataChanged()
bench.Check("back after 2 weeks", Find(addon:GetWorthATry("All"), name) ~= nil)

-- Selling once isn't enough: how fast it went and for how much (user,
-- 2026-11-18). Each case two weeks after the last, so they don't mix.
local cost = try.row.cost
local function Case(posts, each)
    bench.world.baseTime = bench.world.baseTime + 15 * 86400
    for _ = 1, posts do addon.ledger:addCost("Unassigned", name, 1, 100, "DEPOSIT", try.itemID) end
    addon.ledger:addRevenue("Unassigned", name, 1, math.floor(each), nil, nil, nil, nil, try.itemID)
    addon:DataChanged()
    return Find(addon:GetWorthATry("All"), name) ~= nil,
        Find(addon:GetBestCrafts("All", math.huge), name) ~= nil
end
local onTry, onBest = Case(4, cost * 2)
bench.Check("slow sale (4 listings): off Worth a try", not onTry)
bench.Check("slow sale: not a Best craft", not onBest)
onTry, onBest = Case(1, cost * 1.02)
bench.Check("sold under your ROI: off Worth a try", not onTry)
bench.Check("sold under your ROI: not a Best craft", not onBest)
onTry, onBest = Case(1, cost * 2)
bench.Check("quick, good profit: off Worth a try", not onTry)
bench.Check("quick, good profit: a Best craft", onBest)

-- Not on retail (the What's new box, when the save hasn't seen this
-- release's, lists Worth a try too: closed so only the card counts)
addon:HideNews()
addon.isForever = false
addon:ShowTab("history")
bench.Advance(2)
addon:ShowTab("overview")
bench.Advance(5)
bench.HasNot("retail: no card", table.concat(bench.Screen(), "\n"), "Worth a try", true)
bench.Done()
