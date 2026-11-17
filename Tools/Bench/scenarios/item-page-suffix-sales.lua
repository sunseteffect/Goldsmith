-- Gear with random suffixes is sold under its full name: Northern
-- Shortsword's page listed the sales under "Nothing sold yet." (user,
-- 2026-11-17). Sold and profit count them; the deposit too.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local SWORD = 990051
bench.AddItem(SWORD, "Bench Shortsword", { stack = 1 })
local L = addon.ledger
L:addCost("Unassigned", "Bench Shortsword of the Boar", 1, 1000, "PURCHASE", nil, { itemID = SWORD })
L:addCost("Unassigned", "Bench Shortsword of the Bear", 1, 100, "DEPOSIT")
L:addRevenue("Unassigned", "Bench Shortsword of the Boar", 1, 1070, 1000, false, 0, "paid", SWORD, { vendor = true })
L:addRevenue("Unassigned", "Bench Shortsword of the Bear", 1, 1070, 1000, false, 0, "paid", SWORD, { vendor = true })
addon:DataChanged()
local d = addon:GetItemDetails("Bench Shortsword", SWORD)
bench.Check("sales counted", d.earned and d.earned.units == 2, d.earned and d.earned.units)
bench.Equal("profit: 2 x 70 less the deposit", d.earned and d.earned.profit, 40)
local posted = false
for _, a in ipairs(d.activity) do if a.kind == "Posted" then posted = true end end
bench.Check("the deposit is in its activity", posted)
bench.Done()
