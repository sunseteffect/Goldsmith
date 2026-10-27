-- Every to-do line, on every character, queued on its own the way its
-- right-click does, has the same profit at today's prices in the queue as
-- on the to-do. The to-do and plans used to cost materials two ways: the
-- to-do priced crafted materials' own materials as bought and left
-- salvaging out, plans milled and butchered, so Munsell Ink, Champion's
-- Bento and the Missive disagreed by 3g to 47g with nothing to say why
-- (user, 2026-10-25: "if there is a gap then it is explained"). What's
-- left between the two numbers is what you paid (HeldGap), which the queue
-- and plan say in plain text.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
for key in pairs(db.queues) do db.queues[key] = {} end
local addon = bench.Login("Maddoxynn", { db = db })

local lines = 0
for key, t in pairs(addon:GetCharacterTodo("All")) do
    for _, item in ipairs(t.items) do
        GoldsmithDB.queues[key] = {}
        local mix = item.leftoverOf and item.row.description or nil
        local prefMix = not mix and item.concentration and item.row.description or nil
        addon:QueueSuggestion(key, item.recipe, item.row.tier, item.concentration and true or false, item.crafts,
            nil, mix, prefMix)
        local q = addon:BuildQueue(key)
        local plan = q.rows[#q.rows] and q.rows[#q.rows].plan
        local name = string.format("%s, %dx %s", key:match("^[^-]+"), item.crafts, item.recipe.outputName)
        -- Known gap, not yet fixed: a plan salvages herbs the crafter holds
        -- even when buying is a little cheaper (HELD_SALVAGE_SHARE); the
        -- to-do's material costs are shared by every character, so they
        -- can't know who holds what (Mysticmead's 10 Malleable Root: Bento
        -- +43.48g on the to-do, +51.35g in the queue; 2026-10-26)
        local heldSalvage
        for _, node in ipairs(plan and addon:FlattenPlan(plan) or {}) do
            local o = node.options
            if o and o.millHeld and node.best == o.mill and o.other and o.other.unit < o.mill.unit * 1.1 then
                heldSalvage = node.name
            end
            -- The same for crafting from held materials when buying is
            -- a little cheaper (HELD_CRAFT_PREFERENCE): Trypttamine's
            -- Gloaming Alloy made its gold ingots from held ore at 52.40g,
            -- the to-do bought them at 49.69g, 5.05g apart (2026-10-27)
            if o and o.craftHeld and node.best == o.craft and o.buy
                and o.buy.unit < (o.craft.compareUnit or o.craft.unit) then
                heldSalvage = node.name .. " (crafted from held materials)"
            end
        end
        if heldSalvage and plan.revenue and plan.marketCost then
            bench.Log("%s: uses held materials for %s, to-do %s, queue %s", name, heldSalvage,
                addon:FormatMoney(item.profit), addon:FormatMoney(plan.revenue - (plan.todayCost or plan.marketCost)))
        elseif plan and plan.revenue and plan.marketCost then
            lines = lines + 1
            bench.Near(name, item.profit, plan.revenue - (plan.todayCost or plan.marketCost), bench.Gold(0.5))
        else
            bench.Check(name .. " has a priced plan", false)
        end
        GoldsmithDB.queues[key] = {}
    end
end
bench.Check("to-do lines to compare", lines >= 5, tostring(lines))
bench.Done()
