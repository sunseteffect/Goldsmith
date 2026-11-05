-- A box whose contents lead back to itself: one that held itself, and two
-- that held each other. Priced inside itself, it went round until the
-- stack ran out, 2 s a time, and a player froze 15-20 s on every visit to
-- the Patron tab (Sunfire Silk Backpack, Atlasdair, 2026-11-04). Now the
-- copy inside counts at its AH price (none for these made-up boxes), and
-- the rest is priced as before.
local bench = dofile(BENCH_DIR .. "bench.lua")
local SELF, A, B = 990001, 990002, 990003
local db = bench.LoadSaved()
local addon = bench.Login("Maddoxynn", { db = db })

-- Something with a price, to find inside the boxes
local loot, price
for id in pairs(GoldsmithDB.priceHistory) do
    price = addon:GetMarketPrice(id)
    if price and price > 0 and not addon:GetBoxValue(id) then loot = id break end
end
bench.Check("an item with a price to put inside (what this tests)", loot ~= nil)
loot, price = loot or 0, price or 0

GoldsmithDB.boxContents = GoldsmithDB.boxContents or {}
GoldsmithDB.boxContents[SELF] = { opened = 2, items = { [loot] = 4, [SELF] = 1 } }
GoldsmithDB.boxContents[A] = { opened = 1, items = { [loot] = 1, [B] = 1 } }
GoldsmithDB.boxContents[B] = { opened = 1, items = { [loot] = 3, [A] = 1 } }

local ok, value, opened = pcall(addon.GetBoxValue, addon, SELF)
bench.Check("a box holding itself is priced, no stack overflow", ok, not ok and tostring(value) or nil)
bench.Near("it's worth what else came out", ok and value or 0, price * 4 / 2, 1)
bench.Equal("times opened", ok and opened, 2)

local okA, valueA = pcall(addon.GetBoxValue, addon, A)
bench.Check("two boxes holding each other are priced", okA, not okA and tostring(valueA) or nil)
-- A holds 1 loot and B; B (inside A) holds 3 loot and A, which counts as nothing
bench.Near("A: its loot and B's", okA and valueA or 0, price * 4, 1)

-- Afterwards the boxes still price normally (nothing left marked busy)
local again = addon:GetBoxValue(SELF)
bench.Near("priced again the same", again or 0, price * 2, 1)

bench.Done()
