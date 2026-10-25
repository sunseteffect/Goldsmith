-- On a character with nothing queued, while other characters' queues have
-- everything they need: Buy next says so rather than vanishing (user,
-- 2026-10-24: on Mysticmead nothing showed; Maddoxynn's Sienna Ink was
-- covered by her pigments and Mana Lily to mill, Trypttamine's alloy too)
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead", { db = bench.LoadSaved() })
bench.OpenAH()
bench.Advance(2)
bench.Has("says their queues need nothing", bench.Screen(), "Nothing to buy: Maddoxynn's and Trypttamine's queues have everything they need from the AH.")
bench.HasNot("no All queues box with nothing to buy", bench.Screen(), "All queues")
bench.Done()
