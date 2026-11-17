-- Forever: a search lists each random suffix of a piece of gear as its own
-- row, all one item ID. The last row's price stood for all, and the
-- tooltip read "+1101%" (Northern Shortsword, user 2026-11-17). The
-- cheapest row counts, also across a later batch of the same search.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local SWORD = 990041
bench.AddItem(SWORD, "Bench Shortsword", { stack = 1 })
local function Row(suffix, price, qty)
    return { itemKey = { itemID = SWORD, itemSuffix = suffix, itemLevel = 13, battlePetSpeciesID = 0 },
        minPrice = price, totalQuantity = qty }
end
C_AuctionHouse.GetBrowseResults = function()
    return { Row(1, 1000, 4), Row(2, 1088, 5), Row(3, 12840, 2) }
end
bench.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
bench.Equal("cheapest suffix", addon:GetSearchPrice(SWORD), 1000)
bench.Equal("all of them counted", GoldsmithDB.searchPrices[SWORD].quantity, 11)
-- More rows come in, dearer: still the cheapest
bench.Fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", { Row(4, 2568, 2), Row(5, 990, 1) })
bench.Equal("later batch joins", addon:GetSearchPrice(SWORD), 990)
bench.Done()
