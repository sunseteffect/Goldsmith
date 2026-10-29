-- Text cuts C2-C6 and C27 (user, 2026-10-25: keep text short)
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local row = { recipe = { outputName = "Gloaming Alloy" },
    state = { enabled = true, step = "Craft 1 Refulgent Copper Ingot" } }
bench.Equal("Next line: the step only", addon:QueueNextLine(row), "Next: Craft 1 Refulgent Copper Ingot")
row.state.final = true
bench.Equal("Next line: the final craft", addon:QueueNextLine(row), "Next: Gloaming Alloy")
-- The button says the same: no line (Mill 30 Mana Lily twice, 2026-10-29)
row = { recipe = { outputName = "Thalassian Treatise" },
    state = { enabled = true, step = "Mill 30 Mana Lily", label = "Mill 30 Mana Lily" } }
bench.Equal("Next line: not the button again", addon:QueueNextLine(row), nil)
row.state.label = "Mill 30 Mana..."
bench.Equal("Next line: the button cut short", addon:QueueNextLine(row), "Next: Mill 30 Mana Lily")
local ARGENTLEAF = bench.ItemID("Argentleaf")
addon:AddStockToQueue(addon.charKey, ARGENTLEAF, 20, "Argentleaf")
bench.Has("stock-up chat, yours", bench.Chat(), "Stocking up: 20 Argentleaf.")
addon:AddStockToQueue("Maddoxynn-Sargeras", ARGENTLEAF, 5, "Argentleaf")
bench.Has("stock-up chat, an alt", bench.Chat(), "Stocking up for Maddoxynn: 5 Argentleaf.")
bench.Done()
