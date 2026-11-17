-- Auctionator installed with its auction tooltips turned off: nothing
-- showed an AH price, as Goldsmith left it to Auctionator (Mercenary Blade
-- of the Hierophant, user 2026-11-17). Goldsmith shows its own then.
local bench = dofile(BENCH_DIR .. "bench.lua")
local callbacks = {}
TooltipDataProcessor.AddTooltipPostCall = function(_, fn) table.insert(callbacks, fn) end
local db = bench.LoadSaved()
db.searchPrices, db.orderBooks = {}, {}
local BLADE = 990021
bench.AddItem(BLADE, "Bench Mercenary Blade", { stack = 1 })
local tipsOn = false
Auctionator = { API = { v1 = {} }, Config = { Options = { AUCTION_TOOLTIPS = "auction_tooltips" },
    Get = function(name) return name == "auction_tooltips" and tipsOn end } }
local addon = bench.Login("Mysticmead", { db = db })
GoldsmithDB.ownScan = { time = time() - 60, method = "full", items = 1, group = addon:RealmGroup(),
    prices = { [BLADE] = { 8760, 8759, 81 } } }
addon:DataChanged()
addon:SetSetting("tooltips", "full")

local lines = {}
GameTooltip.AddDoubleLine = function(_, left, right) table.insert(lines, tostring(left) .. " " .. tostring(right)) end
GameTooltip.AddLine = function(_, text) table.insert(lines, tostring(text)) end
local function Hover(id)
    lines = {}
    for _, fn in ipairs(callbacks) do fn(GameTooltip, { id = id }) end
    return table.concat(lines, "\n")
end

bench.Check("Auctionator counts as installed", addon:HasAuctionator())
bench.Has("its tooltips off: Goldsmith shows the price", Hover(BLADE), "AH price", true)
tipsOn = true
bench.HasNot("its tooltips on: left to Auctionator", Hover(BLADE), "AH price", true)
bench.Done()
