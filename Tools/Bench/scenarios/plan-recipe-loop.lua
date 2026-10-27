-- Two materials each crafted from the other (quality conversions with
-- multicraft can make both look cheaper crafted than bought): the plan
-- built A from B from A from B... until "stack overflow" (a player's Lua
-- error on CurseForge, 2.7.0-beta, 2026-10-27). The plan must stop: each
-- item crafts at most once down a branch, and buys it after.
local bench = dofile(BENCH_DIR .. "bench.lua")
local A, B, TOP = 990001, 990002, 990003
local db = bench.LoadSaved()
db.recipes[990101] = { recipeID = 990101, name = "Convert to Loop A", outputName = "Loop A", outputItemID = A,
    outputQty = 2, outputMin = 2, outputMax = 2, profession = "Alchemy", skillLine = "Midnight Alchemy",
    reagents = { { itemIDs = { B }, names = { "Loop B" }, quantity = 1 } } }
db.recipes[990102] = { recipeID = 990102, name = "Convert to Loop B", outputName = "Loop B", outputItemID = B,
    outputQty = 2, outputMin = 2, outputMax = 2, profession = "Alchemy", skillLine = "Midnight Alchemy",
    reagents = { { itemIDs = { A }, names = { "Loop A" }, quantity = 1 } } }
db.recipes[990103] = { recipeID = 990103, name = "Loop Top", outputName = "Loop Top", outputItemID = TOP,
    outputQty = 1, outputMin = 1, outputMax = 1, profession = "Alchemy", skillLine = "Midnight Alchemy",
    reagents = { { itemIDs = { A }, names = { "Loop A" }, quantity = 4 } } }
db.ownScan.prices[A] = { bench.Gold(100) }
db.ownScan.prices[B] = { bench.Gold(100) }
db.ownScan.prices[TOP] = { bench.Gold(900) }
local addon = bench.Login("Mysticmead", { db = db })

local ok, plan = pcall(addon.BuildPlan, addon, db.recipes[990103], 1)
bench.Check("the plan finishes", ok, tostring(plan))
if ok then
    local depth, bought = 0, nil
    local function Walk(node, d)
        depth = math.max(depth, d)
        if node.loopBought then bought = node end
        for _, child in ipairs(node.children or {}) do Walk(child, d + 1) end
    end
    for _, node in ipairs(plan.nodes or {}) do Walk(node, 1) end
    bench.Check("it stops within a few steps", depth <= 6, "depth " .. depth)
    bench.Check("where it loops, it buys", bought ~= nil and bought.best and bought.best.method == "Buy",
        bought and (bought.name .. " " .. tostring(bought.best and bought.best.method)) or "none")
end
bench.Done()
