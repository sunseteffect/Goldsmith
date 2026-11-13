-- A Waylaid Crate's tooltip says what filling it costs, cheapest way first,
-- counting what's already in your bags (user, 2026-11-11: "so i know how
-- much it costs in materials to fill up").
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

-- 6 Bruiseweed in bags: only 4 to buy, now the cheapest
bench.SetBags({ [2453] = 6 })
list = addon:CrateFillCosts("Waylaid Crate: Journeyman Herbs")
bench.Equal("bags count: cheapest now", list[1].name, "Bruiseweed")
bench.Equal("bags count: 4 to buy", list[1].cost, 800)
bench.Equal("bags count: have 6", list[1].have, 6)

-- Enough in bags: costs nothing more
bench.SetBags({ [2453] = 12 })
bench.Equal("in bags: nothing to buy", addon:CrateFillCosts("Waylaid Crate: Journeyman Herbs")[1].cost, 0)

-- Short tooltips: the one line
addon:SetSetting("tooltips", "short")
bench.Equal("short: one line", #Hover(CRATE), 1)
bench.Equal("not a crate: nothing", addon:CrateFillCosts("Silk Cloth"), nil)
bench.Done()
