-- Forever's item search rows can say more than the item stacks to, with the
-- buyout for one: a Red Leather Bag at 18s came back quantity 8, so it was
-- 2s 25c each, under its 8s 75c vendor price, and Pattern: Red Linen Bag was
-- recorded as 105 (user, 2026-11-06).
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.foreverTest = true
-- Recorded by 2.8.0-beta: stack 1 goes to one, a real stack stays
local BAG, CLOTH = 990011, 990012
bench.AddItem(BAG, "Bench Bag", { sellPrice = 875, stack = 1 })
bench.AddItem(CLOTH, "Bench Cloth", { sellPrice = 10, stack = 20 })
local addon = bench.Login("Mysticmead", { db = db })

bench.Equal("a stack of one is one", addon:AuctionQuantity({ quantity = 8 }, BAG), 1)
bench.Equal("a real stack stays", addon:AuctionQuantity({ quantity = 12 }, CLOTH), 12)
bench.Equal("never over a stack", addon:AuctionQuantity({ quantity = 50 }, CLOTH), 20)
bench.Equal("no quantity is one", addon:AuctionQuantity({}, BAG), 1)

-- Bought: one bag for all the gold
bench.world.itemResults = { { auctionID = 1, itemKey = { itemID = BAG }, quantity = 8, buyoutAmount = 1800,
    itemLink = "|cffffffff|Hitem:" .. BAG .. "|h[Bench Bag]|h|r" } }
bench.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = BAG })
C_AuctionHouse.PlaceBid(1, 1800)
bench.Fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 1)
local bought
for _, e in ipairs(addon.ledger:getAll()) do
    if e.itemID == BAG then bought = e end
end
bench.Equal("recorded as one", bought and bought.quantity, 1)

-- Already recorded wrong
local old = addon.ledger
old:addCost("Unassigned", "Bench Bag", 8, 1800, "PURCHASE", BAG)
old:addCost("Unassigned", "Bench Cloth", 12, 120, "PURCHASE", CLOTH)
GoldsmithDB.auctionQuantitiesRepaired = nil
addon:RepairAuctionQuantities()
local bag, cloth
for _, e in ipairs(addon.ledger:getAll()) do
    if e.itemID == BAG then bag = e elseif e.itemID == CLOTH then cloth = e end
end
bench.Equal("old bag repaired", bag.quantity, 1)
bench.Equal("old stack left alone", cloth.quantity, 12)
bench.Done()
