local addon = _G.Goldsmith or {}

local function Print(msg, ...)
    print("|cFF00FF00[Goldsmith]|r " .. string.format(msg, ...))
end

local function FormatGold(copper)
    if addon.isForever then return addon:FormatMoney(copper) end
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

-- During the tour the sample's prices are frozen (Tour.lua): Goldsmith
-- Data's from when it was made, nothing from Auctionator, TSM or searches
local function TourPrices()
    return addon.UsingTourData ~= nil and addon:UsingTourData()
end

-- Realm groups. Materials and most crafts (food, potions, gems, ingots:
-- commodities) are one AH for the whole region; gear and other single
-- items are one AH per group of connected realms. Goldsmith's own scan and
-- searches say which group they came from, and on another group only
-- their commodity prices are used (user, 2026-10-22: characters on two
-- realm groups). TSM and Auctionator keep their own prices per realm.
local realmGroup
function addon:RealmGroup()
    if realmGroup then return realmGroup end
    local names = {}
    for _, name in ipairs(GetAutoCompleteRealms and GetAutoCompleteRealms() or {}) do table.insert(names, name) end
    if #names == 0 then
        local own = GetNormalizedRealmName and GetNormalizedRealmName()
        if not own then return nil end
        names[1] = own
    end
    table.sort(names)
    realmGroup = table.concat(names, ",")
    return realmGroup
end

-- Sold on the region-wide AH: stackable items are commodities. Not known
-- yet (item not loaded) counts as region-wide: nearly everything Goldsmith
-- prices is a material.
function addon:IsRegionWide(itemID)
    local stack = itemID and select(8, C_Item.GetItemInfo(itemID))
    if not stack then return true end
    return stack > 1
end

-- The realm Goldsmith's last scan was made on, when that's another realm
-- group than this character's (its gear prices aren't used here), else nil
function addon:OwnScanElsewhere()
    local scan = GoldsmithDB.ownScan
    local here = addon:RealmGroup()
    if not (scan and scan.group and here) or scan.group == here then return nil end
    return scan.realm or scan.group:match("^[^,]+") or "another realm"
end

-- Whether a price recorded on `group` holds here
function addon:PriceHoldsHere(group, itemID)
    if not group then return true end
    local here = addon:RealmGroup()
    return not here or group == here or addon:IsRegionWide(itemID)
end

-- Auctionator's price for an item, regardless of TSM
function addon:GetAuctionatorPrice(itemID)
    if not itemID or TourPrices() then return nil end
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
    if TourPrices() then return nil end
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not (api and api.GetAuctionAgeByItemID) then return nil end
    local ok, age = pcall(api.GetAuctionAgeByItemID, "Goldsmith", itemID)
    if ok and type(age) == "number" then
        return age
    end
end

local function GetTSMValue(source, itemID)
    if not (TSM_API and TSM_API.GetCustomPriceValue) or TourPrices() then return nil end
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
-- and used for ORDER_BOOK_FRESH like an order book.
-- A search shows only the cheapest listing, not how many are at that
-- price, so a lone undercut can't be told apart: a search price more than
-- SEARCH_MAX_DROP below the price Goldsmith has otherwise (Goldsmith Data,
-- Auctionator, TSM) isn't used (GetAHPriceInfo); clicking into the item
-- gives the real depth. It replaced a 25g floor for materials (2026-10-13,
-- user: searching Null and Void Plate's materials didn't update them):
-- across the US AH, the cheapest listing was over 10% below the price with
-- quantity behind it for 10% of items under 25g and 18% of those over, so
-- the floor kept the safer half out and let the riskier half in.
local SEARCH_MAX_DROP = 0.10

local function RecordSearchResults(results)
    GoldsmithDB.searchPrices = GoldsmithDB.searchPrices or {}
    local now, recorded = time(), false
    for _, r in ipairs(results or {}) do
        local key = r.itemKey
        local itemID = key and key.itemID
        if itemID and (key.battlePetSpeciesID or 0) == 0 and type(r.minPrice) == "number" and r.minPrice > 0 then
            GoldsmithDB.searchPrices[itemID] = { time = now, price = r.minPrice, quantity = r.totalQuantity,
                                                 group = addon:RealmGroup() }
            recorded = true
        end
    end
    return recorded
end

-- The lowest price from a fresh search, before the check against the
-- other prices (GetAHPriceInfo)
function addon:GetSearchPrice(itemID)
    local s = not TourPrices() and GoldsmithDB.searchPrices and GoldsmithDB.searchPrices[itemID]
    if s and time() - s.time <= ORDER_BOOK_FRESH and addon:PriceHoldsHere(s.group, itemID) then return s.price end
end

local function GetFreshOrderBook(itemID)
    local book = not TourPrices() and GoldsmithDB.orderBooks and GoldsmithDB.orderBooks[itemID]
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

-- The same rule for Goldsmith's own scan, which sees every listing (Scan.lua)
function addon:RobustBookPrice(book)
    return GetRobustBookPrice(book)
end

-- Goldsmith's own AH scan (Scan.lua), saved as
--   GoldsmithDB.ownScan = { time, method, auctions, items, seconds,
--                           prices = { [itemID] = { fair, lowest, quantity } } }
-- fair: the lowest price with real quantity behind it (the order book
-- rule above), from every listing in a full scan; a page-by-page scan only
-- sees each item's lowest, so there fair = lowest. Used like an
-- Auctionator scan: when it's the newest price there is (OwnScanIsNewest),
-- or for items nothing else prices.
function addon:GetScanPrice(itemID)
    -- The scan turned off in Settings: its prices aren't used either
    local scan = not TourPrices() and addon:Setting("ahScan") and GoldsmithDB.ownScan
    local entry = scan and scan.prices and itemID and scan.prices[itemID]
    if not entry or not addon:PriceHoldsHere(scan.group, itemID) then return nil end
    return entry[1], math.max(0, math.floor((time() - scan.time) / 86400))
end

-- No price for an item: in Forever, after a scan of your own, it simply
-- wasn't listed (most old items aren't), so "scan the AH" misled
-- (stress test, 2026-10-21)
function addon:NoPriceText(text)
    if addon.isForever and addon:GetOwnScanTime() then return "None on the AH in your last scan." end
    return text
end

function addon:GetOwnScanTime()
    if not addon:Setting("ahScan") then return nil end
    return GoldsmithDB.ownScan and GoldsmithDB.ownScan.time
end

-- Newer than Auctionator's last full scan and Goldsmith Data; with TSM,
-- only a scan from this session or the last hour (TSM's app refreshes
-- about hourly). A /reload right after a scan switched to TSM and the
-- queue wanted 13 gold ingots bought instead of crafted (user, 2026-10-22)
function addon:OwnScanIsNewest()
    local scanned = not TourPrices() and addon:GetOwnScanTime()
    if not scanned then return false end
    if addon:HasAuctionator() and (GoldsmithDB.lastFullScan or 0) > scanned then return false end
    local data = addon:GetBlizzardDataTime()
    if data and data > scanned then return false end
    if addon:HasTSM() and scanned < sessionStart and time() - scanned > 3600 then return false end
    return true
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
--   GoldsmithPriceData.items[itemID] = { min, market, median, quantity, sells, sold, usual }
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

-- True if Blizzard AH data is under a day old and no Auctionator full scan
-- came after it (the newer one wins). An AH search doesn't count: it only
-- updates the items searched, and Goldsmith's own record of those (Search)
-- comes first anyway.
-- It used to: one shift-click search on a character with Auctionator made
-- every item use Auctionator's days-old prices over Goldsmith Data from the
-- same hour (Gleeful Glamour dropped out of Best crafts, user 2026-10-11).
function addon:BlizzardDataBeatsScan()
    local updated = addon:GetBlizzardDataTime()
    if not updated or time() - updated >= 86400 then return false end
    local full = GoldsmithDB.lastFullScan
    return not full or full < updated
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
-- A note that changes nothing starts with INFO_NOTE: it shows in the hover
-- without "~" or "Adjusted:" (both said the price was changed when it wasn't,
-- code review 2026-10-14).
-- Over SOLD_EXTREME_RATIO times what it sold for, with fewer than
-- SOLD_DEEP_QTY listed, is a shelf whatever the sell level: gold Gleeful
-- Glamour - Night Elf was rated Sells (quiet items overcount, cancellations
-- look like sales) with all 93 listings at 18,888g and sales at 9.82g, and
-- was suggested for +53,825g (user, 2026-10-14). Deep markets are left as
-- they were: this price is also a material's cost, and capping a deep
-- material (19,939 listed at 5.25g, "sold for" 0.20g) would make crafts
-- look cheaper than buying really is. The Haste scroll wall was 5.3x.
local SOLD_HIGH_RATIO = 3
local SOLD_EXTREME_RATIO = 10
local SOLD_DEEP_QTY = 100
-- The 10x rule's own depth: 355 Felberry Figs at 10g, sold for 0.98g, are
-- a shelf, not a wall (user, 2026-10-18); 19,939 at 5.25g still count
local SOLD_EXTREME_DEEP_QTY = 1000
local INFO_NOTE = "Note: "

-- Whether a price note means the price was changed (so it shows with "~")
function addon:PriceAdjusted(note)
    return note ~= nil and note:sub(1, #INFO_NOTE) ~= INFO_NOTE
end

local function SoldCap(itemID, price)
    local data = GoldsmithPriceData
    local entry = data and data.items and data.items[itemID]
    local level, sold, quantity = entry and entry[5], entry and entry[6], entry and entry[4]
    if sold and sold > 0 and price > sold * SOLD_EXTREME_RATIO and (quantity or 0) < SOLD_EXTREME_DEEP_QTY then
        return sold, string.format("listed at %s, but it sold for %s this week", FormatGold(price), FormatGold(sold))
    end
    if level and level < addon.SELL_LEVEL.sells and sold and price > sold * SOLD_HIGH_RATIO then
        if quantity and quantity >= SOLD_DEEP_QTY then
            return nil, string.format("%sit sold for %s this week", INFO_NOTE, FormatGold(sold))
        end
        return sold, string.format("listed at %s, but it sold for %s this week", FormatGold(price), FormatGold(sold))
    end
end

local function GetBlizzardPrice(itemID, buying)
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
    local sold, soldNote
    if not buying then sold, soldNote = SoldCap(itemID, price) end
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

-- Forever's vendor crafting materials, so plans know them before you've
-- opened a vendor: the prices recorded at the stress test (2026-10-21),
-- before any Bartering discount. A vendor you open still records its own.
local FOREVER_VENDOR = {
    [2320] = 10, [2321] = 100, [4291] = 500, [8343] = 2000,       -- threads
    [2324] = 25, [2325] = 1000, [2604] = 50, [2605] = 100,        -- bleach, dyes
    [4340] = 350, [4341] = 500, [4342] = 2500, [6260] = 50,
    [2880] = 100, [3466] = 2000, [3857] = 500,                    -- flux, coal
    [3371] = 4, [3372] = 40, [8925] = 500,                        -- vials
    [6217] = 124,                                                 -- copper rod
    [4289] = 50, [4399] = 200, [4400] = 2000,                     -- salt, stocks
    [2678] = 2, [2692] = 40, [3713] = 160,                        -- spices
    [2928] = 20,                                                  -- dust of decay
}

function addon:GetVendorPrice(itemID)
    if not itemID then return nil end
    local price = GoldsmithDB.vendorPrices and GoldsmithDB.vendorPrices[itemID]
    if not price and addon.isForever then price = FOREVER_VENDOR[itemID] end
    return price
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
local StoredAHPrice -- below
local SALE_HIGH_RATIO = 3

-- A searched or live price is what's listed now, and gets the same check
-- against what the item actually sold for as saved prices do: after the
-- cheap Felberry Figs sold out, 355 sat at 10g while they sold for about
-- 1g, and a search made Figs a 40g craft (user, 2026-10-18). TSM's region
-- sale average, else Goldsmith Data's sale price (SoldCap).
-- Not when buying: a material costs what's listed, whatever it sold for
-- before (user, 2026-10-20: Hollow Grouper bought out and relisted at 3g,
-- the plan still salvaged it at its 0.50g sale average)
local function SaleCheck(itemID, price, source, buying)
    if buying then return price, source, nil end
    local saleAvg = GetTSMValue("DBRegionSaleAvg", itemID)
    if saleAvg then
        if price > saleAvg * SALE_HIGH_RATIO then
            return saleAvg, "TSM sale avg", nil,
                string.format("listed at %s, but it usually sells for %s", FormatGold(price), FormatGold(saleAvg))
        end
        return price, source, nil
    end
    local sold, note = SoldCap(itemID, price)
    if sold then return sold, "Blizzard", nil, note end
    return price, source, nil, note
end

-- Price jumps
--
-- What you'd sell at, against its usual price: the cheap Felberry Figs
-- sold out and the lowest went from about 1.50g to 10g, and 500g the day
-- before; made at 10g each, they sell for 1.40g (user, 2026-10-18). Over
-- JUMP_RATIO times the usual, an item is valued at the usual price and
-- the plan warns. Only for what you sell: a material that jumped really
-- costs what's listed. The usual price: Goldsmith Data's median of the last
-- 7 days' prices, else TSM's historical price, else the median of your own
-- saved daily prices before today (JUMP_MIN_DAYS of them).
local JUMP_RATIO = 3
local JUMP_MIN_DAYS = 4

local function OwnUsualPrice(itemID)
    local history = GoldsmithDB.priceHistory and GoldsmithDB.priceHistory[itemID]
    if not history then return nil end
    local today, list = date("%Y-%m-%d"), {}
    for day, price in pairs(history) do
        if day ~= today then table.insert(list, price) end
    end
    if #list < JUMP_MIN_DAYS then return nil end
    table.sort(list)
    return list[math.floor((#list + 1) / 2)]
end

-- PriceJump as it was on a past day: against your saved prices from the
-- JUMP_LOOKBACK days before `when`, not today's usual price. For a price
-- kept back then: a Worldsoul Aegis kept at 1,250g on Oct 16 was judged
-- at today's 306g, so a later price drop read as "expected" (2026-10-29).
-- Without enough saved days then, today's check (PriceJump).
local JUMP_LOOKBACK = 14
function addon:PriceJumpAt(itemID, price, when)
    local history = GoldsmithDB.priceHistory and GoldsmithDB.priceHistory[itemID]
    if history and price and when then
        local from, to, list = date("%Y-%m-%d", when - JUMP_LOOKBACK * 86400), date("%Y-%m-%d", when), {}
        for day, p in pairs(history) do
            if day >= from and day <= to then table.insert(list, p) end
        end
        if #list >= JUMP_MIN_DAYS then
            table.sort(list)
            local usual = list[math.floor((#list + 1) / 2)]
            if usual > 0 and price > usual * JUMP_RATIO then return usual end
            return nil
        end
    end
    return (addon:PriceJump(itemID, price))
end

-- An item's usual price and where it's from, or nil
function addon:UsualPrice(itemID)
    local data = GoldsmithPriceData
    local entry = itemID and data and data.items and data.items[itemID]
    if entry and entry[7] then return entry[7], "Goldsmith Data, last 7 days" end
    local tsm = GetTSMValue("DBHistorical", itemID)
    if tsm then return tsm, "TSM" end
    local own = OwnUsualPrice(itemID)
    if own then return own, "your saved prices" end
end

-- For a selling price (from GetMarketPriceInfo): the usual price and a note
-- when the price jumped, else nil. Not for vendor prices or box contents.
function addon:PriceJump(itemID, price, source)
    if not (itemID and price) or source == "Vendor" or source == "Contents" or TourPrices() then return nil end
    local usual, from = addon:UsualPrice(itemID)
    if usual and usual > 0 and price > usual * JUMP_RATIO then
        return usual, string.format("price jumped: listed at %s, usually %s (%s)",
            FormatGold(price), FormatGold(usual), from)
    end
end

-- Most listings expire: under this share sold (TSM's sale rate), plans warn
addon.LOW_SALE_RATE = 0.10

local DepthCheck -- below

-- buying: the price to pay for it (plans, material costs), without the
-- checks against what it sold for (SaleCheck, SoldCap, TSM sale average),
-- which are for valuing what you'd sell
function addon:GetAHPriceInfo(itemID, buying)
    if not itemID then return nil end

    -- The price source setting: "auto" (above), "auctionator" (its last
    -- scan, however old, TSM only without one) or "tsm" (TSM, Auctionator
    -- only without it; live searches ignored)
    local preferred = addon:Setting("priceSource")

    local book = preferred ~= "tsm" and GetFreshOrderBook(itemID)
    if book then
        return SaleCheck(itemID, GetRobustBookPrice(book), "Live", buying)
    end
    local price, source, age, note = StoredAHPrice(itemID, preferred, buying)
    -- A search price, unless it's far below the others: likely a lone
    -- undercut (see SEARCH_MAX_DROP)
    local searched = preferred ~= "tsm" and addon:GetSearchPrice(itemID)
    if searched and (not price or searched >= price * (1 - SEARCH_MAX_DROP)) then
        return DepthCheck(itemID, SaleCheck(itemID, searched, "Search", buying))
    end
    return DepthCheck(itemID, price, source, age, note)
end

-- The AH price from saved data (Auctionator, TSM, Goldsmith Data), as
-- GetAHPriceInfo returns it, without live or searched prices
StoredAHPrice = function(itemID, preferred, buying)
    -- Goldsmith's own scan, when it's the newest (not with a source preferred)
    local scanned, scanAge = addon:GetScanPrice(itemID)
    if scanned and preferred == "auto" and addon:OwnScanIsNewest() then
        return addon:CheckAgainstMarket(itemID, scanned, "Scan", scanAge, buying)
    end
    local auctionator = addon:GetAuctionatorPrice(itemID)
    local age = auctionator and GetAuctionatorAge(itemID)
    local price, source
    -- Goldsmith Data from this hour beats an Auctionator price from "today"
    -- (its age is in whole days, so maybe hours ago) unless a full scan came
    -- after it; what you searched shows as Search above. Before, a price
    -- seen today, or any search this session, made Auctionator win: with it
    -- on, Maddoxynn's to-do had Missive of the Harmonious, without it the
    -- Quickblade (user, 2026-10-11).
    local dataWins = auctionator and preferred ~= "auctionator"
        and addon:BlizzardDataBeatsScan() and GetBlizzardPrice(itemID) ~= nil
    local useAuctionator = auctionator and not dataWins and (preferred == "auctionator"
        or (preferred ~= "tsm" and age == 0 and addon:ScannedThisSession()))
    if useAuctionator then
        price, source = auctionator, "Auctionator"
    else
        local tsm = GetTSMValue("DBMinBuyout", itemID)
        if tsm then
            price, source, age = tsm, "TSM", nil
        elseif auctionator and not dataWins then
            price, source = auctionator, "Auctionator"
        else
            -- No price from either addon, or Auctionator's is a day or more
            -- old and the Blizzard data is fresher
            local blizzard, blizzardAge, note = GetBlizzardPrice(itemID, buying)
            if blizzard then
                return blizzard, "Blizzard", blizzardAge, note
            end
        end
    end
    -- Nothing else prices it: Goldsmith's own scan, however old
    if not price and scanned then
        return addon:CheckAgainstMarket(itemID, scanned, "Scan", scanAge, buying)
    end
    if not price then return nil end

    return addon:CheckAgainstMarket(itemID, price, source, age, buying)
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

-- A low price that held for days is the price, not an undercut: TSM's
-- market value is an average that trails a falling market. Petrified Root
-- went 340g to 60g over two weeks, 126,000 listed from 59g, and plans
-- bought it at TSM's 110.42g (user, 2026-10-24). Real when Goldsmith's own
-- saved prices for the days before today (at least SUSTAINED_DAYS of the
-- last SUSTAINED_LOOKBACK) have a median within SUSTAINED_RATIO of it; a
-- lone undercut under a steady price still isn't.
local SUSTAINED_DAYS, SUSTAINED_LOOKBACK, SUSTAINED_RATIO = 2, 4, 1.25
local function SustainedLow(itemID, price)
    local history = GoldsmithDB.priceHistory and GoldsmithDB.priceHistory[itemID]
    if not history then return false end
    local list = {}
    for back = 1, SUSTAINED_LOOKBACK do
        local p = history[date("%Y-%m-%d", time() - back * 86400)]
        if p then table.insert(list, p) end
    end
    if #list < SUSTAINED_DAYS then return false end
    table.sort(list)
    return list[math.floor((#list + 1) / 2)] <= price * SUSTAINED_RATIO
end

-- A price counts when there's quantity behind it (user, 2026-10-28). A
-- search and Auctionator see only the lowest listing, so a few far below
-- the usual price may be gone before you buy:
-- one search priced Photosynthesized Scrap at 1.40g with 2,131 listed at
-- about 19g, and Auctionator saw the same search. Under FAR_BELOW_USUAL
-- of the usual price, such a price is valued at the usual one until a
-- full scan or the item's own listings (both see quantity) say otherwise,
-- or it held for days (SustainedLow). TSM's minimum buyout is already
-- checked against its market value (CheckAgainstMarket), which has
-- quantity in it.
local LOWEST_ONLY = { Search = true, Auctionator = true }
local FAR_BELOW_USUAL = 0.5
DepthCheck = function(itemID, price, source, age, note)
    if not (price and LOWEST_ONLY[source]) or TourPrices() then return price, source, age, note end
    local usual = addon:UsualPrice(itemID)
    if usual and price < usual * FAR_BELOW_USUAL and not SustainedLow(itemID, price) then
        return usual, "Usual", nil,
            string.format("lowest listing %s is far below usual, with no sign how many there are", FormatGold(price))
    end
    return price, source, age, note
end

function addon:CheckAgainstMarket(itemID, price, source, age, buying)
    local listed, note = price, nil
    local market = GetTSMValue("DBMarket", itemID)
    if not market then
        local blizzard, blizzardAge
        if source ~= "Blizzard" then blizzard, blizzardAge = GetBlizzardPrice(itemID, buying) end
        if blizzard and price > blizzard * OUTLIER_HIGH_RATIO then
            return blizzard, "Blizzard", blizzardAge,
                string.format("lowest listing %s is far above the usual price", FormatGold(listed))
        end
        if buying then return price, source, age, note end
        local sold, soldNote = SoldCap(itemID, price)
        if sold then
            return sold, "Blizzard", blizzardAge, soldNote
        end
        return price, source, age, note or soldNote
    end
    if price < market * UNDERCUT_RATIO and not SustainedLow(itemID, price) then
        price, source, age = market, "TSM market", nil
        note = string.format("lowest listing %s looked like a small undercut", FormatGold(listed))
    elseif market and price > market * OUTLIER_HIGH_RATIO then
        price, source, age = market, "TSM market", nil
        note = string.format("lowest listing %s is far above the usual price", FormatGold(listed))
    end
    local saleAvg = not buying and GetTSMValue("DBRegionSaleAvg", itemID)
    if saleAvg and price > saleAvg * SALE_HIGH_RATIO then
        return saleAvg, "TSM sale avg", nil,
            string.format("listed at %s, but it usually sells for %s", FormatGold(listed), FormatGold(saleAvg))
    end
    return price, source, age, note
end

function addon:GetAHPrice(itemID, buying)
    return (addon:GetAHPriceInfo(itemID, buying))
end

-- What an item costs to get: the AH price, unless a vendor sells it for
-- less (or it isn't on the AH), in which case the vendor price with source
-- "Vendor". Same returns as GetAHPriceInfo.
function addon:GetMarketPriceInfo(itemID, buying)
    if not itemID then return nil end
    -- A box you craft and have opened (School of Gems): what's inside, on
    -- average (Gathered.lua). It can't go on the AH itself.
    local box = addon.GetBoxValue and addon:GetBoxValue(itemID)
    if box then return box, "Contents", nil end
    local price, source, age, note = addon:GetAHPriceInfo(itemID, buying)
    local vendor = addon:GetVendorPrice(itemID)
    if vendor and (not price or vendor <= price) then
        return vendor, "Vendor", nil
    end
    return price, source, age, note
end

-- buying: what it costs to get (see GetAHPriceInfo)
function addon:GetMarketPrice(itemID, buying)
    return (addon:GetMarketPriceInfo(itemID, buying))
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
-- "TSM market value", "live, 5m ago". Short, for tooltips. With the note
-- GetAHPriceInfo gives when it replaced the lowest listing (an undercut, a
-- shelf price), ", adjusted" is added, so a changed price is never passed
-- off as the listing (design review, 2026-10-09: show what the numbers do).
function addon:PriceSourceText(itemID, source, age, note)
    local text = addon:PlainPriceSourceText(itemID, source, age)
    return addon:PriceAdjusted(note) and (text .. ", adjusted") or text
end

function addon:PlainPriceSourceText(itemID, source, age)
    if source == "Live" then
        local book = itemID and GoldsmithDB.orderBooks[itemID]
        return book and string.format("live, %dm ago", math.floor((time() - book.time) / 60)) or "live"
    end
    if source == "Search" then
        local s = itemID and GoldsmithDB.searchPrices and GoldsmithDB.searchPrices[itemID]
        return s and string.format("AH search, %dm ago", math.floor((time() - s.time) / 60)) or "AH search"
    end
    if source == "Scan" then
        local t = addon:GetOwnScanTime()
        -- Made on another realm group: say where (only materials use it)
        local elsewhere = addon:OwnScanElsewhere()
        local from = elsewhere and (", from " .. elsewhere) or ""
        if t then return "Goldsmith scan, " .. addon:WhenText(t, "") .. from end
        return "Goldsmith scan, " .. addon:FormatAge(math.max(1, age or 1)) .. from
    end
    if source == "TSM" then return "TSM" end
    if source == "TSM market" then return "TSM market value" end
    if source == "TSM sale avg" then return "TSM sale average" end
    if source == "Usual" then return "usual price" end
    if source == "Blizzard" then return BlizzardAgeText() end
    if source == "Vendor" then return "vendor" end
    if source == "Contents" then
        local _, opened, complete = addon:GetBoxValue(itemID)
        return string.format("what's inside, average of %d opened%s", opened or 0,
            complete == false and " (some of it has no price, so at least this)" or "")
    end
    if source == "Auctionator" then
        return age and ("Auctionator, " .. addon:FormatAge(age, itemID):gsub("^from ", "")) or "Auctionator"
    end
    return source or "no price"
end

-- Where the price in use came from, and how old (see PriceSourceText)
function addon:PriceAgeText(itemID, buying)
    local price, source, age, note = addon:GetMarketPriceInfo(itemID, buying)
    if not price then return "no price" end
    return addon:PriceSourceText(itemID, source, age, note)
end

-- Same as PriceAgeText, for the AH price only (ignoring vendor prices)
function addon:AHPriceAgeText(itemID, buying)
    local price, source, age, note = addon:GetAHPriceInfo(itemID, buying)
    if not price then return "no price" end
    return addon:PriceSourceText(itemID, source, age, note)
end

-- Why a price was adjusted ("listed at 81,484g, but it usually sells for
-- 1,200g"), or nil when it's the lowest listing as is
function addon:PriceNote(itemID)
    local _, _, _, note = addon:GetMarketPriceInfo(itemID)
    return note
end

-- A hover line saying a price was adjusted and why. Always shown, not only
-- with Ctrl: it changes what the number means.
function addon:AddPriceNote(tooltip, note)
    if not note then return end
    if not addon:PriceAdjusted(note) then
        tooltip:AddLine(note .. ".", 0.8, 0.8, 0.8, true)
        return
    end
    local r, g, b = addon:Color("warning")
    tooltip:AddLine("Adjusted: " .. note .. ".", r, g, b, true)
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

-- When something happened, for a label: "at 14:32" today (`today` replaces
-- "at "), "yesterday 23:35", else "3 days ago" in calendar days. Whole
-- 24-hour days said "1 day ago" for a scan made half an hour before
-- midnight (user, 2026-10-25: "when really i did it probably like an hour
-- ago").
local function DayNumber(t)
    local d = date("*t", t)
    return math.floor(time({ year = d.year, month = d.month, day = d.day, hour = 12 }) / 86400 + 0.5)
end

function addon:WhenText(ts, today)
    local days = DayNumber(time()) - DayNumber(ts)
    if days <= 0 then return (today or "at ") .. date("%H:%M", ts) end
    if days == 1 then return "yesterday " .. date("%H:%M", ts) end
    return string.format("%d days ago", days)
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
addon.OWN_SALES_DAYS = OWN_SALES_DAYS

local function GetTSMSoldPerDay(itemID)
    if not (TSM_API and TSM_API.GetCustomPriceValue) or TourPrices() then return nil end
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
-- Anything else you can equip counts too, bags aside (crafted bags sell
-- like any item): by class alone an Apprentice Jeweler's Apron wasn't gear
-- in game, so its soulbound copy counted as stock for sale (user,
-- 2026-10-27).
local NOT_GEAR_SLOTS = { [""] = true, INVTYPE_NON_EQUIP_IGNORE = true, INVTYPE_BAG = true, INVTYPE_QUIVER = true }
function addon:IsGear(itemID)
    if not itemID then return false end
    local _, _, _, equipLoc, _, classID = C_Item.GetItemInfoInstant(itemID)
    if classID == Enum.ItemClass.Weapon or classID == Enum.ItemClass.Armor
        or classID == Enum.ItemClass.Profession then
        return true
    end
    return equipLoc ~= nil and not NOT_GEAR_SLOTS[equipLoc]
end

function addon:HasTSM()
    return TSM_API and TSM_API.GetCustomPriceValue and not TourPrices() and true or false
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

-- A price nothing can check. Gear and profession tools aren't commodities,
-- so Goldsmith Data has no regional price or sales for them, and without
-- TSM the only price is the realm's lowest listing: one Thalassian
-- Competitor's Emblem at 10M g showed +9.5M g profit on an unlearned
-- recipe (user, 2026-10-16). TSM, Goldsmith Data or your own sales of the
-- item count as a check. The warning goes by what backs the price, not
-- by ROI alone: a 150% gear craft on one listing is as unconfirmed as a
-- 5,000% one, it just costs less to be wrong about.
--   info.unconfirmed: counted, but the player should look at the AH first
--   (a "?" before the price, a warning in the hover and the plan).
--   Over UNCHECKED_MAX_ROI it isn't counted either: price, profit and
--   margin become nil (so nothing sorts it to the top) and info.doubtPrice
--   keeps the listing for the hover.
-- Suggestions already skip these (no sales data, Insights.lua).
local UNCHECKED_MAX_ROI = 1000

function addon:PriceConfirmed(itemID, name, source)
    if TourPrices() then return true end
    source = source or ""
    if source:find("^TSM") or source == "Blizzard" or source == "Vendor" or source == "Contents" then return true end
    if itemID and GetTSMValue("DBMarket", itemID) then return true end
    local data = GoldsmithPriceData
    if itemID and data and data.items and data.items[itemID] then return true end
    return name and GetOwnSoldPerDay(name) and true or false
end

function addon:DoubtPrice(info, itemID, name)
    if not info.price or addon:PriceConfirmed(itemID, name, info.priceSource) then return end
    info.unconfirmed = true
    if info.margin and info.margin > UNCHECKED_MAX_ROI then
        info.doubtPrice = info.price
        info.price, info.profit, info.margin = nil, nil, nil
    end
end

-- The hover and plan wording for both cases
function addon:UnconfirmedPriceText(info)
    if info.doubtPrice then
        return "Not counted: a listing this far above the cost, with no sales data to back it, is almost never a real price."
    end
    return "Price not confirmed: only your realm's listings back it, with no sales data. Look at the AH before you buy materials or learn the recipe."
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
    if not (itemID and TSM_API and TSM_API.GetCustomPriceValue) or TourPrices() then return nil end
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
                -- Finishing reagents too (Bazaar Bites): unloaded, a craft
                -- is costed without them (ChooseFinishing)
                for _, stats in pairs(c.recipeStats or {}) do
                    for _, o in ipairs(stats.finishing or {}) do
                        if o.itemID and not C_Item.GetItemInfo(o.itemID) then RequestItem(o.itemID) end
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

-- A bound box you craft and open (Bouquet of Herbs): no sales of its own,
-- so the sales column says "Opens", not "-" (read as missing data, user,
-- 2026-10-27). A tier not opened yet (gold) counts when its recipe's base
-- item has been: baseItemID.
addon.OPENS_TEXT = "Opens"
function addon:IsBox(itemID, baseItemID)
    if addon:CanAuction(itemID) ~= false then return false end
    return addon:GetBoxValue(itemID) ~= nil or (baseItemID ~= nil and addon:GetBoxValue(baseItemID) ~= nil)
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
        -- The game gives no profession for some recipes you haven't
        -- learned (Midnight Cooking's came back ""), so they matched no
        -- profession filter: take it from the skill line instead
        -- ("Midnight Cooking" -> "Cooking"; user, 2026-10-12)
        local line = okL and type(skillLine) == "string" and skillLine or (existing and existing.skillLine)
        if (not profession or profession == "" or profession == "Unassigned") and line then
            profession = line:match("(%S+)$") or profession
        end
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
    if isNew then
        -- Its materials and output can be counted in stock now
        addon:RecountStockSoon()
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

-- An enchant whose scroll Goldsmith hasn't found yet (by recipe ID or the
-- enchant's name): nothing to price it by, which looked broken (user,
-- 2026-10-18: Rite of the Hash'ey, a "?" page with no price)
local SCROLL_MISSING_TEXT = "Goldsmith hasn't found this enchant's scroll yet. It fills in once one shows up in an AH scan or you craft one."
function addon:EnchantScrollMissing(recipeID, name)
    if recipeID then
        return GoldsmithDB.pendingEnchants[recipeID] ~= nil and not GoldsmithDB.scrollOutputs[recipeID]
    end
    if not name then return false end
    for id, pending in pairs(GoldsmithDB.pendingEnchants or {}) do
        if pending.name == name and not GoldsmithDB.scrollOutputs[id] then return true end
    end
    return false
end
addon.SCROLL_MISSING_TEXT = SCROLL_MISSING_TEXT

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
    for recipeID, pending in pairs(GoldsmithDB.pendingEnchants or {}) do
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
    for recipeID, pending in pairs(GoldsmithDB.pendingEnchants or {}) do
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

-- Finishing reagents: what each one in a recipe's finishing slots does to
-- your stats, read the same way (the game answers for ones you don't have:
-- Bazaar Bites on Arcano Cutlets read as multicraft 100%, Savory Anomaly as
-- resourcefulness 8.8% to 21.0%, 2026-10-17). Slots still locked by skill
-- are left out. Kept in recipeStats[recipeID].finishing:
--   { { itemID, dataSlotIndex, quantity, multicraft, resourcefulness,
--       ingenuity, skill } }
-- Which one to use is worked out from prices (ChooseFinishing, below).
local function SlotLocked(slot, recipeID)
    local mcrSlotID = slot.slotInfo and slot.slotInfo.mcrSlotID
    local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
    if not (C_TradeSkillUI.GetReagentSlotStatus and mcrSlotID and info and info.skillLineAbilityID) then
        return false
    end
    local ok, locked = pcall(C_TradeSkillUI.GetReagentSlotStatus, mcrSlotID, recipeID, info.skillLineAbilityID)
    return ok and locked == true
end

local function ReadFinishingOptions(recipeID)
    local finishingType = Enum.CraftingReagentType and Enum.CraftingReagentType.Finishing
    if not finishingType then return nil end
    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not (ok and schematic) then return nil end
    local options
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        if slot.reagentType == finishingType and slot.reagents and not SlotLocked(slot, recipeID) then
            local quantity = math.max(slot.quantityRequired or 1, 1)
            for _, reagent in ipairs(slot.reagents) do
                if reagent.itemID then
                    -- Each option is a call to the game: the scan can wait here
                    if addon.TierYield then addon.TierYield() end
                    local list = { { reagent = { itemID = reagent.itemID }, quantity = quantity,
                        dataSlotIndex = slot.dataSlotIndex } }
                    local okOp, op = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, list, nil, false)
                    if okOp and op then
                        local o = { itemID = reagent.itemID, dataSlotIndex = slot.dataSlotIndex, quantity = quantity,
                            multicraft = 0, resourcefulness = 0, ingenuity = 0,
                            skill = (op.baseSkill or 0) + (op.bonusSkill or 0) }
                        for _, stat in ipairs(op.bonusStats or {}) do
                            local key = STAT_KEYS[stat.bonusStatName]
                            if key and stat.ratingPct then o[key] = stat.ratingPct end
                        end
                        if not C_Item.GetItemNameByID(reagent.itemID) then
                            C_Item.RequestLoadItemDataByID(reagent.itemID)
                        end
                        options = options or {}
                        table.insert(options, o)
                    end
                end
            end
        end
    end
    return options
end

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
    stats.finishing = ReadFinishingOptions(recipeID)
    addon.char.recipeStats[recipeID] = stats

    -- Each expansion's version of a profession has its own concentration,
    -- stored as a currency (0 for recipes that don't use concentration).
    -- Remember each recipe's currency, and for the profession the current
    -- expansion's one, so its amount can be read any time (Quality.lua).
    -- A profession without concentration (Cooking), or a currency another
    -- profession has already: an Enchanting recipe filed under Cooking gave
    -- Cooking Enchanting's concentration, so Mysticmead's Cooking showed
    -- "1000, full" (user, 2026-10-12: cooking has no concentration)
    local currencyID = op.concentrationCurrencyID
    if currencyID and currencyID > 0 then
        stats.concentrationCurrencyID = currencyID
        local recipe = GoldsmithDB.recipes[recipeID]
        if recipe and recipe.profession and not addon.NO_CONCENTRATION[recipe.profession] then
            GoldsmithDB.concentrationCurrency = GoldsmithDB.concentrationCurrency or {}
            local known = GoldsmithDB.concentrationCurrency[recipe.profession]
            local isCurrent = addon:GetRecipeExpansion(recipe) == addon:GetCurrentExpansion()
            local taken = false
            for other, id in pairs(GoldsmithDB.concentrationCurrency) do
                if other ~= recipe.profession and id == currencyID then taken = true end
            end
            if not taken and (isCurrent or not known or known == 0) then
                GoldsmithDB.concentrationCurrency[recipe.profession] = currencyID
            end
        end
    end

    -- Quality crafts: work out which tiers are reachable (Quality.lua).
    -- Enchants included once their scroll is known (their tiers are found
    -- from it)
    if op.isQualityCraft and (GoldsmithDB.recipes[recipeID] or GoldsmithDB.unlearned[recipeID])
        and addon.RefreshTierData then
        if addon.TierYield then addon.TierYield() end
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
-- With a finishing reagent worth using (ChooseFinishing): its stats, and
-- the reagent as one more slot ({ slot, quantity, finishing = option }),
-- so costs, plans and shopping lists all count it; then a fourth value,
-- the choice (options and picks, for the planner). Never with noProcs (the
-- worst case doesn't pay for a reagent) or noFinishing (what the window holds).
local ChooseFinishing -- below, with material costs

function addon:GetCraftModel(recipe, noProcs, noFinishing)
    local stats = not noProcs and recipe.recipeID and addon:StatsChar().recipeStats[recipe.recipeID]
    local base = recipe.outputQty
    local slots = {}
    if not stats then
        for _, slot in ipairs(recipe.reagents) do
            table.insert(slots, { slot = slot, quantity = slot.quantity })
        end
        return base, slots, nil
    end

    local finishing = not noFinishing and stats.finishing and ChooseFinishing(recipe, stats)
    local multicraft = finishing and finishing.multicraft or stats.multicraft
    local resourcefulness = finishing and finishing.resourcefulness or stats.resourcefulness
    local mcExtra, resSave = GetCalibration(recipe.profession)
    -- With finishing reagents tried, their own learned multicraft (ChooseFinishing)
    local outputPerCraft = base * (1 + (finishing and finishing.extraRatio or multicraft / 100 * mcExtra))
    local useFactor = 1 - resourcefulness / 100 * resSave
    for _, slot in ipairs(recipe.reagents) do
        table.insert(slots, { slot = slot, quantity = slot.quantity * useFactor })
    end
    -- Resourcefulness doesn't save finishing reagents
    for _, pick in ipairs(finishing and finishing.picks or {}) do
        table.insert(slots, { slot = pick.slot, quantity = pick.slot.quantity, finishing = pick.option })
    end
    return outputPerCraft, slots, stats, finishing
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

-- Patron rewards: { itemID, count, link }
local function GetOrderRewards(order)
    local rewards = {}
    for _, r in ipairs(order.npcOrderRewards or {}) do
        local id = r.itemLink and C_Item.GetItemInfoInstant(r.itemLink)
        if id then table.insert(rewards, { itemID = id, count = r.count or 1, link = r.itemLink }) end
    end
    return rewards
end

local function GetOrderTerms(recipeID)
    local order = GetClaimedOrder(recipeID)
    if not order then return nil end
    local provided = GetProvided(order.reagents)
    local rewards = GetOrderRewards(order)
    return {
        commission = math.max((order.tipAmount or 0) - (order.consortiumCut or 0), 0),
        tip = order.tipAmount, cut = order.consortiumCut, orderType = order.orderType,
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
    entry.char = addon.charKey
    table.insert(GoldsmithDB.craftLog, entry)
    while #GoldsmithDB.craftLog > CRAFT_LOG_SIZE do
        table.remove(GoldsmithDB.craftLog, 1)
    end
    -- Added to the lifetime stats now, before it can drop off (Lifetime.lua)
    if addon.LifetimeCatchUp then addon:LifetimeCatchUp() end
end

-- A finishing reagent that raises multicraft, if the craft used one: its
-- crafts are learned on their own, in calibration[profession].finishing
-- [itemID] = { crafts, extraRatio (sum of extra items / normal output) }.
-- Every craft counts, procs or not, so the average is what a craft with it
-- makes. Bazaar Bites read as multicraft 100% but give 3 to 9 extra, not
-- the usual amount (a CurseForge comment: about 5.17 per bite over 400;
-- user, 2026-10-17). Returns true when the craft was counted here.
local function FinishingCrafted(c, recipeID, recipe, reagents, extra)
    local stats = addon.char.recipeStats[recipeID]
    if not (stats and stats.finishing and reagents and recipe.outputQty > 0) then return false end
    for _, entry in ipairs(reagents) do
        local itemID = entry.reagent and entry.reagent.itemID or entry.itemID
        for _, o in ipairs(stats.finishing) do
            if o.itemID == itemID and o.multicraft > (stats.multicraft or 0) + 1 then
                c.finishing = c.finishing or {}
                local f = c.finishing[itemID] or { crafts = 0, extraRatio = 0 }
                c.finishing[itemID] = f
                f.crafts = f.crafts + 1
                f.extraRatio = f.extraRatio + ((type(extra) == "number" and extra > 0) and extra or 0) / recipe.outputQty
                return true
            end
        end
    end
    return false
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
    if not currentCraftIsOrder then
        addon:QueueCrafted(currentCraftRecipeID, resultData.quantity, resultData.itemID)
    end

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

    -- Multicraft: extra items beyond the recipe's normal output. With a
    -- finishing reagent that raises multicraft (Bazaar Bites: 100%), every
    -- craft is counted for that reagent, procs or not, and kept out of the
    -- ordinary numbers (FinishingCrafted)
    local extra = resultData.multicraft
    local boosted = FinishingCrafted(c, currentCraftRecipeID, recipe, currentCraftReagents, extra)
    if not boosted and type(extra) == "number" and extra > 0 and recipe.outputQty > 0 then
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
    local lot, used = addon:RecordCraftLot(recipe, resultData, currentCraftReagents, currentCraftIsOrder, currentOrderTerms)
    -- The planner's "Craft complete" notice (CraftDone.lua)
    if not currentCraftIsOrder then addon:CraftBatchResult(currentCraftRecipeID, recipe, resultData, lot, used) end
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

-- GoldsmithDB was swapped for another (the tour's sample data, Tour.lua):
-- indexes built from the old one are rebuilt
function addon:RecipesSwapped()
    addon.recipesVersion = addon.recipesVersion + 1
    craftLotsVersion = craftLotsVersion + 1
end

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
    if addon.LifetimeCatchUp then addon:LifetimeCatchUp() end
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

-- What a bound reward bag (Artisan's Consortium payout) is worth: the
-- average of what came out of the ones you opened (Gathered.lua tracks
-- them), and how many that is; nil before you've opened one. The bag's
-- contents stay gathered materials when opened, valued at the AH price as
-- their cost, so counting the bag here (the order's profit) isn't counted
-- again (user, 2026-10-11).
local function BagValue(itemID)
    local inside, opened = addon:GetBoxValue(itemID)
    if inside then return inside, opened end
end

-- Rewards you could sell, at their AH price; a payout bag at what's inside
-- on average (r.opened: from how many); other bound ones (knowledge,
-- currencies) are listed at 0. Sets each reward's value; returns the total.
local function ValueRewards(rewards)
    local total = 0
    for _, r in ipairs(rewards or {}) do
        local price = addon:CanAuction(r.itemID) and addon:GetAHPrice(r.itemID)
        local inside, opened
        if not price then inside, opened = BagValue(r.itemID) end
        r.value = (price or inside or 0) * r.count
        r.opened = opened
        total = total + r.value
    end
    return total
end

-- A saved order craft's reward, worth now: what was saved, or for a payout
-- bag valued 0 then, its contents average since (orders from before you
-- opened one). Returns the value and, for a bag, from how many opened.
function addon:RewardValueNow(r)
    local value, opened = r.value or 0, r.opened
    if value == 0 then
        local inside, n = BagValue(r.itemID)
        if inside then value, opened = inside * (r.count or 1), n end
    end
    return value, opened
end

-- All of a saved order craft's rewards, worth now (RewardValueNow)
function addon:LotRewardsValue(lot)
    if not lot.rewards then return lot.rewardsValue or 0 end
    local total = 0
    for _, r in ipairs(lot.rewards) do total = total + (addon:RewardValueNow(r)) end
    return total
end

-- What a crafting order will cost you, before you craft it (the line under
-- the order's materials, OrderCost.lua). order = the order the game is
-- showing, tx = its recipe form's transaction (Blizzard's
-- ProfessionsRecipeTransactionMixin). Works like RecordCraftLot: the
-- recipe's materials as Goldsmith saved them, with the qualities the form
-- has chosen for quality materials, less what the customer supplies. The
-- form's own slot list can't be the base: it leaves out materials that
-- come in one quality (a Leatherworking patron order listed only its
-- Void-Tempered Plating, not the 2 Mote of Light and 1 Fantastic Fur the
-- crafter supplies, 2026-10-11). A quality slot the form hasn't filled
-- (before you start the order, nothing is) counts at its lowest quality:
-- what you'd go and buy. Optional materials you've added count too.
-- Valued like RecordCraftLot, so the line matches History. Resourcefulness
-- isn't counted (it may give some back; History shows that as kept).
-- Returns { cost, complete, mats = { { itemID, qty, unit } }, provided =
-- { [itemID] = qty }, commission, rewards, rewardsValue }, or nil.

-- The recipe's required material slots: { { itemIDs, quantity } }. The
-- saved recipe, else the game's recipe data (as SaveRecipe reads it).
local function RequiredSlots(recipeID)
    local recipe = recipeID and GoldsmithDB.recipes[recipeID]
    if recipe and recipe.reagents and #recipe.reagents > 0 then
        return recipe.reagents, recipe.outputItemID
    end
    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not (ok and type(schematic) == "table") then return nil end
    local slots = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        if slot.required then
            local ids = {}
            for _, r in ipairs(slot.reagents or {}) do
                if r.itemID then table.insert(ids, r.itemID) end
            end
            if #ids > 0 then table.insert(slots, { itemIDs = ids, quantity = slot.quantityRequired or 0 }) end
        end
    end
    return slots, schematic.outputItemID
end

-- What the form's craft uses: { [itemID] = quantity } from the required
-- slots (the form's qualities, the lowest for what isn't allocated) and
-- any optional materials added; with slotOf ({ [itemID] = the slot's
-- itemIDs }), the output's item, and the form's list (for checking)
local function FormMaterials(recipeID, tx)
    local required, outputID = RequiredSlots(recipeID)
    if not required then return nil end

    -- What the form has allocated: { [itemID] = quantity }
    local allocated = {}
    local okA, list = pcall(tx.CreateCraftingReagentInfoTbl, tx)
    for _, entry in ipairs(okA and type(list) == "table" and list or {}) do
        local id = (type(entry.reagent) == "table" and entry.reagent.itemID) or entry.itemID
        if id and (entry.quantity or 0) > 0 then
            allocated[id] = (allocated[id] or 0) + entry.quantity
        end
    end

    local used, slotOf = {}, {}
    for _, slot in ipairs(required) do
        local ids = slot.itemIDs or {}
        for _, id in ipairs(ids) do slotOf[id] = ids end
        local counted = 0
        if #ids > 1 then
            for _, id in ipairs(ids) do
                if allocated[id] then
                    used[id] = (used[id] or 0) + allocated[id]
                    counted = counted + allocated[id]
                end
            end
        end
        local short = (slot.quantity or 0) - counted
        if short > 0 and ids[1] then
            used[ids[1]] = (used[ids[1]] or 0) + short
        end
    end
    -- Optional and finishing materials you've added
    for id, qty in pairs(allocated) do
        if not slotOf[id] then used[id] = (used[id] or 0) + qty end
    end
    return used, slotOf, outputID, okA and list or nil
end

-- One material at today's value, as the Crafts tab counts it (SlotCost):
-- the price, or making it yourself (milling, your crafts) when that's
-- cheaper, or what you paid when there's no price
local function TodaysUnit(id, name, outputID)
    local best = addon:GetMarketPrice(id, true)
    if name and id ~= outputID then
        for _, made in ipairs({ addon:GetMilledCost(name) or false, addon:GetCraftedCostByName(name) or false }) do
            if made and (not best or made < best) then best = made end
        end
    end
    return best or (name and addon:GetOwnCost(name, outputID, id))
end

-- What those materials cost you (GetOwnCost, else the price; or with
-- today: today's value, as in Crafts): cost, complete (all priced),
-- mats = { { itemID, qty, unit } } (dearest first)
local function ValueMaterials(used, outputID, today)
    local cost, complete, mats = 0, true, {}
    for id, qty in pairs(used) do
        if qty > 0 then
            local name = C_Item.GetItemNameByID(id)
            local unit
            if today then
                unit = TodaysUnit(id, name, outputID)
            else
                unit = (name and addon:GetOwnCost(name, outputID, id)) or addon:GetMarketPrice(id, true)
            end
            if unit then cost = cost + unit * qty else complete = false end
            table.insert(mats, { itemID = id, qty = qty, unit = unit })
        end
    end
    table.sort(mats, function(a, b) return (a.unit or 0) * a.qty > (b.unit or 0) * b.qty end)
    return cost, complete, mats
end

-- What the order's materials would cost at their lowest qualities, as the
-- orders list counts them (OrderList.lua), when the game filled a slot
-- from your bags with a dearer quality (user, 2026-10-18: holding only
-- gold Azeroot, a Hobbyist Scribe's Quill said 163.68g opened and about
-- 84g in the list, which looked like an error). Returns that cost and the
-- names of the dearer materials ("Azeroot (gold)"), or nil when the slots
-- already hold the cheapest, the gap is under 1g, or the order asks for a
-- quality (the cheapest might not reach it).
local QUALITY_NAMES = { [2] = { "silver", "gold" } }

local function CheapestQualities(used, slotOf, outputID, cost, order)
    if (order.minQuality or 0) > 1 then return nil end
    local cheap, pricier = {}, {}
    for id, qty in pairs(used) do
        local ids = slotOf[id]
        local lowest = ids and #ids > 1 and ids[1] or id
        cheap[lowest] = (cheap[lowest] or 0) + qty
        if lowest ~= id and qty > 0 then
            local index
            for i, other in ipairs(ids) do if other == id then index = i end end
            local names = QUALITY_NAMES[#ids]
            local quality = (names and index and names[index]) or ("tier " .. (index or "?"))
            table.insert(pricier, (C_Item.GetItemNameByID(id) or ("item " .. id)) .. " (" .. quality .. ")")
        end
    end
    if #pricier == 0 then return nil end
    local cheapest, complete = ValueMaterials(cheap, outputID)
    if not complete or cost - cheapest < 10000 then return nil end
    table.sort(pricier)
    return cheapest, pricier
end

function addon:GetOrderPreview(order, tx)
    if type(order) ~= "table" or not tx then return nil end
    local okR, recipeID = pcall(tx.GetRecipeID, tx)
    recipeID = (okR and recipeID) or order.spellID
    local used, slotOf, outputID, list = FormMaterials(recipeID, tx)
    if not used then return nil end

    local provided = GetProvided(order.reagents)
    -- For checking from the saved file if the line looks wrong
    GoldsmithDB.orderPreviewDebug = { time = time(), recipeID = recipeID,
        allocated = list and PlainCopy(list, 3) or nil, provided = provided,
        orderReagents = PlainCopy(order.reagents, 4) }
    TakeOffProvided(used, provided, slotOf)

    local cost, complete, mats = ValueMaterials(used, outputID)
    local rewards = GetOrderRewards(order)
    local result = {
        cost = cost, complete = complete, mats = mats, provided = provided,
        commission = math.max((order.tipAmount or 0) - (order.consortiumCut or 0), 0),
        rewards = rewards, rewardsValue = ValueRewards(rewards),
    }
    result.cheapest, result.pricier = CheapestQualities(used, slotOf, outputID, cost, order)
    GoldsmithDB.orderPreviewDebug.orderID = order.orderID
    GoldsmithDB.orderPreviewDebug.result = PlainCopy(result, 3)
    GoldsmithDB.orderPreviewDebug.npcOrderRewards = PlainCopy(order.npcOrderRewards, 3)
    return result
end

-- The same for an order in the game's list of orders, before it's opened
-- (OrderList.lua; user, 2026-10-18: see the rewards and the cost without
-- clicking into each one). No form yet, so every material you supply
-- counts at its lowest quality, as GetOrderPreview counts a quality slot
-- the form hasn't filled. Valued as GetOrderPreview values them (what yours
-- cost you, else the price), so the row and the opened order agree.
-- Returns the same table, plus learned (you know the recipe), or nil.
function addon:GetOrderListPreview(order)
    if type(order) ~= "table" or not order.spellID then return nil end
    local required, outputID = RequiredSlots(order.spellID)
    if not required then return nil end
    local used, slotOf = {}, {}
    for _, slot in ipairs(required) do
        local ids = slot.itemIDs or {}
        for _, id in ipairs(ids) do slotOf[id] = ids end
        if ids[1] and (slot.quantity or 0) > 0 then used[ids[1]] = (used[ids[1]] or 0) + slot.quantity end
    end
    local provided = GetProvided(order.reagents)
    TakeOffProvided(used, provided, slotOf)
    local cost, complete, mats = ValueMaterials(used, outputID)
    local rewards = GetOrderRewards(order)
    local okI, info = pcall(C_TradeSkillUI.GetRecipeInfo, order.spellID)
    local result = {
        cost = cost, complete = complete, mats = mats, provided = provided,
        commission = math.max((order.tipAmount or 0) - (order.consortiumCut or 0), 0),
        rewards = rewards, rewardsValue = ValueRewards(rewards),
        learned = okI and type(info) == "table" and info.learned or false,
    }
    -- A check saved on 2026-10-18, no longer needed: cleared from the file
    GoldsmithDB.orderListDebug = nil
    return result
end

-- The same for one of your own crafts in the game's profession window
-- (user, 2026-10-11: Box of Rocks isn't in Goldsmith, so what does it
-- cost?): every material is yours. outputItemID: the item at the quality
-- the window shows, if known. Valued as the Crafts tab does, so the two
-- agree (user, 2026-10-11: the window said 53.11g where Crafts said
-- 18.90g, as Sunglass Vials counted at what your own crafts cost, not
-- today's 2.75g): today's prices, and your multicraft and resourcefulness
-- averages (GetCraftModel). Returns { cost (after resourcefulness),
-- complete, mats (full quantities), saved (what resourcefulness saves on
-- average), itemID, perCraft (items a craft makes on average), base
-- (without multicraft), unitPrice (its price, nil if none), sellable
-- (false when it can't go on the AH) }, or nil for a recipe without
-- materials (salvage).
function addon:GetCraftPreview(tx, outputItemID)
    if not tx then return nil end
    local okR, recipeID = pcall(tx.GetRecipeID, tx)
    if not (okR and recipeID) then return nil end
    local used, _, outputID = FormMaterials(recipeID, tx)
    if not (used and next(used)) then return nil end
    local full, complete, mats = ValueMaterials(used, outputID, true)
    -- A recipe not learned yet too: without it, Amani Cornucopia was
    -- counted as making 1, not 2 (1,471g each against 682.01g in
    -- Crafts, user 2026-10-12)
    local recipe = GoldsmithDB.recipes[recipeID] or (GoldsmithDB.unlearned and GoldsmithDB.unlearned[recipeID])
    local itemID = outputItemID or outputID or (recipe and recipe.outputItemID)
    -- A bound box is worth what's inside once you've opened one
    local bound = itemID and addon:CanAuction(itemID) == false
    local _, opened = addon:GetBoxValue(itemID)
    local sellable = not bound or opened ~= nil
    local base = (recipe and recipe.outputQty) or 1
    local perCraft, useFactor = base, 1
    if recipe and recipe.reagents and #recipe.reagents > 0 then
        -- What the window has in it, not Goldsmith's finishing reagent pick
        local made, slots = addon:GetCraftModel(recipe, false, true)
        local first = slots[1]
        perCraft = made or base
        if first and (first.slot.quantity or 0) > 0 then useFactor = first.quantity / first.slot.quantity end
    end
    return {
        cost = full * useFactor, saved = full * (1 - useFactor), complete = complete, mats = mats,
        itemID = itemID, perCraft = perCraft, base = base,
        unitPrice = sellable and itemID and addon:GetMarketPrice(itemID) or nil,
        sellable = sellable,
        scrollMissing = not itemID and addon:EnchantScrollMissing(recipeID) or nil,
        -- A bound box: priced by what's inside, from this many opened
        opened = bound and opened or nil,
    }
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
                    local unit = (names[id] and addon:GetOwnCost(names[id], lot.itemID)) or addon:GetMarketPrice(id, true)
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
-- if the craft made nothing; for your own crafts also what it used up
-- ({ [itemID] = quantity }, resourcefulness returns taken off)
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
    -- Finishing and optional reagents: whatever else went in the craft.
    -- They weren't counted: a Glitter Skewers craft with a 533g Bazaar
    -- Bite was saved at 14g each and called a profit (user, 2026-10-17)
    for _, entry in ipairs(usedReagents or {}) do
        local id = (type(entry.reagent) == "table" and entry.reagent.itemID) or entry.itemID
        if id and not slotOf[id] and (entry.quantity or 0) > 0 then
            used[id] = (used[id] or 0) + entry.quantity
            names[id] = C_Item.GetItemNameByID(id)
            slotOf[id] = { id }
        end
    end

    TakeOffProvided(used, orderTerms and orderTerms.provided, slotOf)

    -- What a material is worth to you: what that exact item (its quality)
    -- cost you, or its price. By name it was the average of every quality:
    -- 2 silver Munsell Ink at 37.50g each (gold ones in the average) made a
    -- Missive cost 66g instead of about 40g (2026-10-10).
    local function UnitValue(id)
        return (names[id] and addon:GetOwnCost(names[id], resultData.itemID, id)) or addon:GetMarketPrice(id, true)
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
    -- What it used up, by item (after resourcefulness), and what each was
    -- valued at: so a cost can be checked or repaired later (none was kept
    -- before, so wrong lots couldn't be worked out again)
    lot.used, lot.values = {}, {}
    for id, qty in pairs(used) do
        if qty > 0 then
            lot.used[id] = qty
            lot.values[id] = UnitValue(id)
        end
    end
    if addon.RecordMaterialUse then addon:RecordMaterialUse(lot.used) end
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
            -- Patron (NPC) or a player's order (Lifetime.lua counts them apart)
            lot.orderType = orderTerms.orderType
            local rewardsValue = ValueRewards(orderTerms.rewards)
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
    -- Made while Goldsmith suggested it, up to the number suggested
    -- (TakeSuggested, GetFollowedSummary). The price it would sell for then
    -- is kept, to see later how the suggestion held up.
    if addon.TakeSuggested and addon:TakeSuggested(lot.name, lot.qty) then
        lot.suggested = true
        -- As plans price it: a spike counts at the usual price (PriceJump)
        local price, source = addon:GetMarketPriceInfo(resultData.itemID)
        lot.expectedPrice = addon:PriceJump(resultData.itemID, price, source) or price
        -- Checked now, so not again later against later prices
        lot.priceChecked = true
    end
    table.insert(lots, lot)
    while #lots > CRAFT_LOT_LIMIT do
        table.remove(lots, 1)
    end
    return lot, used
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
-- "crafted", or several joined with "+"), or nil; third, the parts:
-- { { source, copper per unit, units } } (the item tooltip lists them).
-- Your crafts cover what you hold first and purchases the rest: purchases
-- used to cover everything held, crafts included, so 8 crafted Mote of
-- Light were counted twice next to 161 held (2026-10-11).
-- excludeItemID leaves out that item's own crafts (so a craft's cost isn't
-- worked out from itself).
-- exactItemID: that one item (quality tier) only, not every quality with
-- the name: a craft's materials are valued this way (RecordCraftLot), so
-- silver ink isn't costed at the average with gold (2026-10-10).
-- How many of what you hold of one item are your own crafts: crafts,
-- purchases and gathering taken newest first together, up to what you
-- hold (the newest one when you hold none). Crafts used to come first
-- whatever their age, so one Sunglass Vial made at 70g on Oct 4 stayed
-- "held" after hundreds bought at 2.75g since, and yours cost 12.37g
-- each (user, 2026-10-11: "sunglass vial is a vendor item").
local function CraftedUnitsHeld(itemName, itemID, lots)
    local list = {}
    for _, lot in ipairs(lots) do
        list[#list + 1] = { time = lot.time or 0, qty = lot.qty or 0, crafted = true }
    end
    for _, e in ipairs(addon.ledger:index().purchases[itemName] or {}) do
        if e.itemID == itemID and (e.quantity or 0) > 0 then
            list[#list + 1] = { time = e.timestamp or 0, qty = e.quantity }
        end
    end
    for _, e in ipairs(addon.GatheredIndex and addon:GatheredIndex()[itemName] or {}) do
        if e.itemID == itemID then list[#list + 1] = { time = e.time or 0, qty = e.qty or 0 } end
    end
    table.sort(list, function(a, b) return a.time > b.time end)
    local remaining = math.max(addon.HeldAnywhere and addon:HeldAnywhere(itemID) or 0, 1)
    local crafted = 0
    for _, a in ipairs(list) do
        local take = math.min(a.qty, remaining)
        if a.crafted then crafted = crafted + take end
        remaining = remaining - take
        if remaining <= 0 then break end
    end
    return crafted
end

-- forSale: for a sale's profit (GetUnitCostBasis). What you gathered
-- yourself is free then: nothing counted its worth before, so selling it
-- is profit (user, 2026-10-11). What came out of a payout bag still counts
-- at its AH price: the order's profit counted the bag already. Crafting
-- with either keeps the AH price (what you could sell them for).
function addon:GetOwnCost(itemName, excludeItemID, exactItemID, forSale)
    local sources = {}
    local crafted, craftedQty
    if exactItemID then
        local lots = exactItemID ~= excludeItemID and GoldsmithDB.craftLots[exactItemID]
        local units = lots and #lots > 0 and CraftedUnitsHeld(itemName, exactItemID, lots) or 0
        if units > 0 then crafted, craftedQty = addon:GetCraftedCost(exactItemID, units) end
    else
        crafted, craftedQty = addon:GetCraftedCostByName(itemName)
        if excludeItemID and C_Item.GetItemNameByID(excludeItemID) == itemName then crafted = nil end
    end
    local paid, paidQty, _, gatheredIDs, ownIDs, uncovered, salvagedQty = addon:GetAcquiredCost(itemName, exactItemID, crafted and craftedQty)
    -- salvaged: how many of them came out of your own salvage runs, so the
    -- item page doesn't call butchered Plant Protein "bought" (2026-10-28)
    if paid then table.insert(sources, { "paid", paid, paidQty, salvaged = salvagedQty }) end
    if forSale and ownIDs and next(ownIDs) then
        local free, rest = 0, {}
        for id, n in pairs(gatheredIDs) do
            local own = ownIDs[id] or 0
            free = free + own
            if n - own > 0 then rest[id] = n - own end
        end
        if free > 0 then table.insert(sources, { "free", 0, free }) end
        gatheredIDs = rest
    end
    -- Gathered ones at today's AH price: what you could sell them for
    local gathered, gatheredQty = addon:GatheredValue(gatheredIDs)
    if gathered then table.insert(sources, { "gathered", gathered, gatheredQty }) end
    -- The all-time milling average only for what the dated lots above
    -- (purchases, gathering, your recent salvage runs) don't cover, and
    -- only for that many: it weighed every pigment ever milled against the
    -- few you hold
    local milled, milledQty = addon:GetMilledCost(itemName)
    if milled and paid == nil and #sources == 0 and not gatheredIDs then
        table.insert(sources, { "milled", milled, milledQty })
    elseif milled and (uncovered or 0) > 0 then
        table.insert(sources, { "milled", milled, math.min(milledQty, uncovered) })
    end
    if crafted then
        table.insert(sources, { "crafted", crafted, craftedQty })
    end
    if #sources == 0 then return nil end

    local total, qty, labels = 0, 0, {}
    for _, s in ipairs(sources) do
        total = total + s[2] * s[3]
        qty = qty + s[3]
        table.insert(labels, s[1])
    end
    return total / qty, table.concat(labels, "+"), sources
end

-- Unit cost of one reagent slot, the cheapest of its qualities, for
-- deciding what's worth crafting (the Crafts list, Do this next):
--   - today's price (the AH, or the vendor when it's cheaper): what the
--     materials you hold could be sold for, so what using them costs
--   - crafting it now from today's prices, when that's cheaper
--   - with no price today: what making it yourself cost (your milling or
--     crafts), then what you paid
-- What you paid used to come first, so a held Petrified Root counted at
-- 331g here and 340g in the planner (user, 2026-10-09: one basis, today's
-- price). Making it yourself used to win when cheaper too: Plant Protein
-- at 3.1g from slabs bought last week, while it sold for 6.35g, had 11
-- Impossibly Royal Roasts recommended that turned 1,000g of protein into
-- 580g of roasts (user, 2026-10-22: always the best way to make gold).
-- Plans and notices show what you paid (Planner.lua NodeCost).
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
        -- Worked out without crafting (CraftUnitCost busy): not kept
        if not addon.craftUnitBusy then store[slot] = cached end
    end
    return cached[1], cached[2], cached[3], cached[4]
end

SlotCost = function(slot)
    local best, bestSource, bestName, bestID
    -- Today's price: the AH, or the vendor when it's cheaper. Recipes saved
    -- before item IDs were stored have no itemIDs until re-crafted.
    for i, itemID in ipairs(slot.itemIDs or {}) do
        local price, source = addon:GetMarketPriceInfo(itemID)
        if price and (not best or price < best) then
            best, bestName, bestID = price, slot.names[i], itemID
            bestSource = source == "Vendor" and "vendor" or "AH price"
        end
    end
    -- Crafting it now from today's prices, when that's cheaper, as the plan
    -- would (Planner.lua): a gold vial listed at 293g that crafts for 49g
    for i, itemID in ipairs(slot.itemIDs or {}) do
        local made = addon.CraftUnitCost and addon:CraftUnitCost(itemID, slot.names[i])
        if made and (not best or made < best) then
            best, bestSource, bestName, bestID = made, "craft it", slot.names[i], nil
        end
    end
    -- Salvaging for it (milling, butchering) when that beats the rest by
    -- the plan's margin, as the plan would (SalvageUnitCost)
    for i, itemID in ipairs(slot.itemIDs or {}) do
        local unit, margin
        if addon.SalvageUnitCost then unit, margin = addon:SalvageUnitCost(itemID, slot.names[i]) end
        if unit and (not best or unit * (1 + margin) < best) then
            best, bestSource, bestName, bestID = unit, "salvage it", slot.names[i], nil
        end
    end
    if best then
        return best, bestSource, bestName, bestSource == "AH price" and bestID or nil
    end
    -- No price today at all: what making it yourself cost
    for _, name in ipairs(slot.names) do
        local milled = addon:GetMilledCost(name)
        local crafted = addon:GetCraftedCostByName(name)
        for _, made in ipairs({ { milled, "milled" }, { crafted, "crafted" } }) do
            if made[1] and (not best or made[1] < best) then
                best, bestSource, bestName, bestID = made[1], made[2], name, nil
            end
        end
    end
    if best then return best, bestSource, bestName end
    -- No price at all: what you paid
    for _, name in ipairs(slot.names) do
        local cost, source = addon:GetOwnCost(name)
        if cost and (not best or cost < best) then
            best, bestSource, bestName = cost, source, name
        end
    end
    if best then return best, bestSource, bestName end
end

-- Cheapest known unit cost for a recipe slot (see SlotCost), for other
-- files. Returns cost and source, or nil.
function addon:GetSlotUnitCost(slot)
    local cost, source = GetSlotCost(slot)
    return cost, source
end

-- Finishing reagents: per slot, the one whose extra profit per craft beats
-- its cost by the most, or none (user, 2026-10-17: cooking's Bazaar Bites,
-- Earthy Garnish and Savory Anomaly). Its value per craft:
--   extra items from its multicraft x the item's price after the AH cut
--   + materials its resourcefulness saves x what they cost
--   - the reagent
-- Skill and ingenuity aren't valued yet (quality and concentration plans
-- don't try reagents), so one that only adds those is never picked.
-- Valued at the item's price (for quality crafts, the recipe's item), with
-- the profession's calibrated proc sizes: a Bazaar Bites multicraft is
-- valued as an ordinary one until crafts teach otherwise.
-- Your pick on the plan (ui2.finishing[recipeID] = itemID, or false for
-- none) wins. Returns { multicraft, resourcefulness, ingenuity (with the
-- picks), picks = { { slot, option } }, options = { { option, slot, unit,
-- value, picked } } }; cached until data changes.
local finishingSlots = {}
local finishingCache = addon:NewCache()

-- A finishing reagent as a material slot, the same table each time (slot
-- costs are cached by table)
-- Priced by item ID, so it doesn't wait for the name: waiting, Amani
-- Cornucopia was costed without Bazaar Bites after a /reload (574.42g, not
-- 284.67g; user, 2026-10-27). A stand-in name until the game sends it
-- (RequestItem refreshes then), filled into the same table.
local FINISHING_NAME = "Finishing reagent"
local function FinishingSlot(o)
    local key = o.itemID .. "x" .. o.quantity
    local slot = finishingSlots[key]
    if not slot then
        slot = { names = { FINISHING_NAME }, itemIDs = { o.itemID }, quantity = o.quantity, finishing = true }
        finishingSlots[key] = slot
    end
    if slot.names[1] == FINISHING_NAME then
        local name = C_Item.GetItemNameByID(o.itemID)
        if name then slot.names[1] = name else RequestItem(o.itemID) end
    end
    return slot
end

ChooseFinishing = function(recipe, stats)
    local store = finishingCache:Get()
    local cached = store[stats]
    if cached ~= nil then return cached or nil end

    local mcExtra, resSave, calibration = GetCalibration(recipe.profession)
    -- Extra items per craft (times normal output) from multicraft: without a
    -- reagent, and with one, blended with its own crafts once there are
    -- some (FinishingCrafted), the way proc sizes are learned
    local baseRatio = stats.multicraft / 100 * mcExtra
    local function OptionRatio(o)
        local prior = o.multicraft / 100 * mcExtra
        local learned = calibration and calibration.finishing and calibration.finishing[o.itemID]
        if learned and learned.crafts > 0 and o.multicraft > stats.multicraft + 1 then
            return (prior * PRIOR_WEIGHT + learned.extraRatio) / (PRIOR_WEIGHT + learned.crafts), learned.crafts
        end
        return prior
    end
    local price = recipe.outputItemID and addon:GetMarketPrice(recipe.outputItemID)
    local materials = 0
    for _, slot in ipairs(recipe.reagents or {}) do
        local cost = GetSlotCost(slot)
        if cost then materials = materials + cost * slot.quantity end
    end
    local yours = GoldsmithDB.ui2 and GoldsmithDB.ui2.finishing and GoldsmithDB.ui2.finishing[recipe.recipeID]
    local result = { multicraft = stats.multicraft, resourcefulness = stats.resourcefulness,
        ingenuity = stats.ingenuity, picks = {}, options = {}, yours = yours,
        recipeID = recipe.recipeID, base = stats, priced = price ~= nil, extraRatio = baseRatio }
    local bySlot, order = {}, {}
    -- A reagent whose details the game hasn't sent yet (right after a
    -- /reload) can't be priced: the choice isn't kept, so it's made again
    -- once they arrive. Kept, it stayed "none, not worth it" all session:
    -- Silvermoon Parade lost its Bazaar Bites, about 700g of profit, after
    -- a /reload (user, 2026-10-24)
    local unready = false
    for _, o in ipairs(stats.finishing) do
        if not bySlot[o.dataSlotIndex] then
            bySlot[o.dataSlotIndex] = {}
            table.insert(order, o.dataSlotIndex)
        end
        local slot = FinishingSlot(o)
        if not slot then unready = true end
        local unit = slot and GetSlotCost(slot)
        local ratio, learnedCrafts = OptionRatio(o)
        local extraItems = (recipe.outputQty or 1) * (ratio - baseRatio)
        local value
        if unit and price then
            local saved = (o.resourcefulness - stats.resourcefulness) / 100 * resSave * materials
            value = extraItems * price * (1 - AH_CUT) + saved - unit * o.quantity
        end
        local entry = { option = o, slot = slot, unit = unit, value = value, ratio = ratio,
            extraItems = extraItems, learnedCrafts = learnedCrafts }
        table.insert(bySlot[o.dataSlotIndex], entry)
        table.insert(result.options, entry)
    end
    for _, index in ipairs(order) do
        local pick
        for _, entry in ipairs(bySlot[index]) do
            if yours == entry.option.itemID and entry.slot then
                pick = entry
                break
            elseif yours == nil and entry.value and entry.value > 0 and (not pick or entry.value > pick.value) then
                pick = entry
            end
        end
        if pick then
            pick.picked = true
            local o = pick.option
            result.multicraft = result.multicraft + o.multicraft - stats.multicraft
            result.resourcefulness = result.resourcefulness + o.resourcefulness - stats.resourcefulness
            result.ingenuity = result.ingenuity + o.ingenuity - stats.ingenuity
            result.extraRatio = result.extraRatio + pick.ratio - baseRatio
            table.insert(result.picks, { slot = pick.slot, option = o })
        end
    end
    if not unready then store[stats] = result end
    return result
end

-- The finishing reagent choice for a recipe, with the crafter's stats (run
-- in WithCharacter for someone else's), or nil when it has none
function addon:GetFinishingChoice(recipe)
    local stats = recipe and recipe.recipeID and addon:StatsChar().recipeStats[recipe.recipeID]
    return stats and stats.finishing and ChooseFinishing(recipe, stats) or nil
end

-- /gsm finishing <craft name> (dev tools): the finishing reagent choice for
-- the craft's crafter, option by option, for when one isn't counted (Amani
-- Cornucopia without Bazaar Bites after a /reload, 2026-10-27)
function addon:PrintFinishing(name)
    name = name and strtrim(name) or ""
    if name == "" then name = "Amani Cornucopia" end
    for _, recipe in pairs(GoldsmithDB.recipes) do
        if recipe.outputName and recipe.outputName:lower() == name:lower() then
            local key = addon:GetCrafter(recipe.recipeID) or addon.charKey
            addon:WithCharacter(key, function()
                local stats = addon:StatsChar().recipeStats[recipe.recipeID]
                print(string.format("Goldsmith: %s on %s: stats %s, finishing options %d", recipe.outputName, key,
                    stats and "yes" or "NO", stats and stats.finishing and #stats.finishing or 0))
                local c = addon:GetFinishingChoice(recipe)
                if not c then return end
                print(string.format("  picks %d, output priced %s, your pick %s, cost %s", #c.picks, tostring(c.priced),
                    tostring(c.yours), addon:FormatMoney((addon:GetRecipeCost(recipe)) or 0)))
                for _, e in ipairs(c.options) do
                    local id = e.option.itemID
                    print(string.format("  %s %s: %s, unit %s, value %s, ratio %.2f%s", id,
                        C_Item.GetItemNameByID(id) or "(not loaded)", e.slot and "slot" or "NO SLOT",
                        e.unit and addon:FormatMoney(e.unit) or "nil", e.value and addon:FormatSignedMoney(e.value) or "nil",
                        e.ratio or 0, e.picked and ", PICKED" or ""))
                end
            end)
            return
        end
    end
    print("Goldsmith: no craft named " .. name)
end

-- Your pick of finishing reagent for a recipe: an item ID, false for none,
-- or nil to let Goldsmith choose
function addon:SetFinishingPick(recipeID, pick)
    GoldsmithDB.ui2.finishing = GoldsmithDB.ui2.finishing or {}
    GoldsmithDB.ui2.finishing[recipeID] = pick
    addon:DataChanged()
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
    local price, priceSource, priceAge, priceNote = addon:GetMarketPriceInfo(priceItemID)
    local usual, jumped = addon:PriceJump(priceItemID, price, priceSource)
    if usual then price, priceNote = usual, jumped end
    local demand, demandSource = addon:GetDemand(priceItemID, recipe.outputName)
    local profit, margin
    if price then
        profit = price * (1 - AH_CUT) - cost
        margin = cost > 0 and (profit / cost * 100) or nil
    end
    local info = {
        cost = cost,
        missing = missing,
        partial = #missing > 0,
        breakdown = breakdown,
        stats = stats,
        price = price,
        priceSource = priceSource,
        priceAge = priceAge,
        priceNote = priceNote,
        jumped = jumped,
        priceAgeText = price and addon:PriceAgeText(priceItemID),
        demand = demand,
        demandSource = demandSource,
        saleRate = addon:GetSaleRate(priceItemID),
        profit = profit,
        margin = margin,
    }
    addon:DoubtPrice(info, priceItemID, recipe.outputName)
    return info
end

-- What one unit of an item cost you, for working out profit on a sale:
-- the craft cost for things you make, otherwise what you paid or milled.
-- Returns cost per unit and whether it's partial (some material costs
-- unknown), or nil if there's no cost data at all.
-- Also returns where the cost came from: "free" (marked as loot or a
-- reward), "crafted" (your crafts of it), "paid" (what you paid, milled or
-- gathered) or "estimated" (the recipe at today's prices: you didn't craft
-- or buy these while Goldsmith was watching).
-- itemID (optional): the exact item, when a sale matched your post
-- (MatchSaleToPost): its own crafts and purchases only, so silver and gold
-- of the same item aren't blended (user, 2026-10-10).
-- The selling character's own ways of getting an item, newest first, when
-- they cover the units sold: what they gathered themselves is free, payout
-- bag loot counts at its AH price, a crafted box's loot and purchases at
-- what they cost. Returns cost per unit and "free" or "paid", or nil (then
-- every character's stock is used, GetOwnCost). Raikozaan's own herbs were
-- costed at the average with Mysticmead's purchases and bouquet herbs
-- (user, 2026-10-12: Sanguithorn 0.38g, Mana Lily 1.29g, Tranquility Bloom
-- 1.32g, all gathered by the seller).
local function SellerCost(itemName, units, itemID)
    if not itemID then return nil end
    local me, realm = UnitName("player"), GetRealmName()
    local list = {}
    for _, e in ipairs(addon.ledger:index().purchases[itemName] or {}) do
        if e.itemID == itemID and e.character == me and (not e.realm or e.realm == realm) and (e.quantity or 0) > 0 then
            list[#list + 1] = { time = e.timestamp or 0, qty = e.quantity, each = (e.totalCopper or 0) / e.quantity }
        end
    end
    for _, e in ipairs(addon.GatheredIndex and addon:GatheredIndex()[itemName] or {}) do
        if e.itemID == itemID and e.character == me and e.realm == realm and (e.qty or 0) > 0 then
            local each, free = 0, true
            if e.box then
                each, free = (e.cost and (e.costQty or 0) > 0) and e.cost / e.costQty or 0, false
            elseif e.payout then
                -- What it was worth when the bag gave it (the order counted
                -- it then), as order rewards (RewardCost): today's price
                -- made 5 Tranquility Bloom from a patron bag read -3.24g
                -- (user, 2026-10-27)
                each = (e.value and e.value > 0) and e.value / e.qty or addon:GetMarketPrice(itemID) or 0
                free = false
            end
            list[#list + 1] = { time = e.time or 0, qty = e.qty, each = each, free = free }
        end
    end
    if #list == 0 then return nil end
    table.sort(list, function(a, b) return a.time > b.time end)
    local need, covered, total, allFree = math.max(units or 1, 1), 0, 0, true
    for _, a in ipairs(list) do
        local take = math.min(a.qty, need - covered)
        total, covered = total + take * a.each, covered + take
        if not a.free then allFree = false end
        if covered >= need then break end
    end
    if covered < need then return nil end
    return total / covered, allFree and "free" or "paid"
end

-- A crafting order's reward you sell: what the order counted it at (its
-- AH price then), newest rewards first. That value is already in the
-- order's profit, so the sale's profit is only what it sold for over it.
-- A Void-Touched Augment Rune sold for 1,115.92g read "no cost" and was
-- left out of the mail's total; the order counted it at 367.77g (user,
-- 2026-10-27). before: only orders finished by then (a sale's time).
local function RewardCost(itemName, units, itemID, before)
    local need, covered, total = math.max(units or 1, 1), 0, 0
    local lots = GoldsmithDB.orderCrafts or {}
    -- A sale without its item: the ID from a reward with that name (some
    -- were saved without a link, so they're matched by ID)
    for i = #lots, 1, -1 do
        if itemID then break end
        for _, r in ipairs(lots[i].rewards or {}) do
            local name = (r.link and r.link:match("%[(.-)%]")) or (r.itemID and C_Item.GetItemNameByID(r.itemID))
            if name == itemName then itemID = r.itemID break end
        end
    end
    if not itemID then return nil end
    for i = #lots, 1, -1 do
        for _, r in ipairs((not before or (lots[i].time or 0) <= before) and lots[i].rewards or {}) do
            local same = r.itemID == itemID
            if same and (r.count or 0) > 0 then
                local take = math.min(r.count, need - covered)
                total, covered = total + take * (addon:RewardValueNow(r) / r.count), covered + take
                if covered >= need then return total / covered end
            end
        end
    end
end

function addon:GetUnitCostBasis(itemName, units, itemID)
    if GoldsmithDB.freeItems and GoldsmithDB.freeItems[itemName] then
        return 0, false, "free"
    end
    -- Items you crafted: what your latest crafts actually cost
    if itemID and GoldsmithDB.craftLots[itemID] then
        -- Averaged over all you held before this sale (the ones on the AH
        -- included), not just the newest craft: selling 1 of 4 Missives
        -- took only the newest craft's cost
        local cover = math.max(addon.GetHeld and addon:GetHeld(itemID) or 0, units or 1)
        local crafted, _, craftedPartial = addon:GetCraftedCost(itemID, cover)
        if crafted then return crafted, craftedPartial, "crafted" end
    end
    local crafted, _, craftedPartial = addon:GetCraftedCostByName(itemName, units)
    if crafted then
        return crafted, craftedPartial, "crafted"
    end
    -- What you paid before what making it would cost: 100 Crystalline
    -- Glass bought at 13.79g were recorded as sold at a cost of 119.86g each
    -- (its recipe's estimate), a 10,000g loss that was really about 200g
    -- (2026-10-10)
    local mine, mineSource = SellerCost(itemName, units, itemID)
    if mine then return mine, false, mineSource end
    local own, ownSource = addon:GetOwnCost(itemName, nil, itemID, true)
    if own then
        return own, false, ownSource == "free" and "free" or "paid"
    end
    local reward = RewardCost(itemName, units, itemID)
    if reward then return reward, false, "reward" end
    local recipe = addon:FindRecipeByOutput(itemName)
    if recipe then
        local cost, missing = addon:GetRecipeCost(recipe)
        return cost, #missing > 0, "estimated"
    end
end

-- Sales saved before the fix to value materials by item (2026-10-10) with a recipe estimate though you had bought
-- the item: their cost becomes what you paid, from the newest purchases
-- before the sale that cover it. Runs once (estimatedSalesRepaired).
-- Returns how many sales changed.
function addon:RepairEstimatedSales()
    if GoldsmithDB.estimatedSalesRepaired then return 0 end
    local purchases = addon.ledger:index().purchases
    local changed = 0
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.type == "REVENUE" and e.costSource == "estimated" and e.item and (e.quantity or 0) > 0 then
            local paid, units = 0, 0
            local list = purchases[e.item] or {}
            for i = #list, 1, -1 do
                local p = list[i]
                if (p.timestamp or 0) <= e.timestamp and (p.quantity or 0) > 0 then
                    paid, units = paid + p.totalCopper, units + p.quantity
                    if units >= e.quantity then break end
                end
            end
            if units > 0 then
                e.costBasis = math.floor(paid / units * e.quantity + 0.5)
                e.costSource = "paid"
                changed = changed + 1
            end
        end
    end
    GoldsmithDB.estimatedSalesRepaired = true
    return changed
end

-- Sales of order rewards saved with no cost before RewardCost (2026-10-27)
-- get what an order finished before the sale counted them at. Runs once
-- (rewardSalesRepaired = 2). The first version (true) took the newest
-- order for every sale, even ones from before it: those are redone, and
-- left with no cost when no order came first.
function addon:RepairRewardSales()
    if GoldsmithDB.rewardSalesRepaired == 2 then return 0 end
    local changed = 0
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.type == "REVENUE" and (not e.costBasis or e.costSource == "reward") and e.item and (e.quantity or 0) > 0 then
            local unit = RewardCost(e.item, e.quantity, e.itemID, e.timestamp)
            if unit then
                e.costBasis, e.costSource = math.floor(unit * e.quantity + 0.5), "reward"
                changed = changed + 1
            elseif e.costSource == "reward" then
                e.costBasis, e.costSource = nil, nil
                changed = changed + 1
            end
        end
    end
    GoldsmithDB.rewardSalesRepaired = 2
    return changed
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

-- An item's name even while the game hasn't loaded it: the game's, else the
-- name saved with your recipes (as a material or what one makes), else
-- "item 12345". Asks the game to load it for next time. ("item 242606"
-- showed in a plan's old-prices warning, 2026-10-10.)
local knownNames, knownNamesVersion
function addon:KnownItemName(itemID)
    if not itemID then return nil end
    local name = C_Item.GetItemNameByID(itemID)
    if name then return name end
    if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    if not knownNames or knownNamesVersion ~= addon.recipesVersion then
        knownNames, knownNamesVersion = {}, addon.recipesVersion
        for _, recipe in pairs(GoldsmithDB.recipes) do
            if recipe.outputItemID and recipe.outputName then knownNames[recipe.outputItemID] = recipe.outputName end
            for _, slot in ipairs(recipe.reagents or {}) do
                for i, id in ipairs(slot.itemIDs or {}) do
                    if slot.names and slot.names[i] then knownNames[id] = knownNames[id] or slot.names[i] end
                end
            end
        end
    end
    return knownNames[itemID] or ("item " .. itemID)
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

-- Detail lines (grey, indented: where a number comes from, whose stats,
-- the AH price under the profit) show only while Ctrl is held; the item
-- tooltip then ends with one "Hold Ctrl for details" line instead (user,
-- 2026-10-11). In Goldsmith's own hovers (the Crafts tab shares
-- AddRecipeTooltipLines) they're explanations like any other (addon:Explain).
local detailHidden = false
local function Detail(tooltip, text)
    if IsControlKeyDown() then
        tooltip:AddLine("  " .. text, 0.6, 0.6, 0.6)
    else
        detailHidden = true
        addon:Explain(tooltip, text)
    end
end

local function AddTooltipLines(tooltip, data)
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    if not addon.ledger or not data or not data.id then return end
    local mode = addon:Setting("tooltips")
    if mode == "off" then return end
    detailHidden = false

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

    -- What yours cost you: this exact quality, counted the way every cost
    -- is (GetOwnCost, so it matches the order line and History): your
    -- crafts, the purchases covering the rest of what you hold, and
    -- gathered ones at their AH price (user, 2026-10-11: "we are looking
    -- for cost not spent"; the tooltip had them free, the order line not).
    -- By name if nothing has this item ID (purchases saved before IDs were).
    -- Where it comes from is a detail line: "50 bought at 2.06g, 14
    -- gathered (worth 2.06g, cost you nothing)".
    local own, ownSource, parts = addon:GetOwnCost(name, nil, data.id)
    if not own then own, ownSource, parts = addon:GetOwnCost(name) end
    local madeFor, _, madePartial = addon:GetCraftedCost(data.id)
    local ownPartial = madeFor and madePartial
    if own then
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r yours cost you",
            string.format("%s%s each", FormatGold(own), ownPartial and "+" or ""), 1, 1, 1, 1, 1, 1)
        if not short then
            local list = {}
            for _, p in ipairs(parts or {}) do
                local n, unit = math.floor(p[3] + 0.5), FormatGold(p[2])
                if p[1] == "gathered" then
                    table.insert(list, string.format("%d gathered (worth %s, cost you nothing)", n, unit))
                elseif p[1] == "crafted" then
                    table.insert(list, string.format("%d crafted at %s", n, unit))
                elseif p[1] == "milled" then
                    table.insert(list, string.format("%d milled at %s", n, unit))
                else
                    table.insert(list, string.format("%d bought at %s", n, unit))
                end
            end
            if #list > 0 then Detail(tooltip, table.concat(list, ", ")) end
        end
    end
    -- Today's AH price, for things you don't craft (crafted items show it
    -- under their profit), when Auctionator or TSM aren't there to show it
    if not recipe and not addon:HasAuctionator() and not addon:HasTSM() then
        local price = addon:GetAHPrice(data.id)
        if price then
            tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r AH price",
                string.format("%s (%s)", FormatGold(price), addon:AHPriceAgeText(data.id) or "?"), 1, 1, 1, 1, 1, 1)
        end
    end

    -- No salvage yields here: they're for planning in Goldsmith (Crafts'
    -- salvage rows, /gsm milling), not for a bag hover (user, 2026-10-11).
    -- A pigment's milled cost is part of "yours cost you" above.

    -- Today's price vs its usual price, once there's enough history
    local insight = addon:GetPriceInsight(data.id)
    if insight then
        local pct = insight.diff * 100
        local r, g, b = 0.8, 0.8, 0.8
        if pct <= -15 then r, g, b = 0.3, 1, 0.3 elseif pct >= 15 then r, g, b = 1, 0.6, 0.2 end
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r vs usual price",
            string.format("%+.0f%% (usual %s, %s)", pct, FormatGold(insight.usual),
                insight.regional and "region, 7 days" or (insight.days .. " days")),
            1, 1, 1, r, g, b)
    end
    if short then return end

    -- Lowest AH listing price that doesn't lose money after the AH cut, from
    -- what yours cost you. Not when all of it was gathered: that's just the
    -- AH price plus the cut, and any sale is gold you didn't have
    -- (Nocturnal Lotus from a payout bag, 2026-10-09).
    if own and own > 0 and ownSource ~= "gathered" then
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r break-even on yours",
            FormatGold(own / (1 - AH_CUT)) .. (ownPartial and "+" or ""), 1, 1, 1, 1, 1, 1)
    elseif not own then
        -- None of yours: from the estimated cost (a recipe you haven't
        -- crafted yet)
        local unitCost, partial = addon:GetUnitCostBasis(name)
        if unitCost and unitCost > 0 then
            tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r break-even price",
                FormatGold(unitCost / (1 - AH_CUT)) .. (partial and "+" or ""), 1, 1, 1, 1, 1, 1)
        end
    end

    if recipe then
        addon:WithCharacter(crafter, addon.AddRecipeTooltipLines, addon, tooltip, recipe, data.id, IsShiftKeyDown())
        if crafter ~= addon.charKey then
            local c = GoldsmithDB.characters[crafter]
            local better = addon:BetterCrafterText(recipe.recipeID)
            Detail(tooltip, string.format("Made on %s%s", c and c.name or crafter,
                better and (", " .. better) or ""))
        end
    end
    -- One hint in place of the hidden lines; the Shift breakdown is
    -- named too, its own hint being one of them
    if detailHidden then
        tooltip:AddLine(recipe and "  Hold Ctrl for details, Shift for material costs" or "  Hold Ctrl for details",
            0.6, 0.6, 0.6)
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
    -- "Now": today's prices and your stats, unlike "yours cost you" above
    tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r cost to craft now", costText, 1, 1, 1, 1, 1, 1)

    -- Profit if sold at the current AH price, after the AH cut
    if info.profit then
        local r, g, b = 0.3, 1, 0.3
        if info.profit < 0 then r, g, b = 1, 0.3, 0.3 end
        local profitText = string.format("%s%s each", info.profit >= 0 and "+" or "-", FormatGold(math.abs(info.profit)))
        if info.margin then
            -- Toward zero, as in the Crafts tab
            local m = info.margin >= 0 and math.floor(info.margin) or math.ceil(info.margin)
            profitText = profitText .. string.format(" (%d%%)", m)
        end
        -- Unknown costs can only lower the profit, so it's an upper bound
        local label = info.partial and "|cFF00FF00Goldsmith|r profit crafting now (at most)"
            or "|cFF00FF00Goldsmith|r profit crafting now"
        tooltip:AddDoubleLine(label, profitText, 1, 1, 1, r, g, b)
        -- Without Auctionator or TSM the price itself, not just its age:
        -- nothing else in the tooltip shows it then (2026-10-09). A line of
        -- its own, not a Ctrl detail: the profit is that price less the
        -- cost (user, 2026-10-11: "can it show the AH price?")
        if not short then
            if addon:HasAuctionator() or addon:HasTSM() then
                Detail(tooltip, "AH price " .. info.priceAgeText)
            else
                tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r AH price",
                    string.format("%s each (%s)", FormatGold(info.price), info.priceAgeText), 1, 1, 1, 1, 1, 1)
            end
        end
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
        Detail(tooltip, string.format("%s: %s - %.2f made per craft", whose,
            #parts > 0 and table.concat(parts, ", ") or "no multicraft or resourcefulness",
            outputPerCraft))
    else
        Detail(tooltip, "Base recipe numbers (older recipes have no multicraft or resourcefulness)")
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
        Detail(tooltip, "Hold Shift for material costs")
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
-- 2 ms a frame: at 130 fps a frame is under 8 ms, and 5 took it to about
-- 50 while the scan ran (user, 2026-10-19). Slower, but in the background.
local FRAME_BUDGET_MS = 2
-- Stats are read again when a profession window opens only after
-- something that changes them (skill, knowledge, gear), or an hour on
-- (prices pick which mixes are tried): every open re-read every recipe
local STATS_STALE = 3600
-- A slice every STEP_GAP seconds, not every frame: even 2 ms a frame
-- was felt on the first open after a reload (user, 2026-10-19). Most
-- frames are left alone; the scan takes longer, in the background.
local STEP_GAP = 0.05
local statsDirty, statsReadAt = true, 0
local scanTimer = nil
local scanning = false
local triedThisSession = {}
local statsReadThisSession = {}

local function CountRecipes()
    local n = 0
    for _ in pairs(GoldsmithDB.recipes) do n = n + 1 end
    return n
end

-- A saved recipe no character has learned: clicking one in the profession
-- window used to save it with the learned ones, where it showed nowhere
-- (Null and Void Plate, user 2026-10-12)
local function KnownByAnyone(recipeID)
    for _, c in pairs(GoldsmithDB.characters) do
        if c.knownRecipes and c.knownRecipes[recipeID] then return true end
    end
    return false
end

local function ScanLearnedRecipes()
    scanTimer = nil
    if scanning then return end
    -- Not during the tour: the sample has no recipe tables of yours, and
    -- what was saved would go with it ("bad argument to pairs" in
    -- MatchEnchantScrolls with a profession open in the tour; user,
    -- 2026-10-24). The next profession window after the tour reads them.
    if TourPrices() then return end

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
        -- Seen unlearned earlier this session and learned since (from a
        -- trainer, where NEW_RECIPE_LEARNED doesn't always come): looked at
        -- again, so it's marked known without a reload (Braised Blood
        -- Hunter, user 2026-10-12)
        if triedThisSession[id] and not addon.char.knownRecipes[id] then
            local info = C_TradeSkillUI.GetRecipeInfo(id)
            if info and info.learned then triedThisSession[id], statsReadThisSession[id] = nil, nil end
        end
        if not statsReadThisSession[id] and not triedThisSession[id] then
            local info = C_TradeSkillUI.GetRecipeInfo(id)
            local learned = info and info.learned
            if learned then
                addon:MarkRecipeKnown(id)
            end
            if info and not learned and GoldsmithDB.recipes[id] and not KnownByAnyone(id) then
                -- Saved but nobody knows it: moved to the ones not learned
                GoldsmithDB.recipes[id] = nil
                addon.recipesVersion = addon.recipesVersion + 1
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
    -- Stats run as a coroutine that can stop for the frame partway through
    -- a recipe: one recipe's tiers and mixes are 20 to 40 calls to the game,
    -- more than a frame's budget on their own, and checking only between
    -- recipes dropped frames for about 10 s after opening Blacksmithing
    -- (user, 2026-10-19)
    local statsCo, sliceStart
    addon.TierYield = function()
        if statsCo and coroutine.running() == statsCo and debugprofilestop() - sliceStart >= FRAME_BUDGET_MS then
            coroutine.yield()
        end
    end
    local function Step()
        -- Stats first: they update costs for recipes you have
        if toStats[statsIndex] or statsCo then
            statsCo = statsCo or coroutine.create(function()
                while toStats[statsIndex] do
                    addon:RefreshRecipeStats(toStats[statsIndex])
                    statsIndex = statsIndex + 1
                    addon.TierYield()
                end
            end)
            -- For /gsm perf only (user, 2026-10-19: no progress shown to
            -- players, who have nothing to wait for): how long the read
            -- took, its work, and its longest slice and where
            local rec = addon.lastRecipeScan
            if not rec or rec.done then
                rec = { recipes = #toStats, at = time(), started = GetTime(), slices = 0, busyMs = 0, longestMs = 0 }
                addon.lastRecipeScan = rec
            end
            local recipeBefore = toStats[statsIndex]
            sliceStart = debugprofilestop()
            local ok, err = coroutine.resume(statsCo)
            local ms = debugprofilestop() - sliceStart
            rec.slices, rec.busyMs = rec.slices + 1, rec.busyMs + ms
            if ms > rec.longestMs then rec.longestMs, rec.longestRecipe = ms, recipeBefore end
            if not ok then
                -- Skip the rest rather than stop the scan
                statsCo, statsIndex = nil, #toStats + 1
                geterrorhandler()(err)
            elseif coroutine.status(statsCo) == "dead" then
                statsCo = nil
            end
            if not statsCo then
                rec.done, rec.seconds = true, GetTime() - rec.started
            end
            C_Timer.After(STEP_GAP, Step)
            return
        end
        local start = debugprofilestop()
        -- Then recipes not learned yet (their stats too, so a slice each)
        while toUnlearned[1] and debugprofilestop() - start < FRAME_BUDGET_MS do
            SaveRecipe(table.remove(toUnlearned, 1), true, 1, nil, true)
        end
        if toUnlearned[1] then
            C_Timer.After(STEP_GAP, Step)
            return
        end

        for _ = 1, SCAN_BATCH do
            local id = toSave[i]
            if not id then
                scanning = false
                addon.TierYield = nil
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
        C_Timer.After(STEP_GAP, Step)
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

    -- Professions without concentration: drop what was saved for them
    for profession in pairs(addon.NO_CONCENTRATION) do
        if GoldsmithDB.concentrationCurrency then GoldsmithDB.concentrationCurrency[profession] = nil end
        for _, c in pairs(GoldsmithDB.characters or {}) do
            if c.concentration then c.concentration[profession] = nil end
        end
    end

    -- Recipes not learned yet saved without a profession (see SaveRecipe)
    for _, recipe in pairs(GoldsmithDB.unlearned or {}) do
        if (not recipe.profession or recipe.profession == "" or recipe.profession == "Unassigned") and recipe.skillLine then
            recipe.profession = recipe.skillLine:match("(%S+)$") or recipe.profession
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
            -- (Was a tip to install Auctionator; Goldsmith scans by itself now, Scan.lua)
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
    for _, e in ipairs({ "SKILL_LINES_CHANGED", "TRAIT_CONFIG_UPDATED", "PLAYER_EQUIPMENT_CHANGED" }) do
        resultFrame:RegisterEvent(e)
    end
    resultFrame:SetScript("OnEvent", function(_, event, resultData)
        if event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
            OnCraftResult(resultData)
        elseif event == "SKILL_LINES_CHANGED" or event == "TRAIT_CONFIG_UPDATED" or event == "PLAYER_EQUIPMENT_CHANGED" then
            -- Skill, knowledge points or gear (profession tools too): the
            -- next window open reads every recipe's stats again
            statsDirty = true
        else
            -- Stats change with knowledge points, gear and skill, so they're
            -- read again when a profession window opens after one of those
            -- changed (or STATS_STALE on)
            if event == "TRADE_SKILL_SHOW" and (statsDirty or time() - statsReadAt > STATS_STALE) then
                wipe(statsReadThisSession)
                statsDirty, statsReadAt = false, time()
            end
            -- Just learned: looked at again, though seen unlearned earlier this session
            if event == "NEW_RECIPE_LEARNED" and resultData then
                triedThisSession[resultData], statsReadThisSession[resultData] = nil, nil
            end
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
        addon:CheckSellNow()
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
                local info = C_TradeSkillUI.GetRecipeInfo(recipeInfo.recipeID)
                if info and info.learned == false then
                    -- Kept with the ones not learned yet (Crafts > Show:
                    -- Not learned yet), not with the ones you can craft
                    if not GoldsmithDB.recipes[recipeInfo.recipeID] then
                        SaveRecipe(recipeInfo.recipeID, true, 1, nil, true)
                    end
                else
                    SaveRecipe(recipeInfo.recipeID, true)
                end
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
    -- hide the material breakdown, and on Ctrl for the detail lines (Detail),
    -- while hovering. Item tooltips only, and
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
        if key ~= "LSHIFT" and key ~= "RSHIFT" and key ~= "LCTRL" and key ~= "RCTRL" then return end
        for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
            if SafeToRedraw(tooltip) then
                tooltip:RefreshData()
            end
        end
    end)
end

_G.Goldsmith = addon
