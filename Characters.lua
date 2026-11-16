local addon = _G.Goldsmith or {}

local function Print(msg, ...)
    print("|cFF00FF00[Goldsmith]|r " .. string.format(msg, ...))
end

local function FormatGold(copper)
    if addon.isForever then return addon:FormatMoney(copper) end
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
--                        not counting what you wear (bags in bag slots too)
--     bankBags      = { [itemID] = count } in the bank's bag slots (Forever)
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

-- Forever characters have a surname, and two of yours can share a first
-- name: both were saved as one character (GitHub #6, 2026-11-16). The
-- surname is UnitName's second result there; the unmodified name, so hiding
-- surnames in the game's settings doesn't change who you are.
function addon:HasSurnames()
    return RegionalUniqueNamesEnabled ~= nil and RegionalUniqueNamesEnabled() == true
end

-- A unit's name, with the surname where the game has them. Second result:
-- the first name alone.
function addon:FullName(unit)
    local first, surname = (UnitNameUnmodified or UnitName)(unit)
    if not first then return nil end
    if not addon:HasSurnames() or type(surname) ~= "string" or surname == "" then return first, first end
    local consts = Constants and Constants.CharacterNameSeparatorConsts
    local sep = consts and consts.CHARACTERNAME_SURNAME_SEPARATOR
    if type(sep) ~= "string" or sep == "" then sep = " " end
    if first:sub(-#(sep .. surname)) == sep .. surname then
        return first, first:sub(1, #first - #(sep .. surname))
    end
    return first .. sep .. surname, first
end

function addon:PlayerName()
    return addon:FullName("player")
end

-- False while the game hasn't given the surname yet (login waits for it)
function addon:PlayerNameReady()
    if not addon:HasSurnames() then return true end
    local _, surname = (UnitNameUnmodified or UnitName)("player")
    return type(surname) == "string" and surname ~= ""
end

function addon:CharKey()
    return (addon:PlayerName() or "Unknown") .. "-" .. (GetRealmName() or "Unknown")
end

-- The first word of a name: the first name of "Namo Dormammu"
local function FirstName(name)
    return name and name:match("^(%S+)") or name
end

-- The character a saved name belongs to. Records from before surnames hold
-- the first name alone: they count for your one character with that first
-- name. With two namesakes nobody can tell whose they were, so they stay
-- under the first name (still in account totals).
local keyFor = {}
function addon:CharKeyFor(name, realm)
    local key = name .. "-" .. realm
    if not addon:HasSurnames() or GoldsmithDB.characters[key] then return key end
    if keyFor[key] == nil then
        local found, count = nil, 0
        if not name:find("%s") then
            for k, c in pairs(GoldsmithDB.characters) do
                if c.realm == realm and c.name and c.name ~= name and FirstName(c.name) == name then
                    found, count = k, count + 1
                end
            end
        end
        keyFor[key] = count == 1 and found or false
    end
    return keyFor[key] or key
end

-- Whether a ledger or gathering entry is the logged-in character's
function addon:IsMyEntry(e)
    return e.character ~= nil and addon:CharKeyFor(e.character, e.realm or GetRealmName()) == addon.charKey
end

-- Which of your characters a typed or shown name means (mail, trades), or
-- nil. The full name wins; a first name alone counts only when exactly one
-- of yours has it.
function addon:FindOwnCharacter(name, realm)
    if type(name) ~= "string" or name == "" then return nil end
    local who = name:lower()
    local first = FirstName(who)
    local found, count = nil, 0
    for k, c in pairs(GoldsmithDB.characters or {}) do
        local theirs = c.name and c.name:lower()
        if theirs and (not realm or not c.realm or c.realm == realm) then
            if theirs == who then return k end
            -- Saved before surnames, or typed without one
            if (not theirs:find("%s") and theirs == first) or (not who:find("%s") and FirstName(theirs) == who) then
                found, count = k, count + 1
            end
        end
    end
    return count == 1 and found or nil
end

-- Every saved mention of a character's key becomes the new key: queues,
-- mail, learners, lots, settings. Also "key:..." (a key with more after it).
local function RenameKey(old, new)
    local seen, prefix = {}, old .. ":"
    local function Fix(s)
        if s == old then return new end
        if type(s) == "string" and s:sub(1, #prefix) == prefix then return new .. s:sub(#old + 1) end
        return s
    end
    local function Walk(t)
        if seen[t] then return end
        seen[t] = true
        local moved
        for k, v in pairs(t) do
            if type(v) == "table" then
                Walk(v)
            elseif type(v) == "string" then
                local fixed = Fix(v)
                if fixed ~= v then t[k] = fixed end
            end
            if type(k) == "string" and Fix(k) ~= k then
                moved = moved or {}
                table.insert(moved, k)
            end
        end
        for _, k in ipairs(moved or {}) do
            local to = Fix(k)
            if t[to] == nil then t[to] = t[k] end
            t[k] = nil
        end
    end
    Walk(GoldsmithDB)
end

-- The record saved under the first name alone becomes this character's.
-- With two namesakes the first to log in takes it and the other starts
-- fresh: professions, gold and stock are read again at every login.
local function ClaimFirstNameRecord(key, name, first, realm)
    local old = first .. "-" .. realm
    local c = GoldsmithDB.characters[old]
    if old == key or not c or (c.name and c.name ~= first) then return end
    RenameKey(old, key)
    c.name = name
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
    local seen, any = {}, false
    for _, index in pairs({ GetProfessions() }) do
        local name, icon, skill, maxSkill, _, _, skillLine = GetProfessionInfo(index)
        if name then any = true end
        if name and NON_CRAFTING_SKILL_LINES[skillLine] then
            GoldsmithDB.nonCrafting[name] = true
            c.professions[name] = nil
        elseif name then
            c.professions[name] = { icon = icon, skill = skill, maxSkill = maxSkill }
            seen[name] = true
        end
    end
    -- A profession you dropped goes, with its concentration and the
    -- recipes it taught: the Characters tab kept showing it (TheShua,
    -- CurseForge, 2026-11-12: "changed to a different secondary profession
    -- and it is still showing my old"). Not when the game listed nothing:
    -- right at login it can answer before it knows.
    if not any then return end
    for name in pairs(c.professions) do
        if not seen[name] then
            c.professions[name] = nil
            if c.concentration then c.concentration[name] = nil end
            for recipeID in pairs(c.knownRecipes or {}) do
                local recipe = GoldsmithDB.recipes[recipeID]
                if recipe and recipe.profession == name then c.knownRecipes[recipeID] = nil end
            end
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
    -- Older expansions' concentration too, by currency, for the recipes
    -- known that spend it (GetCharacterConcentration with a recipe)
    local byCurrency = {}
    for recipeID, stats in pairs(c.recipeStats or {}) do
        local id = stats.concentrationCurrencyID
        if id and id > 0 and not byCurrency[id] and c.knownRecipes and c.knownRecipes[recipeID] then
            local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
            if ok and info then
                byCurrency[id] = {
                    currencyID = id,
                    current = info.quantity or 0,
                    max = info.maxQuantity or 0,
                    cycleMS = info.rechargingCycleDurationMS,
                    perCycle = info.rechargingAmountPerCycle,
                    time = time(),
                }
            end
        end
    end
    c.concentrationByCurrency = byCurrency
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
    -- Not while the tour shows its sample data (Tour.lua): it isn't yours
    if addon:UsingTourData() then return end
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
-- as "tier unknown" (see GetHeld). Bound gear can't be sold, so it's left
-- out and counted apart. Returns own tiers, warband tiers, bound
-- ({ [itemID] = count } in your bags and bank), bound in the warband bank,
-- bound in your bags alone (for the bags/bank split), and whether the
-- bank's slots could be read (only while it's open; its counts can be
-- read any time).
local function ScanGearTiers(ids)
    local own, warband, seen = {}, {}, {}
    local bound, boundWarband, boundBags = {}, {}, {}
    local bankRead = false
    for name, bag in pairs(Enum.BagIndex or {}) do
        local isBag = name == "Backpack" or name:find("^Bag_") or name == "ReagentBag"
        local tiers = (name:find("^Account") and warband)
            or ((isBag or name:find("Bank")) and own)
        -- Some bags have more than one name
        if tiers and not seen[bag] then
            seen[bag] = true
            for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and not isBag and tiers == own then bankRead = true end
                if info and ids[info.itemID] and addon:IsGear(info.itemID) then
                    if info.isBound == true then
                        local count = info.stackCount or 1
                        local list = tiers == warband and boundWarband or bound
                        list[info.itemID] = (list[info.itemID] or 0) + count
                        if isBag then boundBags[info.itemID] = (boundBags[info.itemID] or 0) + count end
                    else
                        local tier = GearTier(info.hyperlink)
                        if tier then AddTier(tiers, info.itemID, tier, info.stackCount or 1) end
                    end
                end
            end
        end
    end
    return own, warband, bound, boundWarband, boundBags, bankRead
end

-- What you have equipped ({ [itemID] = count }): gear and profession tools
-- in use aren't stock (the item count includes them; an equipped Sin'dorei
-- Quill counted 2,400g in Gold in stock, user 2026-10-11)
-- Bags in your bag slots too: two Linen Reagent Bags in use said "You
-- have 2" on the Crafts list (user, 2026-11-13). bankBags: bags in the
-- bank's bag slots (Forever), not in the bag count; as last seen when the
-- game can't say (the bank closed).
local LAST_EQUIPPED_SLOT = 30 -- past the profession tool and gear slots
local function BagSlotItem(bag, into)
    local ok, slot = pcall(C_Container.ContainerIDToInventoryID, bag)
    if not (ok and type(slot) == "number") then return end
    local ok2, itemID = pcall(GetInventoryItemID, "player", slot)
    if ok2 and type(itemID) == "number" then into[itemID] = (into[itemID] or 0) + 1 return true end
end

local function EquippedItems(bankRead)
    local equipped, bankBags = {}, {}
    for slot = 1, LAST_EQUIPPED_SLOT do
        local ok, itemID = pcall(GetInventoryItemID, "player", slot)
        if ok and type(itemID) == "number" then equipped[itemID] = (equipped[itemID] or 0) + 1 end
    end
    local worn = NUM_TOTAL_EQUIPPED_BAG_SLOTS or 5
    for bag = 1, worn do BagSlotItem(bag, equipped) end
    local found = false
    for bag = worn + 1, worn + (NUM_BANKBAGSLOTS or 0) do
        if BagSlotItem(bag, bankBags) then found = true end
    end
    if found or bankRead then
        addon.char.bankBags = bankBags
    else
        bankBags = addon.char.bankBags or {}
    end
    return equipped, bankBags
end

-- The game reports the bank and warband bank even while they're closed
-- (checked in game 2026-09-26), so everything is counted at any time.
-- A warband bank that suddenly reads empty is more likely not loaded yet
-- than really empty, so the last count is kept in that case.
--
-- Thousands of items, three counts each: done in one go it ran past the
-- game's script time limit while looting in a delve ("script ran too long",
-- user 2026-10-15). So it counts STOCK_BUDGET_MS a frame, waits out combat,
-- and saves the result only when the whole count is done.
local STOCK_BUDGET_MS = 4
local stockJob -- the count in progress

-- One frame's worth of counting; true when every item is counted
local function CountStock(job, budget)
    local start = debugprofilestop()
    if not job.ids then
        job.set = GetStockItemIDs()
        job.ids = addon:Keys(job.set)
        if debugprofilestop() - start >= budget then return false end
    end
    if not job.gearTiers then
        job.gearTiers, job.warbandTiers, job.bound, job.boundWarband, job.boundBags, job.bankRead =
            ScanGearTiers(job.set)
        job.equipped, job.bankBags = EquippedItems(job.bankRead)
        -- Bound gear in the bank: as seen the last time it was open. A
        -- soulbound Apprentice Jeweler's Apron put in the bank was back on
        -- the Held board (user, 2026-10-29)
        job.boundBank = {}
        if job.bankRead then
            for itemID, n in pairs(job.bound) do
                local inBank = n - (job.boundBags[itemID] or 0)
                if inBank > 0 then job.boundBank[itemID] = inBank end
            end
        end
        if debugprofilestop() - start >= budget then return false end
    end
    local ids, equipped = job.ids, job.equipped
    local bound, boundWarband, boundBags = job.bound, job.boundWarband, job.boundBags
    while job.i <= #ids do
        local itemID = ids[job.i]
        job.i = job.i + 1
        local own = C_Item.GetItemCount(itemID, true, false, true, false) or 0
        local withWarband = C_Item.GetItemCount(itemID, true, false, true, true) or 0
        -- Bound gear in bags is left out of own below, so out of this too
        local inBags = (C_Item.GetItemCount(itemID, false, false, true, false) or 0) - (equipped[itemID] or 0)
            - (boundBags[itemID] or 0)
        local inWarband = withWarband - own
        -- Not for sale: what you wear, and bound gear (in a closed bank, up
        -- to what's there)
        local boundHere = bound[itemID] or 0
        if not job.bankRead then
            local bankCount = own - (C_Item.GetItemCount(itemID, false, false, true, false) or 0)
            boundHere = boundHere + math.min((addon.char.boundBank or {})[itemID] or 0, math.max(bankCount, 0))
        end
        own = own - (equipped[itemID] or 0) - (job.bankBags[itemID] or 0) - boundHere
        inWarband = inWarband - (boundWarband[itemID] or 0)
        if own > 0 then job.stock[itemID] = own end
        local bank = math.min(own, math.max(own - math.max(inBags, 0), 0))
        if bank > 0 then job.inBank[itemID] = bank end
        if inWarband > 0 then
            job.warband[itemID] = inWarband
            job.warbandTotal = job.warbandTotal + inWarband
        end
        if job.i % 16 == 0 and debugprofilestop() - start >= budget then return false end
    end
    return true
end

local function NewStockJob()
    -- How many of each are in the bank, for "where is it" in hovers (the
    -- rest are in your bags; user, 2026-10-11)
    return { i = 1, stock = {}, inBank = {}, warband = {}, warbandTotal = 0, onDone = {}, later = {} }
end

-- Returns whether anything counted differs from what was saved
local function SaveStock(job)
    local c = addon.char
    local S = function(a, b) return addon:SameData(a, b) end
    local changed = not (S(c.stock, job.stock) and S(c.gearTiers, job.gearTiers) and S(c.stockBank, job.inBank)
        and (not job.bankRead or S(c.boundBank, job.boundBank)))
    c.stock, c.gearTiers, c.stockTime, c.stockBank = job.stock, job.gearTiers, time(), job.inBank
    if job.bankRead then c.boundBank = job.boundBank end
    -- Left over from when bags and bank were kept separately
    c.bagStock, c.bankStock, c.bankTime = nil, nil, nil
    if job.warbandTotal > 0 or next(GoldsmithDB.warbandStock) == nil then
        changed = changed or not (S(GoldsmithDB.warbandStock, job.warband)
            and S(GoldsmithDB.warbandGearTiers, job.warbandTiers))
        GoldsmithDB.warbandStock = job.warband
        GoldsmithDB.warbandGearTiers = job.warbandTiers
    end
    return changed
end

-- Counts stock over a few frames, then calls onDone (if given) with
-- whether anything changed. A count asked for while one runs starts again
-- once it's done, so the newest bags are what's saved.
local function SnapshotStock(onDone)
    -- Not while the tour shows its sample data (Tour.lua): it isn't yours
    if addon:UsingTourData() then return end
    if stockJob then
        stockJob.again = true
        if onDone then table.insert(stockJob.later, onDone) end
        return
    end
    local job = NewStockJob()
    if onDone then table.insert(job.onDone, onDone) end
    stockJob = job
    local function Step()
        -- Combat: wait, the count can be a moment late
        if InCombatLockdown() then C_Timer.After(1, Step) return end
        if not CountStock(job, STOCK_BUDGET_MS) then C_Timer.After(0, Step) return end
        stockJob = nil
        -- The tour may have started while this was counting
        local changed = not addon:UsingTourData() and SaveStock(job) or false
        for _, fn in ipairs(job.onDone) do fn(changed) end
        if job.again then
            SnapshotStock(function(again)
                for _, fn in ipairs(job.later) do fn(changed or again) end
            end)
        end
    end
    Step()
end

-- The whole count at once, for /gsm data, which prints right after
local function SnapshotStockNow()
    if addon:UsingTourData() then return end
    local job = NewStockJob()
    CountStock(job, math.huge)
    SaveStock(job)
end

-- Stock is only counted for items in saved recipes, so a recipe saved after
-- login (opening a profession on a fresh install) needs a new count: without
-- it Gold in stock said "nothing tracked in your bags yet" until a bag
-- changed or a relog (user's laptop, 2026-10-15). Waits for a burst of
-- saves (a profession's whole scan) to finish, then counts once.
local STOCK_RECOUNT_DELAY = 3
local recountTimer

function addon:RecountStockSoon()
    if recountTimer then recountTimer:Cancel() end
    recountTimer = C_Timer.NewTimer(STOCK_RECOUNT_DELAY, function()
        recountTimer = nil
        -- Saving the recipes refreshed already: again only for new counts
        SnapshotStock(function(changed)
            if changed and addon.Refresh then addon.Refresh() end
        end)
    end)
end

-- An item's stock across the account, leaving out characters excluded in
-- Settings. Returns the total and a list of { key, name, count } (the
-- warband bank has key "warband"), largest first.
function addon:GetStock(itemID)
    local list, total = {}, 0
    for key, c in pairs(GoldsmithDB.characters) do
        local included = addon:IsCharacterIncluded(key)
        local count = included and c.stock[itemID] or 0
        -- In their mailbox: bought with Buy next, or mailed from another
        -- of your characters (Shop.lua)
        local book = included and GoldsmithDB.inMail and GoldsmithDB.inMail[key]
        local mail = book and book[itemID] and math.max(book[itemID].quantity or 0, 0) or 0
        if count + mail > 0 then
            -- bank: how many of them are in the bank (nil: not known yet,
            -- saved before this was kept)
            local bank = c.stockBank and math.min(c.stockBank[itemID] or 0, count)
            table.insert(list, { key = key, name = c.name, count = count + mail, bank = bank, mail = mail })
            total = total + count + mail
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

-- "4 (bags)", "2 (bank)", "4 (3 bags, 1 bank)" for a GetStock entry
function addon:StockWhereText(entry)
    local count = tostring(entry.count)
    local mail = entry.mail or 0
    if mail > 0 then
        local bank = entry.bank or 0
        local bags = entry.count - bank - mail
        local parts = {}
        if bags > 0 then table.insert(parts, bags .. " bags") end
        if bank > 0 then table.insert(parts, bank .. " bank") end
        table.insert(parts, mail .. " mail")
        if #parts == 1 then return count .. " (mail)" end
        return count .. " (" .. table.concat(parts, ", ") .. ")"
    end
    if entry.key == "warband" or entry.bank == nil then return count end
    if entry.bank == 0 then return count .. " (bags)" end
    if entry.bank >= entry.count then return count .. " (bank)" end
    return string.format("%d (%d bags, %d bank)", entry.count, entry.count - entry.bank, entry.bank)
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

-- A sale collected from the mail (Core.lua). itemID is the quality, when
-- the sale matched your post; the mail itself only names the item. By name
-- only when one listing has that name: qualities share it, and lowering
-- the wrong one made Goldsmith suggest a quality still listed. Otherwise
-- the counts wait for the next AH visit (held errs toward not suggesting).
function addon:AuctionSold(itemName, count, itemID)
    local auctions = addon.char.auctions
    if not (itemID and auctions[itemID]) then
        itemID = nil
        for id in pairs(auctions) do
            if C_Item.GetItemNameByID(id) == itemName then
                if itemID then return end
                itemID = id
            end
        end
        if not itemID then return end
    end
    local left = auctions[itemID] - (count or 1)
    auctions[itemID] = left > 0 and left or nil
end

-- Everything you hold of an item, whether or not the character counts
-- (an excluded bank alt still holds it): bags and banks on every
-- character, the warband bank, and AH listings.
-- With a tier, gear counts only that tier: silver gear doesn't stop gold
-- being made. Items whose tier wasn't read (a bank the game hadn't
-- loaded, stock saved before tiers were kept) count toward every tier, to
-- be safe.
function addon:GetHeld(itemID, tier)
    local stored, listed = addon:GetHeldParts(itemID, tier)
    return stored + listed
end

-- The same, in two parts: in bags and banks (the warband bank too), and
-- listed on the AH. Mail isn't in either (InMailCountFor, Shop.lua).
-- where: a table to fill with where they are, one entry per character
-- (and the warband bank) holding any: { key, name, stored, bank, listed }
function addon:GetHeldParts(itemID, tier, where)
    local function Count(total, tiers)
        local byTier = tier and tiers and tiers[itemID]
        if not byTier or total == 0 then return total end
        local known = 0
        for _, n in pairs(byTier) do known = known + n end
        return math.min((byTier[tier] or 0) + math.max(total - known, 0), total)
    end
    local stored = Count(GoldsmithDB.warbandStock[itemID] or 0, GoldsmithDB.warbandGearTiers)
    if where and stored > 0 then
        table.insert(where, { key = "warband", name = "Warband bank", stored = stored, bank = stored, listed = 0 })
    end
    local listed = 0
    for key, c in pairs(GoldsmithDB.characters) do
        local s, l = Count(c.stock[itemID] or 0, c.gearTiers), Count(c.auctions[itemID] or 0, c.auctionTiers)
        stored, listed = stored + s, listed + l
        if where and s + l > 0 then
            table.insert(where, { key = key, name = c.name or key, stored = s, listed = l,
                bank = c.stockBank and math.min(c.stockBank[itemID] or 0, s) or 0 })
        end
    end
    return stored, listed
end

-- Goldmaking time
--
-- Time spent making gold, for gold per hour: while a profession window, the
-- AH, the mailbox, a vendor or the bank is open. A gap shorter than
-- GOLDMAKING_GAP between two of them (walking from the AH to the mailbox)
-- counts too. Dungeons, questing and idling in town don't.
local GOLDMAKING_GAP = 2 * 60 -- the city flight from professions to the AH is 15-20 s (user, 2026-10-30); was 5 min
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

-- Stock is only counted while something uses it: Goldsmith's window, a
-- profession, the AH, mail, a vendor or the bank. Questing or in a dungeon
-- bags change all the time and nothing needs the count ("i am only crafting
-- in the city", user 2026-10-15), so a bag change there only marks it stale
-- and opening one of those counts it.
local stockStale = true -- nothing counted since login

local function StockInUse()
    return IsGoldmaking() or (addon.window ~= nil and addon.window:IsShown())
end

function addon:CountStockIfStale()
    if not stockStale then return end
    stockStale = false
    -- Bags change in bursts while crafting or looting, and the same bags
    -- recounted reloaded the window every 10 s (user, 2026-11-03)
    SnapshotStock(function(changed)
        if changed and addon.Refresh then addon.Refresh() end
        -- Something new in stock can be worth selling too, not only new
        -- prices: a Sunglass Vial taken out after the scan made the card
        -- but no chat line (user, 2026-10-29). Once a day per item anyway.
        addon:CheckSellNow()
    end)
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
-- counts as nothing. Returns { { day, copper, warband, characters } },
-- characters = { { key, copper } } with gold that day, most first.
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
        local warband = ValueOn(GoldsmithDB.warbandGold, day)
        local total, characters = warband, {}
        for key, c in pairs(GoldsmithDB.characters) do
            if addon:IsCharacterIncluded(key) then
                local copper = ValueOn(c.gold, day)
                total = total + copper
                if copper > 0 then table.insert(characters, { key = key, copper = copper }) end
            end
        end
        table.sort(characters, function(a, b) return a.copper > b.copper end)
        table.insert(list, { day = day, copper = total, warband = warband, characters = characters })
    end
    return list
end

-- loggingOut: the game reports 0 gold while logging out or reloading, so
-- gold isn't saved then (PLAYER_MONEY and login keep it up to date)
local function UpdateAll(loggingOut)
    -- Not while the tour shows its sample data (Tour.lua): it isn't yours
    if addon:UsingTourData() then return end
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
-- recipe: that recipe's own concentration (an older expansion's has its
-- own, see GetConcentration), or nil if it hasn't been saved
function addon:GetCharacterConcentration(charKey, profession, recipe)
    local c = GoldsmithDB.characters[charKey]
    local snap = c and c.concentration[profession]
    local id = recipe and addon:RecipeConcentrationCurrency(recipe.recipeID)
    if id and not (snap and snap.currencyID == id) then
        snap = c and c.concentrationByCurrency and c.concentrationByCurrency[id]
    end
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
    keyFor = {}
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
    SnapshotStockNow()
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
    local name, first = addon:PlayerName()
    if not GoldsmithDB.characters[key] and name and name ~= first then
        ClaimFirstNameRecord(key, name, first, GetRealmName())
    end
    keyFor = {}
    local c = GoldsmithDB.characters[key]
    if not c then
        c = NewCharacter(name, GetRealmName())
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

    local pending, stockPending, entered = false, false, false
    -- What a skill or currency event can change that the window shows:
    -- skill and concentration (whole points) per profession
    local function ProfessionPrint()
        local c, prints = addon.char, {}
        for name, p in pairs(c.professions or {}) do
            local conc = c.concentration and c.concentration[name]
            prints[name] = { p.skill, p.maxSkill, conc and math.floor(conc.current or 0), conc and conc.max }
        end
        return prints
    end
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
            stockStale = true
        end
        if GOLDMAKING_OPEN[event] then
            OnGoldmakingOpen(GOLDMAKING_OPEN[event])
            C_Timer.After(1, function() addon:CountStockIfStale() end)
            return
        elseif GOLDMAKING_CLOSE[event] then
            OnGoldmakingClose(GOLDMAKING_CLOSE[event])
            return
        end

        if event == "PLAYER_LOGOUT" then
            -- No stock snapshot here: bags read as empty while logging out.
            -- Opening the window or a profession, AH, mail, vendor or bank
            -- counts it (CountStockIfStale).
            FlushGoldTime()
            UpdateAll(true)
        elseif event == "PLAYER_MONEY" then
            RecordGold()
        elseif event == "BAG_UPDATE_DELAYED" then
            -- Bags change in bursts while crafting or looting
            stockStale = true
            if StockInUse() and not stockPending then
                stockPending = true
                C_Timer.After(10, function()
                    stockPending = false
                    if StockInUse() then addon:CountStockIfStale() end
                end)
            end
        elseif not pending or event == "PLAYER_ENTERING_WORLD" then
            -- Profession and currency data can arrive a moment after these
            -- events, and they can fire in bursts
            pending = true
            entered = entered or event == "PLAYER_ENTERING_WORLD"
            C_Timer.After(2, function()
                if not pending then return end
                pending = false
                local before = ProfessionPrint()
                UpdateAll()
                -- Any currency fires this (crests, anything looted): only
                -- new skill or concentration is worth a reload (user,
                -- 2026-11-03: too much loading); logging in always is
                if (entered or not addon:SameData(before, ProfessionPrint())) and addon.Refresh then
                    addon.Refresh()
                end
                entered = false
            end)
        end
    end)
end

-- /gsm fakechars [count] (dev tools): copies of your characters until
-- there are `count` (27 by default), all counted, to try data shaped like
-- a player with many alts (Atlasdair froze 15-20 s on the Patron tab with
-- 27 characters, 2026-11-03). Only for this session: /gsm fakechars off,
-- or logging out or /reload, takes them away before the game saves.
local function RemoveFakeCharacters()
    local removed = 0
    for key, c in pairs(GoldsmithDB and GoldsmithDB.characters or {}) do
        if c.goldsmithFake then
            GoldsmithDB.characters[key] = nil
            removed = removed + 1
        end
    end
    return removed
end

function addon:FakeCharacters(rest)
    rest = rest and strtrim(rest) or ""
    if rest == "off" then
        print(string.format("Goldsmith: removed %d copied characters", RemoveFakeCharacters()))
    else
        local want = tonumber(rest) or 27
        local real, count = {}, 0
        for key, c in pairs(GoldsmithDB.characters) do
            count = count + 1
            if not c.goldsmithFake then table.insert(real, key) end
        end
        table.sort(real)
        local made = 0
        while count < want and #real > 0 do
            local from = real[made % #real + 1]
            local name, realm = from:match("^(.-)%-(.+)$")
            local copy = CopyTable(GoldsmithDB.characters[from])
            copy.goldsmithFake = true
            made = made + 1
            GoldsmithDB.characters[string.format("%sCopy%d-%s", name or from, made, realm or "Copy")] = copy
            count = count + 1
        end
        print(string.format("Goldsmith: %d characters now (%d copied, all counted). /gsm fakechars off removes them.",
            count, made))
    end
    addon:DataChanged()
    if addon.Refresh then addon.Refresh() end
end

-- Made as the file loads, before the frames that save at logout (as the
-- tour's): the copies never reach the saved file
local fakeLogout = CreateFrame("Frame")
fakeLogout:RegisterEvent("PLAYER_LOGOUT")
fakeLogout:SetScript("OnEvent", RemoveFakeCharacters)

_G.Goldsmith = addon
