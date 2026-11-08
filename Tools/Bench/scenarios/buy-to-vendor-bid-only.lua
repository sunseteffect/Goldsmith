-- Spiked Chain Gauntlets of Power (user, 2026-11-08): listed with a 7s bid
-- and no buyout. The scan showed 7s, Buy to vendor listed it, and clicking
-- said "isn't available any more". It should say bid only, and leave it off
-- the list at that price.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local world = bench.world
local GLOVES = 990071
bench.AddItem(GLOVES, "Bench Gauntlets", { sellPrice = 879, stack = 1 })
addon:SetSetting("flipMin", 50)
GetMoney = function() return 100000 end

local function Find()
    for _, e in ipairs(addon:GetFlips()) do
        if e.itemID == GLOVES then return e end
    end
end
C_AuctionHouse.GetBrowseResults = function()
    return { { itemKey = { itemID = GLOVES }, minPrice = 700 } }
end
addon:FindVendorFlips("pages")
bench.Advance(3)
bench.Check("listed at the scan's price", Find() ~= nil)
bench.Chat()

world.itemResults = { { auctionID = 1, itemKey = { itemID = GLOVES }, quantity = 1, bidAmount = 700,
    itemLink = "|cff1eff00|Hitem:" .. GLOVES .. "|h[Bench Gauntlets]|h|r" } }
addon:ClickFlip(Find())
bench.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = GLOVES })
local chat = bench.Chat()
bench.Has("says it's bid only", chat, "bid only", true)
bench.HasNot("not 'isn't available'", chat, "available", true)
bench.Check("row dropped", Find() == nil)

-- The next scan, the same bid: still off the list
addon:FindVendorFlips("pages")
bench.Advance(3)
bench.Check("stays off at that price", Find() == nil)
-- A buyout listing at another price comes back
C_AuctionHouse.GetBrowseResults = function()
    return { { itemKey = { itemID = GLOVES }, minPrice = 600 } }
end
addon:FindVendorFlips("pages")
bench.Advance(3)
bench.Check("another price lists it again", Find() ~= nil)
bench.Done()
