-- When what you hold cost clearly more or less than today's prices, the
-- queue and the plan say so in plain sight: the profit at today's prices
-- (the to-do's basis) and what you paid more or less for. Flames of the
-- Sin'dorei read +463.63g on the to-do and +341.67g in the queue, the 6
-- Petrified Root held at 81g against 60g, and nothing said why (user,
-- 2026-10-25). Also: a to-do line's profit is for what its crafts make
-- (1 Missive craft makes about 1.3), as the queue counts it, and equals
-- the queue's profit at today's prices.
local bench = dofile(BENCH_DIR .. "bench.lua")
local MADDOXYNN = "Maddoxynn-Sargeras"
local FLAMES, MISSIVE

local db = bench.LoadSaved()
for id, r in pairs(db.recipes) do
    if r.outputName == "Enchant Weapon - Flames of the Sin'dorei" then FLAMES = id end
    if r.outputName == "Thalassian Missive of the Aurora" then MISSIVE = id end
end
db.queues[MADDOXYNN] = {
    { recipeID = FLAMES, quantity = 2, made = 0, tier = 2, concentrate = true, added = os.time() },
    { recipeID = MISSIVE, quantity = 1, made = 0, tier = 1, added = os.time() },
}
local addon = bench.Login("Maddoxynn", { db = db })

local q = addon:BuildQueue(MADDOXYNN)
local plans = {}
for _, row in ipairs(q.rows) do table.insert(plans, row.plan) end
local gap, item = addon:HeldGap(plans)
bench.Log("queue: profit %s, gap %s (%s)", addon:FormatMoney(q.profit), addon:FormatMoney(gap or 0), tostring(item))
bench.Check("the roots make a gap", gap and gap > bench.Gold(10), addon:FormatMoney(gap or 0))
bench.Equal("named for Petrified Root", item, "Petrified Root")

-- Queue tab footer
addon:ToggleWindow()
addon:ShowTab("queue")
bench.Advance(3)
local screen = bench.Screen()
bench.Has("queue footer: profit at today's prices", screen,
    addon:FormatSignedMoney(q.profit + (gap or 0)) .. " at today's prices")
bench.Has("queue footer: why", screen, "You paid " .. addon:FormatMoney(gap or 0) .. " more for Petrified Root")

-- The Flames plan screen (it plans what concentration covers now, so its
-- numbers can be for fewer crafts than the queue's)
addon:OpenCraftPlan(GoldsmithDB.recipes[FLAMES], { tier = 2, concentrate = true }, MADDOXYNN, 2, "queue")
bench.Advance(2)
screen = bench.Screen()
bench.Has("plan: profit at today's prices", screen, "%d+%% ROI · %+[%d,%.]+g at today's prices", false)
bench.Has("plan: why", screen, "You paid [%d,%.]+g more for Petrified Root", false)

-- Under the threshold (a few gold either way): nothing extra
local small = { nodes = {}, cost = bench.Gold(100), marketCost = bench.Gold(95), revenue = bench.Gold(150) }
bench.Equal("a 5g gap says nothing", addon:HeldGap(small), nil)

-- The to-do's Missive: profit for the whole craft, as the queue counts it
local todo = addon:GetCharacterTodo("All")[MADDOXYNN]
for _, t in ipairs(todo and todo.items or {}) do
    if t.recipe.recipeID == MISSIVE then
        local m = q.rows[2].plan
        local today = m.revenue - m.marketCost
        bench.Log("Missive: to-do %s for %d craft (about %.2f made), queue at today's prices %s",
            addon:FormatMoney(t.profit), t.crafts, t.made or 0, addon:FormatMoney(today))
        bench.Near("to-do counts what the craft makes", t.made, m.expectedOutput, 0.01)
        -- Same number: the inks it crafts are costed the same way on both
        -- (CraftPlanUnit, milling the pigments), not bought on one
        bench.Near("to-do matches the queue at today's prices", t.profit, today, bench.Gold(0.5))
    end
end
bench.Done()
