-- Some crafted, some bought: the posting screen's break-even is the
-- tooltip's, from all you hold. It counted the crafts alone, so Coarse
-- Weightstone said break-even 64c there and 74c in the tooltip (user,
-- 2026-11-11: 29 crafted, the rest bought).
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
local STONE = 990301
bench.AddItem(STONE, "Bench Weightstone", { stack = 20 })
local addon = bench.Login("Mysticmead", { db = db })
local lots = {}
for i = 1, 30 do
    lots[i] = { unitCost = 60, qty = 1, time = time() - 86400 + i, name = "Bench Weightstone", char = addon.charKey }
end
GoldsmithDB.craftLots[STONE] = lots
-- 20 bought at 90c after the crafts
addon.ledger:addCost("Unassigned", "Bench Weightstone", 20, 1800, "PURCHASE", STONE)
bench.SetBags({ [STONE] = 50 })
GoldsmithDB.characters[addon.charKey].stock[STONE] = 50
addon:DataChanged()

local own = addon:GetOwnCost("Bench Weightstone", nil, STONE)
bench.Equal("tooltip: crafts and purchases", own, (30 * 60 + 20 * 90) / 50)
bench.Equal("posting screen: the same", addon:PostCost(STONE, "Bench Weightstone", 50), own)
bench.Equal("posting a few: the same", addon:PostCost(STONE, "Bench Weightstone", 5), own)

bench.Done()
