-- Forever: a scan saves a price a day for every item it saw, not only the
-- ones Goldsmith tracks, so any item's page has a chart and a usual price
-- from before you first looked (user, 2026-11-16: Frost Tiger Blade).
-- Kept small (one string an item, 30 days); opening the page moves the
-- item to the tracked history.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.foreverTest = true
local addon = bench.Login("Mysticmead", { db = db })
bench.Check("Forever mode", addon.isForever == true)

local BLADE, GONE = 990001, 990002
bench.AddItem(BLADE, "Bench Tiger Blade", {})
bench.AddItem(GONE, "Bench Gone Blade", {})
local tracked = next(GoldsmithDB.priceHistory)

local function Scan(prices)
    GoldsmithDB.ownScan = { time = time(), method = "full", auctions = 10, items = 3, group = addon:RealmGroup(),
        realm = GetRealmName(), seconds = 1, prices = prices }
    addon:RecordScanHistory()
    bench.Advance(1)
end
-- Days pass on the clock alone: timers would run a day of tickers
local function Days(n) bench.world.baseTime = bench.world.baseTime + n * 86400 end
local function Day(back) return date("%Y-%m-%d", time() - back * 86400) end

local first = Day(0)
Scan({ [BLADE] = { 11900, 11900, 11 }, [GONE] = { 500, 500, 1 }, [tracked] = { 700, 700, 50 } })
local market = GoldsmithDB.marketHistory
bench.Check("saved as one string", type(market[BLADE]) == "string" and market[BLADE]:match(":11900$") ~= nil, market[BLADE])
bench.Equal("tracked items stay out", market[tracked], nil)
bench.Equal("not in the tracked history", GoldsmithDB.priceHistory[BLADE], nil)
bench.Equal("the day reads back", addon:GetDayPrices(BLADE)[first], 11900)

-- A later scan the same day: the day's last price
Scan({ [BLADE] = { 12000, 12000, 11 } })
bench.Equal("same day replaces", addon:GetDayPrices(BLADE)[first], 12000)

-- Two days on (a day without a scan between), then daily for a while
Days(2)
Scan({ [BLADE] = { 12500, 12500, 9 } })
local days = addon:GetDayPrices(BLADE)
bench.Equal("first day kept", days[Day(2)], 12000)
bench.Equal("skipped day is empty", days[Day(1)], nil)
bench.Equal("new day", days[Day(0)], 12500)
for _ = 1, 5 do
    Days(1)
    Scan({ [BLADE] = { 13000, 13000, 9 } })
end
local insight = addon:GetPriceInsight(BLADE)
bench.Check("usual price from it", insight ~= nil and insight.usual == 13000, insight and insight.usual)
local details = addon:GetItemDetails("Bench Tiger Blade", BLADE)
bench.Check("chart has the days", #details.history == 7, #details.history)

-- Past 30 days the old ones go, and an item no longer listed goes whole
Days(27)
Scan({ [BLADE] = { 14000, 14000, 9 } })
days = addon:GetDayPrices(BLADE)
local count = 0
for day in pairs(days) do
    count = count + 1
    bench.Check("within 30 days: " .. day, day > Day(30))
end
bench.Check("old days dropped", count >= 2 and count < 8, count)
bench.Equal("unlisted item dropped", market[GONE], nil)
local items, points = addon:MarketHistorySize()
bench.Check("size counted", items == 1 and points == count, items .. " items, " .. points .. " prices")

-- Opening the page: tracked from now on, days kept
addon:WatchItemPrice(BLADE)
bench.Equal("left the every-item history", market[BLADE], nil)
bench.Equal("days moved over", GoldsmithDB.priceHistory[BLADE][Day(0)], 14000)
Days(1)
Scan({ [BLADE] = { 14500, 14500, 9 } })
bench.Equal("stays out after", market[BLADE], nil)
bench.Equal("tracked history gets the scan", GoldsmithDB.priceHistory[BLADE][Day(0)], 14500)

-- Not on retail
addon.isForever = false
Scan({ [GONE] = { 500, 500, 1 } })
bench.Equal("retail: nothing saved", market[GONE], nil)
bench.Done()
