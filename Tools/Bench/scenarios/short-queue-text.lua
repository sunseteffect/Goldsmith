-- Queue text cuts C2-C6 (user, 2026-10-25: keep text short)
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local row = { recipe = { outputName = "Gloaming Alloy" },
    state = { enabled = true, step = "Craft 1 Refulgent Copper Ingot" } }
bench.Equal("Next line: the step only", addon:QueueNextLine(row), "Next: Craft 1 Refulgent Copper Ingot")
row.state.final = true
bench.Equal("Next line: the final craft", addon:QueueNextLine(row), "Next: Gloaming Alloy")
bench.Done()
