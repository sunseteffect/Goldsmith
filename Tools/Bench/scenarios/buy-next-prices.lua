-- Buy next against the AH's price: over the plan waits for a second
-- click, a price that can't be met skips the item, closing the AH forgets
-- the skips
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT = 236774
local db = bench.LoadSaved()
db.settings.buyOver = 0
db.queues["Mysticmead-Sargeras"] = { { recipeID = 1226197, quantity = 8, made = 0, added = os.time() } }
local myst = db.characters["Mysticmead-Sargeras"]
-- Nothing in her mailbox, whatever the last login saw
db.inMail["Mysticmead-Sargeras"] = {}
myst.stock[AZEROOT], myst.stock[AZEROOT + 1] = nil, nil
local addon = bench.Login("Mysticmead", { db = db })
bench.SetBags({ [AZEROOT] = nil, [AZEROOT + 1] = nil })

addon:BuyNext()
bench.Has("AH closed: says to open it", bench.Chat(), "Open the auction house first.")
bench.OpenAH()
bench.Click("Buy 8 Azeroot")
bench.Has("asks the price", bench.Calls(), "StartCommoditiesPurchase(236774, 8)")

-- 30g each against the plan's ~19.89g: shows the price, waits
bench.QuotePrice(AZEROOT, bench.Gold(30), 8)
bench.HasNot("not bought over plan", bench.Calls(), "Confirm")
bench.Has("button shows the price", bench.Screen(), "Buy 8 Azeroot for 240")
bench.Click("Buy 8 Azeroot for 240")
bench.Has("second click buys", bench.Calls(), "ConfirmCommoditiesPurchase(236774, 8)")
bench.PurchaseSucceeds(AZEROOT, 8, bench.Gold(240))
bench.Has("bought line says over plan", bench.Chat(), "over plan")
bench.Has("bought, in the mail: queue covered", bench.Screen(), "In your mailbox: 8x Azeroot")
bench.CloseAH()
bench.OpenMail()
bench.TakeMail()
bench.CloseMail()
bench.Equal("in the bags now", bench.world.bags[AZEROOT], 8)
bench.Equal("no longer counted in the mail", addon:InMailCount(AZEROOT), 0)

-- Twice as many queued: 8 more, and the AH can't sell them
GoldsmithDB.queues["Mysticmead-Sargeras"][1].quantity = 16
addon:QueueEntryChanged()
bench.OpenAH()
bench.Click("Buy 8 Azeroot")
bench.Fire("COMMODITY_PRICE_UNAVAILABLE")
bench.Advance(1)
bench.Has("unavailable is skipped", bench.Screen(), "skipped")
bench.CloseAH()
bench.OpenAH()
bench.Has("skips forgotten on a new visit", bench.Screen(), "Buy 8 Azeroot")
bench.Done()
