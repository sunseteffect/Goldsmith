-- A post the game never confirms went nowhere: Goldsmith says so, with the
-- game's error if there was one, keeps the details and forgets the price.
-- A confirmed post stays as it was (user, 2026-11-06).
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local POTENTIAL = bench.ItemID("Light's Potential")
bench.SetBags({ [POTENTIAL] = 20 })
C_AuctionHouse.CalculateCommodityDeposit = function() return 100 end
local function Post(price)
    local slot
    for i = 1, C_Container.GetContainerNumSlots(0) do
        local info = C_Container.GetContainerItemInfo(0, i)
        if info and info.itemID == POTENTIAL then slot = i break end
    end
    C_AuctionHouse.PostCommodity(ItemLocation:CreateFromBagAndSlot(0, slot), 2, 5, price)
end
local function Remembered(price)
    for _, p in ipairs(GoldsmithDB.posts or {}) do
        if p.unitPrice == price then return true end
    end
    return false
end
local function Deposits()
    local n = 0
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.kind == "DEPOSIT" then n = n + 1 end
    end
    return n
end
bench.OpenAH()
bench.Chat()
local before = Deposits()

-- Confirmed
Post(1234567)
bench.Fire("AUCTION_HOUSE_AUCTION_CREATED")
bench.Advance(10)
local chat = bench.Chat()
bench.Has("posted line", chat, "Posted Light's Potential", true)
bench.HasNot("no failure line", chat, "didn't post", true)
bench.Equal("deposit recorded", Deposits(), before + 1)
bench.Check("price remembered", Remembered(1234567))

-- Never confirmed
Post(2345678)
bench.Advance(4)
bench.HasNot("not yet", bench.Chat(), "didn't post", true)
bench.Advance(2)
bench.Has("says so", bench.Chat(), "Light's Potential didn't post. Check your Auctions tab.", true)
bench.Equal("no deposit", Deposits(), before + 1)
bench.Check("price forgotten", not Remembered(2345678))
local fail = GoldsmithDB.postFails[#GoldsmithDB.postFails]
bench.Equal("details kept", fail.buyout, 2345678)

-- The game's error
Post(3456789)
bench.Fire("UI_ERROR_MESSAGE", 1, "Internal auction error")
bench.Advance(6)
bench.Has("gives the reason", bench.Chat(), "didn't post: Internal auction error", true)
bench.Equal("reason kept", GoldsmithDB.postFails[#GoldsmithDB.postFails].reason, "Internal auction error")

-- A late confirmation after that doesn't record a post that's gone
bench.Fire("AUCTION_HOUSE_AUCTION_CREATED")
bench.Equal("nothing recorded", Deposits(), before + 1)

-- An item with copper in its price: says what to do
C_AuctionHouse.CalculateItemDeposit = function() return 100 end
local function PostItem(buyout)
    local slot
    for i = 1, C_Container.GetContainerNumSlots(0) do
        local info = C_Container.GetContainerItemInfo(0, i)
        if info and info.itemID == POTENTIAL then slot = i break end
    end
    C_AuctionHouse.PostItem(ItemLocation:CreateFromBagAndSlot(0, slot), 2, 1, nil, buyout)
end
bench.Chat()
PostItem(275)
bench.Advance(6)
bench.Has("copper named", bench.Chat(), "item prices can't have copper", true)
PostItem(300)
bench.Advance(6)
bench.HasNot("whole silver: not blamed on copper", bench.Chat(), "copper", true)
bench.Done()
