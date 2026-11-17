-- Buy next for an item sold one listing at a time (gear): the AH won't
-- quote it as a commodity, so it said "Not enough listed" for Green
-- Leather Armor with 26 listed (Green Iron Hauberk, user, 2026-11-17).
-- One click finds the cheapest buyout, the next buys that listing.
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
GoldsmithDB.orderBooks[AZEROOT] = { time = time(), total = 200, levels = { { price = bench.Gold(15), qty = 200 } } }
GoldsmithDB.orderBooks[AZEROOT + 1] = { time = time(), total = 200, levels = { { price = bench.Gold(70), qty = 200 } } }
addon:DataChanged()
-- The game says this one is sold one listing at a time
Enum.ItemCommodityStatus = Enum.ItemCommodityStatus or { Unknown = 0, Item = 1, Commodity = 2 }
C_AuctionHouse.GetItemCommodityStatus = function(id)
    return id == AZEROOT and Enum.ItemCommodityStatus.Item or Enum.ItemCommodityStatus.Commodity
end
GetMoney = function() return bench.Gold(10000) end
local function Listing(id, buyout, own)
    return { auctionID = id, itemKey = { itemID = AZEROOT }, quantity = 1, buyoutAmount = buyout,
        containsOwnerItem = own, itemLink = "|cffffffff|Hitem:" .. AZEROOT .. "|h[Azeroot]|h|r" }
end

bench.OpenAH()
bench.Calls()
bench.Click("Buy 8 Azeroot")
local calls = table.concat(bench.Calls(), "\n")
bench.Has("searched the item", calls, "SendSearchQuery(" .. AZEROOT, true)
bench.HasNot("not as a commodity", calls, "StartCommoditiesPurchase", true)

-- Your own listing is passed over for the cheapest other one
bench.world.itemResults = { Listing(71, bench.Gold(12), true), Listing(72, bench.Gold(15)), Listing(73, bench.Gold(16)) }
bench.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = AZEROOT })
local screen = bench.Screen()
bench.Has("the price on the button", screen, "Buy 1 Azeroot for 15", true)
bench.Has("says a click buys it", screen, "Click again to buy this one (1 of 8)", true)
bench.HasNot("not 'Not enough listed'", screen, "Not enough listed", true)
bench.HasNot("nothing bought yet", table.concat(bench.Calls(), "\n"), "PlaceBid", true)

bench.Click("Buy 1 Azeroot")
bench.Has("bought that listing", table.concat(bench.Calls(), "\n"), "PlaceBid(72, " .. bench.Gold(15) .. ")", true)
bench.Fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 72)
bench.Advance(1)
bench.Equal("on its way in the mail", GoldsmithDB.inMail["Mysticmead-Sargeras"][AZEROOT].quantity, 1)
bench.Has("the rest next", bench.Screen(), "Buy 7 Azeroot", true)

-- None listed: skipped with the reason
bench.Calls()
bench.Click("Buy 7 Azeroot")
bench.world.itemResults = {}
bench.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = AZEROOT })
bench.Has("none listed", bench.Screen(), "None listed", true)

-- Forever: the game gave no status for Green Leather Armor. The AH
-- refusing it as a commodity: tried as gear before "Not enough listed"
bench.CloseAH()
C_AuctionHouse.GetItemCommodityStatus = function() return nil end
bench.OpenAH()
bench.Calls()
bench.Click("Buy 7 Azeroot")
bench.Has("asked as a commodity first", table.concat(bench.Calls(), " "), "StartCommoditiesPurchase", true)
bench.Fire("COMMODITY_PRICE_UNAVAILABLE")
bench.Has("then searched as gear", table.concat(bench.Calls(), " "), "SendSearchQuery(" .. AZEROOT, true)
bench.world.itemResults = { Listing(74, bench.Gold(15)) }
bench.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = AZEROOT })
bench.Has("priced as gear", bench.Screen(), "Buy 1 Azeroot for 15", true)

-- A real commodity short on listings: still "Not enough listed"
bench.CloseAH()
bench.OpenAH()
bench.Click("Buy 7 Azeroot")
bench.Fire("COMMODITY_PRICE_UNAVAILABLE")
bench.Fire("COMMODITY_SEARCH_RESULTS_UPDATED", AZEROOT)
bench.Has("not enough listed", bench.Screen(), "Not enough listed", true)
bench.Done()
