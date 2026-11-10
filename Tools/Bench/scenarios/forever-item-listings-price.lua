-- Clicking into an item that isn't a commodity (Red Linen Bag) showed its
-- listings from 4s, while Goldsmith still priced it at 20s: only
-- commodities' listings were recorded (user, 2026-11-08). In Forever they
-- are now, priced like a commodity's (where enough are listed), without
-- bid-only listings. A row is how many are up at that price, each at its
-- buyout (207 at 4s showed as one, and it priced at 6s). Retail is left
-- alone: one item ID is every item level.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.foreverTest = true
local addon = bench.Login("Mysticmead", { db = db })
local world = bench.world
local BAG = 990091
bench.AddItem(BAG, "Bench Linen Bag", { stack = 1 })
GoldsmithDB.ownScan = { time = time() - 600, method = "pages", items = 1, group = addon:RealmGroup(),
    prices = { [BAG] = { 2000, 2000, 5 } } }
local before = addon:GetAHPriceInfo(BAG)
bench.Equal("before: the scan's 20s", before, 2000)

local function Listing(id, buyout, quantity)
    return { auctionID = id, itemKey = { itemID = BAG }, quantity = quantity or 1, buyoutAmount = buyout,
        bidAmount = buyout == nil and 300 or nil }
end
world.itemResults = { Listing(1, nil), Listing(2, 400, 200) }
for i = 3, 30 do world.itemResults[i] = Listing(i, i < 25 and 500 or 900) end
bench.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = BAG })
bench.Advance(1)
local price, source = addon:GetAHPriceInfo(BAG)
bench.Equal("priced from the listings", source, "Live")
bench.Equal("4s: 200 are up there", price, 400)
local book = GoldsmithDB.orderBooks[BAG]
bench.Equal("bid-only left out; each row its count", book and book.total, 200 + 22 + 6)
bench.Done()
