-- Buying from Buy to vendor (user, 2026-11-05): one click loads the
-- listings, the next buys, and only at the scan's price. A new price still
-- over the minimum warns and needs the next click. Gone or under the
-- minimum warns and drops the row.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local world = bench.world

local SWORD, AXE, MACE, BOW = 990001, 990002, 990003, 990004
bench.AddItem(SWORD, "Bench Sword", { sellPrice = 500 })
bench.AddItem(AXE, "Bench Axe", { sellPrice = 500 })
bench.AddItem(MACE, "Bench Mace", { sellPrice = 500 })
bench.AddItem(BOW, "Bench Bow", { sellPrice = 500 })
addon:SetSetting("flipMin", 50)
GetMoney = function() return 100000 end

local function Listing(id, itemID, buyout, own)
    return { auctionID = id, itemKey = { itemID = itemID }, quantity = 1, buyoutAmount = buyout,
        containsOwnerItem = own, itemLink = "|cffffffff|Hitem:" .. itemID .. "|h[Bench]|h|r" }
end
local function Find(itemID)
    for _, e in ipairs(addon:GetFlips()) do
        if e.itemID == itemID then return e end
    end
end
local function Bids()
    local n = 0
    for _, c in ipairs(bench.Calls()) do
        if tostring(c):find("PlaceBid", 1, true) then n = n + 1 end
    end
    return n
end
local function Load(itemID, results)
    world.itemResults = results
    addon:ClickFlip(Find(itemID))
    bench.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = itemID })
end

C_AuctionHouse.GetBrowseResults = function()
    return { { itemKey = { itemID = SWORD }, minPrice = 100 }, { itemKey = { itemID = AXE }, minPrice = 100 },
        { itemKey = { itemID = MACE }, minPrice = 100 }, { itemKey = { itemID = BOW }, minPrice = 100 } }
end
addon:FindVendorFlips("pages")
bench.Advance(3)
bench.Equal("all four listed", #addon:GetFlips(), 4)
bench.Check("the listing's key is kept", Find(SWORD).key and Find(SWORD).key.itemID == SWORD)
bench.Chat()

-- The scan's price: no warning, the second click buys
local before = Bids()
Load(SWORD, { Listing(1, SWORD, 100), Listing(2, SWORD, 300) })
bench.Equal("first click doesn't buy", Bids(), before)
bench.HasNot("no warning", bench.Chat(), "now", true)
addon:ClickFlip(Find(SWORD))
bench.Equal("second click buys", Bids(), before + 1)
bench.Check("bought row goes", Find(SWORD) == nil)

-- Your own listing doesn't count
before = Bids()
Load(AXE, { Listing(3, AXE, 100, true), Listing(4, AXE, 200) })
bench.Has("new price warns", bench.Chat(), "Bench Axe is now", true)
bench.Equal("a new price doesn't buy on its own", Bids(), before)
addon:ClickFlip(Find(AXE))
bench.Equal("the next click buys at it", Bids(), before + 1)

-- Under the minimum (470 leaves 30c)
before = Bids()
Load(MACE, { Listing(5, MACE, 470) })
bench.Has("under the minimum warns", bench.Chat(), "under your minimum", true)
bench.Check("row dropped", Find(MACE) == nil)
bench.Equal("nothing bought", Bids(), before)

-- Gone
Load(BOW, {})
bench.Has("gone warns", bench.Chat(), "sold or was taken down", true)
bench.Check("row dropped", Find(BOW) == nil)
bench.Equal("nothing bought", Bids(), before)

-- A list over 5 minutes old goes away
addon:FindVendorFlips("pages")
bench.Advance(3)
bench.Equal("fresh scan lists", #addon:GetFlips(), 4)
bench.Advance(280)
addon:RefreshFlips()
bench.Equal("still there at 4:43", #addon:GetFlips(), 4)
bench.Advance(30)
bench.Equal("gone after 5 minutes", #addon:GetFlips(), 0)
bench.Done()
