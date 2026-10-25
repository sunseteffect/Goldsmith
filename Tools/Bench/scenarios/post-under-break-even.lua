-- Posting under what yours cost you (crafted or paid, after the AH cut):
-- a chat warning, the raid warning and a popup right after the post (error review
-- #5). At or over break-even, and items with only an estimated cost, say
-- nothing.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local POTENTIAL = bench.ItemID("Light's Potential")
local cost, _, source = addon:GetUnitCostBasis("Light's Potential", 1, POTENTIAL)
bench.Check("Light's Potential has a crafted cost", source == "crafted" and cost > 0, tostring(source))
local breakEven = cost / 0.95
local function Post(unitPrice)
    local slot
    for i = 1, C_Container.GetContainerNumSlots(0) do
        local info = C_Container.GetContainerItemInfo(0, i)
        if info and info.itemID == POTENTIAL then slot = i break end
    end
    C_AuctionHouse.PostCommodity(ItemLocation:CreateFromBagAndSlot(0, slot), 2, 5, math.floor(unitPrice))
    bench.Advance(1)
end
bench.OpenAH()
bench.Calls()
Post(breakEven * 0.5)
bench.Has("warns under break-even", bench.Chat(), "under your break-even")
local calls = bench.Calls()
bench.Has("raid warning sound", calls, "PlaySound(RAID_WARNING)")
bench.Has("popup", calls, "RaidNotice(Goldsmith: Light's Potential posted under your break-even")
Post(breakEven * 1.2)
bench.HasNot("quiet over break-even", bench.Chat(), "under your break-even")
bench.HasNot("no sound over break-even", bench.Calls(), "PlaySound(")
bench.Done()
