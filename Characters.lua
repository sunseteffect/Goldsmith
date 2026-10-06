local addon = _G.Goldsmith or {}

local function Print(msg, ...)
    print("|cFF00FF00[Goldsmith]|r " .. string.format(msg, ...))
end

local function FormatGold(copper)
    return string.format("%.2fg", copper / 10000)
end

-- Characters
--
-- Everything that differs between your characters is kept per character in
-- GoldsmithDB.characters["Name-Realm"]:
--   { name, realm, class, lastSeen,
--     professions   = { [profession] = { icon, skill, maxSkill } },
--     knownRecipes  = { [recipeID] = true },
--     recipeStats   = { [recipeID] = stats }       (see Pricing.lua)
--     tierData      = { [recipeID] = tiers }       (see Quality.lua)
--     calibration   = { [profession] = procs }     (see Pricing.lua)
--     concentration = { [profession] = { currencyID, current, max,
--                                        cycleMS, perCycle, time } },
--     money, gold   = { ["YYYY-MM-DD"] = copper at the end of that day },
--     goldTime      = { ["YYYY-MM-DD"] = seconds spent making gold },
--     stock, stockTime = { [itemID] = count in bags and bank } and when,
--     auctions, auctionsTime = { [itemID] = count listed on the AH } and
--                              when it was last read from the AH,
--     gearTiers, auctionTiers = { [itemID] = { [tier] = count } } for
--                              gear in bags and bank, and on the AH }
-- addon.char is the logged-in character's table. Prices, recipes' materials,
-- the ledger, milling and vendor prices stay shared across the account.
-- The warband bank is shared too: GoldsmithDB.warbandStock, warbandGearTiers
-- and warbandGold.
--
-- Concentration refills over time, so an alt's current amount is worked out
-- from its last saved amount and how long ago that was.

local GOLD_HISTORY_DAYS = 365

function addon:CharKey()
    return (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "Unknown")
end

local function NewCharacter(name, realm)
    return {
        name = name, realm = realm,
        professions = {}, knownRecipes = {},
        recipeStats = {}, tierData = {}, calibration = {},
        concentration = {}, gold = {}, goldTime = {}, stock = {}, auctions = {},
    }
end

local function EnsureFields(c)
    for _, key in ipairs({ "professions", "knownRecipes", "recipeStats", "tierData",
                           "calibration", "concentration", "gold", "goldTime", "stock", "auctions",
                           "gearTiers", "auctionTiers" }) do
        c[key] = c[key] or {}
    end
end

-- v1 kept stats, tiers and calibration for the whole account. They belong to
-- the character who made them: the one in the ledger most often (not
-- necessarily whoever logs in first after the update).
local function MigrateAccountData()
    local legacy = GoldsmithDB.recipeStats or GoldsmithDB.tierData or GoldsmithDB.calibration
    if not legacy then return end

    local counts, owner, best = {}, nil, 0
    for _, e in ipairs(GoldsmithDB.entries or {}) do
        if e.character and e.realm then
            local key = e.character .. "-" .. e.realm
            counts[key] = (counts[key] or 0) + 1
            if counts[key] > best then owner, best = key, counts[key] end
        end
    end
    owner = owner or addon:CharKey()

    local c = GoldsmithDB.characters[owner]
    if not c then
        local name, realm = owner:match("^(.-)%-(.+)$")
        c = NewCharacter(name, realm)
        GoldsmithDB.characters[owner] = c
    end
    EnsureFields(c)

    for recipeID, stats in pairs(GoldsmithDB.recipeStats or {}) do
        c.recipeStats[recipeID] = c.recipeStats[recipeID] or stats
        c.knownRecipes[recipeID] = true
    end
    for recipeID, tiers in pairs(GoldsmithDB.tierData or {}) do
        c.tierData[recipeID] = c.tierData[recipeID] or tiers
    end
    for profession, procs in pairs(GoldsmithDB.calibration or {}) do
        c.calibration[profession] = c.calibration[profession] or procs
    end
    -- v1 scanned every recipe on this character, so it knows them all
    for recipeID in pairs(GoldsmithDB.recipes or {}) do
        c.knownRecipes[recipeID] = true
    end

    GoldsmithDB.recipeStats, GoldsmithDB.tierData, GoldsmithDB.calibration = nil, nil, nil
    Print("Moved your crafting stats to %s. Each character now keeps its own.", owner)
end

-- Archaeology and Fishing (by skill line) make nothing, so they aren't
-- kept as professions. Their names in the game's language are remembered in
-- GoldsmithDB.nonCrafting.
local NON_CRAFTING_SKILL_LINES = { [794] = true, [356] = true }

function addon:IsCraftingProfession(name)
    return not GoldsmithDB.nonCrafting[name]
end

-- Professions and skill levels of the logged-in character. pairs, not
-- ipairs: GetProfessions() returns nil for a slot not learned.
local function UpdateProfessions()
    local c = addon.char
    for _, index in pairs({ GetProfessions() }) do
        local name, icon, skill, maxSkill, _, _, skillLine = GetProfessionInfo(index)
        if name and NON_CRAFTING_SKILL_LINES[skillLine] then
            GoldsmithDB.nonCrafting[name] = true
            c.professions[name] = nil
        elseif name then
            c.professions[name] = { icon = icon, skill = skill, maxSkill = maxSkill }
        end
    end
end

-- Current concentration for each of this character's professions whose
-- concentration currency is known (learned when a profession is opened)
local function SnapshotConcentration()
    local c = addon.char
    for profession in pairs(c.professions) do
        local currencyID = GoldsmithDB.concentrationCurrency and GoldsmithDB.concentrationCurrency[profession]
        if currencyID and currencyID > 0 then
            local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
            if ok and info then
                c.concentration[profession] = {
                    currencyID = currencyID,
                    current = info.quantity or 0,
                    max = info.maxQuantity or 0,
                    cycleMS = info.rechargingCycleDurationMS,
                    perCycle = info.rechargingAmountPerCycle,
                    time = time(),
                }
            end
        end
    end
end

local function PruneDays(days)
    local cutoff = date("%Y-%m-%d", time() - GOLD_HISTORY_DAYS * 86400)
    for day in pairs(days) do
        if day < cutoff then days[day] = nil end
    end
end

-- Gold in the warband bank, if the game reports it
local function GetWarbandGold()
    if not (C_Bank and C_Bank.FetchDepositedMoney and Enum.BankType and Enum.BankType.Account) then return nil end
    local ok, money = pcall(C_Bank.FetchDepositedMoney, Enum.BankType.Account)
    if ok and type(money) == "number" then return money end
end

local function RecordGold()
    local c = addon.char
    local money = GetMoney()
    local today = date("%Y-%m-%d")
    c.money = money
    c.gold[today] = money
    PruneDays(c.gold)

    local warband = GetWarbandGold()
    if warband then
        GoldsmithDB.warbandGold[today] = warband
        PruneDays(GoldsmithDB.warbandGold)
    end
end

-- Stock
--
-- How many of each item Goldsmith cares about (materials and crafted items)
-- each character has in bags and bank, so alts' stock counts too. The
-- warband bank is counted once, for the account.

-- Every item worth counting: tracked materials, and recipe outputs
-- including each quality tier's item
local function GetStockItemIDs()
    local ids = {}
    for itemID in pairs(addon:GetTrackedMaterials()) do
        ids[itemID] = true
    end
    for _, recipe in pairs(GoldsmithDB.recipes) do
        if recipe.outputItemID then ids[recipe.outputItemID] = true end
    end
    for _, c in pairs(GoldsmithDB.characters) do
        for _, td in pairs(c.tierData) do
            for _, out in pairs(td.outputs or {}) do
                if out.itemID then ids[out.itemID] = true end
            end
        end
    end
    return ids
end

-- Gear's quality tier (1, 2, ...) from its link: every tier of a piece of
-- gear shares one item ID
local function GearTier(link)
    local fn = link and C_TradeSkillUI.GetItemCraftedQualityByItemInfo
    if not fn then return nil end
    local ok, tier = pcall(fn, link)
    if ok and tier and tier > 0 then return tier end
end

local function AddTier(tiers, itemID, tier, count)
    tiers[itemID] = tiers[itemID] or {}
    tiers[itemID][tier] = (tiers[itemID][tier] or 0) + count
end

-- Gear in bags and bank (character's and warband's) by tier, read slot by
-- slot. Containers the game hasn't loaded are skipped; their items count
-- as "tier unknown" (see GetHeld). Returns own tiers, warband tiers.
local function ScanGearTiers(ids)
    local own, warband, seen = {}, {}, {}
    for name, bag in pairs(Enum.BagIndex or {}) do
        local tiers = (name:find("^Account") and warband)
            or ((name == "Backpack" or name:find("^Bag_") or name == "ReagentBag"
                or name:find("Bank")) and own)
        -- Some bags have more than one name
        if tiers and not seen[bag] then
            seen[bag] = true
            for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and ids[info.itemID] and addon:IsGear(info.itemID) then
                    local tier = GearTier(info.hyperlink)
                    if tier then AddTier(tiers, info.itemID, tier, info.stackCount or 1) end
                end
            end
        end
    end
    return own, warband
end

-- The game reports the bank and warband bank even while they're closed
-- (checked in game 2026-09-26), so everything is counted at any time.
-- A warband bank that suddenly reads empty is more likely not loaded yet
-- than really empty, so the last count is kept in that case.
local function SnapshotStock()
    local c = addon.char
    local stock, warband, warbandTotal = {}, {}, 0
    local ids = GetStockItemIDs()
    for itemID in pairs(ids) do
        local own = C_Item.GetItemCount(itemID, true, false, true, false) or 0
        local withWarband = C_Item.GetItemCount(itemID, true, false, true, true) or 0
        if own > 0 then stock[itemID] = own end
        if withWarband > own then
            warband[itemID] = withWarband - own
            warbandTotal = warbandTotal + withWarband - own
        end
    end
    local gearTiers, warbandTiers = ScanGearTiers(ids)
    c.stock, c.gearTiers, c.stockTime = stock, gearTiers, time()
    -- Left over from when bags and bank were kept separately
    c.bagStock, c.bankStock, c.bankTime = nil, nil, nil
    if warbandTotal > 0 or next(GoldsmithDB.warbandStock) == nil then
        GoldsmithDB.warbandStock = warband
        GoldsmithDB.warbandGearTiers = warbandTiers
    end
end

-- An item's stock across the account, leaving out characters excluded in
-- Settings. Returns the total and a list of { key, name, count } (the
-- warband bank has key "warband"), largest first.
function addon:GetStock(itemID)
    local list, total = {}, 0
    for key, c in pairs(GoldsmithDB.characters) do
        local count = addon:IsCharacterIncluded(key) and c.stock[itemID]
        if count and count > 0 then
            table.insert(list, { key = key, name = c.name, count = count })
            total = total + count
        end
    end
    local warband = GoldsmithDB.warbandStock[itemID]
    if warband and warband > 0 then
        table.insert(list, { key = "warband", name = "Warband bank", count = warband })
        total = total + warband
    end
    table.sort(list, function(a, b) return a.count > b.count end)
    return total, list
end

-- Auctions
--
-- How many of each item each character has listed on the AH, so an item
-- you've posted still counts as held until it sells. Read from the AH
-- whenever it's open (your auctions list, which also drops expired and
-- cancelled ones); in between, a sale collected from the mailbox takes
-- its count off.
local function SnapshotAuctions()
    if not (C_AuctionHouse and C_AuctionHouse.GetOwnedAuctions) then return end
    local ok, owned = pcall(C_AuctionHouse.GetOwnedAuctions)
    if not ok or type(owned) ~= "table" then return end
    local active = Enum.AuctionStatus and Enum.AuctionStatus.Active or 0
    local auctions, tiers = {}, {}
    for _, a in ipairs(owned) do
        local itemID = a.itemKey and a.itemKey.itemID
        if itemID and a.status == active then
            auctions[itemID] = (auctions[itemID] or 0) + (a.quantity or 1)
            local tier = addon:IsGear(itemID) and GearTier(a.itemLink)
            if tier then AddTier(tiers, itemID, tier, a.quantity or 1) end
        end
    end
    addon.char.auctions, addon.char.auctionTiers, addon.char.auctionsTime = auctions, tiers, time()
    if addon.Refresh then addon.Refresh() end
end

local function QueryAuctions()
    if C_AuctionHouse and C_AuctionHouse.QueryOwnedAuctions then
        pcall(C_AuctionHouse.QueryOwnedAuctions, {})
    end
end

-- A sale collected from the mail (Core.lua): the mail names the item, not
-- its ID, so it's matched by name
function addon:AuctionSold(itemName, count)
    local auctions = addon.char.auctions
    for itemID, listed in pairs(auctions) do
        if C_Item.GetItemNameByID(itemID) == itemName then
            local left = listed - (count or 1)
            auctions[itemID] = left > 0 and left or nil
            return
        end
    end
end

-- Everything you hold of an item, whether or not the character counts
-- (an excluded bank alt still holds it): bags and banks on every
-- character, the warband bank, and AH listings.
-- With a tier, gear counts only that tier: silver gear doesn't stop gold
-- being made. Items whose tier wasn't read (a bank the game hadn't
-- loaded, stock saved before tiers were kept) count toward every tier, to
-- be safe.
function addon:GetHeld(itemID, tier)
    local function Count(total, tiers)
        local byTier = tier and tiers and tiers[itemID]
        if not byTier or total == 0 then return total end
        local known = 0
        for _, n in pairs(byTier) do known = known + n end
        return math.min((byTier[tier] or 0) + math.max(total - known, 0), total)
    end
    local total = Count(GoldsmithDB.warbandStock[itemID] or 0, GoldsmithDB.warbandGearTiers)
    for _, c in pairs(GoldsmithDB.characters) do
        total = total + Count(c.stock[itemID] or 0, c.gearTiers) + Count(c.auctions[itemID] or 0, c.auctionTiers)
    end
    return total
end

-- Goldmaking time
--
-- Time spent making gold, for gold per hour: while a profession window, the
-- AH, the mailbox, a vendor or the bank is open. A gap shorter than
-- GOLDMAKING_GAP between two of them (walking from the AH to the mailbox)
-- counts too. Dungeons, questing and idling in town don't.
local GOLDMAKING_GAP = 5 * 60
local GOLDMAKING_TICK = 30

local GOLDMAKING_OPEN = {
    TRADE_SKILL_SHOW = "profession", AUCTION_HOUSE_SHOW = "ah", MAIL_SHOW = "mail",
    MERCHANT_SHOW = "vendor", BANKFRAME_OPENED = "bank",
}
local GOLDMAKING_CLOSE = {
    TRADE_SKILL_CLOSE = "profession", AUCTION_HOUSE_CLOSED = "ah", MAIL_CLOSED = "mail",
    MERCHANT_CLOSED = "vendor", BANKFRAME_CLOSED = "bank",
}

local openSources = {}   -- which of the above are open now
local lastMark           -- time goldmaking time was last added up to
local lastActiveEnd      -- when the last goldmaking stretch ended

local function IsGoldmaking()
    return next(openSources) ~= nil
end

local function AddGoldTime(seconds)
    if seconds <= 0 then return end
    local c = addon.char
    local today = date("%Y-%m-%d")
    c.goldTime[today] = (c.goldTime[today] or 0) + seconds
end

-- Count time up to now while goldmaking
local function FlushGoldTime()
    if IsGoldmaking() and lastMark then
        local now = time()
        AddGoldTime(now - lastMark)
        lastMark = now
    end
end

local function OnGoldmakingOpen(source)
    local now = time()
    if not IsGoldmaking() then
        if lastActiveEnd and now - lastActiveEnd < GOLDMAKING_GAP then
            AddGoldTime(now - lastActiveEnd)
        end
        lastMark = now
    end
    openSources[source] = true
end

local function OnGoldmakingClose(source)
    if not openSources[source] then return end
    FlushGoldTime()
    openSources[source] = nil
    if not IsGoldmaking() then
        lastActiveEnd = time()
    end
end

-- Seconds spent making gold on a day ("YYYY-MM-DD"), all characters
function addon:GetGoldmakingSeconds(day)
    local total = 0
    for _, c in pairs(GoldsmithDB.characters) do
        total = total + (c.goldTime[day] or 0)
    end
    return total
end

-- Account gold
--
-- Gold across all characters (except those excluded in Settings) plus the
-- warband bank, at the end of each of the last `days` days (oldest first).
-- A character's gold on a day without
-- a record is its most recent earlier record; before its first record it
-- counts as nothing. Returns { { day, copper } }.
local function ValueOn(history, day)
    local best, bestDay
    for d, value in pairs(history) do
        if d <= day and (not bestDay or d > bestDay) then
            best, bestDay = value, d
        end
    end
    return best or 0
end

function addon:GetAccountGoldHistory(days)
    local list = {}
    for i = days - 1, 0, -1 do
        local day = date("%Y-%m-%d", time() - i * 86400)
        local total = ValueOn(GoldsmithDB.warbandGold, day)
        for key, c in pairs(GoldsmithDB.characters) do
            if addon:IsCharacterIncluded(key) then total = total + ValueOn(c.gold, day) end
        end
        table.insert(list, { day = day, copper = total })
    end
    return list
end

-- loggingOut: the game reports 0 gold while logging out or reloading, so
-- gold isn't saved then (PLAYER_MONEY and login keep it up to date)
local function UpdateAll(loggingOut)
    local c = addon.char
    c.lastSeen = time()
    c.class = select(2, UnitClass("player"))
    UpdateProfessions()
    SnapshotConcentration()
    if not loggingOut then RecordGold() end
end

-- Versions before 2.1 saved that 0 at every logout. Dropping the zeros lets
-- each day carry the last real amount forward instead.
local function RepairLogoutGold()
    if GoldsmithDB.logoutGoldRepaired then return end
    for _, c in pairs(GoldsmithDB.characters) do
        local lastDay
        for day, copper in pairs(c.gold) do
            if copper == 0 then
                c.gold[day] = nil
            elseif not lastDay or day > lastDay then
                lastDay = day
            end
        end
        if c.money == 0 then c.money = lastDay and c.gold[lastDay] or nil end
    end
    for day, copper in pairs(GoldsmithDB.warbandGold) do
        if copper == 0 then GoldsmithDB.warbandGold[day] = nil end
    end
    GoldsmithDB.logoutGoldRepaired = true
end

-- Whose stats to use
--
-- Recipe stats, tiers and calibration are read from addon:StatsChar(): the
-- logged-in character, unless addon:WithCharacter is working something out
-- for an alt (e.g. what an alt's concentration is worth). New stats are
-- always saved to the logged-in character.
function addon:StatsChar()
    return addon.statsChar or addon.char
end

local function Pack(...) return { n = select("#", ...), ... } end

-- Runs fn(...) using charKey's stats and returns what it returns.
-- Inside work spread over frames (Settings.lua) it may wait for a frame:
-- the work keeps its stats to itself while it waits, and it runs without
-- a pcall (Lua can't pause in one); if it errors, the work stops and puts
-- the stats back. Elsewhere a pcall puts them back, and nothing pauses
-- inside (addon.noYield).
function addon:WithCharacter(charKey, fn, ...)
    local previous = addon.statsChar
    addon.statsChar = GoldsmithDB.characters[charKey] or addon.char
    if addon:InWork() then
        local results = Pack(fn(...))
        addon.statsChar = previous
        return unpack(results, 1, results.n)
    end
    addon.noYield = addon.noYield + 1
    local results = { pcall(fn, ...) }
    addon.noYield = addon.noYield - 1
    addon.statsChar = previous
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2)
end

-- A character's concentration for a profession, worked out to now from its
-- last saved amount and recharge rate. Returns current, max, minutes until
-- full (nil if full or unknown) and when it was last saved, or nil.
function addon:GetCharacterConcentration(charKey, profession)
    local c = GoldsmithDB.characters[charKey]
    local snap = c and c.concentration[profession]
    if not snap then return nil end

    local current = snap.current
    if charKey ~= addon.charKey and snap.cycleMS and snap.perCycle and snap.cycleMS > 0 then
        local cycles = (time() - snap.time) * 1000 / snap.cycleMS
        current = math.min(snap.max, current + cycles * snap.perCycle)
    end
    local minutesToFull
    if snap.cycleMS and snap.perCycle and snap.perCycle > 0 and current < snap.max then
        minutesToFull = (snap.max - current) / snap.perCycle * snap.cycleMS / 60000
    end
    return math.floor(current), snap.max, minutesToFull, snap.time
end

-- Characters sorted: the logged-in one first, then by name
function addon:GetCharacters()
    local list = {}
    for key, c in pairs(GoldsmithDB.characters) do
        table.insert(list, { key = key, data = c })
    end
    table.sort(list, function(a, b)
        if (a.key == addon.charKey) ~= (b.key == addon.charKey) then return a.key == addon.charKey end
        return a.key < b.key
    end)
    return list
end

-- Mark recipes this character knows (called by the recipe scan)
function addon:MarkRecipeKnown(recipeID)
    addon.char.knownRecipes[recipeID] = true
end

function addon:KnowsRecipe(recipeID, charKey)
    local c = charKey and GoldsmithDB.characters[charKey] or addon.char
    return c and c.knownRecipes[recipeID] == true
end

-- Forgets a character (deleted, renamed or moved realm): its recipes,
-- stats, concentration, stock and gold. Sales and purchases in the ledger
-- stay. It stays excluded, so if you log in on it again it comes back
-- excluded, not in your recommendations. Not the logged-in one.
function addon:RemoveCharacter(charKey)
    if charKey == addon.charKey then return end
    GoldsmithDB.characters[charKey] = nil
    GoldsmithDB.settings = GoldsmithDB.settings or {}
    GoldsmithDB.settings.excluded = GoldsmithDB.settings.excluded or {}
    GoldsmithDB.settings.excluded[charKey] = true
    if addon.Refresh then addon.Refresh() end
end

-- /gsm chars
function addon:ListCharacters()
    UpdateAll()
    Print("Your characters:")
    for _, entry in ipairs(addon:GetCharacters()) do
        local c = entry.data
        local seen = entry.key == addon.charKey and "online now"
            or (c.lastSeen and ("last seen " .. date("%b %d %H:%M", c.lastSeen)) or "never seen")
        print(string.format("  %s%s - %s, %s", entry.key, entry.key == addon.charKey and " (you)" or "",
            c.money and FormatGold(c.money) or "?", seen))
        for profession, p in pairs(c.professions) do
            local line = string.format("    %s %d/%d", profession, p.skill or 0, p.maxSkill or 0)
            local current, max, minutesToFull = addon:GetCharacterConcentration(entry.key, profession)
            if current then
                line = line .. string.format(", concentration %d/%d", current, max)
                if minutesToFull then
                    line = line .. string.format(" (full in %.1fh)", minutesToFull / 60)
                end
            end
            print(line)
        end
    end
end

-- /gsm data: the numbers the v2 screens are built on, for checking them
function addon:ListData()
    FlushGoldTime()
    RecordGold()
    SnapshotStock()
    Print("Profit on sales (all professions):")
    for _, r in ipairs(addon.DATE_RANGES) do
        local s = addon:GetSummary("All", r.key)
        print(string.format("  %s: %s%s from %s of sales", r.label,
            s.profit >= 0 and "+" or "-", FormatGold(math.abs(s.profit)), FormatGold(s.sales)))
    end

    local parts = {}
    for _, d in ipairs(addon:GetGoldPerHour("All", 7)) do
        table.insert(parts, string.format("%s %s%.0fg (%dm)", d.day:sub(6),
            d.profit >= 0 and "+" or "-", math.abs(d.profit) / 10000, math.floor(d.seconds / 60)))
    end
    Print("Last 7 days, profit (goldmaking minutes): %s", table.concat(parts, ", "))

    local history = addon:GetAccountGoldHistory(7)
    parts = {}
    for _, d in ipairs(history) do
        table.insert(parts, string.format("%s %.0fg", d.day:sub(6), d.copper / 10000))
    end
    Print("Account gold: %s", table.concat(parts, ", "))
    local warband = GetWarbandGold()
    print(string.format("  Warband bank gold: %s", warband and FormatGold(warband) or "not reported"))

    local items, units = 0, 0
    for _, c in pairs(GoldsmithDB.characters) do
        for _, count in pairs(c.stock) do items, units = items + 1, units + count end
    end
    local wItems, wUnits = 0, 0
    for _, count in pairs(GoldsmithDB.warbandStock) do wItems, wUnits = wItems + 1, wUnits + count end
    Print("Stock: %d kinds of item (%d units) on characters, %d kinds (%d units) in the warband bank.",
        items, units, wItems, wUnits)

    -- What the game reports right now, to compare with the saved stock
    local bags, withBank, withWarband = 0, 0, 0
    for itemID in pairs(GetStockItemIDs()) do
        bags = bags + (C_Item.GetItemCount(itemID, false, false, false, false) or 0)
        withBank = withBank + (C_Item.GetItemCount(itemID, true, false, true, false) or 0)
        withWarband = withWarband + (C_Item.GetItemCount(itemID, true, false, true, true) or 0)
    end
    Print("Game reports now: %d units in bags, %d with bank, %d with warband bank.",
        bags, withBank, withWarband)
    local stock = addon:GetStockValue("All")
    Print("Gold in stock (all professions): %s", addon:FormatMoney(stock.value))
    for i = 1, math.min(#stock.items, 5) do
        local item = stock.items[i]
        print(string.format("  %s x%d: %s", item.name, item.count, addon:FormatMoney(item.value)))
    end
end

function addon:InitializeCharacters()
    GoldsmithDB.characters = GoldsmithDB.characters or {}
    GoldsmithDB.warbandGold = GoldsmithDB.warbandGold or {}
    GoldsmithDB.warbandStock = GoldsmithDB.warbandStock or {}
    local key = addon:CharKey()
    local c = GoldsmithDB.characters[key]
    if not c then
        c = NewCharacter(UnitName("player"), GetRealmName())
        GoldsmithDB.characters[key] = c
    end
    EnsureFields(c)
    addon.char, addon.charKey = c, key

    MigrateAccountData()
    -- The migration may have created or filled this character's table
    addon.char = GoldsmithDB.characters[key]
    -- Every character, not just this one: alts saved by an older version
    -- lack fields added since, and screens read all characters
    for _, c in pairs(GoldsmithDB.characters) do
        EnsureFields(c)
    end

    -- Older versions kept Archaeology and Fishing as professions; drop them
    -- from every character, alts included
    GoldsmithDB.nonCrafting = GoldsmithDB.nonCrafting or { Archaeology = true, Fishing = true }
    for _, c in pairs(GoldsmithDB.characters) do
        for name in pairs(GoldsmithDB.nonCrafting) do c.professions[name] = nil end
    end
    RepairLogoutGold()

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("SKILL_LINES_CHANGED")
    frame:RegisterEvent("PLAYER_MONEY")
    frame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:RegisterEvent("BAG_UPDATE_DELAYED")
    frame:RegisterEvent("OWNED_AUCTIONS_UPDATED")
    frame:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED")
    for event in pairs(GOLDMAKING_OPEN) do frame:RegisterEvent(event) end
    for event in pairs(GOLDMAKING_CLOSE) do frame:RegisterEvent(event) end
    C_Timer.NewTicker(GOLDMAKING_TICK, FlushGoldTime)

    local pending, stockPending = false, false
    frame:SetScript("OnEvent", function(_, event)
        if event == "OWNED_AUCTIONS_UPDATED" then
            SnapshotAuctions()
            return
        elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
            -- The new auction shows in your list a moment later
            C_Timer.After(1, QueryAuctions)
            return
        elseif event == "AUCTION_HOUSE_SHOW" then
            QueryAuctions()
        elseif event == "BANKFRAME_OPENED" then
            -- The bank's slots can be read now, so gear tiers there too
            C_Timer.After(1, function()
                SnapshotStock()
                if addon.Refresh then addon.Refresh() end
            end)
        end
        if GOLDMAKING_OPEN[event] then
            OnGoldmakingOpen(GOLDMAKING_OPEN[event])
            return
        elseif GOLDMAKING_CLOSE[event] then
            OnGoldmakingClose(GOLDMAKING_CLOSE[event])
            return
        end

        if event == "PLAYER_LOGOUT" then
            -- No stock snapshot here: bags read as empty while logging out.
            -- Login and bag changes keep stock up to date.
            FlushGoldTime()
            UpdateAll(true)
        elseif event == "PLAYER_MONEY" then
            RecordGold()
        elseif event == "BAG_UPDATE_DELAYED" then
            -- Bags change in bursts while crafting or looting
            if not stockPending then
                stockPending = true
                C_Timer.After(10, function()
                    stockPending = false
                    SnapshotStock()
                    if addon.Refresh then addon.Refresh() end
                end)
            end
        elseif not pending then
            -- Profession and currency data can arrive a moment after these
            -- events, and they can fire in bursts
            pending = true
            local login = event == "PLAYER_ENTERING_WORLD"
            C_Timer.After(2, function()
                pending = false
                UpdateAll()
                if login then SnapshotStock() end
                if addon.Refresh then addon.Refresh() end
            end)
        end
    end)
end

_G.Goldsmith = addon
