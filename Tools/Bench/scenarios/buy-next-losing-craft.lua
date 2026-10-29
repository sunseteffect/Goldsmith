-- Buy next for a queued craft that now loses gold (what it sells for
-- dropped since it was queued): even under the plan's price it waits for
-- a second click, says why, plays the raid warning and pops up the loss in
-- the middle of the screen (error review #1)
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT, TEA = 236774, 1226197
local db = bench.LoadSaved()
db.settings.buyOver = 0
db.inMail["Mysticmead-Sargeras"] = {}
db.queues["Mysticmead-Sargeras"] = { { recipeID = TEA, quantity = 8, made = 0, added = os.time() } }
-- Azeroot Tea now sells for 1 copper
db.ownScan.prices[db.recipes[TEA].outputItemID] = { 1 }
db.searchPrices = {}  -- a search of the tea (newer) would set its price again
local myst = db.characters["Mysticmead-Sargeras"]
myst.stock[AZEROOT], myst.stock[AZEROOT + 1] = nil, nil
bench.Login("Mysticmead", { db = db })
bench.world.bank[AZEROOT], bench.world.bank[AZEROOT + 1] = nil, nil
bench.SetBags({ [AZEROOT] = 0, [AZEROOT + 1] = 0 })

bench.OpenAH()
bench.Click("Buy 8 Azeroot")
bench.Calls()
-- 15g each, under the plan's ~20g
bench.QuotePrice(AZEROOT, bench.Gold(15), 8)
local calls = bench.Calls()
bench.HasNot("not bought though under plan", calls, "Confirm")
bench.Has("raid warning sound", calls, "PlaySound(RAID_WARNING)")
bench.Has("popup says the craft loses gold", calls, "RaidNotice(Goldsmith: Azeroot Tea loses")
bench.Has("says the craft loses gold", bench.Screen(), "Azeroot Tea loses")
bench.Click("Buy 8 Azeroot for 120")
bench.Has("second click buys anyway", bench.Calls(), "ConfirmCommoditiesPurchase(236774, 8)")
bench.Done()
