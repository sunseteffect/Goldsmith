local addon = _G.Goldsmith or {}

local function Print(msg, ...)
    print("|cFF00FF00[Goldsmith]|r " .. string.format(msg, ...))
end

local function FormatGold(copper)
    return string.format("%.2fg", copper / 10000)
end

-- Bumped whenever a recipe is saved or removed, for indexes of recipes
-- (FindRecipeByOutput, GetRecipesUsing)
addon.recipesVersion = 0

-- Average cost

-- What the ones you hold cost you, from recorded AH purchases: the newest
-- purchases, going back until they cover what you have on every character
-- (or just the newest one when you hold none, e.g. right after using them
-- up in a craft). Prices you paid long ago stop counting once those items
-- are gone, so the cost follows the market. The same rule as crafted items
-- (GetCraftedCost). Materials you gathered take their place in that line
-- (Gathered.lua), so they aren't costed at what you paid for others.
-- Returns copper per unit and units covered, or nil if never bought (or
-- what you hold was all gathered since).
function addon:GetAverageCost(itemName)
    local paid, covered = addon:GetAcquiredCost(itemName)
    if paid then return paid, covered end
end

-- Market prices (Auctionator, optional)

local AH_CUT = 0.05

-- AH prices come from Auctionator or TSM, whichever is more recent.
--
-- TSM doesn't tell other addons when its data was downloaded, but it only
-- loads new data at login or /reload. So an Auctionator scan made since this
-- session started is always newer than TSM's data. Without one, TSM's data
-- (refreshed by its app, typically hourly) is usually newer than an older
-- Auctionator scan, so TSM is used, falling back to Auctionator.
local sessionStart = time()

-- Auctionator's price for an item, regardless of TSM
function addon:GetAuctionatorPrice(itemID)
    if not itemID then return nil end
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not (api and api.GetAuctionPriceByItemID) then return nil end
    local ok, price = pcall(api.GetAuctionPriceByItemID, "Goldsmith", itemID)
    if ok and price and price > 0 then
        return price
    end
end

-- True if Auctionator has updated its prices since this login/reload,
-- i.e. its prices are newer than TSM's
function addon:ScannedThisSession()
    return GoldsmithDB.lastPriceUpdate ~= nil and GoldsmithDB.lastPriceUpdate >= sessionStart
end

local function GetAuctionatorAge(itemID)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not (api and api.GetAuctionAgeByItemID) then return nil end
    local ok, age = pcall(api.GetAuctionAgeByItemID, "Goldsmith", itemID)
    if ok and type(age) == "number" then
        return age
    end
end

local function GetTSMValue(source, itemID)
    if not (TSM_API and TSM_API.GetCustomPriceValue) then return nil end
    local ok, price = pcall(TSM_API.GetCustomPriceValue, source, "i:" .. itemID)
    if ok and price and price > 0 then
        return price
    end
end

-- Live order books
--
-- When an AH search shows a commodity's listings (e.g. clicking an item in
-- Auctionator's shopping list), every price level and its quantity are
-- recorded. For ORDER_BOOK_FRESH seconds that item is priced from this real
-- depth, which is more accurate than any scan's single lowest price:
--   - tiny undercuts are ignored: the price used is where at least
--     THIN_MIN_UNITS units (or THIN_SHARE of everything listed) are
--     available at or below it, so 10 units listed cheap don't count
--   - buying N units (planner) costs what walking the listings costs
-- Kept in GoldsmithDB.orderBooks[itemID] = { time, total, levels = {{price, qty}} }
local ORDER_BOOK_FRESH = 30 * 60
local ORDER_BOOK_KEEP = 24 * 60 * 60
local ORDER_BOOK_LEVELS = 100
local THIN_MIN_UNITS = 20
local THIN_SHARE = 0.002

local function RecordOrderBook(itemID)
    local count = C_AuctionHouse.GetNumCommoditySearchResults(itemID)
    if not count or count == 0 then return end
    local levels, total = {}, 0
    for i = 1, count do
        local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if info and info.unitPrice and info.quantity then
            total = total + info.quantity
            local last = levels[#levels]
            if last and last.price == info.unitPrice then
                last.qty = last.qty + info.quantity
            elseif #levels < ORDER_BOOK_LEVELS then
                table.insert(levels, { price = info.unitPrice, qty = info.quantity })
            end
        end
    end
    if #levels > 0 then
        GoldsmithDB.orderBooks[itemID] = { time = time(), total = total, levels = levels }
    end
end

-- AH search results (the list a search shows, before clicking an item):
-- each item's lowest price, so searching updates prices without
-- Auctionator (user, 2026-10-09: Goldsmith Data was 1,250g, the AH 866g).
-- Kept as GoldsmithDB.searchPrices[itemID] = { time, price, quantity }
-- and used for ORDER_BOOK_FRESH like an order book. Materials only from
-- SEARCH_MIN_PRICE on: for cheap bulk materials one cheap listing is often
-- a one-unit undercut, and clicking in gives the depth. Crafted items at
-- any price (a 5g ring scroll was left out at first).
local SEARCH_MIN_PRICE = 25 * 10000 -- 25g

local function RecordSearchResults(results)
    GoldsmithDB.searchPrices = GoldsmithDB.searchPrices or {}
    local now, recorded = time(), false
    for _, r in ipairs(results or {}) do
        local key = r.itemKey
        local itemID = key and key.itemID
        if itemID and (key.battlePetSpeciesID or 0) == 0 and type(r.minPrice) == "number" and r.minPrice > 0 then
            GoldsmithDB.searchPrices[itemID] = { time = now, price = r.minPrice, quantity = r.totalQuantity }
            recorded = true
        end
    end
    return recorded
end

function addon:GetSearchPrice(itemID)
    local s = GoldsmithDB.searchPrices and GoldsmithDB.searchPrices[itemID]
    if not (s and time() - s.time <= ORDER_BOOK_FRESH) then return nil end
    local name = C_Item.GetItemNameByID(itemID)
    local material = name and GoldsmithDB.reagents[name] and not addon:FindRecipeByOutput(name)
    if s.price >= SEARCH_MIN_PRICE or not material then
        return s.price
    end
end

local function GetFreshOrderBook(itemID)
    local book = GoldsmithDB.orderBooks and GoldsmithDB.orderBooks[itemID]
    if book and time() - book.time <= ORDER_BOOK_FRESH then
        return book
    end
end

-- Lowest price with meaningful quantity behind it: THIN_MIN_UNITS units
-- (or THIN_SHARE of the total), but no more than THIN_SMALL_SHARE of a
-- small market, and enough once THIN_MIN_VALUE of gold is listed at or
-- below the price. A scroll with 64 listed was priced at the 20th cheapest
-- (about 3,000g) when one sold for 950g (2026-10-08): for pricey items one
-- listing is the real price, not an undercut.
local THIN_SMALL_SHARE = 0.1
local THIN_MIN_VALUE = 500 * 10000 -- 500g
local function GetRobustBookPrice(book)
    local threshold = math.max(THIN_MIN_UNITS, book.total * THIN_SHARE)
    threshold = math.max(math.min(threshold, math.ceil(book.total * THIN_SMALL_SHARE)), 1)
    local cumulative, value = 0, 0
    for _, level in ipairs(book.levels) do
        cumulative = cumulative + level.qty
        value = value + level.qty * level.price
        if cumulative >= threshold or value >= THIN_MIN_VALUE then
            return level.price
        end
    end
    return book.levels[#book.levels].price
end

-- Average price per unit to buy `quantity` from the live listings, whether
-- enough were listed, and the book's time; nil without a fresh order book.
function addon:GetLiveBuyCost(itemID, quantity)
    local book = GetFreshOrderBook(itemID)
    if not book or quantity <= 0 then return nil end
    local remaining, cost = quantity, 0
    for _, level in ipairs(book.levels) do
        local take = math.min(remaining, level.qty)
        cost = cost + take * level.price
        remaining = remaining - take
        if remaining <= 0 then break end
    end
    local bought = quantity - remaining
    if bought <= 0 then return nil end
    return cost / bought, remaining <= 0, book.time
end

-- Undercut check for scan prices: a lowest price below UNDERCUT_RATIO of
-- TSM's market value is treated as a small undercut rather than the real
-- price, and the market value is used instead.
local UNDERCUT_RATIO = 0.6

-- Blizzard AH data
--
-- From the Goldsmith Data addon (its own repo, GoldsmithData): a workflow
-- fetches the Blizzard API hourly and releases it daily, one file per
-- region, and only your region's file builds the table. Region-wide
-- commodities only, so no gear. It loads at login or /reload. Used when neither
-- Auctionator nor TSM has a price for the item, or when Auctionator's price
-- is a day or more old and this data is newer (not with TSM installed).
--   GoldsmithPriceData.items[itemID] = { min, market, median, quantity, sells }
-- (copper; market = average of the cheapest 15% of units listed; sells =
-- the sell level, see GetSellLevel)
-- How well an item sells across the region, from Goldsmith Data's last week
-- of hourly listings: 3 sells, 2 slow, 1 hardly sells, or nil (no data, or
-- not a week of it yet). Used for recommendations when TSM isn't installed.
addon.SELL_LEVEL = { hardly = 1, slow = 2, sells = 3 }
local SELL_LEVEL_TEXT = { "Hardly sells", "Slow", "Sells" }

function addon:GetSellLevel(itemID)
    local data = GoldsmithPriceData
    local entry = itemID and data and data.items and data.items[itemID]
    return entry and entry[5]
end

function addon:SellLevelText(level)
    return level and SELL_LEVEL_TEXT[level]
end

function addon:SellLevelColor(level)
    if not level then return "dim" end
    return level == addon.SELL_LEVEL.sells and "text" or "warning"
end

function addon:GetBlizzardDataTime()
    return GoldsmithPriceData and GoldsmithPriceData.updated
end

-- True if Blizzard AH data is under a day old and the last Auctionator scan
-- was before it and on an earlier day (an older scan loses to fresh data)
function addon:BlizzardDataBeatsScan()
    local updated = addon:GetBlizzardDataTime()
    local scan = GoldsmithDB.lastPriceUpdate
    if not updated or time() - updated >= 86400 then return false end
    return not scan or (scan < updated and date("%Y-%m-%d", scan) ~= date("%Y-%m-%d"))
end

-- Lowest price, or the market price when the lowest looks like a small
-- undercut (same rule as the TSM check). Not when market is more than
-- MARKET_TRUST_RATIO times the lowest: then market is the unreliable one, a
-- thin market whose cheapest 15% is mostly silly listings (99 gold-tier
-- Gleeful Glamours: lowest 3.62g, market 6,668g). Returns price, age in
-- days, note.
local MARKET_TRUST_RATIO = 3

-- An item that doesn't sell well (Slow or Hardly sells) priced more than
-- SOLD_HIGH_RATIO times what it sold for this week is a shelf price: the
-- cheap ones sold and what's left sits (silver Orc Gleeful Glamour: lowest
-- 35.65g, sold for 0.60g). Same idea as TSM's sale average check. Not for
-- a deep market (SOLD_DEEP_QTY or more listed): a wall of listings at the
-- lowest price is what you'd list at, not a shelf price (silver Thalassian
-- Haste scroll: 16,515 at 5.03g, "sold for" 0.95g, priced 0.95g, user
-- 2026-10-09); the sale price is only noted. Returns the sale price and a
-- note, nil and a note, or nil when the price is fine.
local SOLD_HIGH_RATIO = 3
local SOLD_DEEP_QTY = 100

local function SoldCap(itemID, price)
    local data = GoldsmithPriceData
    local entry = data and data.items and data.items[itemID]
    local level, sold, quantity = entry and entry[5], entry and entry[6], entry and entry[4]
    if level and level < addon.SELL_LEVEL.sells and sold and price > sold * SOLD_HIGH_RATIO then
        if quantity and quantity >= SOLD_DEEP_QTY then
            return nil, string.format("it sold for %s this week", FormatGold(sold))
        end
        return sold, string.format("listed at %s, but it sold for %s this week", FormatGold(price), FormatGold(sold))
    end
end

local function GetBlizzardPrice(itemID)
    local data = GoldsmithPriceData
    local entry = data and data.items and data.items[itemID]
    if not entry then return nil end
    local price, market, note = entry[1], entry[2], nil
    -- Not when this week's sales are well under the market price: then the
    -- low listing is the real price (silver Arcane Mastery scroll: lowest
    -- 950g, market 2,322g, sold for 364g; it was priced at 2,322g)
    local sold = entry[6]
    local salesBackMarket = not sold or (market and sold >= market * UNDERCUT_RATIO)
    if market and price < market * UNDERCUT_RATIO and market <= price * MARKET_TRUST_RATIO and salesBackMarket then
        note = string.format("lowest listing %s looked like a small undercut", FormatGold(price))
        price = market
    end
    local sold, soldNote = SoldCap(itemID, price)
    if sold then price, note = sold, soldNote elseif soldNote then note = note or soldNote end
    local age = math.max(0, math.floor((time() - (data.updated or time())) / 86400))
    return price, age, note
end

-- "Goldsmith Data, 17:15" (today) or "Goldsmith Data, 2 days old"
local function BlizzardAgeText()
    local updated = addon:GetBlizzardDataTime()
    local when
    if updated and date("%Y-%m-%d", updated) == date("%Y-%m-%d") then
        when = date("%H:%M", updated)
    else
        when = addon:FormatAge(updated and math.max(1, math.floor((time() - updated) / 86400)))
    end
    return "Goldsmith Data, " .. when
end

-- Vendor prices
--
-- The game only shows what a vendor charges while you're at the vendor, so
-- every vendor you open is recorded: price per unit for each item bought
-- with gold (items costing currencies or tokens are skipped). Kept in
-- GoldsmithDB.vendorPrices[itemID]. Includes any reputation discount you had.
local function RecordVendorPrices()
    local count = GetMerchantNumItems and GetMerchantNumItems() or 0
    for i = 1, count do
        local itemID = GetMerchantItemID(i)
        local price, stackCount, hasExtendedCost
        if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
            local info = C_MerchantFrame.GetItemInfo(i)
            if info then
                price, stackCount, hasExtendedCost = info.price, info.stackCount, info.hasExtendedCost
            end
        elseif GetMerchantItemInfo then
            local _
            _, _, price, stackCount, _, _, _, hasExtendedCost = GetMerchantItemInfo(i)
        end
        if itemID and price and price > 0 and not hasExtendedCost then
            GoldsmithDB.vendorPrices[itemID] = price / math.max(stackCount or 1, 1)
        end
    end
end

function addon:GetVendorPrice(itemID)
    return itemID and GoldsmithDB.vendorPrices and GoldsmithDB.vendorPrices[itemID]
end

-- Sold by a vendor: you've opened a vendor selling it, or it's in TSM's
-- list of vendor items. Its AH price swings don't matter, so it stays out
-- of Cheap materials.
function addon:IsVendorItem(itemID)
    return addon:GetVendorPrice(itemID) ~= nil or GetTSMValue("vendorbuy", itemID) ~= nil
end

-- AH price only (no vendor cap). Returns price per unit, source, the
-- price's age in days (Auctionator only), and a note when the price was
-- adjusted. Sources:
--   "Live"         - a fresh order book from an AH search
--   "Search"       - the lowest price in fresh AH search results
--   "Auctionator"  - Auctionator's last scan
--   "TSM"          - TSM's minimum buyout
--   "TSM market"   - TSM's market value, used because the lowest price
--                    looked like a small undercut or far too high
--   "TSM sale avg" - TSM's region sale average, used because the price
--                    was far above what the item actually sells for
--   "Blizzard"     - Blizzard AH data, when neither addon has a price or
--                    Auctionator's is older
-- nil if nothing has a price.
function addon:GetAHPriceInfo(itemID)
    if not itemID then return nil end

    -- The price source setting: "auto" (above), "auctionator" (its last
    -- scan, however old, TSM only without one) or "tsm" (TSM, Auctionator
    -- only without it; live searches ignored)
    local preferred = addon:Setting("priceSource")

    local book = preferred ~= "tsm" and GetFreshOrderBook(itemID)
    if book then
        return GetRobustBookPrice(book), "Live", nil
    end
    local searched = preferred ~= "tsm" and addon:GetSearchPrice(itemID)
    if searched then
        return searched, "Search", nil
    end

    local auctionator = addon:GetAuctionatorPrice(itemID)
    local age = auctionator and GetAuctionatorAge(itemID)
    local price, source
    local useAuctionator = auctionator and (preferred == "auctionator"
        or (preferred ~= "tsm" and age == 0 and addon:ScannedThisSession()))
    if useAuctionator then
        price, source = auctionator, "Auctionator"
    else
        local tsm = GetTSMValue("DBMinBuyout", itemID)
        if tsm then
            price, source, age = tsm, "TSM", nil
        elseif auctionator and (preferred == "auctionator" or (age or 0) < 1
                or not addon:BlizzardDataBeatsScan() or not GetBlizzardPrice(itemID)) then
            price, source = auctionator, "Auctionator"
        else
            -- No price from either addon, or Auctionator's is a day or more
            -- old and the Blizzard data is fresher
            local blizzard, blizzardAge, note = GetBlizzardPrice(itemID)
            if blizzard then
                return blizzard, "Blizzard", blizzardAge, note
            end
        end
    end
    if not price then return nil end

    return addon:CheckAgainstMarket(itemID, price, source, age)
end

-- Outlier check against TSM's market value: a lowest price far below it
-- looks like a small undercut; far above it (e.g. a 9,999,999g listing when
-- nothing else is up) isn't a real price either. Either way TSM's market
-- value is used instead, with a note. Without TSM, Goldsmith Data's market
-- value is the check for far too high prices (an old Auctionator scan of a
-- lone 6,000g listing for a 1g item), and its price is used instead.
--
-- Market value comes from listings, so for items that rarely sell it's as
-- unrealistic as the listings themselves (an item-level-15 staff listed at
-- 81,484g). TSM's region sale average is what it actually sold for, so a
-- price more than SALE_HIGH_RATIO times that is capped at it.
local OUTLIER_HIGH_RATIO = 5
local SALE_HIGH_RATIO = 3

function addon:CheckAgainstMarket(itemID, price, source, age)
    local listed, note = price, nil
    local market = GetTSMValue("DBMarket", itemID)
    if not market then
        local blizzard, blizzardAge
        if source ~= "Blizzard" then blizzard, blizzardAge = GetBlizzardPrice(itemID) end
        if blizzard and price > blizzard * OUTLIER_HIGH_RATIO then
            return blizzard, "Blizzard", blizzardAge,
                string.format("lowest listing %s is far above the usual price", FormatGold(listed))
        end
        local sold, soldNote = SoldCap(itemID, price)
        if sold then
            return sold, "Blizzard", blizzardAge, soldNote
        end
        return price, source, age, note or soldNote
    end
    if price < market * UNDERCUT_RATIO then
        price, source, age = market, "TSM market", nil
        note = string.format("lowest listing %s looked like a small undercut", FormatGold(listed))
    elseif market and price > market * OUTLIER_HIGH_RATIO then
        price, source, age = market, "TSM market", nil
        note = string.format("lowest listing %s is far above the usual price", FormatGold(listed))
    end
    local saleAvg = GetTSMValue("DBRegionSaleAvg", itemID)
    if saleAvg and price > saleAvg * SALE_HIGH_RATIO then
        return saleAvg, "TSM sale avg", nil,
            string.format("listed at %s, but it usually sells for %s", FormatGold(listed), FormatGold(saleAvg))
    end
    return price, source, age, note
end

function addon:GetAHPrice(itemID)
    return (addon:GetAHPriceInfo(itemID))
end

-- What an item costs to get: the AH price, unless a vendor sells it for
-- less (or it isn't on the AH), in which case the vendor price with source
-- "Vendor". Same returns as GetAHPriceInfo.
function addon:GetMarketPriceInfo(itemID)
    if not itemID then return nil end
    local price, source, age, note = addon:GetAHPriceInfo(itemID)
    local vendor = addon:GetVendorPrice(itemID)
    if vendor and (not price or vendor <= price) then
        return vendor, "Vendor", nil
    end
    return price, source, age, note
end

function addon:GetMarketPrice(itemID)
    return (addon:GetMarketPriceInfo(itemID))
end

-- Auctionator's own age for an item's price, regardless of which source is
-- in use (price history only records prices Auctionator saw today)
function addon:GetAuctionatorAge(itemID)
    return GetAuctionatorAge(itemID)
end

function addon:HasAuctionator()
    return Auctionator and Auctionator.API and Auctionator.API.v1 and true or false
end

-- Days since the item's price was seen (0 = today), when the price in use
-- is Auctionator's. nil when the price is TSM's (it doesn't share its age).
function addon:GetMarketAge(itemID)
    local _, source, age = addon:GetMarketPriceInfo(itemID)
    if source == "Auctionator" then
        return age
    end
end

-- Where a price came from, and how old, from GetAHPriceInfo's source and
-- age: "Goldsmith Data, 09:15", "Auctionator, 2 days old", "TSM",
-- "TSM market value", "live, 5m ago". Short, for tooltips.
function addon:PriceSourceText(itemID, source, age)
    if source == "Live" then
        local book = itemID and GoldsmithDB.orderBooks[itemID]
        return book and string.format("live, %dm ago", math.floor((time() - book.time) / 60)) or "live"
    end
    if source == "Search" then
        local s = itemID and GoldsmithDB.searchPrices and GoldsmithDB.searchPrices[itemID]
        return s and string.format("AH search, %dm ago", math.floor((time() - s.time) / 60)) or "AH search"
    end
    if source == "TSM" then return "TSM" end
    if source == "TSM market" then return "TSM market value" end
    if source == "TSM sale avg" then return "TSM sale average" end
    if source == "Blizzard" then return BlizzardAgeText() end
    if source == "Vendor" then return "vendor" end
    if source == "Auctionator" then
        return age and ("Auctionator, " .. addon:FormatAge(age, itemID):gsub("^from ", "")) or "Auctionator"
    end
    return source or "no price"
end

-- Where the price in use came from, and how old (see PriceSourceText)
function addon:PriceAgeText(itemID)
    local price, source, age = addon:GetMarketPriceInfo(itemID)
    if not price then return "no price" end
    return addon:PriceSourceText(itemID, source, age)
end

-- Same as PriceAgeText, for the AH price only (ignoring vendor prices)
function addon:AHPriceAgeText(itemID)
    local price, source, age = addon:GetAHPriceInfo(itemID)
    if not price then return "no price" end
    return addon:PriceSourceText(itemID, source, age)
end

-- When an item's Auctionator price was seen today ("14:32"), from
-- GoldsmithDB.priceSeen (see RecordPriceHistory), else nil. Auctionator
-- only reports ages in whole days.
function addon:GetPriceSeenTime(itemID)
    local entry = itemID and GoldsmithDB.priceSeen and GoldsmithDB.priceSeen[itemID]
    if entry and date("%Y-%m-%d", entry[1]) == date("%Y-%m-%d") then
        return date("%H:%M", entry[1])
    end
end

-- "from 14:32" (seen today, with itemID), "from today", "2 days old"
function addon:FormatAge(days, itemID)
    if not days then return "age unknown" end
    if days == 0 then
        local seenTime = addon:GetPriceSeenTime(itemID)
        return seenTime and ("from " .. seenTime) or "from today"
    end
    if days == 1 then return "1 day old" end
    return days .. " days old"
end

-- Demand
--
-- Units sold per day. From TSM's region data when TSM is installed (built
-- from many players' scans; commodity markets are region-wide), otherwise
-- from your own sales over the last OWN_SALES_DAYS days.
local OWN_SALES_DAYS = 14

local function GetTSMSoldPerDay(itemID)
    if not (TSM_API and TSM_API.GetCustomPriceValue) then return nil end
    -- TSM returns whole numbers, so scale up to keep fractions like 0.4/day
    local ok, value = pcall(TSM_API.GetCustomPriceValue, "dbregionsoldperday*1000", "i:" .. itemID)
    if ok and value then
        return value / 1000
    end
end

local function GetOwnSoldPerDay(itemName)
    local since = time() - OWN_SALES_DAYS * 86400
    local units = 0
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.type == "REVENUE" and e.item == itemName and e.timestamp >= since then
            units = units + e.quantity
        end
    end
    if units == 0 then return nil end
    return units / OWN_SALES_DAYS
end

-- Units of an item you sold per day over the last OWN_SALES_DAYS days, or
-- nil if none
function addon:GetOwnDemand(itemName)
    return itemName and GetOwnSoldPerDay(itemName)
end

-- What you got per unit (after the AH cut) for your sales of an item over
-- the last OWN_SALES_DAYS days, or nil if none
function addon:GetOwnSalePrice(itemName)
    if not itemName then return nil end
    local since = time() - OWN_SALES_DAYS * 86400
    local units, copper = 0, 0
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.type == "REVENUE" and e.item == itemName and e.timestamp >= since then
            units = units + e.quantity
            copper = copper + e.totalCopper
        end
    end
    if units == 0 then return nil end
    return copper / units
end

-- Weapons, armor and profession equipment. They aren't commodities: each
-- realm has its own listings, so region sales are spread over every realm.
function addon:IsGear(itemID)
    local classID = itemID and select(6, C_Item.GetItemInfoInstant(itemID))
    return classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor
        or classID == Enum.ItemClass.Profession
end

function addon:HasTSM()
    return TSM_API and TSM_API.GetCustomPriceValue and true or false
end

-- Returns units sold per day and where it came from ("TSM region" or
-- "your sales"), or nil if there's no data.
function addon:GetDemand(itemID, itemName)
    local tsm = itemID and GetTSMSoldPerDay(itemID)
    if tsm then
        return tsm, "TSM region"
    end
    local own = itemName and GetOwnSoldPerDay(itemName)
    if own then
        return own, "your sales"
    end
end

function addon:FormatDemand(perDay)
    if not perDay then return "-" end
    if perDay >= 10000 then return string.format("%.0fk", perDay / 1000) end
    if perDay >= 1000 then return string.format("%.1fk", perDay / 1000) end
    if perDay >= 10 then return string.format("%.0f", perDay) end
    return string.format("%.1f", perDay)
end

-- Share of an item's auctions that sell (0 to 1), from TSM's region data,
-- or nil without TSM or data. A low rate means most listings expire.
function addon:GetSaleRate(itemID)
    if not (itemID and TSM_API and TSM_API.GetCustomPriceValue) then return nil end
    -- TSM returns whole numbers, so scale up to keep the decimals
    local ok, value = pcall(TSM_API.GetCustomPriceValue, "dbregionsalerate*1000", "i:" .. itemID)
    if ok and value then
        return value / 1000
    end
end

-- As a percent: 25%, or <1% for rates that round to nothing
function addon:FormatSaleRate(rate)
    if not rate then return "-" end
    if rate > 0 and rate < 0.005 then return "<1%" end
    return string.format("%.0f%%", rate * 100)
end

-- List columns marked tsm = true only ever have data from TSM (sale rate),
-- so without TSM they're left out rather than shown empty
function addon:AvailableColumns(columns)
    if addon:HasTSM() then return columns end
    local list = {}
    for _, col in ipairs(columns) do
        if not col.tsm then table.insert(list, col) end
    end
    return list
end

-- Items the game hasn't loaded yet
--
-- The game only knows an item's details (expansion, bind type) once
-- something asks for them. Until then Goldsmith can't tell whether a craft
-- is worth recommending, so it asks the game to load the item, and
-- refreshes (emptying the caches) when items arrive. Recipe outputs are
-- asked for at login, so recommendations are right from the start.
local waitingItems = {}
local itemRefreshPending = false

local function RequestItem(itemID)
    if waitingItems[itemID] then return end
    waitingItems[itemID] = true
    C_Item.RequestLoadItemDataByID(itemID)
end

local itemEvents = CreateFrame("Frame")
itemEvents:RegisterEvent("GET_ITEM_INFO_RECEIVED")
itemEvents:RegisterEvent("PLAYER_ENTERING_WORLD")
itemEvents:SetScript("OnEvent", function(self, event, itemID)
    if event == "PLAYER_ENTERING_WORLD" then
        self:UnregisterEvent("PLAYER_ENTERING_WORLD")
        C_Timer.After(2, function()
            for _, recipe in pairs(GoldsmithDB.recipes or {}) do
                local id = recipe.outputItemID
                if id and not C_Item.GetItemInfo(id) then RequestItem(id) end
            end
            for _, c in pairs(GoldsmithDB.characters or {}) do
                for _, td in pairs(c.tierData or {}) do
                    for _, out in pairs(td.outputs or {}) do
                        if out.itemID and not C_Item.GetItemInfo(out.itemID) then RequestItem(out.itemID) end
                    end
                end
            end
        end)
        return
    end
    if not (itemID and waitingItems[itemID]) then return end
    waitingItems[itemID] = nil
    -- Items arrive in bursts; refresh once for the lot
    if not itemRefreshPending then
        itemRefreshPending = true
        C_Timer.After(1, function()
            itemRefreshPending = false
            if addon.Refresh then addon.Refresh() end
        end)
    end
end)

-- Expansions

-- An item's expansion and bind type never change, but the game can drop an
-- item's details again soon after loading them, so asking it each time
-- made recommendations flicker. They're remembered once seen, in
-- GoldsmithDB.itemFacts[itemID] = { expansion, bind }.
local function ItemFacts(itemID)
    -- Some rows have no item (a recipe without one); anything but a number
    -- makes the game raise an error instead of returning nothing
    if type(itemID) ~= "number" then return nil end
    GoldsmithDB.itemFacts = GoldsmithDB.itemFacts or {}
    local facts = GoldsmithDB.itemFacts[itemID]
    if facts then return facts end
    local bind = select(14, C_Item.GetItemInfo(itemID))
    local expansion = select(15, C_Item.GetItemInfo(itemID))
    if bind == nil or expansion == nil then
        RequestItem(itemID)
        return nil
    end
    facts = { expansion = expansion, bind = bind }
    GoldsmithDB.itemFacts[itemID] = facts
    return facts
end

-- Expansion an item comes from (0 = Classic), or nil if not loaded yet
-- (it's asked for, and everything refreshes when it arrives)
function addon:GetItemExpansion(itemID)
    local facts = ItemFacts(itemID)
    return facts and facts.expansion
end

function addon:GetExpansionName(expansionID)
    return _G["EXPANSION_NAME" .. expansionID] or ("Expansion " .. expansionID)
end

function addon:GetCurrentExpansion()
    return (GetServerExpansionLevel and GetServerExpansionLevel()) or GetExpansionLevel()
end

-- The expansion a recipe comes from, from its skill line ("Classic
-- Inscription", "Midnight Inscription"), saved as recipe.skillLine while
-- the profession window is open. The item a recipe makes isn't reliable:
-- Enchanting Vellum is made by a Classic recipe but is a Midnight item
-- (Midnight enchants go on it). Before the skill line is known, the item's
-- expansion is used. Older skill lines are named by region, not expansion.
local SKILL_LINE_EXPANSIONS = {
    { "Classic", 0 }, { "Outland", 1 }, { "Northrend", 2 }, { "Cataclysm", 3 },
    { "Pandaria", 4 }, { "Draenor", 5 }, { "Legion", 6 }, { "Kul Tiran", 7 },
    { "Zandalari", 7 }, { "Shadowlands", 8 }, { "Dragon Isles", 9 }, { "Khaz Algar", 10 },
}

function addon:RecordRecipeSkillLine(recipeID)
    local recipe = GoldsmithDB.recipes[recipeID]
    if not recipe or recipe.skillLine or not C_TradeSkillUI.GetTradeSkillLineForRecipe then return end
    -- Returns skillLineID, skillLineName, parentSkillLineID, parentSkillLineName
    local ok, _, name = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeID)
    if ok and type(name) == "string" and name ~= "" then
        recipe.skillLine = name
    end
end

function addon:GetRecipeExpansion(recipe)
    local line = recipe.skillLine
    if line then
        for _, e in ipairs(SKILL_LINE_EXPANSIONS) do
            if line:find(e[1], 1, true) == 1 then return e[2] end
        end
        -- Newer skill lines start with the expansion's name ("Midnight")
        for id = addon:GetCurrentExpansion(), 0, -1 do
            local name = _G["EXPANSION_NAME" .. id]
            if name and line:find(name, 1, true) == 1 then return id end
        end
    end
    return addon:GetItemExpansion(recipe.outputItemID)
end

-- Expansion filter: the header's "Show items from", followed by every tab
-- that lists items (user, 2026-10-06: the current expansion is always the
-- most profitable). GoldsmithDB.ui2.expansions is a set of expansion IDs to
-- show; until it's changed, only the current expansion is shown. An
-- expansion that isn't known yet (nil) is shown until its data loads.
-- Recommendations stay current-expansion only whatever this says
-- (WhyNotRecommended), except on the Crafts tab, where picking an older
-- expansion judges its crafts on their sales.

function addon:IsExpansionShown(expansionID)
    if expansionID == nil then return true end
    local selected = GoldsmithDB.ui2 and GoldsmithDB.ui2.expansions
    if not selected then return expansionID == addon:GetCurrentExpansion() end
    return selected[expansionID] == true
end

function addon:SetExpansionShown(expansionID, shown)
    local ui = GoldsmithDB.ui2
    ui.expansions = ui.expansions or { [addon:GetCurrentExpansion()] = true }
    ui.expansions[expansionID] = shown or nil
end

-- Expansions with at least one saved (sellable) recipe, newest first; the
-- current expansion is always offered. By the recipe's expansion, not the
-- item's (see GetRecipeExpansion).
function addon:GetFilterExpansions()
    local seen, list = {}, {}
    for _, recipe in pairs(GoldsmithDB.recipes) do
        local expansionID = addon:GetRecipeExpansion(recipe)
        if expansionID and not seen[expansionID] and addon:CanAuction(recipe.outputItemID) ~= false then
            seen[expansionID] = true
            table.insert(list, expansionID)
        end
    end
    local current = addon:GetCurrentExpansion()
    if not seen[current] then table.insert(list, current) end
    table.sort(list, function(a, b) return a > b end)
    return list
end

-- True when every offered expansion is shown, so filtering can be skipped
function addon:AllExpansionsShown()
    for _, expansionID in ipairs(addon:GetFilterExpansions()) do
        if not addon:IsExpansionShown(expansionID) then return false end
    end
    return true
end

function addon:ExpansionFilterLabel()
    local shown = {}
    for _, expansionID in ipairs(addon:GetFilterExpansions()) do
        if addon:IsExpansionShown(expansionID) then table.insert(shown, expansionID) end
    end
    if #shown == 1 then return addon:GetExpansionName(shown[1]) end
    if addon:AllExpansionsShown() then return "All expansions" end
    return string.format("Expansions (%d)", #shown)
end

-- The filter as text, for cache keys
function addon:ExpansionFilterKey()
    local selected = GoldsmithDB.ui2 and GoldsmithDB.ui2.expansions
    if not selected then return "current" end
    local ids = {}
    for expansionID in pairs(selected) do table.insert(ids, expansionID) end
    table.sort(ids)
    return table.concat(ids, ",")
end

-- Whether an item can be listed on the AH, from its bind type. Bind on
-- pickup, quest items and account/warband-bound items can't be. Returns nil
-- if the item isn't in the game's cache yet (it's requested for next time).
local UNSELLABLE_BINDS = { [1] = true, [4] = true, [7] = true, [8] = true, [9] = true }

function addon:CanAuction(itemID)
    local facts = ItemFacts(itemID)
    if not facts then return nil end
    return not UNSELLABLE_BINDS[facts.bind]
end

-- Recipes

-- Recipes are saved automatically when you craft them, from the game's own
-- recipe data. Stored in GoldsmithDB.recipes keyed by recipe ID:
--   { name, profession, outputItemID, outputName, outputQty,
--     reagents = { { names = {...}, itemIDs = {...}, quantity = n }, ... } }
-- A reagent slot can list several items (e.g. different qualities); the
-- cheapest one with a known cost is used.
-- Recipes with quality tiers may not fill in schematic.outputItemID, so fall
-- back to the output data the profession window uses.
local function IsEnchantRecipe(schematic)
    local types = Enum.TradeskillRecipeType
    return types and schematic.recipeType == types.Enchant
end

local function GetOutputItemID(recipeID, schematic)
    -- Enchants don't report their scroll; it's learned from your first
    -- scroll craft (see OnCraftResult)
    if IsEnchantRecipe(schematic) then
        local scroll = GoldsmithDB.scrollOutputs[recipeID]
        return scroll and scroll.itemID
    end
    if schematic.outputItemID then
        return schematic.outputItemID
    end
    local ok, output = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
    if not ok or not output then return nil end
    if output.itemID then
        return output.itemID
    end
    if output.hyperlink then
        return (C_Item.GetItemInfoInstant(output.hyperlink))
    end
end

-- Only recipes that make an item are saved: normal crafts, and enchants
-- once you've put one on a scroll. Salvage (milling, prospecting) is tracked
-- by Milling.lua; recrafts don't make a new item.
local function IsCraftRecipe(schematic)
    local types = Enum.TradeskillRecipeType
    if not types or not schematic.recipeType then return true end
    return schematic.recipeType == types.Item or schematic.recipeType == types.Enchant
end

-- quiet is true when saving from a spell cast or from viewing a recipe, where
-- failures and "Saved recipe" messages would just be noise.
-- Item names come from the game's item cache. When viewing recipes you've
-- never crafted, some names may not be loaded yet, so the save is retried a
-- few times rather than storing a recipe with materials missing.
local MAX_RETRIES = 3

-- profession is passed when saving outside the profession window (enchants
-- matched to scrolls after an AH scan); otherwise it's the open profession.
-- unlearned: a recipe nobody has learned yet, saved to
-- GoldsmithDB.unlearned instead (same shape, plus skillLine, source = where
-- to learn it, learners = { [charKey] = true } who have the profession),
-- for the Crafts tab's "Not learned yet". Kept apart so nothing else takes
-- it for a recipe someone knows.
local function SaveRecipe(recipeID, quiet, attempt, profession, unlearned)
    attempt = attempt or 1
    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not ok or not schematic or not IsCraftRecipe(schematic) then return end

    if not profession then
        -- The recipe's own profession first: the open window can be
        -- another one (an Enchanting recipe was saved as Jewelcrafting from
        -- a jewelcrafter's window, so no enchanter ever read its tiers)
        local okL, _, _, _, parentName = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeID)
        if okL and type(parentName) == "string" and parentName ~= "" then
            profession = parentName
        else
            local profInfo = C_TradeSkillUI.GetBaseProfessionInfo()
            profession = (profInfo and profInfo.professionName) or "Unassigned"
        end
    end

    local outputItemID = GetOutputItemID(recipeID, schematic)
    if not outputItemID then
        if IsEnchantRecipe(schematic) then
            -- Remember it so its scroll can be matched by name later
            if schematic.name then
                -- learner: who could learn it, since the scroll may be
                -- matched later on another character
                GoldsmithDB.pendingEnchants[recipeID] = { name = schematic.name, profession = profession,
                    unlearned = unlearned or nil, learner = unlearned and addon.charKey or nil }
            end
        elseif not quiet then
            addon:Notify("info", "Couldn't save recipe %s: the game didn't report what it makes.", schematic.name or recipeID)
        end
        return
    end
    local pendingLearner = GoldsmithDB.pendingEnchants[recipeID] and GoldsmithDB.pendingEnchants[recipeID].learner
    GoldsmithDB.pendingEnchants[recipeID] = nil

    local reagents = {}
    local namesMissing = false
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        if slot.required and slot.reagents then
            local names, itemIDs = {}, {}
            for _, reagent in ipairs(slot.reagents) do
                if reagent.itemID then
                    local name = C_Item.GetItemNameByID(reagent.itemID)
                    if name then
                        table.insert(names, name)
                        table.insert(itemIDs, reagent.itemID)
                    else
                        namesMissing = true
                        C_Item.RequestLoadItemDataByID(reagent.itemID)
                    end
                end
            end
            if #names > 0 then
                table.insert(reagents, { names = names, itemIDs = itemIDs, quantity = slot.quantityRequired })
            end
        end
    end

    -- A scroll uses up the vellum the enchant was put on, so it's a material
    local scroll = IsEnchantRecipe(schematic) and GoldsmithDB.scrollOutputs[recipeID]
    if scroll and scroll.vellumID then
        local vellumName = C_Item.GetItemNameByID(scroll.vellumID)
        if vellumName then
            table.insert(reagents, { names = { vellumName }, itemIDs = { scroll.vellumID }, quantity = 1 })
        else
            namesMissing = true
            C_Item.RequestLoadItemDataByID(scroll.vellumID)
        end
    end

    local outputName = C_Item.GetItemNameByID(outputItemID)
    if not outputName then
        namesMissing = true
        C_Item.RequestLoadItemDataByID(outputItemID)
    end

    if namesMissing then
        if attempt < MAX_RETRIES then
            C_Timer.After(1, function() SaveRecipe(recipeID, quiet, attempt + 1, profession, unlearned) end)
        end
        return
    end

    if unlearned then
        if GoldsmithDB.recipes[recipeID] then return end
        local existing = GoldsmithDB.unlearned[recipeID]
        local okL, _, skillLine = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeID)
        local okS, source = pcall(C_TradeSkillUI.GetRecipeSourceText, recipeID)
        local learners = existing and existing.learners or {}
        learners[pendingLearner or addon.charKey] = true
        GoldsmithDB.unlearned[recipeID] = {
            recipeID = recipeID,
            name = schematic.name,
            profession = profession,
            outputItemID = outputItemID,
            outputName = outputName,
            outputQty = ((schematic.quantityMin or 1) + (schematic.quantityMax or 1)) / 2,
            outputMin = schematic.quantityMin or 1,
            outputMax = schematic.quantityMax or 1,
            reagents = reagents,
            skillLine = okL and type(skillLine) == "string" and skillLine or (existing and existing.skillLine),
            source = okS and type(source) == "string" and source ~= "" and source or (existing and existing.source),
            learners = learners,
        }
        addon:RefreshRecipeStats(recipeID)
        return
    end

    for _, slot in ipairs(reagents) do
        for _, name in ipairs(slot.names) do
            GoldsmithDB.reagents[name] = GoldsmithDB.reagents[name] or profession
        end
    end
    -- Learned now: no longer one to go learn
    GoldsmithDB.unlearned[recipeID] = nil

    local isNew = GoldsmithDB.recipes[recipeID] == nil

    addon.recipesVersion = addon.recipesVersion + 1
    GoldsmithDB.recipes[recipeID] = {
        recipeID = recipeID,
        name = schematic.name,
        profession = profession,
        outputItemID = outputItemID,
        outputName = outputName,
        outputQty = ((schematic.quantityMin or 1) + (schematic.quantityMax or 1)) / 2,
        outputMin = schematic.quantityMin or 1,
        outputMax = schematic.quantityMax or 1,
        reagents = reagents,
    }
    GoldsmithDB.products[outputName] = GoldsmithDB.products[outputName] or profession
    addon:RecordRecipeSkillLine(recipeID)
    addon:RefreshRecipeStats(recipeID)

    if isNew and not quiet then
        addon:Notify("info", "Saved recipe: %s", outputName)
    end
    if isNew and addon.Refresh then
        addon.Refresh()
    end
end

-- Enchant scrolls by name
--
-- An enchant scroll has the same name as its enchant ("Enchant Ring - ..."),
-- so a scroll can be found without crafting it first. The game only looks
-- items up by name once they've been loaded, e.g. seen in an Auctionator
-- scan, so enchants are matched after scans and whenever the profession
-- window is opened. A match only counts if the item really is an item
-- enhancement (scroll), not something else with the same name.
local ENCHANTING_VELLUM = 38682

local function GetVellumID()
    for _, scroll in pairs(GoldsmithDB.scrollOutputs) do
        if scroll.vellumID then
            return scroll.vellumID
        end
    end
    return ENCHANTING_VELLUM
end

-- An expansion's scrolls are numbered together, in recipe order (Midnight's
-- 243948-244018), so the item IDs around scrolls already known are looked
-- up too and matched by name. That finds enchants nobody has made or seen
-- on the AH, learned or not; the game doesn't report their scroll even
-- with a vellum as the target. Items not loaded yet are asked for, and the
-- match runs again a few seconds later (a few times a session).
local SCROLL_NEIGHBOURS = 60
local neighbourRetries = 0

function addon:MatchEnchantScrolls()
    local itemEnhancement = Enum.ItemClass and Enum.ItemClass.ItemEnhancement or 8
    local matched, unlearned = 0, 0
    local function Found(recipeID, pending, itemID)
        GoldsmithDB.scrollOutputs[recipeID] = { itemID = itemID, vellumID = GetVellumID() }
        SaveRecipe(recipeID, true, 1, pending.profession, pending.unlearned)
        if pending.unlearned then unlearned = unlearned + 1 else matched = matched + 1 end
    end
    for recipeID, pending in pairs(GoldsmithDB.pendingEnchants) do
        local link = select(2, C_Item.GetItemInfo(pending.name))
        local itemID = link and C_Item.GetItemInfoInstant(link)
        local classID = itemID and select(6, C_Item.GetItemInfoInstant(itemID))
        if itemID and classID == itemEnhancement then
            Found(recipeID, pending, itemID)
        end
    end

    -- Item IDs next to known scrolls, matched by name (lowest ID per
    -- enchant; its tiers are found from it, Quality.lua)
    local byName = {}
    for recipeID, pending in pairs(GoldsmithDB.pendingEnchants) do
        if not GoldsmithDB.scrollOutputs[recipeID] then byName[pending.name] = recipeID end
    end
    if next(byName) then
        local candidates, known = {}, {}
        for _, scroll in pairs(GoldsmithDB.scrollOutputs) do
            if scroll.itemID then
                known[scroll.itemID] = true
                for id = scroll.itemID - SCROLL_NEIGHBOURS, scroll.itemID + SCROLL_NEIGHBOURS do
                    candidates[id] = true
                end
            end
        end
        local found, waiting = {}, false
        for id in pairs(candidates) do
            if not known[id] then
                local name = C_Item.GetItemNameByID(id)
                if not name then
                    C_Item.RequestLoadItemDataByID(id)
                    waiting = true
                else
                    local recipeID = byName[name]
                    if recipeID and select(6, C_Item.GetItemInfoInstant(id)) == itemEnhancement
                        and (not found[recipeID] or id < found[recipeID]) then
                        found[recipeID] = id
                    end
                end
            end
        end
        for recipeID, itemID in pairs(found) do
            local pending = GoldsmithDB.pendingEnchants[recipeID]
            if pending then Found(recipeID, pending, itemID) end
        end
        if waiting and neighbourRetries < 5 then
            neighbourRetries = neighbourRetries + 1
            C_Timer.After(3, function() addon:MatchEnchantScrolls() end)
        end
    end

    if matched > 0 then
        addon:Notify("info", "Found scrolls for %d enchant%s. See the Crafts tab in /gsm.", matched, matched == 1 and "" or "s")
    end
    if unlearned > 0 then
        addon:Notify("info", "Found scrolls for %d enchant%s you haven't learned. See Crafts > Show: Not learned yet in /gsm.",
            unlearned, unlearned == 1 and "" or "s")
    end
    if (matched > 0 or unlearned > 0) and addon.Refresh then addon.Refresh() end
end

-- Crafting stats
--
-- Your multicraft, resourcefulness and ingenuity chances, concentration cost
-- and expected quality come straight from the game for each recipe
-- (C_TradeSkillUI.GetCraftingOperationInfo). They're read whenever you open
-- a profession and kept in addon.char.recipeStats[recipeID]:
--   { multicraft = %, resourcefulness = %, ingenuity = %,
--     concentrationCost, ingenuityRefund, quality, qualityID,
--     isQualityCraft, updated }
-- The game doesn't report how big a proc is (how many extra items a
-- multicraft gives, how much resourcefulness saves), since that depends on
-- specialization bonuses. Those start at common base values and are
-- corrected from your own crafts (see calibration below).
--
-- Stat names come from the game in your client's language; this matches the
-- English names.
local STAT_KEYS = {
    Multicraft = "multicraft",
    Resourcefulness = "resourcefulness",
    Ingenuity = "ingenuity",
}

function addon:RefreshRecipeStats(recipeID)
    if not C_TradeSkillUI.GetCraftingOperationInfo then return end
    local ok, op = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, {}, nil, false)
    if not ok or not op then return end
    local stats = {
        multicraft = 0, resourcefulness = 0, ingenuity = 0,
        concentrationCost = op.concentrationCost,
        ingenuityRefund = op.ingenuityRefund,
        quality = op.quality,
        qualityID = op.craftingQualityID,
        isQualityCraft = op.isQualityCraft,
        updated = time(),
    }
    for _, stat in ipairs(op.bonusStats or {}) do
        local key = STAT_KEYS[stat.bonusStatName]
        if key and stat.ratingPct then
            stats[key] = stat.ratingPct
        end
    end
    addon.char.recipeStats[recipeID] = stats

    -- Each expansion's version of a profession has its own concentration,
    -- stored as a currency (0 for recipes that don't use concentration).
    -- Remember each recipe's currency, and for the profession the current
    -- expansion's one, so its amount can be read any time (Quality.lua).
    local currencyID = op.concentrationCurrencyID
    if currencyID and currencyID > 0 then
        stats.concentrationCurrencyID = currencyID
        local recipe = GoldsmithDB.recipes[recipeID]
        if recipe and recipe.profession then
            GoldsmithDB.concentrationCurrency = GoldsmithDB.concentrationCurrency or {}
            local known = GoldsmithDB.concentrationCurrency[recipe.profession]
            local isCurrent = addon:GetRecipeExpansion(recipe) == addon:GetCurrentExpansion()
            if isCurrent or not known or known == 0 then
                GoldsmithDB.concentrationCurrency[recipe.profession] = currencyID
            end
        end
    end

    -- Quality crafts: work out which tiers are reachable (Quality.lua).
    -- Enchants included once their scroll is known (their tiers are found
    -- from it)
    if op.isQualityCraft and (GoldsmithDB.recipes[recipeID] or GoldsmithDB.unlearned[recipeID])
        and addon.RefreshTierData then
        addon:RefreshTierData(recipeID)
    end
end

-- Calibration
--
-- Proc sizes, learned from your crafts and pooled per profession so they're
-- learned quickly. Kept in addon.char.calibration[profession]:
--   mcProcs, mcExtraRatio  - multicraft procs, and the sum of
--                            (extra items / normal output) per proc
--   resProcs, resSavedRatio - resourcefulness returns, and the sum of
--                            (amount returned / amount required) per return
-- Blended with the base values below, which count as PRIOR_WEIGHT
-- observations, so a few lucky procs don't swing the numbers.
local BASE_MULTICRAFT_EXTRA = 1.5    -- extra items per proc, times normal output
local BASE_RESOURCEFULNESS_SAVE = 0.30 -- share of a material saved per proc
local PRIOR_WEIGHT = 5

local function GetCalibration(profession)
    local c = addon:StatsChar().calibration[profession]
    local mcExtra, resSave = BASE_MULTICRAFT_EXTRA, BASE_RESOURCEFULNESS_SAVE
    if c then
        mcExtra = (BASE_MULTICRAFT_EXTRA * PRIOR_WEIGHT + (c.mcExtraRatio or 0)) / (PRIOR_WEIGHT + (c.mcProcs or 0))
        resSave = (BASE_RESOURCEFULNESS_SAVE * PRIOR_WEIGHT + (c.resSavedRatio or 0)) / (PRIOR_WEIGHT + (c.resProcs or 0))
    end
    return mcExtra, resSave, c
end

function addon:GetCalibration(profession)
    return GetCalibration(profession)
end

-- The craft model for a recipe: expected items per craft and expected
-- amount of each material per craft, with your stats and calibrated proc
-- sizes. Without stats for the recipe, or with noProcs (the worst case:
-- no multicraft or resourcefulness), the recipe's base numbers.
-- Returns outputPerCraft, slots ({ slot, quantity }), and the stats used.
function addon:GetCraftModel(recipe, noProcs)
    local stats = not noProcs and recipe.recipeID and addon:StatsChar().recipeStats[recipe.recipeID]
    local base = recipe.outputQty
    local slots = {}
    if not stats then
        for _, slot in ipairs(recipe.reagents) do
            table.insert(slots, { slot = slot, quantity = slot.quantity })
        end
        return base, slots, nil
    end

    local mcExtra, resSave = GetCalibration(recipe.profession)
    local outputPerCraft = base * (1 + stats.multicraft / 100 * mcExtra)
    local useFactor = 1 - stats.resourcefulness / 100 * resSave
    for _, slot in ipairs(recipe.reagents) do
        table.insert(slots, { slot = slot, quantity = slot.quantity * useFactor })
    end
    return outputPerCraft, slots, stats
end

-- Crafting results
--
-- Each finished craft reports what it made, any multicraft extras and any
-- materials resourcefulness gave back. Used for calibration, per-recipe
-- totals (GoldsmithDB.craftStats), and a log of the last CRAFT_LOG_SIZE raw
-- results (GoldsmithDB.craftLog) for checking the numbers.
local CRAFT_LOG_SIZE = 100
local currentCraftRecipeID = nil
local currentEnchantTarget = nil   -- item ID of the vellum an enchant went on
local currentCraftReagents = nil   -- the materials list the game was given (qualities used)
local currentCraftIsOrder = false  -- crafting for a crafting order (patron or player)
local currentOrderTerms = nil      -- that order's commission and customer materials

-- The crafting order you've claimed, if it's for this recipe (in case you
-- craft something else while holding one)
local function GetClaimedOrder(recipeID)
    if not (C_CraftingOrders and C_CraftingOrders.GetClaimedOrder) then return nil end
    local ok, order = pcall(C_CraftingOrders.GetClaimedOrder)
    if ok and type(order) == "table" and order.spellID == recipeID then return order end
end

-- Whether a craft is for a crafting order: the game passes the order's ID
-- to the craft, or reports the order you've claimed. Order crafts go to
-- the customer, so they aren't stock or a cost of yours.
local function IsOrderCraft(recipeID, orderID)
    if type(orderID) == "number" and orderID > 0 then return true end
    return GetClaimedOrder(recipeID) ~= nil
end

-- Copy of game data (tables, numbers, strings, booleans) to save, `depth`
-- levels deep
local function PlainCopy(t, depth)
    if type(t) ~= "table" then return nil end
    local copy = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            if depth > 1 then copy[k] = PlainCopy(v, depth - 1) end
        elseif type(v) ~= "function" and type(v) ~= "userdata" then
            copy[k] = v
        end
    end
    return copy
end

-- What a claimed order pays and supplies: commission = the tip less the
-- consortium's cut (copper; a patron order's gold reward), provided =
-- { [itemID] = quantity } of the materials the customer gave. The raw
-- numbers are kept too, to check against the mail.
--
-- The order's reagents list holds only what the customer supplies (tested
-- on patron orders: every entry had source 0, which isn't the enum's
-- Customer value), so every entry counts as provided.
local function GetProvided(reagents)
    local provided = {}
    for _, r in ipairs(reagents or {}) do
        local info = r.reagentInfo or r
        local id = (type(info.reagent) == "table" and info.reagent.itemID) or info.itemID
        if id and info.quantity then
            provided[id] = (provided[id] or 0) + info.quantity
        end
    end
    return provided
end

local function GetOrderTerms(recipeID)
    local order = GetClaimedOrder(recipeID)
    if not order then return nil end
    local provided = GetProvided(order.reagents)
    -- Patron rewards: { itemID, count, link }
    local rewards = {}
    for _, r in ipairs(order.npcOrderRewards or {}) do
        local id = r.itemLink and C_Item.GetItemInfoInstant(r.itemLink)
        if id then table.insert(rewards, { itemID = id, count = r.count or 1, link = r.itemLink }) end
    end
    return {
        commission = math.max((order.tipAmount or 0) - (order.consortiumCut or 0), 0),
        tip = order.tipAmount, cut = order.consortiumCut,
        provided = provided,
        rewards = rewards,
        reagents = PlainCopy(order.reagents, 4),
    }
end

-- Item ID of a material resourcefulness returned. The game nests it in a
-- reagent table ({ reagent = { itemID = ... }, quantity = n }); older
-- versions had it at the top level.
local function GetReturnedItemID(ret)
    if ret.itemID then return ret.itemID end
    if type(ret.reagent) == "table" then return ret.reagent.itemID end
end

-- Plain copy of a table, a couple of levels deep, for the log
local function CopyForLog(t, depth)
    local copy = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            if (depth or 0) < 2 then copy[k] = CopyForLog(v, (depth or 0) + 1) end
        elseif k ~= "hyperlink" and k ~= "itemGUID" then
            copy[k] = v
        end
    end
    return copy
end

local function LogCraftResult(recipeID, resultData)
    local entry = CopyForLog(resultData)
    entry.time = time()
    entry.recipeID = recipeID
    table.insert(GoldsmithDB.craftLog, entry)
    while #GoldsmithDB.craftLog > CRAFT_LOG_SIZE do
        table.remove(GoldsmithDB.craftLog, 1)
    end
end

local function OnCraftResult(resultData)
    if not currentCraftRecipeID or not resultData or not resultData.itemID then return end
    LogCraftResult(currentCraftRecipeID, resultData)

    -- First scroll from an enchant: now we know which item it makes
    if currentEnchantTarget and not GoldsmithDB.scrollOutputs[currentCraftRecipeID] then
        GoldsmithDB.scrollOutputs[currentCraftRecipeID] = {
            itemID = resultData.itemID,
            vellumID = currentEnchantTarget,
        }
        SaveRecipe(currentCraftRecipeID, false)
        return
    end

    local recipe = GoldsmithDB.recipes[currentCraftRecipeID]
    if not recipe then return end
    -- Ignore results that aren't this recipe's item (e.g. a different craft)
    if C_Item.GetItemNameByID(resultData.itemID) ~= recipe.outputName then return end
    addon:QueueCrafted(currentCraftRecipeID, resultData.quantity)

    local stats = GoldsmithDB.craftStats[currentCraftRecipeID]
    if not stats then
        stats = { crafts = 0, output = 0, returned = {} }
        GoldsmithDB.craftStats[currentCraftRecipeID] = stats
    end
    stats.crafts = stats.crafts + 1
    stats.output = stats.output + (resultData.quantity or 0)

    local c = addon.char.calibration[recipe.profession]
    if not c then
        c = { mcProcs = 0, mcExtraRatio = 0, resProcs = 0, resSavedRatio = 0 }
        addon.char.calibration[recipe.profession] = c
    end

    -- Multicraft: extra items beyond the recipe's normal output
    local extra = resultData.multicraft
    if type(extra) == "number" and extra > 0 and recipe.outputQty > 0 then
        c.mcProcs = c.mcProcs + 1
        c.mcExtraRatio = c.mcExtraRatio + extra / recipe.outputQty
    end

    -- Resourcefulness: each returned material, as a share of what the
    -- recipe needs of it
    for _, ret in ipairs(resultData.resourcesReturned or {}) do
        local returnedID = GetReturnedItemID(ret)
        if returnedID and ret.quantity then
            stats.returned[returnedID] = (stats.returned[returnedID] or 0) + ret.quantity
            for _, slot in ipairs(recipe.reagents) do
                for _, itemID in ipairs(slot.itemIDs or {}) do
                    if itemID == returnedID and slot.quantity > 0 then
                        c.resProcs = c.resProcs + 1
                        c.resSavedRatio = c.resSavedRatio + ret.quantity / slot.quantity
                    end
                end
            end
        end
    end

    -- Order crafts still teach the proc sizes above; only the lot differs
    local lot = addon:RecordCraftLot(recipe, resultData, currentCraftReagents, currentCraftIsOrder, currentOrderTerms)
    -- The planner's "Craft complete" notice (CraftDone.lua)
    if not currentCraftIsOrder then addon:CraftBatchResult(currentCraftRecipeID, recipe, resultData, lot) end
end

-- Crafted lots
--
-- What each craft actually cost: the materials and qualities used, minus
-- anything resourcefulness gave back, valued at what they cost you (or the
-- current price if you have no cost for them), divided by how many it made.
-- Kept per item (each quality tier is its own item) in
-- GoldsmithDB.craftLots[itemID] = { { time, qty, unitCost, partial, name,
-- char, mc, res } }, the last CRAFT_LOT_LIMIT crafts. Concentration isn't a
-- gold cost, so it isn't included. char, mc and res are who crafted it and
-- their multicraft and resourcefulness (%) for the recipe at the time (nil
-- for crafts saved before 2026-10-08), to check the estimate against what
-- crafts really made.
local CRAFT_LOT_LIMIT = 30
local ORDER_CRAFT_LIMIT = 100
-- Bumped whenever craftLots changes (see GetCraftLotsByName)
local craftLotsVersion = 0

-- Crafts for crafting orders go to GoldsmithDB.orderCrafts instead
-- ({ time, qty, unitCost (your materials only), partial, name, itemID,
-- commission (copper, nil for orders saved before it was recorded) }, the last
-- ORDER_CRAFT_LIMIT): the item went to the customer, so it isn't stock and
-- mustn't count toward what yours cost you. Kept for History.
local function AddOrderCraft(lot)
    table.insert(GoldsmithDB.orderCrafts, lot)
    while #GoldsmithDB.orderCrafts > ORDER_CRAFT_LIMIT do
        table.remove(GoldsmithDB.orderCrafts, 1)
    end
end

-- Moves a craft recorded before orders were recognised to the order crafts
-- (History's right-click "This was a crafting order")
function addon:MarkCraftAsOrder(itemID, lot)
    local lots = GoldsmithDB.craftLots[itemID] or {}
    for i, l in ipairs(lots) do
        if l == lot then
            craftLotsVersion = craftLotsVersion + 1
            table.remove(lots, i)
            if #lots == 0 then GoldsmithDB.craftLots[itemID] = nil end
            lot.itemID = itemID
            AddOrderCraft(lot)
            break
        end
    end
    if addon.Refresh then addon.Refresh() end
end

-- A crafting order's customer materials aren't a cost of yours: takes them
-- off `used` ({ [itemID] = quantity }). That exact item first, then any
-- quality of the same material (the list given to the game names the
-- lowest quality when the customer's is a better one). slotOf[itemID] =
-- every item ID of its recipe slot.
local function TakeOffProvided(used, provided, slotOf)
    for id, qty in pairs(provided or {}) do
        local left = qty
        for _, usedID in ipairs({ id, unpack(slotOf[id] or {}) }) do
            if used[usedID] and left > 0 then
                local take = math.min(used[usedID], left)
                used[usedID] = used[usedID] - take
                left = left - take
            end
        end
    end
end

-- Order crafts saved before customer materials were recognised (2026-09-30)
-- counted them as yours. Those that kept the order's reagents list are
-- worked out again once, at today's prices.
function addon:RepairOrderLots()
    for _, lot in ipairs(GoldsmithDB.orderCrafts or {}) do
        local recipe = not lot.providedFixed and lot.orderReagents and lot.yours
            and lot.name and addon:FindRecipeByOutput(lot.name)
        if recipe then
            local names, slotOf = {}, {}
            for _, slot in ipairs(recipe.reagents) do
                for i, id in ipairs(slot.itemIDs or {}) do
                    names[id] = slot.names[i]
                    slotOf[id] = slot.itemIDs
                end
            end
            local used = {}
            for id, qty in pairs(lot.yours) do used[id] = qty end
            TakeOffProvided(used, GetProvided(lot.orderReagents), slotOf)
            local cost, complete = 0, true
            lot.yours = {}
            for id, qty in pairs(used) do
                if qty > 0 then
                    lot.yours[id] = qty
                    local unit = (names[id] and addon:GetOwnCost(names[id], lot.itemID)) or addon:GetMarketPrice(id)
                    if unit then cost = cost + unit * qty else complete = false end
                end
            end
            lot.unitCost = cost / math.max(lot.qty or 1, 1)
            lot.partial = not complete
            lot.providedFixed = true
        end
    end
end

-- Saves one craft's lot (see Crafted lots above) and returns it, or nil
-- if the craft made nothing
function addon:RecordCraftLot(recipe, resultData, usedReagents, isOrder, orderTerms)
    local made = resultData.quantity or 0
    if made <= 0 then return end
    -- Multicraft extras: the game reports them separately. If the quantity
    -- doesn't already include them (it's no more than the recipe's normal
    -- maximum), add them, so a multicraft spreads the cost over every item
    -- it made. Recipes saved before the range was stored use the average.
    local extra = resultData.multicraft
    if type(extra) == "number" and extra > 0 then
        local normalMax = recipe.outputMax or math.ceil(recipe.outputQty)
        if made <= normalMax then
            made = made + extra
        end
    end

    local used, names, slotOf = {}, {}, {}
    for _, slot in ipairs(recipe.reagents) do
        local ids = slot.itemIDs or {}
        for i, id in ipairs(ids) do
            names[id] = slot.names[i]
            slotOf[id] = ids
        end
        if #ids > 1 then
            -- Quality material: the qualities actually used, from the
            -- materials list given to the game
            local counted = 0
            for _, entry in ipairs(usedReagents or {}) do
                local id = (type(entry.reagent) == "table" and entry.reagent.itemID) or entry.itemID
                for _, slotID in ipairs(ids) do
                    if slotID == id and entry.quantity then
                        used[id] = (used[id] or 0) + entry.quantity
                        counted = counted + entry.quantity
                    end
                end
            end
            if counted == 0 then
                used[ids[1]] = (used[ids[1]] or 0) + slot.quantity
            end
        elseif ids[1] then
            used[ids[1]] = (used[ids[1]] or 0) + slot.quantity
        end
    end

    TakeOffProvided(used, orderTerms and orderTerms.provided, slotOf)

    -- What a material is worth to you: what it cost you, or the price
    local function UnitValue(id)
        return (names[id] and addon:GetOwnCost(names[id], resultData.itemID)) or addon:GetMarketPrice(id)
    end

    -- Materials resourcefulness gave back. On your own crafts they lower
    -- the cost. On an order you keep them, even the customer's, so their
    -- value is a gain of the order's (kept).
    local kept = 0
    for _, ret in ipairs(resultData.resourcesReturned or {}) do
        local id = GetReturnedItemID(ret)
        if isOrder then
            local unit = id and ret.quantity and UnitValue(id)
            if unit then kept = kept + unit * ret.quantity end
        elseif id and used[id] and ret.quantity then
            used[id] = math.max(used[id] - ret.quantity, 0)
        end
    end

    local cost, complete = 0, true
    for id, qty in pairs(used) do
        if qty > 0 then
            local unit = UnitValue(id)
            if unit then
                cost = cost + unit * qty
            else
                complete = false
            end
        end
    end

    local lot = {
        time = time(), qty = made, unitCost = cost / made,
        partial = not complete, name = recipe.outputName,
    }
    local stats = recipe.recipeID and addon.char.recipeStats[recipe.recipeID]
    lot.char = addon.charKey
    if stats then lot.mc, lot.res = stats.multicraft, stats.resourcefulness end
    if isOrder then
        lot.itemID = resultData.itemID
        lot.kept = kept > 0 and kept or nil
        if orderTerms then
            -- What the order paid (copper), when the game reported it
            lot.commission = orderTerms.commission
            lot.tip, lot.cut = orderTerms.tip, orderTerms.cut
            -- Rewards you could sell, at their AH price; bound ones
            -- (knowledge, currencies) are listed at 0
            local rewardsValue = 0
            for _, r in ipairs(orderTerms.rewards) do
                local price = addon:CanAuction(r.itemID) and addon:GetAHPrice(r.itemID)
                r.value = price and price * r.count or 0
                rewardsValue = rewardsValue + r.value
            end
            lot.rewards = #orderTerms.rewards > 0 and orderTerms.rewards or nil
            lot.rewardsValue = rewardsValue > 0 and rewardsValue or nil
            -- For checking: the order's materials as the game gave them,
            -- and what was counted as yours
            lot.orderReagents = orderTerms.reagents
            lot.providedFixed = true
            lot.yours = {}
            for id, qty in pairs(used) do
                if qty > 0 then lot.yours[id] = qty end
            end
        end
        AddOrderCraft(lot)
        return lot
    end
    local lots = GoldsmithDB.craftLots[resultData.itemID] or {}
    GoldsmithDB.craftLots[resultData.itemID] = lots
    craftLotsVersion = craftLotsVersion + 1
    table.insert(lots, lot)
    while #lots > CRAFT_LOT_LIMIT do
        table.remove(lots, 1)
    end
    return lot
end

-- Average cost of the newest lots covering `units` items (you'd normally
-- still have your most recent crafts). Returns cost per item, units
-- covered, and whether any lot had unknown material costs.
local function LotAverage(lots, units)
    local remaining, total, covered, partial = math.max(units or 1, 1), 0, 0, false
    for i = #lots, 1, -1 do
        local lot = lots[i]
        local take = math.min(lot.qty, remaining)
        total = total + take * lot.unitCost
        covered = covered + take
        partial = partial or lot.partial
        remaining = remaining - take
        if remaining <= 0 then break end
    end
    if covered == 0 then return nil end
    return total / covered, covered, partial
end

-- Craft lots grouped by item name, built once per change instead of every
-- caller reading every lot (with many lots, costing every recipe that way
-- was slow). Rebuilt when a craft is recorded or moved to orders.
-- Returns { lots (every quality, oldest first), itemIDs = { [itemID] = true } }
-- or nil if never crafted. Don't change what it returns.
local lotIndex, lotIndexVersion

function addon:GetCraftLotsByName(itemName)
    if not lotIndex or lotIndexVersion ~= craftLotsVersion then
        lotIndex, lotIndexVersion = {}, craftLotsVersion
        for itemID, lots in pairs(GoldsmithDB.craftLots) do
            for _, lot in ipairs(lots) do
                if lot.name then
                    local entry = lotIndex[lot.name]
                    if not entry then
                        entry = { lots = {}, itemIDs = {} }
                        lotIndex[lot.name] = entry
                    end
                    table.insert(entry.lots, lot)
                    entry.itemIDs[itemID] = true
                end
            end
        end
        for _, entry in pairs(lotIndex) do
            table.sort(entry.lots, function(a, b) return (a.time or 0) < (b.time or 0) end)
        end
    end
    return lotIndex[itemName]
end

-- What the copies of this exact item (quality tier) in your bags and banks
-- cost you to craft, from your latest crafts of it (or the newest `units`
-- of them). nil if never crafted.
function addon:GetCraftedCost(itemID, units)
    local lots = GoldsmithDB.craftLots[itemID]
    if not lots or #lots == 0 then return nil end
    local onHand = C_Item.GetItemCount(itemID, true, false, true, true) or 0
    return LotAverage(lots, units or onHand)
end

-- Same, for every quality of an item with this name (sale mail and
-- material costs only know the name). Newest crafts first, covering what
-- you have on hand, or `units` if given.
function addon:GetCraftedCostByName(itemName, units)
    local byName = addon:GetCraftLotsByName(itemName)
    if not byName then return nil end
    local onHand = 0
    for itemID in pairs(byName.itemIDs) do
        onHand = onHand + (C_Item.GetItemCount(itemID, true, false, true, true) or 0)
    end
    return LotAverage(byName.lots, units or onHand)
end

-- What an item has cost you: purchases, gathering (at today's AH price),
-- your own milling and your own crafts combined, weighted by how many you
-- got each way. Returns cost and source ("paid", "gathered", "milled",
-- "crafted", or several joined with "+"), or nil.
-- excludeItemID leaves out that item's own crafts (so a craft's cost isn't
-- worked out from itself).
function addon:GetOwnCost(itemName, excludeItemID)
    local sources = {}
    local paid, paidQty, _, gatheredIDs = addon:GetAcquiredCost(itemName)
    if paid then table.insert(sources, { "paid", paid, paidQty }) end
    -- Gathered ones at today's AH price: what you could sell them for
    local gathered, gatheredQty = addon:GatheredValue(gatheredIDs)
    if gathered then table.insert(sources, { "gathered", gathered, gatheredQty }) end
    local milled, milledQty = addon:GetMilledCost(itemName)
    if milled then table.insert(sources, { "milled", milled, milledQty }) end
    local crafted, craftedQty = addon:GetCraftedCostByName(itemName)
    if crafted and not (excludeItemID and C_Item.GetItemNameByID(excludeItemID) == itemName) then
        table.insert(sources, { "crafted", crafted, craftedQty })
    end
    if #sources == 0 then return nil end

    local total, qty, labels = 0, 0, {}
    for _, s in ipairs(sources) do
        total = total + s[2] * s[3]
        qty = qty + s[3]
        table.insert(labels, s[1])
    end
    return total / qty, table.concat(labels, "+")
end

-- Unit cost of one reagent slot, from the first source that has data:
--   1. what it cost you (purchases and milling)
--   2. Auctionator's current AH price
-- Returns cost, source and the item name used, or nil.
local SlotCost
-- The same for every character and recipe using the slot, so it's kept
-- until data changes (the costing of every recipe on every character
-- asked for the same materials over and over)
local slotCostCache = addon:NewCache()

local function GetSlotCost(slot)
    local store = slotCostCache:Get()
    local cached = store[slot]
    if not cached then
        cached = { SlotCost(slot) }
        store[slot] = cached
    end
    return cached[1], cached[2], cached[3], cached[4]
end

SlotCost = function(slot)
    local best, bestSource, bestName
    for _, name in ipairs(slot.names) do
        local cost, source = addon:GetOwnCost(name)
        if cost and (not best or cost < best) then
            best, bestSource, bestName = cost, source, name
        end
    end
    if best then
        return best, bestSource, bestName
    end

    -- Recipes saved before item IDs were stored have no itemIDs until re-crafted
    -- Market price: the AH, or the vendor when it's cheaper
    local bestID, bestMarketSource
    for i, itemID in ipairs(slot.itemIDs or {}) do
        local price, source = addon:GetMarketPriceInfo(itemID)
        if price and (not best or price < best) then
            best, bestName, bestID, bestMarketSource = price, slot.names[i], itemID, source
        end
    end
    if best then
        if bestMarketSource == "Vendor" then
            return best, "vendor", bestName
        end
        return best, "AH price", bestName, bestID
    end
end

-- Cheapest known unit cost for a recipe slot (what you paid or milled, else
-- the AH price), for other files. Returns cost and source, or nil.
function addon:GetSlotUnitCost(slot)
    local cost, source = GetSlotCost(slot)
    return cost, source
end

-- Cost of the materials for one crafted item, using the craft model (your
-- stats: extra items from multicraft, materials saved by resourcefulness).
-- Returns copper per item, a list of reagents with no cost, a breakdown of
-- { name, quantity, unitCost, source } per reagent, and the stats used (nil
-- if the recipe's base numbers were used). noProcs: the worst case, with no
-- multicraft or resourcefulness.
function addon:GetRecipeCost(recipe, noProcs)
    local outputPerCraft, modelSlots, stats = addon:GetCraftModel(recipe, noProcs)
    local perCraft = 0
    local missing = {}
    local breakdown = {}
    for _, m in ipairs(modelSlots) do
        local slot, quantity = m.slot, m.quantity

        local cost, source, name, marketItemID = GetSlotCost(slot)
        if cost then
            perCraft = perCraft + cost * quantity
        else
            table.insert(missing, slot.names[1])
        end
        table.insert(breakdown, {
            name = name or slot.names[1],
            quantity = quantity,
            unitCost = cost,
            source = source,
            -- how old the AH price is, when the cost came from the AH
            ageText = marketItemID and addon:PriceAgeText(marketItemID),
        })
    end
    return perCraft / outputPerCraft, missing, breakdown, stats
end

-- Everything needed to judge a recipe, for tooltips and the Crafts tab.
-- profit and margin are nil without an AH price for the item.
function addon:GetRecipeProfit(recipe, itemID)
    local cost, missing, breakdown, stats = addon:GetRecipeCost(recipe)
    local priceItemID = itemID or recipe.outputItemID
    local price, priceSource, priceAge = addon:GetMarketPriceInfo(priceItemID)
    local demand, demandSource = addon:GetDemand(priceItemID, recipe.outputName)
    local profit, margin
    if price then
        profit = price * (1 - AH_CUT) - cost
        margin = cost > 0 and (profit / cost * 100) or nil
    end
    return {
        cost = cost,
        missing = missing,
        partial = #missing > 0,
        breakdown = breakdown,
        stats = stats,
        price = price,
        priceSource = priceSource,
        priceAge = priceAge,
        priceAgeText = price and addon:PriceAgeText(priceItemID),
        demand = demand,
        demandSource = demandSource,
        saleRate = addon:GetSaleRate(priceItemID),
        profit = profit,
        margin = margin,
    }
end

-- What one unit of an item cost you, for working out profit on a sale:
-- the craft cost for things you make, otherwise what you paid or milled.
-- Returns cost per unit and whether it's partial (some material costs
-- unknown), or nil if there's no cost data at all.
-- Also returns where the cost came from: "free" (marked as loot or a
-- reward), "crafted" (your crafts of it), "estimated" (the recipe at
-- today's prices: you didn't craft these while Goldsmith was watching) or
-- "paid" (what you paid or milled).
function addon:GetUnitCostBasis(itemName, units)
    if GoldsmithDB.freeItems and GoldsmithDB.freeItems[itemName] then
        return 0, false, "free"
    end
    -- Items you crafted: what your latest crafts actually cost
    local crafted, _, craftedPartial = addon:GetCraftedCostByName(itemName, units)
    if crafted then
        return crafted, craftedPartial, "crafted"
    end
    local recipe = addon:FindRecipeByOutput(itemName)
    if recipe then
        local cost, missing = addon:GetRecipeCost(recipe)
        return cost, #missing > 0, "estimated"
    end
    local own = addon:GetOwnCost(itemName)
    if own then
        return own, false, "paid"
    end
end

-- Items you got for free (loot, quest and event rewards): selling them
-- costs you nothing, so the whole sale is profit. Marking one also sets
-- its sales recorded without a cost to 0; unmarking undoes that.
function addon:SetFreeItem(itemName, free)
    GoldsmithDB.freeItems[itemName] = free or nil
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.type == "REVENUE" and e.item == itemName then
            if free and not e.costBasis then
                e.costBasis, e.costSource = 0, "free"
            elseif not free and e.costSource == "free" then
                e.costBasis, e.costSource = nil, nil
            end
        end
    end
    if addon.Refresh then addon.Refresh() end
end

-- By output name (profit numbers ask once per sale), rebuilt when a recipe
-- is saved or removed. Like the loop it replaced, the first recipe found
-- wins when two make the same item.
local outputIndex, outputIndexVersion

function addon:FindRecipeByOutput(itemName)
    if not outputIndex or outputIndexVersion ~= addon.recipesVersion then
        outputIndex, outputIndexVersion = {}, addon.recipesVersion
        for _, recipe in pairs(GoldsmithDB.recipes) do
            if recipe.outputName and outputIndex[recipe.outputName] == nil then
                outputIndex[recipe.outputName] = recipe
            end
        end
    end
    return itemName and outputIndex[itemName] or nil
end

function addon:ListRecipes()
    local list = {}
    for _, recipe in pairs(GoldsmithDB.recipes) do
        table.insert(list, recipe)
    end
    if #list == 0 then
        Print("No recipes saved yet. Craft something once and it's saved automatically.")
        return
    end
    table.sort(list, function(a, b) return a.outputName < b.outputName end)

    Print("Saved recipes (material cost per item, profit at current AH price):")
    for _, recipe in ipairs(list) do
        local cost, missing = addon:GetRecipeCost(recipe)
        local line = "  " .. recipe.outputName .. ": " .. FormatGold(cost)
        if #missing > 0 then
            line = line .. "+"
        end
        local price = addon:GetMarketPrice(recipe.outputItemID)
        if price then
            local profit = price * (1 - AH_CUT) - cost
            line = line .. string.format(", profit %s%s", profit >= 0 and "+" or "-", FormatGold(math.abs(profit)))
            if #missing > 0 then
                line = line .. " at most"
            end
        end
        if #missing > 0 then
            line = line .. " (no cost data for " .. table.concat(missing, ", ") .. ")"
        end
        print(line)
    end
end

-- Tooltips

local function AddTooltipLines(tooltip, data)
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    if not addon.ledger or not data or not data.id then return end
    local mode = addon:Setting("tooltips")
    if mode == "off" then return end

    local name = C_Item.GetItemNameByID(data.id)
    if not name then return end

    -- Short: craft cost and profit for something you craft, otherwise
    -- average cost and today's price against usual
    local recipe = addon:FindRecipeByOutput(name)
    -- Craft lines use the stats of whoever makes it best, as the Crafts tab
    -- does (see GetCrafter)
    local crafter = recipe and (addon:GetCrafter(recipe.recipeID) or addon.charKey)
    if mode == "short" and recipe then
        addon:WithCharacter(crafter, addon.AddRecipeTooltipLines, addon, tooltip, recipe, data.id, false, true)
        return
    end
    local short = mode == "short"

    local avg, qty = addon:GetAverageCost(name)
    if avg then
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r avg cost",
            string.format("%s (newest %d bought)", FormatGold(avg), qty), 1, 1, 1, 1, 1, 1)
    end

    if not short then addon:AddMillingTooltipLines(tooltip, data.id, name) end

    -- Today's price vs its usual price, once there's enough history
    local insight = addon:GetPriceInsight(data.id)
    if insight then
        local pct = insight.diff * 100
        local r, g, b = 0.8, 0.8, 0.8
        if pct <= -15 then r, g, b = 0.3, 1, 0.3 elseif pct >= 15 then r, g, b = 1, 0.6, 0.2 end
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r vs usual price",
            string.format("%+.0f%% (usual %s, %d days)", pct, FormatGold(insight.usual), insight.days),
            1, 1, 1, r, g, b)
    end
    if short then return end

    -- What the ones you crafted cost you (this exact quality), from your
    -- latest crafts of it
    local madeFor, madeUnits, madePartial = addon:GetCraftedCost(data.id)
    if madeFor then
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r you made yours for",
            string.format("%s%s each (%d from your crafts)", FormatGold(madeFor), madePartial and "+" or "", madeUnits),
            1, 1, 1, 1, 1, 1)
    end

    -- Lowest AH listing price that doesn't lose money after the AH cut:
    -- based on what yours cost to make if you crafted them, else the
    -- current average cost
    local unitCost, partial = madeFor, madePartial
    if not unitCost then
        unitCost, partial = addon:GetUnitCostBasis(name)
    end
    if unitCost and unitCost > 0 then
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r break-even price",
            FormatGold(unitCost / (1 - AH_CUT)) .. (partial and "+" or ""), 1, 1, 1, 1, 1, 1)
    end

    if recipe then
        addon:WithCharacter(crafter, addon.AddRecipeTooltipLines, addon, tooltip, recipe, data.id, IsShiftKeyDown())
        if crafter ~= addon.charKey then
            local c = GoldsmithDB.characters[crafter]
            local better = addon:BetterCrafterText(recipe.recipeID)
            tooltip:AddLine(string.format("  Made on %s%s", c and c.name or crafter,
                better and (", " .. better) or ""), 0.6, 0.6, 0.6)
        end
    end
end

local function FormatQuantity(q)
    if q == math.floor(q) then
        return tostring(q)
    end
    return string.format("%.1f", q)
end

-- Craft cost, profit and (optionally) the per-material breakdown. Shared by
-- item tooltips and the Crafts tab. short: only the cost and profit lines
-- (the Short item tooltip setting).
function addon:AddRecipeTooltipLines(tooltip, recipe, itemID, showBreakdown, short)
    local info = addon:GetRecipeProfit(recipe, itemID)

    local costText = FormatGold(info.cost) .. (info.partial and "+" or "") .. " each"
    if info.partial then
        costText = costText .. " (missing " .. #info.missing .. ")"
    end
    tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r craft cost", costText, 1, 1, 1, 1, 1, 1)

    -- Profit if sold at the current AH price, after the AH cut
    if info.profit then
        local r, g, b = 0.3, 1, 0.3
        if info.profit < 0 then r, g, b = 1, 0.3, 0.3 end
        local profitText = string.format("%s%s each", info.profit >= 0 and "+" or "-", FormatGold(math.abs(info.profit)))
        if info.margin then
            profitText = profitText .. string.format(" (%.0f%%)", info.margin)
        end
        -- Unknown costs can only lower the profit, so it's an upper bound
        local label = info.partial and "|cFF00FF00Goldsmith|r profit (at most)" or "|cFF00FF00Goldsmith|r profit"
        tooltip:AddDoubleLine(label, profitText, 1, 1, 1, r, g, b)
        if not short then tooltip:AddLine("  AH price " .. info.priceAgeText, 0.6, 0.6, 0.6) end
    end
    if short then return end

    if info.demand then
        local r, g, b = addon:Color(addon:DemandColor(info.demand, itemID))
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r sold per day",
            string.format("%s (%s)", addon:FormatDemand(info.demand), info.demandSource), 1, 1, 1, r, g, b)
    end
    if info.saleRate then
        local r, g, b = addon:Color(addon:SaleRateColor(info.saleRate))
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r sale rate",
            addon:FormatSaleRate(info.saleRate) .. " of listings sell", 1, 1, 1, r, g, b)
    end

    -- Which stats the cost uses
    local s = info.stats
    if s then
        local outputPerCraft = addon:GetCraftModel(recipe)
        local parts = {}
        if s.multicraft > 0 then table.insert(parts, string.format("multicraft %.1f%%", s.multicraft)) end
        if s.resourcefulness > 0 then table.insert(parts, string.format("resourcefulness %.1f%%", s.resourcefulness)) end
        -- Whose stats: yours, or the crafter's (WithCharacter)
        local statsChar = addon:StatsChar()
        local whose = statsChar == addon.char and "Your stats" or ((statsChar.name or "Their") .. "'s stats")
        tooltip:AddLine(string.format("  %s: %s - %.2f made per craft", whose,
            #parts > 0 and table.concat(parts, ", ") or "no multicraft or resourcefulness",
            outputPerCraft), 0.6, 0.6, 0.6)
    else
        tooltip:AddLine("  Base recipe numbers (older recipes have no multicraft or resourcefulness)", 0.6, 0.6, 0.6)
    end

    if showBreakdown then
        for _, part in ipairs(info.breakdown) do
            local left = string.format("  %sx %s", FormatQuantity(part.quantity), part.name)
            local source = part.source
            if source == "AH price" then
                source = "AH, " .. (part.ageText or "age unknown")
            end
            local right = part.unitCost
                and string.format("%s (%s)", FormatGold(part.unitCost * part.quantity), source)
                or "no cost data"
            tooltip:AddDoubleLine(left, right, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        end
    else
        tooltip:AddLine("  Hold Shift for material costs", 0.6, 0.6, 0.6)
    end
end

-- Learned recipe scan
--
-- When the profession window opens (or switches expansion), every learned
-- recipe that isn't saved yet gets saved, so older-expansion crafts you sell
-- are recognised without clicking each one. Saves run in small batches to
-- avoid a hitch, and each recipe is only tried once per session. Stats
-- (and tier mixes) are read again each time a profession window opens.
local SCAN_BATCH = 20
local FRAME_BUDGET_MS = 5
local scanTimer = nil
local scanning = false
local triedThisSession = {}
local statsReadThisSession = {}

local function CountRecipes()
    local n = 0
    for _ in pairs(GoldsmithDB.recipes) do n = n + 1 end
    return n
end

local function ScanLearnedRecipes()
    scanTimer = nil
    if scanning then return end

    local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not ok or not ids then return end

    -- New learned recipes to save, and saved ones whose stats haven't been
    -- read since the window opened (stats change with gear, specialization
    -- and skill)
    -- Each recipe this character has learned is marked as known by it;
    -- stats are only read for those (they're this character's stats).
    -- Not learned yet: only the current expansion's (the ones worth going
    -- to learn), saved apart (see SaveRecipe) once a session each
    local toSave, toStats, toUnlearned = {}, {}, {}
    local current = addon:GetCurrentExpansion()
    for _, id in ipairs(ids) do
        if not statsReadThisSession[id] and not triedThisSession[id] then
            local info = C_TradeSkillUI.GetRecipeInfo(id)
            local learned = info and info.learned
            if learned then
                addon:MarkRecipeKnown(id)
            end
            if info and not learned and not GoldsmithDB.recipes[id] then
                triedThisSession[id] = true
                local okL, _, skillLine = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe, id)
                if okL and type(skillLine) == "string"
                    and addon:GetRecipeExpansion({ skillLine = skillLine }) == current then
                    table.insert(toUnlearned, id)
                end
            elseif GoldsmithDB.recipes[id] then
                statsReadThisSession[id] = true
                -- Recipes saved before skill lines were kept (for the
                -- expansion filter)
                addon:RecordRecipeSkillLine(id)
                if learned then
                    table.insert(toStats, id)
                end
            elseif learned then
                -- Only learned ones: a recipe learned later this session
                -- still gets saved on the next scan
                triedThisSession[id] = true
                table.insert(toSave, id)
            end
        end
    end
    if #toSave == 0 and #toStats == 0 and #toUnlearned == 0 then
        addon:MatchEnchantScrolls()
        return
    end
    local unlearnedBefore = 0
    for _ in pairs(GoldsmithDB.unlearned) do unlearnedBefore = unlearnedBefore + 1 end

    scanning = true
    local before = CountRecipes()
    local statsIndex = 1
    local i = 1
    local function Step()
        -- Stats first: they update costs for recipes you have. Each one
        -- also checks its tiers and material mixes, so work in slices of
        -- FRAME_BUDGET_MS per frame rather than a fixed count, to keep the
        -- game from stuttering.
        local start = debugprofilestop()
        while toStats[statsIndex] and debugprofilestop() - start < FRAME_BUDGET_MS do
            addon:RefreshRecipeStats(toStats[statsIndex])
            statsIndex = statsIndex + 1
        end
        if toStats[statsIndex] then
            C_Timer.After(0, Step)
            return
        end
        -- Then recipes not learned yet (their stats too, so a slice each)
        while toUnlearned[1] and debugprofilestop() - start < FRAME_BUDGET_MS do
            SaveRecipe(table.remove(toUnlearned, 1), true, 1, nil, true)
        end
        if toUnlearned[1] then
            C_Timer.After(0, Step)
            return
        end

        for _ = 1, SCAN_BATCH do
            local id = toSave[i]
            if not id then
                scanning = false
                -- Saves retry for a few seconds while item names load, so
                -- wait before counting and re-sorting the log
                C_Timer.After(4, function()
                    addon:MatchEnchantScrolls()
                    if addon.Refresh then addon.Refresh() end
                    local added = CountRecipes() - before
                    if added > 0 then
                        addon:Notify("info", "Saved %d learned recipes. See the Crafts tab in /gsm.", added)
                        addon:ReassignProfessions()
                    end
                    local unlearned = 0
                    for _ in pairs(GoldsmithDB.unlearned) do unlearned = unlearned + 1 end
                    if unlearned > unlearnedBefore then
                        addon:Notify("info", "Found %d recipes you haven't learned yet. See Crafts > Show: Not learned yet in /gsm.",
                            unlearned - unlearnedBefore)
                    end
                end)
                return
            end
            SaveRecipe(id, true)
            i = i + 1
        end
        C_Timer.After(0, Step)
    end
    Step()
end

local function QueueRecipeScan()
    if scanTimer then
        scanTimer:Cancel()
    end
    scanTimer = C_Timer.NewTimer(1, ScanLearnedRecipes)
end

-- Crafting stats diagnostic (/gsm stats)
--
-- Temporary: reads what the game reports for the recipe selected in the
-- profession window (skill, difficulty, quality, concentration, and the
-- multicraft/resourcefulness/ingenuity stats), with and without
-- concentration, prints it, and saves it to GoldsmithDB.statsDump so the
-- exact values can be read from the saved variables file. Used to design
-- Goldsmith's own crafting calculations.
local function CopyTable(t, depth)
    if type(t) ~= "table" or (depth or 0) > 4 then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = CopyTable(v, (depth or 0) + 1)
    end
    return copy
end

function addon:DumpCraftingStats()
    local recipeID = addon.selectedRecipeID
    if not recipeID then
        Print("Open your profession window and click a recipe first, then run /gsm stats.")
        return
    end
    if not C_TradeSkillUI.GetCraftingOperationInfo then
        Print("The game's crafting stats function isn't available.")
        return
    end

    local ok1, normal = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, {}, nil, false)
    local ok2, concentrated = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, {}, nil, true)
    local okS, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    local okP, profInfo = pcall(C_TradeSkillUI.GetBaseProfessionInfo)

    GoldsmithDB.statsDump = GoldsmithDB.statsDump or {}
    GoldsmithDB.statsDump[recipeID] = {
        time = time(),
        normal = ok1 and CopyTable(normal) or ("error: " .. tostring(normal)),
        concentrated = ok2 and CopyTable(concentrated) or ("error: " .. tostring(concentrated)),
        schematic = okS and CopyTable(schematic) or nil,
        profession = okP and CopyTable(profInfo) or nil,
    }

    -- Quality tier checks: the item for each tier, and what happens with the
    -- lowest vs highest quality materials, in both reagent list formats the
    -- game has used ({ itemID = } and { reagent = { itemID = } })
    local tiers = {}
    local okQ, qualities = pcall(C_TradeSkillUI.GetQualitiesForRecipe, recipeID)
    tiers.qualities = okQ and CopyTable(qualities) or ("error: " .. tostring(qualities))
    tiers.outputs = {}
    local qualityIDs = (okQ and type(qualities) == "table" and #qualities > 0) and qualities
        or { 1, 2, 3, 4, 5, 13, 14 }
    for _, qualityID in ipairs(qualityIDs) do
        local okO, out = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, {}, nil, qualityID)
        tiers.outputs[qualityID] = okO and CopyTable(out) or ("error: " .. tostring(out))
    end

    local function BuildReagents(pickHighest, nested)
        local list = {}
        for _, slot in ipairs(okS and schematic and schematic.reagentSlotSchematics or {}) do
            -- Only materials that come in qualities; fixed materials use
            -- their own slot numbering, which clashes with these
            if slot.required and slot.reagents and #slot.reagents > 1 then
                local reagent = pickHighest and slot.reagents[#slot.reagents] or slot.reagents[1]
                if reagent.itemID then
                    local entry = { dataSlotIndex = slot.dataSlotIndex, quantity = slot.quantityRequired }
                    if nested then
                        entry.reagent = { itemID = reagent.itemID }
                    else
                        entry.itemID = reagent.itemID
                    end
                    table.insert(list, entry)
                end
            end
        end
        return list
    end
    tiers.runs = {}
    for _, case in ipairs({
        { key = "lowFlat", high = false, nested = false },
        { key = "highFlat", high = true, nested = false },
        { key = "lowNested", high = false, nested = true },
        { key = "highNested", high = true, nested = true },
    }) do
        local reagents = BuildReagents(case.high, case.nested)
        local okR, op = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, reagents, nil, false)
        local okC, opC = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, reagents, nil, true)
        tiers.runs[case.key] = {
            reagents = reagents,
            quality = okR and op and op.quality or ("error: " .. tostring(op)),
            qualityID = okR and op and op.craftingQualityID,
            bonusSkill = okR and op and op.bonusSkill,
            concentrationCost = okC and opC and opC.concentrationCost or ("error: " .. tostring(opC)),
            concentratedQualityID = okC and opC and opC.craftingQualityID,
        }
    end
    GoldsmithDB.statsDump[recipeID].tiers = tiers

    local name = (okS and schematic and schematic.name) or recipeID
    if not ok1 or not normal then
        Print("No crafting stats for %s: %s", name, tostring(normal))
        return
    end
    Print("Crafting stats for %s:", name)
    print(string.format("  Skill %s + %s, difficulty %s + %s", tostring(normal.baseSkill),
        tostring(normal.bonusSkill), tostring(normal.baseDifficulty), tostring(normal.bonusDifficulty)))
    print(string.format("  Quality %s (tier ID %s), concentration cost %s, ingenuity refund %s",
        tostring(normal.quality), tostring(normal.craftingQualityID),
        tostring(normal.concentrationCost), tostring(normal.ingenuityRefund)))
    for _, stat in ipairs(normal.bonusStats or {}) do
        print(string.format("  %s: value %s, %s%% (+%s%% bonus) - %s", tostring(stat.bonusStatName),
            tostring(stat.bonusStatValue), tostring(stat.ratingPct), tostring(stat.bonusRatingPct),
            tostring(stat.ratingDescription)))
    end
    if ok2 and concentrated then
        print(string.format("  With concentration: quality %s (tier ID %s)",
            tostring(concentrated.quality), tostring(concentrated.craftingQualityID)))
    end
    for _, key in ipairs({ "lowFlat", "highFlat", "lowNested", "highNested" }) do
        local run = tiers.runs[key]
        print(string.format("  %s materials: quality %s, skill bonus %s, concentration %s",
            key, tostring(run.quality), tostring(run.bonusSkill), tostring(run.concentrationCost)))
    end
    Print("Saved. /reload so the details are written to disk.")
end

function addon:InitializePricing()
    GoldsmithDB.recipes = GoldsmithDB.recipes or {}
    GoldsmithDB.reagents = GoldsmithDB.reagents or {}

    -- Recipes saved under the profession window that was open rather than
    -- their own (its skill line says: "Midnight Enchanting"): put them
    -- right, and drop stats a character without that profession saved
    local CRAFTING = { "Alchemy", "Blacksmithing", "Enchanting", "Engineering", "Inscription",
                       "Jewelcrafting", "Leatherworking", "Tailoring" }
    for recipeID, recipe in pairs(GoldsmithDB.recipes) do
        local line = recipe.skillLine
        for _, prof in ipairs(CRAFTING) do
            if line and recipe.profession ~= prof and line:sub(-#prof) == prof then
                if GoldsmithDB.products[recipe.outputName] == recipe.profession then
                    GoldsmithDB.products[recipe.outputName] = prof
                end
                recipe.profession = prof
                addon.recipesVersion = addon.recipesVersion + 1
                for _, c in pairs(GoldsmithDB.characters or {}) do
                    if c.recipeStats and c.recipeStats[recipeID] and not (c.professions and c.professions[prof]) then
                        c.recipeStats[recipeID] = nil
                    end
                end
            end
        end
    end

    -- Remove salvage recipes saved before they were filtered out
    for recipeID, recipe in pairs(GoldsmithDB.recipes) do
        local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
        if ok and schematic and not IsCraftRecipe(schematic) then
            addon.recipesVersion = addon.recipesVersion + 1
            GoldsmithDB.recipes[recipeID] = nil
            GoldsmithDB.products[recipe.outputName] = nil
        end
    end

    GoldsmithDB.craftStats = GoldsmithDB.craftStats or {}
    GoldsmithDB.scrollOutputs = GoldsmithDB.scrollOutputs or {}
    GoldsmithDB.pendingEnchants = GoldsmithDB.pendingEnchants or {}
    GoldsmithDB.unlearned = GoldsmithDB.unlearned or {}
    GoldsmithDB.vendorPrices = GoldsmithDB.vendorPrices or {}
    local vendorFrame = CreateFrame("Frame")
    vendorFrame:RegisterEvent("MERCHANT_SHOW")
    vendorFrame:RegisterEvent("MERCHANT_UPDATE")
    vendorFrame:SetScript("OnEvent", function()
        -- Item info can arrive just after the vendor opens
        C_Timer.After(0.5, function()
            RecordVendorPrices()
            if addon.Refresh then
                addon.Refresh()
            end
        end)
    end)

    GoldsmithDB.orderBooks = GoldsmithDB.orderBooks or {}
    for itemID, book in pairs(GoldsmithDB.orderBooks) do
        if time() - book.time > ORDER_BOOK_KEEP then
            GoldsmithDB.orderBooks[itemID] = nil
        end
    end
    local bookFrame = CreateFrame("Frame")
    bookFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
    bookFrame:SetScript("OnEvent", function(_, _, itemID)
        if itemID then
            RecordOrderBook(itemID)
            if addon.Refresh then
                addon.Refresh()
            end
        end
    end)

    -- Search results: the list comes in pages as it loads, so one refresh
    -- for the lot shortly after
    GoldsmithDB.searchPrices = GoldsmithDB.searchPrices or {}
    for itemID, s in pairs(GoldsmithDB.searchPrices) do
        if time() - s.time > ORDER_BOOK_KEEP then GoldsmithDB.searchPrices[itemID] = nil end
    end
    local searchRefreshPending = false
    local searchFrame = CreateFrame("Frame")
    searchFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    searchFrame:RegisterEvent("AUCTION_HOUSE_BROWSE_RESULTS_ADDED")
    searchFrame:RegisterEvent("AUCTION_HOUSE_SHOW")
    searchFrame:SetScript("OnEvent", function(_, event, added)
        -- The first time at the AH without Auctionator: one tip, once ever
        if event == "AUCTION_HOUSE_SHOW" then
            if not addon:HasAuctionator() and not GoldsmithDB.auctionatorTipShown then
                GoldsmithDB.auctionatorTipShown = true
                addon:Notify("info", "Tip: with Auctionator, one scan refreshes every Goldsmith price.")
            end
            return
        end
        local ok, results
        if event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
            ok, results = true, added
        else
            ok, results = pcall(C_AuctionHouse.GetBrowseResults)
        end
        if not (ok and type(results) == "table" and RecordSearchResults(results)) then return end
        if searchRefreshPending or not addon.Refresh then return end
        searchRefreshPending = true
        C_Timer.After(0.5, function()
            searchRefreshPending = false
            addon.Refresh()
        end)
    end)

    GoldsmithDB.craftLog = GoldsmithDB.craftLog or {}
    GoldsmithDB.craftLots = GoldsmithDB.craftLots or {}
    GoldsmithDB.orderCrafts = GoldsmithDB.orderCrafts or {}
    GoldsmithDB.freeItems = GoldsmithDB.freeItems or {}
    -- Recipes saved before recipeID was stored in them
    for recipeID, recipe in pairs(GoldsmithDB.recipes) do
        recipe.recipeID = recipeID
    end

    -- CraftRecipe(recipeID, count, reagents, recipeLevel, orderID, concentrate)
    hooksecurefunc(C_TradeSkillUI, "CraftRecipe", function(recipeID, _, craftingReagents, _, orderID)
        currentCraftRecipeID = recipeID
        currentEnchantTarget = nil
        currentCraftReagents = craftingReagents
        currentCraftIsOrder = IsOrderCraft(recipeID, orderID)
        currentOrderTerms = currentCraftIsOrder and GetOrderTerms(recipeID) or nil
        SaveRecipe(recipeID, false)
    end)
    hooksecurefunc(C_TradeSkillUI, "CraftSalvage", function()
        currentCraftRecipeID = nil
        currentEnchantTarget = nil
    end)
    -- Enchanting onto vellum makes a scroll; the vellum is the target item
    if C_TradeSkillUI.CraftEnchant then
        hooksecurefunc(C_TradeSkillUI, "CraftEnchant", function(recipeID, _, craftingReagents, itemTarget)
            currentCraftReagents = craftingReagents
            currentCraftRecipeID = recipeID
            currentCraftIsOrder = IsOrderCraft(recipeID)
            currentOrderTerms = currentCraftIsOrder and GetOrderTerms(recipeID) or nil
            currentEnchantTarget = itemTarget and C_Item.DoesItemExist(itemTarget)
                and C_Item.GetItemID(itemTarget) or nil
            -- Enchanting gear doesn't make a scroll; only a vellum does
            if currentEnchantTarget and C_Item.IsEquippableItem(currentEnchantTarget) then
                currentEnchantTarget = nil
                currentCraftRecipeID = nil
            end
            SaveRecipe(recipeID, true)
        end)
    end

    local resultFrame = CreateFrame("Frame")
    resultFrame:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT")
    resultFrame:RegisterEvent("TRADE_SKILL_SHOW")
    resultFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
    resultFrame:RegisterEvent("NEW_RECIPE_LEARNED")
    resultFrame:SetScript("OnEvent", function(_, event, resultData)
        if event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
            OnCraftResult(resultData)
        else
            -- Stats change with knowledge points, gear and skill, so they're
            -- read again every time a profession window opens
            if event == "TRADE_SKILL_SHOW" then wipe(statsReadThisSession) end
            QueueRecipeScan()
        end
    end)

    -- Auctionator updates its prices after a full scan and after any AH
    -- search or browse. Both set lastPriceUpdate; a full scan also sets
    -- lastFullScan, so the window doesn't call a search a scan.
    local function OnPricesUpdated(isFullScan)
        local now = time()
        GoldsmithDB.lastPriceUpdate = now
        if isFullScan then GoldsmithDB.lastFullScan = now end
        addon:RecordPriceHistory(isFullScan)
        -- A scan loads the items it saw, so more scrolls can be matched
        addon:MatchEnchantScrolls()
        if addon.Refresh then
            addon.Refresh()
        end
    end

    -- Auctionator's event bus says which kind of update it was. Its public
    -- API (RegisterForDBUpdate) doesn't, so it's only the fallback.
    local A = Auctionator
    local bus = A and A.EventBus
    local fullEvents = A and A.FullScan and A.FullScan.Events
    local incEvents = A and A.IncrementalScan and A.IncrementalScan.Events
    local searchEvents = A and A.Search and A.Search.Events
    local processed = (incEvents and incEvents.PricesProcessed) or (searchEvents and searchEvents.PricesProcessed)
    local isFull = {}
    if fullEvents and fullEvents.ScanComplete then isFull[fullEvents.ScanComplete] = true end
    -- Auctionator's other full scan (browsing every page) ends with this
    -- and then PricesProcessed; the second is skipped
    if incEvents and incEvents.ScanComplete then isFull[incEvents.ScanComplete] = true end
    local registered = false
    if bus and bus.Register and processed and next(isFull) then
        local events = { processed }
        for event in pairs(isFull) do table.insert(events, event) end
        registered = pcall(bus.Register, bus, {
            ReceiveEvent = function(_, event)
                if isFull[event] then
                    OnPricesUpdated(true)
                elseif GoldsmithDB.lastFullScan ~= time() then
                    OnPricesUpdated(false)
                end
            end,
        }, events)
    end
    local api = A and A.API and A.API.v1
    if not registered and api and api.RegisterForDBUpdate then
        pcall(api.RegisterForDBUpdate, "Goldsmith", function() OnPricesUpdated(false) end)
    end

    -- Save each recipe as you click it in the profession window, so costs
    -- and profit are available before you've ever crafted it.
    if EventRegistry then
        EventRegistry:RegisterCallback("ProfessionsRecipeListMixin.Event.OnRecipeSelected", function(_, recipeInfo)
            if recipeInfo and recipeInfo.recipeID then
                addon.selectedRecipeID = recipeInfo.recipeID
                SaveRecipe(recipeInfo.recipeID, true)
            end
        end, addon)
    end

    -- A craft is also a spell cast whose spell ID is the recipe ID. This
    -- catches crafts even if the profession window doesn't go through
    -- CraftRecipe. Saving is repeat-safe, so both firing is fine.
    local castFrame = CreateFrame("Frame")
    castFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    castFrame:SetScript("OnEvent", function(_, _, _, _, spellID)
        if not (ProfessionsFrame and ProfessionsFrame:IsShown()) then return end
        if C_TradeSkillUI.GetRecipeInfo(spellID) then
            SaveRecipe(spellID, true)
        end
    end)

    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, AddTooltipLines)

    -- Tooltips don't redraw on key presses, so redraw on Shift to show or
    -- hide the material breakdown while hovering. Item tooltips only, and
    -- never in combat or with secret data in them: a redraw started by an
    -- addon can't touch the game's secret values (Midnight), and the game
    -- blames Goldsmith for the error (2026-10-08).
    local function SafeToRedraw(tooltip)
        if InCombatLockdown() or not (tooltip:IsShown() and tooltip.RefreshData and tooltip.GetPrimaryTooltipData) then
            return false
        end
        local data = tooltip:GetPrimaryTooltipData()
        if type(data) ~= "table" or (canaccesstable and not canaccesstable(data)) then return false end
        if data.type ~= Enum.TooltipDataType.Item then return false end
        for _, line in ipairs(data.lines or {}) do
            if canaccesstable and not canaccesstable(line) then return false end
            for _, value in pairs(line) do
                if issecretvalue and issecretvalue(value) then return false end
                if type(value) == "table" and canaccesstable and not canaccesstable(value) then return false end
            end
        end
        return true
    end
    local modifierFrame = CreateFrame("Frame")
    modifierFrame:RegisterEvent("MODIFIER_STATE_CHANGED")
    modifierFrame:SetScript("OnEvent", function(_, _, key)
        if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
        for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
            if SafeToRedraw(tooltip) then
                tooltip:RefreshData()
            end
        end
    end)
end

_G.Goldsmith = addon
