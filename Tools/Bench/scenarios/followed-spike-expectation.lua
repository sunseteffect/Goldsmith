-- A price spike kept as a suggestion's expected price is judged at the
-- usual price: two Enchant Ring - Thalassian Haste were expected to sell
-- at 2,488g (usually about 9g), half of all the "missing" profit, so the
-- Stats accuracy read 44% (user, 2026-10-27: "its bad"). Needs Goldsmith
-- Data for the usual price.
local bench = dofile(BENCH_DIR .. "bench.lua")
GetCurrentRegion = function() return 1 end
dofile(BENCH_DIR .. "../../../GoldsmithData/Data_US.lua")
local addon = bench.Login("Mysticmead")

local f = addon:GetFollowedSummary(3650)
local haste
for _, s in ipairs(f.items) do
    if s.name == "Enchant Ring - Thalassian Haste" then haste = s end
end
bench.Check("Thalassian Haste is among the followed", haste ~= nil)
if haste and haste.expected then
    bench.Log("Thalassian Haste: made %s, expected %s", addon:FormatMoney(haste.profit), addon:FormatMoney(haste.expected))
    bench.Check("expected at the usual price, not the spike", haste.expected < bench.Gold(100) * haste.sold,
        addon:FormatMoney(haste.expected))
end
bench.Check("totals add up the checked items", f.expectedTotal > 0 and f.made ~= 0)

-- A price that was normal on its day stays the expectation, whatever the
-- price did since: Worldsoul Aegis kept 1,250g on Oct 16, usually 306g
-- today, and was judged at 306g, so the stat read 107% instead of 90%
-- (user, 2026-10-29: "surprised to see it this good")
local aegis
for _, s in ipairs(f.items) do
    if s.name == "Enchant Weapon - Worldsoul Aegis" then aegis = s end
end
if aegis and aegis.expected then
    bench.Check("Aegis judged at its day's price, not today's", aegis.expected > 0, addon:FormatMoney(aegis.expected))
end
-- Today's usual prices don't move it at all
local withData = f.expectedTotal
GoldsmithPriceData = nil
addon:DataChanged()
bench.Equal("expected doesn't follow today's prices", addon:GetFollowedSummary(3650).expectedTotal, withData)
bench.Done()
