-- Best crafts fitted to a character's gold: when they cost more than the
-- character has, best return per gold first and no craft over 25% of it,
-- so it's spread over several items (user, 2026-11-18: 6 Massive Iron
-- Axes for 9.12g and more on the to-do with 11.53g; "diversifying across
-- items is also good rather than just do 5 axes").
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.settings.minROI, db.settings.minLine = 0, 0
db.queues = {}
local addon = bench.Login("Mysticmead", { db = db })
local me = GoldsmithDB.characters[addon.charKey]

local function Mine(list)
    local out = {}
    for _, c in ipairs(list) do if c.charKey == addon.charKey then table.insert(out, c) end end
    return out
end
local function Cost(list)
    local n = 0
    for _, c in ipairs(list) do n = n + (c.row.cost or 0) * c.make end
    return n
end

-- Plenty of gold: as before
me.money = 1e12
addon:DataChanged()
local rich = Mine(addon:GetBestCrafts("All", math.huge))
bench.Check("Best crafts to fit", #rich >= 3, #rich)
bench.Equal("plenty: nothing waits", addon:GetGoldWaiting(addon.charKey), nil)
local full = Cost(rich)
local makes = {}
for _, c in ipairs(rich) do makes[c.key] = c.make end

-- Gold for all of them, but one would take most of it: capped at 25%
-- (9 Moonsteel Broadswords were 13.50g of 25g; user 2026-11-18)
local big = rich[1]
for _, c in ipairs(rich) do if (c.row.cost or 0) * c.make > (big.row.cost or 0) * big.make then big = c end end
-- Suggested 50 of it
local suggested = addon.SuggestedBatch
addon.SuggestedBatch = function(self, recipe, itemID)
    if recipe.recipeID == big.recipe.recipeID then return 50, "test" end
    return suggested(self, recipe, itemID)
end
local bigCost = (big.row.cost or 0) * 50
me.money = math.floor((full - (big.row.cost or 0) * big.make + bigCost) * 1.1)
bench.Check("one takes over 25% (what this tests)", bigCost > me.money * 0.25)
addon:DataChanged()
local capped
for _, c in ipairs(Mine(addon:GetBestCrafts("All", math.huge))) do if c.key == big.key then capped = c end end
bench.Check("still listed", capped ~= nil)
bench.Check("capped at 25% of the gold", capped and (capped.make == 1 or capped.row.cost * capped.make <= me.money * 0.25),
    capped and capped.make)
bench.Check("fewer than suggested", capped and capped.make < 50)
bench.Equal("gold for all: nothing waits", addon:GetGoldWaiting(addon.charKey), nil)
-- Cut down too small for "Worth a to-do at": it waits (4 Solid
-- Sharpening Stones for 2s74 showed with it at 10s; user 2026-11-18)
local cappedBatch = capped and capped.profit * capped.make or 0
GoldsmithDB.settings.minLine = (cappedBatch + 1) / 10000
addon:DataChanged()
local small
for _, c in ipairs(Mine(addon:GetBestCrafts("All", math.huge))) do if c.key == big.key then small = c end end
bench.Equal("too small once cut: off the list", small, nil)
local w = addon:GetGoldWaiting(addon.charKey)
bench.Check("too small once cut: waiting", w and w.covered and w.waiting[1] and w.waiting[1].key == big.key)
-- Short of gold too: every line fitted still makes it
me.money = math.floor(full / 3)
addon:DataChanged()
local under = 0
for _, c in ipairs(Mine(addon:GetBestCrafts("All", math.huge))) do
    if c.budgetRank and c.profit * c.make < GoldsmithDB.settings.minLine * 10000 then under = under + 1 end
end
bench.Equal("short: no fitted line under Worth a to-do at", under, 0)
GoldsmithDB.settings.minLine = 0
addon.SuggestedBatch = suggested

-- A third of what they cost
local money = math.floor(full / 3)
me.money = money
addon:DataChanged()
local fit = Mine(addon:GetBestCrafts("All", math.huge))
local gold = addon:GetGoldWaiting(addon.charKey)
bench.Check("short: says so", gold ~= nil)
bench.Check("fits the gold", Cost(fit) <= money, string.format("%d of %d", Cost(fit), money))
bench.Check("several crafts, not one", #fit >= 2, #fit)
local over = 0
for _, c in ipairs(fit) do
    local each = c.row.cost or 0
    if c.make > 1 and each * c.make > money * 0.25 then over = over + 1 end
    bench.Check("never more than before: " .. c.recipe.outputName, c.make <= makes[c.key])
end
bench.Equal("none over 25% of the gold (more than one of it)", over, 0)
for i = 2, #fit do
    bench.Check("best return per gold first: " .. fit[i].recipe.outputName, (fit[i - 1].margin or 0) >= (fit[i].margin or 0))
end
bench.Equal("what waits and what's made add up", #fit + #gold.waiting, #rich)

-- The to-do takes the same numbers
local todo = addon:GetCharacterTodo("All")[addon.charKey]
bench.Check("to-do", todo ~= nil)
local byKey = {}
for _, c in ipairs(fit) do byKey[c.recipe.recipeID] = c.make end
for _, item in ipairs(todo and todo.items or {}) do
    if item.budgetRank then
        bench.Equal("to-do: " .. item.recipe.outputName, item.quantity, byKey[item.recipe.recipeID])
    end
end

-- Overview hover says it
addon:ToggleWindow()
addon:ShowTab("overview")
bench.Advance(5)
local screen = table.concat(bench.Screen(), "\n")
bench.Has("card first line: the best return", screen, fit[1].recipe.outputName:sub(1, 20), true)

-- Queued and not bought yet: what the queue still has to buy comes off
-- the gold first (6 axes queued, none bought, skipped the check; user
-- 2026-11-18)
local cheapest = fit[1]
addon:AddToQueue(addon.charKey, cheapest.recipe.recipeID, 1, cheapest.row.tier, false)
-- Gold for the queue's buying on top of the rest's
local spend = addon:BuildQueue(addon.charKey).spend
me.money = money + spend
addon:DataChanged()
local withQueue = Mine(addon:GetBestCrafts("All", math.huge))
gold = addon:GetGoldWaiting(addon.charKey)
bench.Check("queue's buying counted", gold and gold.queueSpend > 0, gold and gold.queueSpend)
local others = {}
for _, c in ipairs(withQueue) do if c.key ~= cheapest.key then table.insert(others, c) end end
bench.Equal("queue's buying", gold and gold.queueSpend, spend)
bench.Check("the rest fit what's left", Cost(others) <= money, string.format("%d of %d", Cost(others), money))
bench.Check("and use it", Cost(others) > money / 2, string.format("%d of %d", Cost(others), money))
addon:ClearQueue(addon.charKey)

-- Queued: stays as you queued it, whatever the gold
local top = rich[1]
for _, c in ipairs(rich) do if (c.row.cost or 0) * c.make > (top.row.cost or 0) * top.make then top = c end end
addon:AddToQueue(addon.charKey, top.recipe.recipeID, makes[top.key], top.row.tier, false)
me.money = 0
addon:DataChanged()
local broke = Mine(addon:GetBestCrafts("All", math.huge))
local kept
for _, c in ipairs(broke) do if c.key == top.key then kept = c end end
bench.Check("queued: still there with no gold", kept ~= nil)
bench.Equal("queued: as many as before", kept and kept.make, makes[top.key])
bench.Equal("no errors", #bench.TakeErrors(), 0)
bench.Done()
