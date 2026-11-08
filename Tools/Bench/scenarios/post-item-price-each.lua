-- Two Linen Reagent Bags posted at 5s each (Auctionator: x2 for 10s): the
-- buyout is for each one, but Goldsmith halved it and said "posted at
-- 2s 50c: a loss of 1s 21c" (user, 2026-11-07).
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local BAG = 990051
bench.AddItem(BAG, "Bench Reagent Bag", { sellPrice = 100, stack = 1 })
bench.SetBags({ [BAG] = 2 })
addon.GetUnitCostBasis = function() return 359, false, "crafted" end
addon.GetOwnCost = function() return 359, "crafted", { { "crafted", 359, 2 } } end
local function Post(each)
    local slot
    for i = 1, C_Container.GetContainerNumSlots(0) do
        local info = C_Container.GetContainerItemInfo(0, i)
        if info and info.itemID == BAG then slot = i break end
    end
    C_AuctionHouse.PostItem(ItemLocation:CreateFromBagAndSlot(0, slot), 2, 2, nil, each)
    bench.Advance(1)
end
bench.OpenAH()
bench.Chat()
Post(500)
bench.HasNot("5s each is over break-even: quiet", bench.Chat(), ": a loss of ")
Post(200)
local chat = bench.Chat()
bench.Has("2s each warns", chat, ": a loss of ")
bench.Has("at the price you set", chat, "posted at " .. addon:FormatMoney(200), true)
local post = GoldsmithDB.posts[#GoldsmithDB.posts]
bench.Equal("remembered at the price each", post and post.unitPrice, 200)
bench.Done()
