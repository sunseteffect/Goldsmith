-- A herb's cost is its own quality's: Maddoxynn mills silver Argentleaf
-- (~4g) but bought gold Argentleaf at ~40g for a gold craft. By name the
-- two were averaged (19.68g a herb), so held Argentleaf Pigment cost 15.51g
-- against 2.85g on the AH, and the queue showed a Thalassian Missive at
-- -15.94g that the to-do had at +49g (user, 2026-10-25).
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Maddoxynn")

local SILVER, GOLD = 236776, 236777
local silver = addon:GetHerbUnitCost(SILVER, "Argentleaf")
local gold = addon:GetHerbUnitCost(GOLD, "Argentleaf")
bench.Log("Argentleaf silver %s, gold %s", addon:FormatMoney(silver or 0), addon:FormatMoney(gold or 0))
bench.Check("silver Argentleaf costs what silver was bought for", silver and silver < bench.Gold(10),
    addon:FormatMoney(silver or 0))
bench.Check("gold Argentleaf costs what gold was bought for", gold and gold > bench.Gold(20),
    addon:FormatMoney(gold or 0))

local pigment = bench.ItemID("Argentleaf Pigment")
local own = addon:GetOwnCost("Argentleaf Pigment", nil, pigment)
local market = addon:GetMarketPrice(pigment)
bench.Log("Argentleaf Pigment held at %s, AH %s", addon:FormatMoney(own or 0), addon:FormatMoney(market or 0))
bench.Check("held pigment near its AH price", own and market and own < market * 2,
    addon:FormatMoney(own or 0) .. " against " .. addon:FormatMoney(market or 0))

-- The Missive planned as the queue does: profit on what it cost you
local recipe
for _, r in pairs(GoldsmithDB.recipes) do
    if r.outputName == "Thalassian Missive of the Aurora" then recipe = r end
end
bench.Check("Maddoxynn knows the Missive", recipe ~= nil)
if recipe then
    local key = addon.charKey
    local p = { recipe = recipe, charKey = key, tier = 1, concentrate = false }
    local tierInfo = addon:WithCharacter(key, addon.FindTierInfo, p)
    tierInfo = tierInfo and addon:WithCharacter(key, addon.ChooseMix, addon, recipe, tierInfo, 1)
    local plan = addon:WithCharacter(key, addon.BuildPlan, addon, recipe, 1, true, tierInfo)
    bench.Log("Missive: cost %s, sells for %s", addon:FormatMoney(plan.cost), addon:FormatMoney(plan.revenue or 0))
    bench.Check("Missive plan makes gold", plan.profit and plan.profit > 0, addon:FormatMoney(plan.profit or 0))
end
bench.Done()
