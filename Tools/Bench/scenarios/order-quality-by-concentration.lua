-- An order that asks for a quality is planned with concentration when that
-- reaches it for less and you have the concentration now: Potion of
-- Devoured Dreams (quality 2) was planned all gold at a 972g loss while
-- silver with 240 concentration made +58g (user, 2026-11-03).
local bench = dofile(BENCH_DIR .. "bench.lua")
local RECIPE = 1230862 -- Potion of Devoured Dreams
local db = bench.LoadSaved()
local key = "Mysticmead-Sargeras"
db.queues[key] = { { orderID = 1, recipeID = RECIPE, quantity = 1, made = 0, tier = 2, concentrate = false,
    provided = {}, commission = 602918, rewardsValue = 788715, added = os.time() } }
local currency = db.concentrationCurrency and db.concentrationCurrency.Alchemy
bench.Check("Alchemy concentration known", currency ~= nil)
local function Plan(concentration)
    bench.world.currencies = { [currency] = { quantity = concentration } }
    local addon = Goldsmith
    addon:DataChanged()
    local row = addon:BuildQueue(key).rows[1]
    return row, row.plan
end
local addon = bench.Login("Mysticmead", { db = db })
bench.Advance(5)

local row, plan = Plan(1000)
bench.Check("planned with concentration", row.tierInfo and row.tierInfo.concentrate == true,
    row.tierInfo and row.tierInfo.description)
bench.Check("makes money", plan and plan.profit > 0, plan and addon:FormatSignedMoney(plan.profit))

-- Not enough concentration: the plain way, as before
row, plan = Plan(10)
bench.Check("too little concentration: plain", row.tierInfo and not row.tierInfo.concentrate,
    row.tierInfo and row.tierInfo.description)
bench.Done()
