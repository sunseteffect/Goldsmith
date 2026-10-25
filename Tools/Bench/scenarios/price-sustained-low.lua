-- A price that fell for days is the price, not an undercut: TSM's market
-- value trails a falling market (SustainedLow, Pricing.lua; 2026-10-24,
-- Petrified Root at 60.40g while TSM said 110.42g). A lone undercut under
-- a steady price is still replaced by TSM's market value.
local bench = dofile(BENCH_DIR .. "bench.lua")
local g = bench.Gold
local ROOT = 251285 -- Petrified Root

-- TSM installed, with its market value for the root
local tsm = { DBMarket = { [ROOT] = g(110.42) } }
TSM_API = {
    GetCustomPriceValue = function(source, item)
        local id = tonumber(item:match("i:(%d+)"))
        return tsm[source] and tsm[source][id]
    end,
}

local addon = bench.Login("Mysticmead")
local function Day(back) return date("%Y-%m-%d", time() - back * 86400) end
local function History(prices)
    local h = {}
    for back, p in pairs(prices) do h[Day(back)] = g(p) end
    GoldsmithDB.priceHistory[ROOT] = h
end

-- Fell over the last days (75, 70, 71.50): 60.40g is the real price
History({ [1] = 75, [2] = 70, [3] = 71.5 })
local price, source, _, note = addon:CheckAgainstMarket(ROOT, g(60.40), "Scan", 0)
bench.Equal("fallen price kept", price, g(60.40))
bench.Equal("from the scan", source, "Scan")
bench.Equal("no undercut note", note, nil)

-- Steady at 110g, one listing at 60.40g: an undercut
History({ [1] = 110, [2] = 112, [3] = 109, [4] = 111 })
price, source, _, note = addon:CheckAgainstMarket(ROOT, g(60.40), "Scan", 0)
bench.Equal("lone undercut replaced", price, g(110.42))
bench.Equal("by TSM's market value", source, "TSM market")
bench.Has("says why", tostring(note), "small undercut")

-- Only one day seen low: not enough to trust
History({ [1] = 72 })
price = addon:CheckAgainstMarket(ROOT, g(60.40), "Scan", 0)
bench.Equal("one low day isn't enough", price, g(110.42))

-- Two of the last four days low (the rule's minimum)
History({ [2] = 70, [4] = 74 })
price = addon:CheckAgainstMarket(ROOT, g(60.40), "Scan", 0)
bench.Equal("two low days are", price, g(60.40))

-- Today's own reading doesn't count (it's the price being checked)
History({ [0] = 60.40, [1] = 110, [2] = 111 })
price = addon:CheckAgainstMarket(ROOT, g(60.40), "Scan", 0)
bench.Equal("today alone isn't history", price, g(110.42))

-- Right at the edge: median 75.50 is within 1.25x of 60.40 (75.50)
History({ [1] = 75.5, [2] = 75.5 })
price = addon:CheckAgainstMarket(ROOT, g(60.40), "Scan", 0)
bench.Equal("within 1.25x counts", price, g(60.40))
History({ [1] = 76, [2] = 76 })
price = addon:CheckAgainstMarket(ROOT, g(60.40), "Scan", 0)
bench.Equal("just over 1.25x doesn't", price, g(110.42))
bench.Done()
