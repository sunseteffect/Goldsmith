-- Mysticmead's to-do, queued from its right-click, fits their concentration
local bench = dofile(BENCH_DIR .. "bench.lua")
dofile(BENCH_DIR .. "lib/todo-concentration.lua")(bench, "Mysticmead")
