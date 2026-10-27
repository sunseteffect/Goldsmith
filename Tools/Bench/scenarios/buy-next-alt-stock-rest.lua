-- Another character holds part of what Buy next buys: shift-click counts
-- theirs this visit and buys only the rest (user, 2026-10-27: Maddoxius
-- held 6 of 12 Petrified Root, "i can't send 6 and buy 6")
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
db.inMail = {}
db.boughtFor = {}
db.warbandStock[AZEROOT] = nil
for key, c in pairs(db.characters) do c.stock[AZEROOT] = nil end
-- Maddoxius holds 6 of the 8, worth over 100g
db.characters["Maddoxius-Sargeras"].stock[AZEROOT] = 6
db.ownScan.prices[AZEROOT] = { 25 * 10000 }

bench.Login("Maddoxynn", { db = db })
bench.world.bank[AZEROOT], bench.world.bank[AZEROOT + 1] = nil, nil
bench.SetBags({ [AZEROOT] = 0, [AZEROOT + 1] = 0 })
bench.OpenAH()
local screen = bench.Screen()
bench.Show(screen)
bench.Has("all 8 to buy", screen, "Buy 8 Azeroot")
bench.Has("names who holds some", screen, "Maddoxius has 6 Azeroot")
bench.Has("says how to use them", screen, "Shift-click to buy only the rest.")

-- Shift-click: theirs count, the rest is bought
bench.world.modifiers.shift = true
bench.Click("Buy 8 Azeroot")
bench.world.modifiers.shift = false
bench.HasNot("shift-click buys nothing", bench.Calls(), "StartCommoditiesPurchase")
screen = bench.Screen()
bench.Has("buys only the rest", screen, "Buy 2 Azeroot")
bench.Has("says where theirs go", screen, "Maddoxius's 6 count: mail them to Mysticmead from Maddoxius.")

bench.Click("Buy 2 Azeroot")
bench.Has("asks the AH for 2", bench.Calls(), "StartCommoditiesPurchase(236774, 2)")
bench.QuotePrice(AZEROOT, bench.Gold(19), 2)
bench.PurchaseSucceeds(AZEROOT, 2, bench.Gold(19) * 2)
bench.Has("then nothing left to buy", bench.Screen(), "Nothing left to buy.")

-- For this visit only: next time it offers again
bench.CloseAH()
bench.OpenAH()
screen = bench.Screen()
bench.Has("next visit: the 6 again", screen, "Buy 6 Azeroot")
bench.Has("next visit: offers theirs again", screen, "Maddoxius has 6 Azeroot")
bench.Done()
