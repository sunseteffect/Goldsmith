local addon = _G.Goldsmith or {}

local INSCRIPTION_ITEMS = {
    [236770] = { name = "Sanguithorn", price = 1 },
    [2447] = { name = "Silverleaf", price = 1 },
    [2449] = { name = "Earthroot", price = 1 },
    [39469] = { name = "Ethereal Pigment", price = 2 },
}

addon.INSCRIPTION_ITEMS = INSCRIPTION_ITEMS

-- Crafted goods you sell. Keyed by exact item name, because AH sale mail
-- only reports the item's name, not its ID.
local INSCRIPTION_PRODUCTS = {
    -- ["Item Name"] = true,
}

addon.INSCRIPTION_PRODUCTS = INSCRIPTION_PRODUCTS

-- Which profession an item belongs to, by name. Nil if it's not tracked.
-- Items added in game live in GoldsmithDB: products from /gsm add (value true
-- means Inscription), and recipe outputs and reagents saved when you craft
-- (value is the profession name).
function addon:GetProfessionForItemName(itemName)
    if INSCRIPTION_PRODUCTS[itemName] then
        return "Inscription"
    end
    if GoldsmithDB then
        for _, list in ipairs({ GoldsmithDB.products, GoldsmithDB.reagents }) do
            local prof = list and list[itemName]
            if prof then
                return prof == true and "Inscription" or prof
            end
        end
    end
    for _, itemData in pairs(INSCRIPTION_ITEMS) do
        if itemData.name == itemName then
            return "Inscription"
        end
    end
    return nil
end

function addon:CreateLedger(store)
    store.entries = store.entries or {}
    store.nextId = store.nextId or 1

    local entries = store.entries
    -- Bumped on every change, so the index below knows when to rebuild
    local version = 0
    local index, indexVersion, indexCount

    return {
        -- kind is "PURCHASE" (default) or "DEPOSIT"
        addCost = function(self, prof, item, qty, totalCopper, kind, itemID)
            version = version + 1
            table.insert(entries, {
                id = store.nextId,
                type = "COST",
                kind = kind or "PURCHASE",
                itemID = itemID,
                profession = prof,
                item = item,
                quantity = qty,
                totalCopper = totalCopper,
                timestamp = time(),
                character = UnitName("player"),
                realm = GetRealmName(),
            })
            store.nextId = store.nextId + 1
        end,

        -- costBasis is what the sold items cost you (at sale time), if known;
        -- costPartial means some of their material costs were unknown
        -- depositRefund is the deposit returned inside this sale's amount
        -- costSource says where costBasis came from (see GetUnitCostBasis)
        addRevenue = function(self, prof, item, qty, totalCopper, costBasis, costPartial, depositRefund, costSource)
            version = version + 1
            table.insert(entries, {
                costBasis = costBasis,
                costPartial = costPartial,
                costSource = costSource,
                depositRefund = depositRefund,
                id = store.nextId,
                type = "REVENUE",
                profession = prof,
                item = item,
                quantity = qty,
                totalCopper = totalCopper,
                timestamp = time(),
                character = UnitName("player"),
                realm = GetRealmName(),
            })
            store.nextId = store.nextId + 1
        end,

        getAll = function(self)
            return entries
        end,

        -- Entries grouped by item, built once per change instead of every
        -- caller reading the whole ledger (with a big ledger, costing every
        -- recipe that way ran long enough for WoW to stop the script):
        --   purchases[name] / purchasesByID[itemID] = { entries }, oldest first
        --   sales[name] = { entries }, oldest first
        -- Rebuilt when the ledger changes (or its length does, if
        -- something changed it directly). Don't change what it returns.
        index = function(self)
            if index and indexVersion == version and indexCount == #entries then return index end
            local idx = { purchases = {}, purchasesByID = {}, sales = {} }
            local function Add(map, key, e)
                local list = map[key]
                if not list then
                    list = {}
                    map[key] = list
                end
                list[#list + 1] = e
            end
            for i, e in ipairs(entries) do
                if i % 64 == 0 then addon:Yield() end
                if e.type == "COST" and (e.kind or "PURCHASE") == "PURCHASE" then
                    if e.item then Add(idx.purchases, e.item, e) end
                    if e.itemID then Add(idx.purchasesByID, e.itemID, e) end
                elseif e.type == "REVENUE" and e.item then
                    Add(idx.sales, e.item, e)
                end
            end
            local function Oldest(a, b) return (a.timestamp or 0) < (b.timestamp or 0) end
            for _, map in ipairs({ idx.purchases, idx.purchasesByID, idx.sales }) do
                for _, list in pairs(map) do table.sort(list, Oldest) end
            end
            index, indexVersion, indexCount = idx, version, #entries
            return index
        end,

        remove = function(self, id)
            for i, e in ipairs(entries) do
                if e.id == id then
                    version = version + 1
                    table.remove(entries, i)
                    return true
                end
            end
            return false
        end,

        clear = function(self)
            version = version + 1
            -- wipe in place so every reference to entries stays valid
            wipe(entries)
        end,

        -- Profit on what you've sold, for one profession or "All".
        --   profit = sales - cost of the items sold - AH deposits
        -- Deposit refunds are part of each sale's amount, so deposits on
        -- items that sold cancel out and only lost deposits reduce profit.
        -- Money spent on materials is reported separately: materials you
        -- still hold aren't a loss until they're sold or wasted.
        -- estimateCost(itemName) fills in cost for sales recorded before
        -- sales kept their cost; sales with no cost data at all are left
        -- out of profit and counted in unknownSales.
        -- since (a time) counts only entries from then on; nil for all time.
        getSummary = function(self, prof, estimateCost, since)
            local s = {
                sales = 0, soldCost = 0, deposits = 0, spent = 0,
                profitSales = 0, unknownSales = 0, estimated = false,
                count = 0,
                -- refunds only known for sales recorded since refunds were saved
                refunds = 0, refundsKnown = true,
            }
            for i, e in ipairs(entries) do
                if i % 4 == 0 then addon:Yield() end
                if (prof == "All" or e.profession == prof) and (not since or e.timestamp >= since) then
                    s.count = s.count + 1
                    if e.type == "REVENUE" then
                        s.sales = s.sales + e.totalCopper
                        if e.depositRefund then
                            s.refunds = s.refunds + e.depositRefund
                        else
                            s.refundsKnown = false
                        end
                        local cost = e.costBasis
                        if not cost and estimateCost then
                            local unit = estimateCost(e.item)
                            if unit then
                                cost = unit * e.quantity
                                s.estimated = true
                            end
                        end
                        if cost then
                            s.soldCost = s.soldCost + cost
                            s.profitSales = s.profitSales + e.totalCopper
                        else
                            s.unknownSales = s.unknownSales + 1
                        end
                    elseif e.kind == "DEPOSIT" then
                        s.deposits = s.deposits + e.totalCopper
                    else
                        s.spent = s.spent + e.totalCopper
                    end
                end
            end
            s.profit = s.profitSales - s.soldCost - s.deposits
            s.margin = s.soldCost > 0 and (s.profit / s.soldCost * 100) or nil
            return s
        end,

        -- Profit and sales for each of the last `days` days (oldest first),
        -- worked out the same way as getSummary: a sale counts on the day
        -- it arrived, a deposit on the day it was paid.
        -- Returns { { day = "YYYY-MM-DD", profit, sales } }.
        getDailyProfit = function(self, prof, estimateCost, days)
            local list, byDay = {}, {}
            for i = days - 1, 0, -1 do
                local day = date("%Y-%m-%d", time() - i * 86400)
                local d = { day = day, profit = 0, sales = 0 }
                table.insert(list, d)
                byDay[day] = d
            end
            for i, e in ipairs(entries) do
                if i % 4 == 0 then addon:Yield() end
                local d = byDay[date("%Y-%m-%d", e.timestamp)]
                if d and (prof == "All" or e.profession == prof) then
                    if e.type == "REVENUE" then
                        d.sales = d.sales + e.totalCopper
                        local cost = e.costBasis
                        if not cost and estimateCost then
                            local unit = estimateCost(e.item)
                            cost = unit and unit * e.quantity
                        end
                        if cost then
                            d.profit = d.profit + e.totalCopper - cost
                        end
                    elseif e.kind == "DEPOSIT" then
                        d.profit = d.profit - e.totalCopper
                    end
                end
            end
            return list
        end,
    }
end

-- Date ranges for the date filter. Ranges start at midnight, so "Last 7
-- days" is today and the 6 days before it.
addon.DATE_RANGES = {
    { key = "today", label = "Today", days = 1 },
    { key = "7d", label = "Last 7 days", days = 7 },
    { key = "30d", label = "Last 30 days", days = 30 },
    { key = "all", label = "All time" },
}

function addon:GetDateRange(key)
    for _, r in ipairs(addon.DATE_RANGES) do
        if r.key == key then return r end
    end
    return addon.DATE_RANGES[2]
end

-- When a date range starts (a time), or nil for all time
function addon:DateRangeStart(key)
    local range = addon:GetDateRange(key)
    if not range.days then return nil end
    local t = date("*t", time() - (range.days - 1) * 86400)
    return time({ year = t.year, month = t.month, day = t.day, hour = 0 })
end

-- Sales recorded before sales kept their cost get today's cost estimate,
-- worked out once per item until data changes (summaries ask once per
-- sale). false = no estimate.
local estimateCache
local function EstimateSaleCost(itemName)
    if not itemName then return nil end
    estimateCache = estimateCache or addon:NewCache()
    local store = estimateCache:Get()
    local cost = store[itemName]
    if cost == nil then
        cost = addon:GetUnitCostBasis(itemName) or false
        store[itemName] = cost
    end
    return cost or nil
end

-- For other files that estimate old sales' cost (SalesByItem)
function addon:EstimateSaleCost(itemName)
    return EstimateSaleCost(itemName)
end

-- Both read the whole ledger, and the Overview asks again every time it's
-- shown, so results are kept until data changes (caches are made on first
-- use: Settings.lua, which has NewCache, loads after this file). Callers
-- may add fields to what's returned (GetGoldPerHour) but not change the
-- ledger's numbers in it.
local summaryCache, dailyCache

-- Profit summary for a profession ("All" for every one) and date range key
function addon:GetSummary(prof, rangeKey)
    summaryCache = summaryCache or addon:NewCache()
    local store = summaryCache:Get()
    local id = prof .. "|" .. tostring(rangeKey)
    store[id] = store[id] or addon.ledger:getSummary(prof, EstimateSaleCost, addon:DateRangeStart(rangeKey))
    return store[id]
end

function addon:GetDailyProfit(prof, days)
    dailyCache = dailyCache or addon:NewCache()
    local store = dailyCache:Get()
    local id = prof .. "|" .. days
    store[id] = store[id] or addon.ledger:getDailyProfit(prof, EstimateSaleCost, days)
    return store[id]
end

-- Profit per hour of goldmaking for each of the last `days` days (oldest
-- first): { { day, profit, seconds, perHour } }. perHour is nil on days
-- without goldmaking time.
function addon:GetGoldPerHour(prof, days)
    local list = addon:GetDailyProfit(prof, days)
    for _, d in ipairs(list) do
        d.seconds = addon:GetGoldmakingSeconds(d.day)
        d.perHour = d.seconds > 0 and (d.profit / d.seconds * 3600) or nil
    end
    return list
end

_G.Goldsmith = addon