-- A Waylaid Crate's tooltip says what filling it costs, cheapest way first
-- (user, 2026-11-11: "so i know how much it costs in materials to fill
-- up"), at the full cost: what's in your bags counts at today's price too
-- (user, 2026-11-14: "show full cost"). Then the crate's cost filled.
local bench = dofile(BENCH_DIR .. "bench.lua")
local callbacks = {}
TooltipDataProcessor.AddTooltipPostCall = function(_, fn) table.insert(callbacks, fn) end
local db = bench.LoadSaved()
db.searchPrices, db.orderBooks = {}, {}
local CRATE = 248686
bench.AddItem(CRATE, "Waylaid Crate: Journeyman Herbs", { stack = 1 })
local herbs = { [3820] = "Stranglekelp", [2453] = "Bruiseweed", [3355] = "Wild Steelbloom",
    [3369] = "Grave Moss", [3356] = "Kingsblood" }
for id, name in pairs(herbs) do bench.AddItem(id, name, { stack = 20 }) end
local addon = bench.Login("Mysticmead", { db = db })
-- No price for Grave Moss
GoldsmithDB.ownScan = { time = time() - 60, method = "pages", items = 4, group = addon:RealmGroup(),
    prices = { [3820] = { 300, 300, 50 }, [2453] = { 200, 200, 50 }, [3355] = { 150, 150, 50 },
        [3356] = { 900, 900, 50 } } }
addon:DataChanged()

local lines = {}
GameTooltip.AddDoubleLine = function(_, left, right) table.insert(lines, tostring(left) .. " " .. tostring(right)) end
GameTooltip.AddLine = function(_, text) table.insert(lines, tostring(text)) end
local function Hover(id)
    lines = {}
    for _, fn in ipairs(callbacks) do fn(GameTooltip, { id = id }) end
    return lines
end

addon:SetSetting("tooltips", "full")
local list = addon:CrateFillCosts("Waylaid Crate: Journeyman Herbs")
bench.Equal("cheapest first", list[1].name, "Wild Steelbloom")
bench.Equal("its cost: 10 at 1.50s", list[1].cost, 1500)
bench.Equal("no price last", list[#list].name, "Grave Moss")
local shown = Hover(CRATE)
bench.Has("says the cost to fill", table.concat(shown, "\n"), "cost to fill")
local count = 0
for _, l in ipairs(shown) do if l:find("^  10 ") then count = count + 1 end end
bench.Equal("every way one per line", count, 5)

-- 6 Bruiseweed in bags: still the full cost, so Wild Steelbloom stays cheapest
bench.SetBags({ [2453] = 6 })
list = addon:CrateFillCosts("Waylaid Crate: Journeyman Herbs")
bench.Equal("bags: cheapest unchanged", list[1].name, "Wild Steelbloom")
bench.Equal("bags: full cost, 10 at 2s", list[2].cost, 2000)
bench.Equal("bags: have 6", list[2].have, 6)
bench.Has("bags: says how many to buy", table.concat(Hover(CRATE), "\n"), "10 Bruiseweed (buy 4)")

-- Enough in bags: still its price, marked in bags
bench.SetBags({ [2453] = 12 })
bench.Equal("in bags: full cost", addon:CrateFillCosts("Waylaid Crate: Journeyman Herbs")[2].cost, 2000)
bench.Has("in bags: says so", table.concat(Hover(CRATE), "\n"), "10 Bruiseweed (in bags)")

-- The crate filled: what it cost you plus the cheapest fill, and its
-- break-even after the 5% cut
local ownCost = addon.GetOwnCost
addon.GetOwnCost = function() return 500, "paid", {} end
local filled = table.concat(Hover(CRATE), "\n")
bench.Has("filled: crate 5s + fill 15s", filled, "cost filled " .. addon:FormatMoney(2000))
bench.Has("filled: break-even", filled, "break-even filled")
addon.GetOwnCost = ownCost

-- Short tooltips: the one line
addon:SetSetting("tooltips", "short")
bench.Equal("short: one line", #Hover(CRATE), 1)
bench.Equal("not a crate: nothing", addon:CrateFillCosts("Silk Cloth"), nil)
bench.Done()
