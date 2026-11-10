-- The craft notice prices materials at what yours cost you, the Crafts list
-- at today's prices. When those differ a lot the notice says both, so the
-- two line up (user, 2026-11-09: Silver Skeleton Key x2, -9s 48c on the
-- notice, -1s 90c each on Crafts; the bars were smelted from 10s ore, and
-- bars were 4s 59c on the AH).
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead", { db = bench.LoadSaved() })
local KEY, BAR = 999101, 999102
local prices = { [KEY] = 51, [BAR] = 459 }
local real = addon.GetMarketPrice
addon.GetMarketPrice = function(self, id, ...) if prices[id] then return prices[id] end return real(self, id, ...) end
addon.PlanCraftsDone = function() end

local recipe = { recipeID = 999100, outputName = "Silver Skeleton Key" }
addon:StartCraftBatch(recipe, { crafts = 1 })
bench.Chat()
addon:CraftBatchResult(999100, recipe, { itemID = KEY, quantity = 2 }, { qty = 2, unitCost = 520 }, { [BAR] = 1 })
local screen = table.concat(bench.Screen(), "\n")
bench.Has("profit on what yours cost", screen, "Estimated profit: " .. addon:FormatSignedMoney(96.9 - 1040), true)
bench.Has("and at today's prices", screen, "At today's prices: " .. addon:FormatSignedMoney(96.9 - 459) .. " (yours cost more)", true)
local chat = table.concat(bench.Chat(), "\n")
bench.Has("chat has the profit", chat, "estimated profit: " .. addon:FormatSignedMoney(96.9 - 1040), true)
bench.HasNot("chat stays one line", chat, "today's", true)

-- Close to today's prices: no second line
addon:StartCraftBatch(recipe, { crafts = 1 })
addon:CraftBatchResult(999100, recipe, { itemID = KEY, quantity = 2 }, { qty = 2, unitCost = 235 }, { [BAR] = 1 })
bench.HasNot("no line when they're close", table.concat(bench.Screen(), "\n"), "At today's prices", true)
bench.Done()
