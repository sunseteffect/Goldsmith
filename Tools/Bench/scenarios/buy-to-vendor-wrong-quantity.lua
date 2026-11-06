-- Red Leather Bag (user, 2026-11-06): Forever's listing said quantity 8 at
-- 18s, so it looked like 2s 25c each, under the 8s 75c vendor price, and Buy
-- to vendor bought it. One bag at 18s must never be bought.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local world = bench.world

local BAG = 990021
bench.AddItem(BAG, "Bench Bag", { sellPrice = 875, stack = 1 })
addon:SetSetting("flipMin", 50)
GetMoney = function() return 100000 end

local function Find()
    for _, e in ipairs(addon:GetFlips()) do
        if e.itemID == BAG then return e end
    end
end
local function Bids()
    local n = 0
    for _, c in ipairs(bench.Calls()) do
        if tostring(c):find("PlaceBid", 1, true) then n = n + 1 end
    end
    return n
end

C_AuctionHouse.GetBrowseResults = function()
    return { { itemKey = { itemID = BAG }, minPrice = 300 } }
end
addon:FindVendorFlips("pages")
bench.Advance(3)
bench.Check("listed at the scan's price", Find() ~= nil)
bench.Chat()

world.itemResults = { { auctionID = 1, itemKey = { itemID = BAG }, quantity = 8, buyoutAmount = 1800,
    itemLink = "|cffffffff|Hitem:" .. BAG .. "|h[Bench Bag]|h|r" } }
local before = Bids()
addon:ClickFlip(Find())
bench.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = BAG })
bench.Has("says it's too dear", bench.Chat(), "under your minimum", true)
bench.Check("row dropped", Find() == nil)
bench.Equal("nothing bought", Bids(), before)
bench.Done()
