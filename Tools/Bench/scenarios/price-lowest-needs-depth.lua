-- A price counts when there's quantity behind it (DepthCheck, Pricing.lua;
-- 2026-10-28): a search priced Photosynthesized Scrap at 1.40g with 2,131
-- listed at about 19g. A search sees only the lowest listing, so far below
-- the usual price it's valued at the usual one; the item's own listings
-- (which show quantity) or days at the low price make it real.
local bench = dofile(BENCH_DIR .. "bench.lua")
local g = bench.Gold
local SCRAP = 275288 -- Photosynthesized Scrap

local addon = bench.Login("Mysticmead")
local function Day(back) return date("%Y-%m-%d", time() - back * 86400) end
local function History(prices)
    local h = {}
    for back, p in pairs(prices) do h[Day(back)] = g(p) end
    GoldsmithDB.priceHistory[SCRAP] = h
end
local function Search(price)
    GoldsmithDB.searchPrices[SCRAP] = { time = time() - 60, price = g(price), quantity = 2131,
                                        group = addon:RealmGroup() }
end
-- Only the search prices it
GoldsmithDB.ownScan = nil
GoldsmithDB.orderBooks[SCRAP] = nil
-- Usually about 17.62g (the median of the week before today)
History({ [1] = 18.20, [2] = 18.36, [3] = 17.79, [4] = 16, [5] = 16.7, [6] = 17.62, [7] = 10.12 })

-- A few at 1.40g: valued at the usual price, and the hover says why
Search(1.40)
local price, source, _, note = addon:GetAHPriceInfo(SCRAP)
bench.Equal("lone cheap listing not used", price, g(17.62))
bench.Equal("valued at the usual price", source, "Usual")
bench.Has("says why", tostring(note), "far below usual")
bench.Equal("shown as adjusted", addon:PriceAdjusted(note), true)
bench.Equal("same when buying", (addon:GetAHPriceInfo(SCRAP, true)), g(17.62))
bench.Has("source text", addon:AHPriceAgeText(SCRAP), "usual price")

-- What test 62 looks at in game: not a cheap material, and the item page
-- shows the usual price with a ~ and why in its hover
local function InDeals()
    addon:DataChanged()  -- the deals list is cached from login
    for _, deal in ipairs((addon:GetDeals("All"))) do
        -- Cheap materials: the ones this far under usual (Items.lua)
        if deal.itemID == SCRAP then return deal.diff <= -addon:Setting("dealPercent") / 100 end
    end
    return false
end
bench.Equal("not in Cheap materials", InDeals(), false)
addon:ToggleWindow()
bench.Advance(2)
addon:OpenItem(C_Item.GetItemNameByID(SCRAP) or "Photosynthesized Scrap", SCRAP)
bench.Advance(5)
local page = table.concat(bench.Screen(), "\n")
bench.Has("item page: the usual price", page, "17.62g")
bench.Has("item page: from the usual price", page, "usual price")
bench.HasNot("item page: not 1.40g as the AH price", page, "\n1.40g\n")
for line in page:gmatch("[^\n]+") do
    if line:find("17.62") or line:find("usual") or line:find("~") then bench.Log("%s", line) end
end

-- Somewhat below usual is a price, not a doubt
Search(12)
price, source = addon:GetAHPriceInfo(SCRAP)
bench.Equal("modest drop kept", price, g(12))
bench.Equal("from the search", source, "Search")

-- The item's own listings show 1.40g with quantity behind it: real
Search(1.40)
GoldsmithDB.orderBooks[SCRAP] = { time = time() - 60, total = 2131,
    levels = { { price = g(1.40), qty = 600 }, { price = g(19), qty = 1531 } } }
price, source = addon:GetAHPriceInfo(SCRAP)
bench.Equal("deep cheap listings used", price, g(1.40))
bench.Equal("from the live listings", source, "Live")
bench.Log("with real quantity at 1.40g, in Cheap materials: %s", tostring(InDeals()))
GoldsmithDB.orderBooks[SCRAP] = nil

-- Low for days: the price really fell
History({ [1] = 1.50, [2] = 1.45, [3] = 1.60 })
price, source = addon:GetAHPriceInfo(SCRAP)
bench.Equal("held low for days", price, g(1.40))
bench.Equal("still the search", source, "Search")
bench.Done()
