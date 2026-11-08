-- Gear with a random suffix: the purchase is saved as "Bench Hammer of
-- Magic" (the link's name) but the item's ID only gives "Bench Hammer", so
-- the tooltip never said what you paid (user, 2026-11-06: Sergeant's
-- Warhammer of Magic, 9s).
local bench = dofile(BENCH_DIR .. "bench.lua")
local callbacks = {}
TooltipDataProcessor.AddTooltipPostCall = function(_, fn) table.insert(callbacks, fn) end
local db = bench.LoadSaved()
local HAMMER = 990031
bench.AddItem(HAMMER, "Bench Hammer", { sellPrice = 933, stack = 1 })
local addon = bench.Login("Mysticmead", { db = db })

local lines = {}
GameTooltip.AddDoubleLine = function(_, left, right) table.insert(lines, tostring(left) .. " " .. tostring(right)) end
GameTooltip.AddLine = function(_, text) table.insert(lines, tostring(text)) end
local function Hover(link)
    lines = {}
    for _, fn in ipairs(callbacks) do fn(GameTooltip, { id = HAMMER, hyperlink = link }) end
    return table.concat(lines, "\n")
end

addon:SetSetting("tooltips", "full")
addon.ledger:addCost("Unassigned", "Bench Hammer of Magic", 1, 900, "PURCHASE", HAMMER)
local shown = Hover("|cff1eff00|Hitem:" .. HAMMER .. "::|h[Bench Hammer of Magic]|h|r")
bench.Has("says what you paid", shown, "yours cost you")
bench.HasNot("another suffix wasn't bought", Hover("|cff1eff00|Hitem:" .. HAMMER .. "::|h[Bench Hammer of the Bear]|h|r"),
    "yours cost you")
bench.Done()
