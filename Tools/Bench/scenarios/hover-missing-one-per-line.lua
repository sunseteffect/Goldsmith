-- The Craft button's hover lists what's missing one item per line, vendor
-- materials under their own heading (user, 2026-10-25: run together it was
-- hard to read)
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local line = "Missing for 2 crafts: 12 Ominous Octopus, 2 Earthy Garnish, 6 A Big Ol' Stick of Butter."
bench.Equal("no vendor items: one per line", addon:ShoppingBlocker(line, { buyVendor = {} }),
    "Missing for 2 crafts:\n  12 Ominous Octopus\n  2 Earthy Garnish\n  6 A Big Ol' Stick of Butter")
addon.lastQueueVendor = { { name = "A Big Ol' Stick of Butter", quantity = 30 } }
local plan = { buyVendor = { { name = "A Big Ol' Stick of Butter", quantity = 6 } } }
bench.Equal("vendor items under their own heading", addon:ShoppingBlocker(line, plan),
    "Missing for 2 crafts:\n  12 Ominous Octopus\n  2 Earthy Garnish\n"
    .. "Buy from a vendor, enough for the whole queue:\n  30 A Big Ol' Stick of Butter (6 for this craft)")
bench.Equal("other blockers untouched", addon:ShoppingBlocker("Needs Cooking Fire nearby", plan),
    "Needs Cooking Fire nearby")
bench.Done()
