-- A mill run keeps what its herbs cost when it started: pigments were
-- costed at whatever herbs you held later, so herbs bought at 8g next week
-- would reprice pigments milled from 4g ones (user, 2026-10-25).
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Maddoxynn")

local HERB = 236776 -- silver Argentleaf
local PIGMENT = bench.ItemID("Argentleaf Pigment")
local recipeID
for _, run in ipairs(GoldsmithDB.salvageRuns or {}) do
    if run.itemID == HERB and run.recipeID then recipeID = run.recipeID end
end
bench.Check("Maddoxynn has milled Argentleaf before", recipeID ~= nil)

local herbs, pigments = addon:HeldAnywhere(HERB), addon:HeldAnywhere(PIGMENT)
local before = #GoldsmithDB.salvageRuns
local expected = addon:GetHerbUnitCost(HERB, "Argentleaf")

-- Mill 20 herbs into 26 pigments, then close the profession (ends the run)
bench.OpenProfession("Inscription")
C_TradeSkillUI.CraftSalvage(recipeID, 4, { itemID = HERB })
bench.SetBags({ [HERB] = (bench.world.bags[HERB] or herbs) - 20,
                [PIGMENT] = (bench.world.bags[PIGMENT] or 0) + 26 })
bench.Advance(1)
bench.CloseProfession()
bench.Fire("TRADE_SKILL_CLOSE")
bench.Advance(1)

local runs = GoldsmithDB.salvageRuns
local run = runs[#runs]
bench.Check("the run was saved", #runs > before or (run and run.time >= bench.world.baseTime))
bench.Equal("it used 20 herbs", run and run.used, 20)
bench.Check("it kept the herb cost from the start", run and run.herbCost and expected
    and math.abs(run.herbCost - expected) < 1, addon:FormatMoney(run and run.herbCost or 0))

-- Herbs get dearer afterwards: the run's pigments keep their cost
local costBefore = addon:GetOwnCost("Argentleaf Pigment", nil, PIGMENT)
for _, r in ipairs(runs) do
    if r.itemID == HERB and not r.herbCost then r.herbCost = expected end
end
local realCost = addon.GetHerbUnitCost
addon.GetHerbUnitCost = function(self, id, name)
    if id == HERB then return expected * 2, "paid" end
    return realCost(self, id, name)
end
addon.Refresh()
local costAfter = addon:GetOwnCost("Argentleaf Pigment", nil, PIGMENT)
addon.GetHerbUnitCost = realCost
bench.Log("pigment %s before, %s after herbs doubled", addon:FormatMoney(costBefore or 0), addon:FormatMoney(costAfter or 0))
bench.Check("pigment cost unchanged when herbs get dearer", costBefore and costAfter
    and math.abs(costAfter - costBefore) < 100, addon:FormatMoney(costAfter or 0))

-- A run saved before the change (no herbCost) still follows the herbs held now
for _, r in ipairs(runs) do r.herbCost = nil end
addon.GetHerbUnitCost = function(self, id, name)
    if id == HERB then return expected * 2, "paid" end
    return realCost(self, id, name)
end
addon.Refresh()
local oldWay = addon:GetOwnCost("Argentleaf Pigment", nil, PIGMENT)
addon.GetHerbUnitCost = realCost
bench.Check("older runs follow the herbs you hold now", oldWay and costBefore and oldWay > costBefore * 1.5,
    addon:FormatMoney(oldWay or 0))
bench.Done()
