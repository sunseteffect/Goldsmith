-- Two AH purchases inside a second: both recorded at what each cost. The
-- second used to replace the first while its gold settled, so it was never
-- saved (user, 2026-10-27: Bazaar Bites x1 and Blood Hunter x20 bought
-- fast got no "Bought" line). Buy next waits for the gold to settle.
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT = 236774
local AZEROOT_TEA = 1226197

local db = bench.LoadSaved()
db.settings.autoScan = false -- a scan older than an hour would start one on opening the AH
db.queues = {}
db.queues["Mysticmead-Sargeras"] = { { recipeID = AZEROOT_TEA, quantity = 8, made = 0, added = os.time() } }
local myst = db.characters["Mysticmead-Sargeras"]
myst.stock[AZEROOT], myst.stock[AZEROOT + 1] = nil, nil
myst.stock[242644] = 20
db.ownScan.prices[db.recipes[AZEROOT_TEA].outputItemID] = { 50 * 10000 }
db.searchPrices = {}
db.inMail["Mysticmead-Sargeras"] = {}
local addon = bench.Login("Mysticmead", { db = db })
bench.world.bank[AZEROOT], bench.world.bank[AZEROOT + 1] = nil, nil
bench.SetBags({ [AZEROOT] = 0, [AZEROOT + 1] = 0 })
bench.OpenAH()

local function Purchases()
    local list = {}
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.type == "COST" and e.kind == "PURCHASE" and e.itemID == AZEROOT then table.insert(list, e) end
    end
    return list
end
local before = #Purchases()

-- Bought by hand, back to back: the second confirmed before the first settled
local function Buy(quantity, total)
    C_AuctionHouse.ConfirmCommoditiesPurchase(AZEROOT, quantity)
    bench.world.money = bench.world.money - total
    bench.Fire("COMMODITY_PURCHASE_SUCCEEDED")
    bench.Fire("PLAYER_MONEY")
end
Buy(3, bench.Gold(60))
bench.Advance(0.3)
Buy(5, bench.Gold(100))
bench.Advance(3)
local list = Purchases()
bench.Equal("both recorded", #list - before, 2)
local first, second = list[before + 1], list[before + 2]
bench.Equal("first: its own gold", first and first.totalCopper, bench.Gold(60))
bench.Equal("second: its own gold", second and second.totalCopper, bench.Gold(100))
local chat = bench.Chat()
bench.Has("first's line", chat, "Bought Azeroot x3 for 60.00g", true)
bench.Has("second's line", chat, "Bought Azeroot x5 for 100.00g", true)

-- Buy next: a press while the last purchase's gold settles does nothing
bench.Click("Buy 8 Azeroot")
bench.Has("asks the AH for 8", bench.Calls(), "StartCommoditiesPurchase(236774, 8)")
bench.QuotePrice(AZEROOT, bench.Gold(19), 8)
bench.Has("buys under plan", bench.Calls(), "ConfirmCommoditiesPurchase(236774, 8)")
bench.world.money = bench.world.money - bench.Gold(19) * 8
bench.Fire("COMMODITY_PURCHASE_SUCCEEDED")
bench.Fire("PLAYER_MONEY")
bench.Advance(0.2)
bench.Check("settling", addon:PurchaseSettling())
addon:BuyNext()
bench.HasNot("press ignored while it settles", bench.Calls(), "StartCommoditiesPurchase")
bench.Advance(3)
bench.Check("settled", not addon:PurchaseSettling())
bench.Has("Buy next's line keeps its plan", bench.Chat(), "Bought Azeroot x8 for 152.00g (19.00g each, ", true)
bench.Done()
