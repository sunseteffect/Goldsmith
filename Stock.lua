local addon = _G.Goldsmith or {}

-- Materials on hand and price history

-- Every material Goldsmith knows about: reagents from saved recipes and
-- herbs you've milled. Returns { [itemID] = name }.
function addon:GetTrackedMaterials()
    local materials = {}
    for _, recipe in pairs(GoldsmithDB.recipes) do
        for _, slot in ipairs(recipe.reagents) do
            for i, itemID in ipairs(slot.itemIDs or {}) do
                materials[itemID] = slot.names[i]
            end
        end
    end
    for herbID, record in pairs(GoldsmithDB.milling) do
        materials[herbID] = record.name
    end
    return materials
end

-- Crafting quality tier of a reagent (1, 2, ...), or nil if it has none
local function GetQualityTier(itemID)
    local fn = C_TradeSkillUI.GetItemReagentQualityByItemInfo
    if not fn then return nil end
    local ok, tier = pcall(fn, itemID)
    if ok and tier and tier > 0 then
        return tier
    end
end

-- Materials in your bags, bank, reagent bank and warband bank, valued at
-- what they cost you (or the AH price if you have no cost for them).
-- prof filters to one profession's materials, or "All".
-- Returns a list of { itemID, name, count, unitValue, value, source }
-- sorted by value, and the total value.
function addon:GetMaterialsOnHand(prof)
    local list, total = {}, 0
    for itemID, name in pairs(addon:GetTrackedMaterials()) do
        local materialProf = GoldsmithDB.reagents[name]
        if prof == "All" or materialProf == prof then
            local count = C_Item.GetItemCount(itemID, true, false, true, true) or 0
            if count > 0 then
                local unit, source = addon:GetOwnCost(name)
                if not unit then
                    unit = addon:GetMarketPrice(itemID)
                    source = unit and "AH price"
                end
                local value = unit and unit * count
                local tier = GetQualityTier(itemID)
                table.insert(list, {
                    itemID = itemID,
                    name = tier and string.format("%s (tier %d)", name, tier) or name,
                    profession = materialProf,
                    count = count,
                    unitValue = unit,
                    value = value,
                    source = source,
                })
                total = total + (value or 0)
            end
        end
    end
    table.sort(list, function(a, b)
        return (a.value or 0) > (b.value or 0)
    end)
    return list, total
end

-- Price history
--
-- Auctionator's own price history isn't available to other addons, so each
-- time Auctionator updates its prices Goldsmith saves one price per day for
-- every material and crafted item it knows. Kept for HISTORY_DAYS days in
-- GoldsmithDB.priceHistory[itemID]["YYYY-MM-DD"], for the item page's
-- chart, usual prices and Cheap materials. Each day's first login also
-- saves the AH price Goldsmith shows (RecordDailyHistory), so all of that
-- works without Auctionator too.
-- A day's price is the middle of that day's scans (Goldsmith's and
-- Auctionator's), not the last one: prices drift through the day, so the
-- last scan said more about when you played than about the day (user,
-- 2026-10-23: "how do we evaluate the single snapshot of the day?"). The
-- scans so far today are kept in GoldsmithDB.priceReadings = { day,
-- items = { [itemID] = { prices } } }, the last MAX_READINGS each; a new
-- day starts it over. The login price (often TSM's, an average of its own)
-- only stands in until today's first scan.
local HISTORY_DAYS = 60
local MAX_READINGS = 8

local function Median(list)
    if #list == 0 then return nil end
    local sorted = {}
    for i, v in ipairs(list) do sorted[i] = v end
    table.sort(sorted)
    local mid = math.floor(#sorted / 2)
    return (#sorted % 2 == 1) and sorted[mid + 1] or (sorted[mid] + sorted[mid + 1]) / 2
end
addon.Median = Median

local function TodaysReadings(today)
    local r = GoldsmithDB.priceReadings
    if not r or r.day ~= today then
        r = { day = today, items = {} }
        GoldsmithDB.priceReadings = r
    end
    return r.items
end

local function AddReading(history, itemID, today, price)
    local items = TodaysReadings(today)
    local list = items[itemID] or {}
    items[itemID] = list
    table.insert(list, price)
    if #list > MAX_READINGS then table.remove(list, 1) end
    history[itemID] = history[itemID] or {}
    history[itemID][today] = Median(list)
end

-- Items whose page you opened, so their chart fills in from then on:
-- GoldsmithDB.viewedItems[itemID] = when last opened (dropped after
-- HISTORY_DAYS). Today's price is saved at once, the chart's first point.
function addon:WatchItemPrice(itemID)
    if type(itemID) ~= "number" then return end
    GoldsmithDB.viewedItems = GoldsmithDB.viewedItems or {}
    GoldsmithDB.viewedItems[itemID] = time()
    local history = GoldsmithDB.priceHistory
    local today = date("%Y-%m-%d")
    if history[itemID] and history[itemID][today] then return end
    local price = addon:GetAHPrice(itemID, true)
    if price and price > 0 then
        history[itemID] = history[itemID] or {}
        history[itemID][today] = price
    end
end

-- Every material and crafted item Goldsmith knows, what you've bought or
-- sold, and pages you opened: { [itemID] = name or true }
local function HistoryItems()
    local items = addon:GetTrackedMaterials()
    for _, e in ipairs(addon.ledger and addon.ledger:getAll() or {}) do
        if e.itemID and not items[e.itemID] then items[e.itemID] = e.item or true end
    end
    local cutoff = time() - HISTORY_DAYS * 86400
    for itemID, when in pairs(GoldsmithDB.viewedItems or {}) do
        if when < cutoff then GoldsmithDB.viewedItems[itemID] = nil
        elseif not items[itemID] then items[itemID] = true end
    end
    for _, recipe in pairs(GoldsmithDB.recipes) do
        items[recipe.outputItemID] = recipe.outputName
    end
    -- Each quality tier of a crafted item is its own item (gold Draught of
    -- Rampant Abandon isn't the silver one), known from any character's
    -- tier data
    for _, c in pairs(GoldsmithDB.characters) do
        for recipeID, td in pairs(c.tierData or {}) do
            local recipe = GoldsmithDB.recipes[recipeID]
            for _, out in pairs(td.outputs or {}) do
                if out.itemID and not items[out.itemID] then
                    items[out.itemID] = recipe and recipe.outputName or true
                end
            end
        end
    end
    return items
end

local function PruneHistory(history)
    local cutoff = date("%Y-%m-%d", time() - HISTORY_DAYS * 86400)
    for itemID, days in pairs(history) do
        for day in pairs(days) do
            if day < cutoff then
                days[day] = nil
            end
        end
        if next(days) == nil then
            history[itemID] = nil
        end
    end
end

-- Today's AH price as Goldsmith shows it (the freshest of TSM, Auctionator
-- and Goldsmith Data, as the Prices setting says: user, 2026-10-09, so the
-- chart matches the AH price tile), for each item without a price today.
-- Once a day, at login. An Auctionator scan later that day overwrites it
-- with what it saw; this never overwrites.
function addon:RecordDailyHistory()
    local day = date("%Y-%m-%d")
    if GoldsmithDB.dataHistoryDay == day then return end
    local history = GoldsmithDB.priceHistory
    local added = 0
    for itemID in pairs(HistoryItems()) do
        if type(itemID) == "number" and not (history[itemID] and history[itemID][day]) then
            -- The listed price, as scans save (not capped for selling)
            local price = addon:GetAHPrice(itemID, true)
            if price and price > 0 then
                history[itemID] = history[itemID] or {}
                history[itemID][day] = price
                added = added + 1
            end
        end
    end
    GoldsmithDB.dataHistoryDay = day
    PruneHistory(history)
    if added > 0 then addon:DataChanged() end
end

-- The same pass also notes when each item's Auctionator price was seen, as
-- GoldsmithDB.priceSeen[itemID] = { time, price }, because Auctionator only
-- gives ages in whole days. A full scan stamps every item priced today. A
-- search doesn't say which items it saw, so it only stamps items whose
-- price changed: an item it saw at the same price keeps its older time,
-- so a time is never newer than it should be.
function addon:RecordPriceHistory(isFullScan)
    local history = GoldsmithDB.priceHistory
    local seen = GoldsmithDB.priceSeen
    local now = time()
    local today = date("%Y-%m-%d")

    for itemID in pairs(HistoryItems()) do
        -- Only prices Auctionator saw today, so old prices aren't saved as new
        local price = addon:GetAuctionatorPrice(itemID)
        if price and addon:GetAuctionatorAge(itemID) == 0 then
            -- A new reading only when it saw something: a search passes on
            -- every price it didn't look at, unchanged, and counting those
            -- again would outweigh the day's other scans
            local last = seen[itemID]
            local new = isFullScan or not last or last[2] ~= price
            local readings = TodaysReadings(today)
            if new or not readings[itemID] then AddReading(history, itemID, today, price) end
            if new then seen[itemID] = { now, price } end
        end
    end

    -- A day on, Auctionator's own age in days takes over
    for itemID, entry in pairs(seen) do
        if now - entry[1] > 2 * 86400 then seen[itemID] = nil end
    end

    PruneHistory(history)
end

-- Goldsmith's own AH scan (Scan.lua) saves today's price for every
-- material and crafted item, as an Auctionator scan does, so the chart,
-- usual prices and Cheap materials fill in without Auctionator
function addon:RecordScanHistory()
    local history = GoldsmithDB.priceHistory
    local today = date("%Y-%m-%d")
    local added = 0
    for itemID in pairs(HistoryItems()) do
        local price = type(itemID) == "number" and addon:GetScanPrice(itemID)
        if price and price > 0 then
            AddReading(history, itemID, today, price)
            added = added + 1
        end
    end
    PruneHistory(history)
    if added > 0 then addon:DataChanged() end
    return added
end

-- Stock-up insights
--
-- Today's price compared with the item's usual price: the median of its
-- daily prices over the last SHORT_DAYS, not counting today (the last
-- LONG_DAYS while fewer than SHORT_MIN of those are saved). It was every
-- saved day, so Petrified Root, down from 340g to 70g over ten days, read
-- 74% below a usual of 310g (user, 2026-10-23). Trend: that recent median
-- against the LONG_DAYS one, "falling" or "rising" past TREND_MOVE, else
-- "steady"; a falling price isn't a deal to stock up on, since next week
-- is likely cheaper again. Needs INSIGHT_MIN_DAYS days of history first. Until then, Goldsmith Data's usual price for the region
-- (its last 7 days, same price rule), so a fresh install has Cheap
-- materials on day one instead of "needs 5 days" (user's laptop,
-- 2026-10-15). Returns { now, usual, diff (-0.18 = 18% below usual),
-- days, low, high } or nil, plus the number of days of your own history.
-- A regional one has regional = true and no days, low or high.
local INSIGHT_MIN_DAYS = 5
local SHORT_DAYS, SHORT_MIN = 7, 3
local LONG_DAYS, LONG_MIN = 30, 10
local TREND_MOVE = 0.15

-- Goldsmith Data's usual price (7th number), or nil
local function RegionalUsual(itemID)
    local data = GoldsmithPriceData
    local entry = data and data.items and data.items[itemID]
    return entry and entry[7]
end

local function RegionalInsight(itemID, ownDays)
    local usual = RegionalUsual(itemID)
    local now = usual and addon:GetMarketPrice(itemID, true)
    if not now or usual <= 0 then return nil, ownDays end
    return { now = now, usual = usual, diff = (now - usual) / usual, regional = true }, ownDays
end

function addon:GetPriceInsight(itemID)
    local days = GoldsmithDB.priceHistory[itemID]
    if not days then return RegionalInsight(itemID, 0) end
    local today = date("%Y-%m-%d")
    local shortFrom = date("%Y-%m-%d", time() - SHORT_DAYS * 86400)
    local longFrom = date("%Y-%m-%d", time() - LONG_DAYS * 86400)
    local short, long = {}, {}
    local low, high = math.huge, 0
    for day, price in pairs(days) do
        if day ~= today and day >= longFrom then
            table.insert(long, price)
            low, high = math.min(low, price), math.max(high, price)
            if day >= shortFrom then table.insert(short, price) end
        end
    end
    if #long < INSIGHT_MIN_DAYS then return RegionalInsight(itemID, #long) end
    local longUsual = Median(long)
    local recent = #short >= SHORT_MIN
    local usual = recent and Median(short) or longUsual
    local trend, move
    if recent and #long >= LONG_MIN and longUsual > 0 then
        move = (usual - longUsual) / longUsual
        trend = (move <= -TREND_MOVE and "falling") or (move >= TREND_MOVE and "rising") or "steady"
    end

    -- What it costs to buy, as the saved prices are: the price for selling
    -- is capped at TSM's sale average, so Malleable Root listed at 15g read
    -- 6.25g, "44% below usual", while it was rising (user, 2026-10-23)
    local now = addon:GetMarketPrice(itemID, true)
    if not now or usual <= 0 then return nil, #long end
    return {
        now = now, usual = usual, diff = (now - usual) / usual,
        days = recent and #short or #long, recent = recent, shortDays = SHORT_DAYS,
        longUsual = longUsual, longDays = #long, trend = trend, move = move,
        low = low, high = high,
    }, #long
end

-- Saved daily prices over the last `days` (today too), oldest first: for
-- the Cheap materials trend line
function addon:GetPriceSeries(itemID, days)
    local saved = GoldsmithDB.priceHistory[itemID]
    if not saved then return {} end
    local from = date("%Y-%m-%d", time() - (days or LONG_DAYS) * 86400)
    local list = {}
    for day, price in pairs(saved) do
        if day >= from then table.insert(list, { day = day, value = price }) end
    end
    table.sort(list, function(a, b) return a.day < b.day end)
    return list
end

-- How many to stock up on, for Cheap materials: a few weeks of what your
-- crafts and salvages used, less what you hold and have queued to stock.
-- More weeks the deeper the discount: 2 under 35% off, 3 under 50%, else 4.
-- A falling price only tops up to a week (it's likely cheaper next week);
-- without a trend yet, at most 2. Nothing under a week's use of 1, and
-- nothing that's cheaper to make (item.makeUnit, MakeUnitCost).
-- Returns amount, weeks, rate a week; or nil and why.
local STOCK_WEEKS = { { 0.5, 4 }, { 0.35, 3 }, { 0, 2 } }
function addon:StockUpAmount(item)
    -- Cheaper to make than to buy, even at today's price: nothing to stock
    if item.makeUnit and item.now and item.makeUnit < item.now then
        return nil, string.format("cheaper to %s (%s each)", (item.makeWay or "make"):lower(), addon:FormatMoney(item.makeUnit))
    end
    -- What you use, never what you buy: a stock-up bought raised a bought
    -- rate and asked for more, "to infinity" (user, 2026-10-23)
    local rate = item.perWeek or 0
    if rate <= 0 then return nil, "no use recorded yet" end
    if rate < 1 then return nil, "you use too few for a stock" end
    local weeks
    for _, w in ipairs(STOCK_WEEKS) do
        if -item.diff >= w[1] then weeks = w[2] break end
    end
    if item.trend == "falling" then
        weeks = 1
    elseif not item.trend then
        weeks = math.min(weeks, 2)
    end
    -- Bought and still in the mailbox counts as held
    local queued = addon.QueuedStock and addon:QueuedStock(item.itemID) or 0
    local mail = addon.InMailCount and addon:InMailCount(item.itemID) or 0
    local amount = math.ceil(rate * weeks) - (item.have or 0) - mail - queued
    if amount < 1 then
        return nil, item.trend == "falling" and "falling: you have a week's worth" or "you have enough"
    end
    -- Round numbers past 20 (as you'd type them)
    if amount > 20 then amount = math.ceil(amount / 5) * 5 end
    return amount, weeks, rate
end

-- How much of a material you've bought lately (every character): the
-- amount over the last BUY_DAYS, the days that covers (fewer when your
-- history is younger, at least a week), and that as a weekly rate. So
-- Cheap materials can say whether it's something you go through (user,
-- 2026-10-23: "I don't know how often I actually use those materials").
-- Purchases saved before item IDs were kept match by name, so both
-- qualities of a material count them.
local BUY_DAYS = 30
function addon:GetRecentBuys(itemID, name)
    local idx = addon.ledger:index()
    local all = addon.ledger:getAll()
    local now = time()
    local since = now - BUY_DAYS * 86400
    local first = all[1] and all[1].timestamp or now
    local days = math.max(math.min(BUY_DAYS, (now - first) / 86400), 7)
    local qty = 0
    for _, e in ipairs(idx.purchasesByID[itemID] or {}) do
        if (e.timestamp or 0) >= since then qty = qty + (e.quantity or 0) end
    end
    for _, e in ipairs(name and idx.purchases[name] or {}) do
        if not e.itemID and (e.timestamp or 0) >= since then qty = qty + (e.quantity or 0) end
    end
    return qty, math.floor(days + 0.5), qty / days * 7
end

-- Materials you use up
--
-- What your crafts and salvages used, by item and day, so Cheap materials
-- can say how much you go through: bought or made yourself (an ingot you
-- smelt because it's cheaper counts too; user, 2026-10-23). In
-- GoldsmithDB.materialUse = { since = time, days = { [day] = { [itemID] =
-- qty } } }, day = time() / 86400, the last USE_KEEP_DAYS. Crafts add what
-- they used after resourcefulness, your share on orders (Pricing.lua);
-- salvage adds what it used up (Milling.lua).
local USE_KEEP_DAYS = 60
local USE_MIN_DAYS = 7
local CRAFT_LOT_LIMIT, ORDER_CRAFT_LIMIT, SALVAGE_RUN_LIMIT = 30, 100, 500

local function UseStore()
    GoldsmithDB.materialUse = GoldsmithDB.materialUse or { since = time(), days = {} }
    return GoldsmithDB.materialUse
end

local function AddUse(store, when, itemID, qty)
    if not itemID or not qty or qty <= 0 then return end
    local day = math.floor(when / 86400)
    store.days[day] = store.days[day] or {}
    store.days[day][itemID] = (store.days[day][itemID] or 0) + qty
end

-- used = { [itemID] = qty }, as a craft lot keeps it
function addon:RecordMaterialUse(used)
    local store = UseStore()
    local now = time()
    for itemID, qty in pairs(used or {}) do AddUse(store, now, itemID, qty) end
    local oldest = math.floor(now / 86400) - USE_KEEP_DAYS
    for day in pairs(store.days) do
        if day < oldest then store.days[day] = nil end
    end
end

-- The first time: filled from the crafts and salvages already saved, back
-- as far as all of them reach. Each item keeps only its last 30 crafts, so
-- one crafted often (Refulgent Copper Ingot: 2 days' worth) sets how far
-- back that is; older ones would leave its materials short.
local function SeedMaterialUse()
    if GoldsmithDB.materialUse then return end
    local now = time()
    local start = now - BUY_DAYS * 86400
    local function Covers(list, limit)
        if #list >= limit and list[1].time then start = math.max(start, list[1].time) end
        for _, lot in ipairs(list) do
            -- Saved before materials were kept
            if not lot.used and lot.time then start = math.max(start, lot.time + 1) end
        end
    end
    for _, lots in pairs(GoldsmithDB.craftLots or {}) do Covers(lots, CRAFT_LOT_LIMIT) end
    Covers(GoldsmithDB.orderCrafts or {}, ORDER_CRAFT_LIMIT)
    local runs = GoldsmithDB.salvageRuns or {}
    if #runs >= SALVAGE_RUN_LIMIT and runs[1].time then start = math.max(start, runs[1].time) end

    local store = { since = start, days = {} }
    local function AddLots(list)
        for _, lot in ipairs(list) do
            if lot.used and (lot.time or 0) >= start then
                for itemID, qty in pairs(lot.used) do AddUse(store, lot.time, itemID, qty) end
            end
        end
    end
    for _, lots in pairs(GoldsmithDB.craftLots or {}) do AddLots(lots) end
    AddLots(GoldsmithDB.orderCrafts or {})
    for _, run in ipairs(runs) do
        if (run.time or 0) >= start then AddUse(store, run.time, run.itemID, run.used) end
    end
    GoldsmithDB.materialUse = store
end

-- How much of a material your crafts and salvages used lately: the amount
-- over the last BUY_DAYS, the days that covers (fewer while the tally is
-- young) and that as a weekly rate, over at least USE_MIN_DAYS: 2 Dawn
-- Crystals used in the tally's first 2 days read 6.5 a week and "Buy 7"
-- (user, 2026-10-23)
function addon:GetRecentUse(itemID)
    local store = UseStore()
    local now = time()
    local from = math.floor((now - BUY_DAYS * 86400) / 86400)
    local qty = 0
    for day, items in pairs(store.days) do
        if day >= from and items[itemID] then qty = qty + items[itemID] end
    end
    local days = math.min(BUY_DAYS, (now - (store.since or now)) / 86400)
    return qty, math.max(math.floor(days + 0.5), 1), qty / math.max(days, USE_MIN_DAYS) * 7
end

-- Whether any use is recorded (a fresh install has none yet)
function addon:UsedAnythingLately()
    local store = GoldsmithDB.materialUse
    return store ~= nil and next(store.days) ~= nil
end

-- "25/wk", "<1/wk" or "-", and its color, for a GetRecentBuys weekly rate
function addon:FormatBuyRate(perWeek)
    if not perWeek or perWeek <= 0 then return "-", "dim" end
    if perWeek < 1 then return "<1/wk", "muted" end
    return addon:FormatDemand(perWeek) .. "/wk", "text"
end

-- Materials with enough history, for the Deals tab, and the earliest date
-- any history was saved (so the tab can say how long until it's ready).
-- prof filters to one profession's materials, or "All". Vendor items and
-- materials the expansion filter hides (IsMaterialShown) are left out (user,
-- 2026-10-06: old pigments and Darkmoon decks filled the list). Kept until
-- data changes (the Overview asks every time it's shown); callers mustn't
-- change the list or its entries.
local dealsCache = addon:NewCache()
local Deals

function addon:GetDeals(prof)
    local store = dealsCache:Get()
    local id = prof .. "|" .. addon:ExpansionFilterKey()
    store[id] = store[id] or { Deals(prof) }
    return store[id][1], store[id][2], store[id][3]
end

Deals = function(prof)
    local list = {}
    local earliest
    -- A list rather than pairs(), so the work can wait for a frame
    local history = GoldsmithDB.priceHistory
    for n, itemID in ipairs(addon:Keys(history)) do
        if n % 8 == 0 then addon:Yield() end
        for day in pairs(history[itemID] or {}) do
            if not earliest or day < earliest then earliest = day end
        end
    end
    local everything = addon:AllExpansionsShown()
    for itemID, name in pairs(addon:GetTrackedMaterials()) do
        addon:Yield()
        local materialProf = GoldsmithDB.reagents[name]
        if (prof == "All" or materialProf == prof) and not addon:IsVendorItem(itemID)
            and (everything or addon:IsMaterialShown(itemID, name)) then
            local insight = addon:GetPriceInsight(itemID)
            if insight then
                insight.itemID = itemID
                insight.name = name
                insight.profession = materialProf
                insight.have = C_Item.GetItemCount(itemID, true, false, true, true) or 0
                table.insert(list, insight)
            end
        end
    end
    table.sort(list, function(a, b) return a.diff < b.diff end)
    return list, earliest, INSIGHT_MIN_DAYS
end

function addon:InitializeStock()
    GoldsmithDB.priceHistory = GoldsmithDB.priceHistory or {}
    GoldsmithDB.priceSeen = GoldsmithDB.priceSeen or {}
    SeedMaterialUse()
    -- After login settles (recipes and tier data are in by then)
    C_Timer.After(20, function() addon:RecordDailyHistory() end)
    -- Anything you've held that today's prices would sell at a profit
    C_Timer.After(30, function() addon:CheckSellNow() end)
end

_G.Goldsmith = addon
