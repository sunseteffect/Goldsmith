-- Selling what came out of a patron payout bag: its cost is what it was
-- worth when the bag gave it (the order counted the bag then), not
-- today's AH price. 5 Tranquility Bloom from Maddoxius's 10-26 bag were
-- costed at today's 2.56g each and read -3.24g (user, 2026-10-27).
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Maddoxius")
local BLOOM = 236767
local loot
for _, g in ipairs(GoldsmithDB.gathered or {}) do
    if g.itemID == BLOOM and g.character == "Maddoxius" and g.payout and (g.value or 0) > 0 then loot = g end
end
bench.Check("Maddoxius got Bloom from a payout bag (what this tests)", loot ~= nil)
if loot then
    -- Today's price far from then, so the two can't be confused
    local market = addon.GetMarketPrice
    addon.GetMarketPrice = function(self, id, ...)
        if id == BLOOM then return bench.Gold(9) end
        return market(self, id, ...)
    end
    addon:DataChanged()
    local cost, _, source = addon:GetUnitCostBasis("Tranquility Bloom", loot.qty, BLOOM)
    bench.Equal("costed as loot", source, "paid")
    bench.Near("at its worth when the bag gave it", cost or 0, loot.value / loot.qty, 1)
end
bench.Done()
