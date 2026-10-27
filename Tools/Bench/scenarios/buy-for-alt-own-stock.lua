-- Buying for another character's queue while holding some yourself: yours
-- count, only the rest is bought, and the mailbox panel mails both (user,
-- 2026-10-27: holding 1 Arcanoweave Bolt, Buy next wanted 6 for
-- Maddoxynn's 6, "i should only need to buy 5")
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT = 236774
local AZEROOT_TEA = 1226197

local db = bench.LoadSaved()
db.settings.buyFor = "all"
db.queues = {}
db.queues["Mysticmead-Sargeras"] = { { recipeID = AZEROOT_TEA, quantity = 8, made = 0, added = os.time() } }
local myst = db.characters["Mysticmead-Sargeras"]
myst.stock[AZEROOT], myst.stock[AZEROOT + 1] = nil, nil
myst.stock[242644] = 20
db.ownScan.prices[db.recipes[AZEROOT_TEA].outputItemID] = { 50 * 10000 }
db.searchPrices = {}
db.inMail["Mysticmead-Sargeras"] = {}
-- Nothing of the buyer's in the mail: it would count toward the order
db.inMail["Maddoxynn-Sargeras"] = {}
db.boughtFor = {}

bench.Login("Maddoxynn", { db = db })
bench.world.bank[AZEROOT], bench.world.bank[AZEROOT + 1] = nil, nil
-- Maddoxynn holds 3 of the 8
bench.SetBags({ [AZEROOT] = 3, [AZEROOT + 1] = 0 })
bench.OpenAH()
local screen = bench.Screen()
bench.Has("buys only the rest", screen, "Buy 5 Azeroot")
bench.Has("says yours count", screen, "Your 3 Azeroot count too: mail them to Mysticmead with these.")

bench.Click("Buy 5 Azeroot")
bench.Has("asks the AH for 5", bench.Calls(), "StartCommoditiesPurchase(236774, 5)")
bench.QuotePrice(AZEROOT, bench.Gold(19), 5)
bench.Has("buys 5", bench.Calls(), "ConfirmCommoditiesPurchase(236774, 5)")
bench.PurchaseSucceeds(AZEROOT, 5, bench.Gold(19) * 5)
bench.Has("then nothing left to buy", bench.Screen(), "Nothing left to buy.")
bench.CloseAH()

-- The mailbox: the 5 bought and your 3, 8 in all
bench.OpenMail()
bench.TakeMail()
bench.Has("mail panel: all 8", bench.Screen(), "8 Azeroot")
bench.Done()
