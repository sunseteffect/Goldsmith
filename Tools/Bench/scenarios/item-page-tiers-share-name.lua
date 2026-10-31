-- Tiers that share a name: your sales and posts are saved by name, so the
-- gold Crystalline Glass page showed the silver ones' cost (9.16g milled),
-- sales and a +85g profit at 928% (user, 2026-10-30). The page doesn't
-- borrow the other tier's cost, and says "both tiers" on your sales.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")

local page = addon:GetItemDetails("Crystalline Glass")
bench.Check("two tiers of Crystalline Glass", #page.tiers == 2)
local silver, gold
for _, t in ipairs(page.tiers) do
    if t.tier == 1 then silver = t.itemID elseif t.tier == 2 then gold = t.itemID end
end
bench.Check("silver and gold found", silver ~= nil and gold ~= nil)

local g = addon:GetItemDetails("Crystalline Glass", gold)
bench.Check("gold page knows the tiers share a name", g.sharedName == "both tiers")
bench.Check("gold page has no cost of yours (never bought or milled gold)", g.paid == nil)
bench.Check("gold break-even isn't the silver cost", g.breakEvenFrom ~= "paid")

local s = addon:GetItemDetails("Crystalline Glass", silver)
bench.Check("silver page still has its own cost", s.paid ~= nil)

bench.Done()
