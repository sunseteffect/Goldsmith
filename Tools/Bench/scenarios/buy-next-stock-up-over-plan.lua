-- A stock-up next to a queued craft: when the AH asks more than planned
-- for the stock-up, the note says how much more but not the queue's
-- profit (a stock-up isn't in it)
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT, TEA = 236774, 1226197
local db = bench.LoadSaved()
db.settings.buyOver = 0
db.inMail["Mysticmead-Sargeras"] = {}
db.queues["Mysticmead-Sargeras"] = { { recipeID = TEA, quantity = 8, made = 0, added = os.time() } }
local myst = db.characters["Mysticmead-Sargeras"]
myst.stock[AZEROOT], myst.stock[AZEROOT + 1] = nil, nil
local addon = bench.Login("Mysticmead", { db = db })
bench.world.bank[AZEROOT], bench.world.bank[AZEROOT + 1] = nil, nil
bench.SetBags({ [AZEROOT] = nil, [AZEROOT + 1] = nil })
local ARGENTLEAF = bench.ItemID("Argentleaf")
addon:AddStockToQueue("Mysticmead-Sargeras", ARGENTLEAF, 20, "Argentleaf")
bench.Advance(1)

bench.OpenAH()
local screen = bench.Screen()
bench.Show(screen)
-- Buy whatever comes first until the stock-up is next
for _ = 1, 5 do
    local label
    for _, l in ipairs(bench.Screen()) do if l:find("^Buy %d") then label = l end end
    if not label or label:find("Argentleaf", 1, true) then break end
    local n, id = tonumber(label:match("^Buy (%d+)")), AZEROOT
    bench.Click(label)
    bench.QuotePrice(id, 1, n)
    bench.PurchaseSucceeds(id, n, n)
end
bench.Click("Buy 20 Argentleaf")
-- Far over its plan
bench.QuotePrice(ARGENTLEAF, bench.Gold(50), 20)
screen = bench.Screen()
bench.Show(screen, "after quote")
bench.HasNot("not bought over plan", bench.Calls(), "ConfirmCommoditiesPurchase(" .. ARGENTLEAF)
bench.Has("says it's over the plan", screen, "more than the plan")
bench.HasNot("no queue profit for a stock-up", screen, "Queue profit")
bench.Done()
