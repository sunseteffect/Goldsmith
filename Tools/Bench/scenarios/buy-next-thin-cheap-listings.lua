-- A few cheap listings, then dear ones: the plan's price with quantity
-- behind it is the dear one, but Buy next is quoted the cheap ones. The
-- loss check counts the material at the quote: 10 Stag Meat quoted at 18s
-- were counted at 5s 77c each and Lean Venison making 21s "loses 17s"
-- (user, 2026-11-16).
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT, TEA = 236774, 1226197
local db = bench.LoadSaved()
db.settings.buyOver = 0
db.settings.autoScan = false
db.queues = {}
db.queues["Mysticmead-Sargeras"] = { { recipeID = TEA, quantity = 8, made = 0, added = os.time() } }
db.inMail["Mysticmead-Sargeras"] = {}
for _, c in pairs(db.characters) do
    for _, held in ipairs({ c.stock or {}, c.stockBank or {} }) do held[AZEROOT], held[AZEROOT + 1] = nil, nil end
end
if db.warbandStock then db.warbandStock[AZEROOT], db.warbandStock[AZEROOT + 1] = nil, nil end
local addon = bench.Login("Mysticmead", { db = db })
bench.SetBags({ [AZEROOT] = 0, [AZEROOT + 1] = 0, [242644] = 20 })
bench.PinPrices(addon, { [242301] = bench.Gold(40) })
-- 18 at 15g, then 200 at 60g: under 20 cheap ones, so 60g is "the price"
GoldsmithDB.orderBooks[AZEROOT] = { time = time(), total = 218,
    levels = { { price = bench.Gold(15), qty = 18 }, { price = bench.Gold(60), qty = 200 } } }
-- The other quality dearer still, so the plan stays on this one
GoldsmithDB.orderBooks[AZEROOT + 1] = { time = time(), total = 200, levels = { { price = bench.Gold(70), qty = 200 } } }
addon:DataChanged()

addon:BuyNext()
bench.OpenAH()
bench.Click("Buy 8 Azeroot")
bench.Calls()
bench.QuotePrice(AZEROOT, bench.Gold(15), 8)
bench.HasNot("no loss warning at the quoted price", bench.Screen(), "loses")
bench.Has("bought without asking", bench.Calls(), "ConfirmCommoditiesPurchase(236774, 8)")
bench.Done()
