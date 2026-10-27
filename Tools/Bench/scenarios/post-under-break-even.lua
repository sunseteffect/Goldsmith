-- Posting under what yours cost you (crafted or paid, after the AH cut):
-- a chat line right after the post, no raid warning or sound (user,
-- 2026-10-26; error review #5). At or over break-even, and items with
-- only an estimated cost, say nothing. The same item again soon: quiet.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local POTENTIAL = bench.ItemID("Light's Potential")
-- Some in the bags, whatever the saved data holds (all 54 were posted on
-- 2026-10-27)
bench.SetBags({ [POTENTIAL] = 20 })
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
-- Patron order bag loot counts at the AH price for a sale's profit; a
-- post only counts the gold you spent, so loot posted at market is quiet,
-- and half loot, half bought at 100g has a break-even on 50g each
local basis, own = addon.GetUnitCostBasis, addon.GetOwnCost
local G = bench.Gold(100)
addon.GetUnitCostBasis = function() return G, false, "paid" end
addon.GetOwnCost = function() return G, "gathered", { { "gathered", G, 5 } } end
Post(G * 0.9)
bench.HasNot("bag loot at market: quiet", bench.Chat(), ": a loss of ")
addon.GetOwnCost = function() return G, "paid+gathered", { { "paid", G, 5 }, { "gathered", G, 5 } } end
Post(G * 0.6)
bench.HasNot("half loot: over what you spent", bench.Chat(), ": a loss of ")
addon.GetUnitCostBasis, addon.GetOwnCost = basis, own
Post(breakEven * 0.5)
local warned = bench.Chat()
bench.Has("warns under break-even", warned, ": a loss of ")
local calls = bench.Calls()
bench.HasNot("no sound", calls, "PlaySound(")
bench.HasNot("no raid warning", calls, "RaidNotice(")
-- The same item again soon: no second line
Post(breakEven * 0.5)
bench.HasNot("once per item", bench.Chat(), ": a loss of ")
Post(breakEven * 1.2)
bench.HasNot("quiet over break-even", bench.Chat(), ": a loss of ")
bench.HasNot("no sound over break-even", bench.Calls(), "PlaySound(")
bench.Done()
