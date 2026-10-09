local addon = _G.Goldsmith or {}

-- Gathered materials
--
-- Materials you got without buying them: herbs, ore and skins you
-- gathered, cloth from mobs, and what's inside bags you open (patron order
-- rewards, quest and event caches). Recorded from the game's loot messages
-- ("You receive loot: ..."), one running total per item, character and day:
--   GoldsmithDB.gathered = { { day = "YYYY-MM-DD", time (latest), itemID,
--     name, qty, value (copper at the AH price when gathered, for History),
--     character, realm } }
-- Kept apart from the ledger so it never counts as money spent.
--
-- What they're worth stays the AH price (you could sell them instead, so a
-- craft only looks good if it beats that). What they change is the cost of
-- bought materials: GetAverageCost takes the newest purchases covering what
-- you hold, and without these, 200 gathered herbs would all be costed at
-- what you once paid for 20 (see GetAcquiredCost).
--
-- Not counted: materials from crafting, salvage, milling, prospecting or
-- disenchanting (they cost what went in), and items pushed into your bags
-- while a vendor, the mailbox, a trade or the AH is open (bought, not
-- gathered).

-- Loot from these isn't free: it costs what was used up
local SALVAGE_SPELLS = {
    [13262] = true, -- Disenchant
    [51005] = true, -- Milling
    [31252] = true, -- Prospecting
}
-- Loot shortly after a craft or salvage belongs to it
local CRAFT_GRACE = 3

-- Patterns from the game's own strings, so other languages work too.
-- "x%d" ones first: the plain one would swallow the count into the link.
local function Pattern(text)
    if not text then return nil end
    local p = text:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    p = p:gsub("%%%%s", "(.+)"):gsub("%%%%d", "(%%d+)")
    return "^" .. p .. "$"
end

local PATTERNS = {}
for _, key in ipairs({ "LOOT_ITEM_SELF_MULTIPLE", "LOOT_ITEM_PUSHED_SELF_MULTIPLE",
                       "LOOT_ITEM_SELF", "LOOT_ITEM_PUSHED_SELF" }) do
    local p = Pattern(_G[key])
    if p then table.insert(PATTERNS, { pattern = p, pushed = key:find("PUSHED") ~= nil }) end
end
-- What your own loot messages start with ("You receive loot: ")
local PREFIXES = {}
for _, key in ipairs({ "LOOT_ITEM_SELF", "LOOT_ITEM_PUSHED_SELF" }) do
    local prefix = _G[key] and _G[key]:match("^(.-)%%s")
    if prefix and prefix ~= "" then table.insert(PREFIXES, prefix) end
end

-- A craft cast never ending (no event came) stops counting after this
local CAST_LIMIT = 30
-- Loot messages kept for /gsm gathered, to see why one wasn't counted.
-- Saved (GoldsmithDB.gatheredLog), so they can be read after logging out.
local RECENT_LIMIT = 30
-- What comes out of a bag you open counts for this long after
local OPENED_GRACE = 5

local busyUntil = 0 -- crafting or salvaging until then (GetTime)
local castingSince -- a craft or salvage cast started then (GetTime)
local openedUntil = 0 -- a bag you opened is giving its loot until then
local open = {} -- vendor, mail, trade, AH: what's pushed then was bought
local lookup -- "day|character|realm|itemID" -> entry
local version = 0 -- bumped on every change, for the index
local index, indexVersion
local recent = {} -- { time, text, result, character }, newest last

-- A bag of loot you opened (patron order payouts, caches): what's in it
-- is free even with the mailbox open or right after a craft
local function OpenedBag()
    openedUntil = GetTime() + OPENED_GRACE
end

local function FromOpenedBag()
    return GetTime() < openedUntil
end

local function Busy()
    castingSince = nil
    busyUntil = GetTime() + CRAFT_GRACE
end

local function StartCast()
    castingSince = GetTime()
end

local function Crafting()
    if castingSince and GetTime() - castingSince < CAST_LIMIT then return true end
    castingSince = nil
    return GetTime() < busyUntil
end

local function Note(text, result)
    table.insert(recent, { time = time(), text = text, result = result, character = UnitName("player") })
    if #recent > RECENT_LIMIT then table.remove(recent, 1) end
end

local function Key(day, character, realm, itemID)
    return day .. "|" .. tostring(character) .. "|" .. tostring(realm) .. "|" .. itemID
end

local function BuildLookup()
    lookup = {}
    for _, e in ipairs(GoldsmithDB.gathered) do
        lookup[Key(e.day, e.character, e.realm, e.itemID)] = e
    end
end

-- A material Goldsmith tracks (from a saved recipe), or anything the game
-- calls a crafting reagent
local function IsMaterial(itemID, name)
    if addon:GetProfessionForItemName(name) then return true end
    local isReagent = select(17, C_Item.GetItemInfo(itemID))
    return isReagent == true
end

-- The name from a link when the item isn't loaded yet, without the tier
-- icon materials have in theirs
local function LinkName(link)
    local text = link and link:match("%[(.-)%]")
    if not text then return nil end
    text = text:gsub("|A.-|a", ""):gsub("^%s+", ""):gsub("%s+$", "")
    return text ~= "" and text or nil
end

-- Returns true if recorded
function addon:RecordGathered(itemID, qty, link)
    local name = C_Item.GetItemNameByID(itemID) or LinkName(link)
    if not name or qty <= 0 or not IsMaterial(itemID, name) then return false end
    local now = time()
    local day = date("%Y-%m-%d", now)
    local character, realm = UnitName("player"), GetRealmName()
    local key = Key(day, character, realm, itemID)
    local e = lookup[key]
    if not e then
        e = { day = day, itemID = itemID, name = name, qty = 0, value = 0, character = character, realm = realm }
        table.insert(GoldsmithDB.gathered, e)
        lookup[key] = e
    end
    e.qty = e.qty + qty
    e.value = e.value + (addon:GetMarketPrice(itemID) or 0) * qty
    e.time = now
    version = version + 1
    -- No addon.Refresh: gathering is constant and costs would be worked
    -- out again every herb. Everything catches up on the next refresh.
    return true
end

local function OnLoot(message)
    if issecretvalue and issecretvalue(message) then
        Note("(hidden by the game)", "skipped: the game hides loot messages here")
        return
    end
    if type(message) ~= "string" then return end
    for _, p in ipairs(PATTERNS) do
        local link, count = message:match(p.pattern)
        if link then
            local itemID = tonumber(link:match("item:(%d+)"))
            if not itemID then return end
            local text = link .. (count and (" x" .. count) or "")
            local fromBag = FromOpenedBag()
            if not fromBag and Crafting() then
                Note(text, "skipped: from a craft or salvage")
            elseif not fromBag and p.pushed and next(open) then
                Note(text, "skipped: a vendor, mailbox, trade or AH was open")
            elseif addon:RecordGathered(itemID, tonumber(count) or 1, link) then
                Note(text, fromBag and "counted (from a bag you opened)" or "counted")
            else
                Note(text, "skipped: not a crafting material")
            end
            return
        end
    end
    -- Yours in a wording the patterns missed ("You receive loot: ..." with
    -- something extra); someone else's loot isn't noted
    if message:find("|Hitem:") then
        for _, prefix in ipairs(PREFIXES) do
            if message:sub(1, #prefix) == prefix then
                Note(message, "skipped: didn't match a loot message")
                return
            end
        end
    end
end

-- /gsm gathered: today's gathered materials and the last loot messages
function addon:ListGathered()
    local today, any = date("%Y-%m-%d"), false
    for _, e in ipairs(GoldsmithDB.gathered) do
        if e.day == today then
            if not any then
                print("|cFFFFD100Goldsmith|r gathered today:")
                any = true
            end
            print(string.format("  %s x%d (%s)", e.name, e.qty, e.character or "?"))
        end
    end
    if not any then print("|cFFFFD100Goldsmith|r: nothing gathered today yet.") end
    if #recent == 0 then
        print("  No loot messages seen yet.")
        return
    end
    print("  Latest loot messages:")
    for _, r in ipairs(recent) do
        print(string.format("    %s  %s%s: %s", date("%m-%d %H:%M:%S", r.time),
            r.character and r.character ~= UnitName("player") and (r.character .. ", ") or "", r.text, r.result))
    end
end

-- Entries by item name (tiers share a name, like purchases), oldest first
function addon:GatheredIndex()
    if index and indexVersion == version then return index end
    local idx = {}
    for _, e in ipairs(GoldsmithDB.gathered) do
        local list = idx[e.name]
        if not list then
            list = {}
            idx[e.name] = list
        end
        list[#list + 1] = e
    end
    for _, list in pairs(idx) do
        table.sort(list, function(a, b) return (a.time or 0) < (b.time or 0) end)
    end
    index, indexVersion = idx, version
    return idx
end

-- How you got what you hold of an item: the newest purchases and gathered
-- lots, going back until they cover what you have on every character (or
-- just the newest one when you hold none, e.g. right after a craft used
-- them up). Returns
--   paid, paidQty         - copper per unit of the purchases covered
--                           (nil if none are)
--   gatheredQty, itemIDs  - units covered by gathering, and how many of
--                           each item ID (tiers are priced apart)
-- or nil if you've never bought or gathered it.
function addon:GetAcquiredCost(itemName)
    local list, ids = {}, {}
    for _, e in ipairs(addon.ledger:index().purchases[itemName] or {}) do
        if (e.quantity or 0) > 0 then
            list[#list + 1] = { time = e.timestamp or 0, qty = e.quantity, copper = e.totalCopper }
            if e.itemID then ids[e.itemID] = true end
        end
    end
    local gathered = addon:GatheredIndex()[itemName]
    for _, e in ipairs(gathered or {}) do
        list[#list + 1] = { time = e.time or 0, qty = e.qty, itemID = e.itemID }
        ids[e.itemID] = true
    end
    if #list == 0 then return nil end
    -- Each list is oldest first already; only a mix needs sorting
    if gathered and #list > #gathered then
        table.sort(list, function(a, b) return a.time < b.time end)
    end

    local held = 0
    for itemID in pairs(ids) do
        held = held + (addon.GetHeld and addon:GetHeld(itemID)
            or C_Item.GetItemCount(itemID, true, false, true, true) or 0)
    end

    local remaining, copper, paidQty, gatheredQty, gatheredIDs = math.max(held, 1), 0, 0, 0, {}
    for i = #list, 1, -1 do
        local a = list[i]
        local take = math.min(a.qty, remaining)
        if a.itemID then
            gatheredQty = gatheredQty + take
            gatheredIDs[a.itemID] = (gatheredIDs[a.itemID] or 0) + take
        else
            copper = copper + a.copper / a.qty * take
            paidQty = paidQty + take
        end
        remaining = remaining - take
        if remaining <= 0 then break end
    end
    return paidQty > 0 and copper / paidQty or nil, paidQty, gatheredQty, gatheredIDs
end

-- What the gathered ones you hold are worth now: today's AH price for each
-- tier. ids is GetAcquiredCost's itemIDs. Returns copper per unit and
-- units, or nil.
function addon:GatheredValue(ids)
    if not ids then return nil end
    local total, priced = 0, 0
    for itemID, n in pairs(ids) do
        local price = addon:GetMarketPrice(itemID)
        if price then
            total = total + price * n
            priced = priced + n
        end
    end
    if priced == 0 then return nil end
    return total / priced, priced
end

-- Gathered lots still covering what you hold, which Keep history for
-- leaves alone (like purchases: they say which of what you hold is free)
function addon:GatheredInUse(keep)
    for name, list in pairs(addon:GatheredIndex()) do
        local ids, held = {}, 0
        for _, e in ipairs(list) do ids[e.itemID] = true end
        for _, e in ipairs(addon.ledger:index().purchases[name] or {}) do
            if e.itemID then ids[e.itemID] = true end
        end
        for itemID in pairs(ids) do held = held + addon:GetHeld(itemID) end
        -- Purchases newer than a lot cover what you hold first; counting
        -- them too would need the merged walk, and keeping a few more small
        -- lots is harmless
        local remaining = math.max(held, 1)
        for i = #list, 1, -1 do
            keep[list[i]] = true
            remaining = remaining - list[i].qty
            if remaining <= 0 then break end
        end
    end
    return keep
end

-- Deletes gathered lots from before `before` that aren't in keep.
-- Returns how many went.
function addon:TrimGathered(before, keep)
    local kept, removed = {}, 0
    for _, e in ipairs(GoldsmithDB.gathered) do
        if (e.time or 0) < before and not keep[e] then
            removed = removed + 1
        else
            kept[#kept + 1] = e
        end
    end
    if removed > 0 then
        wipe(GoldsmithDB.gathered)
        for i, e in ipairs(kept) do GoldsmithDB.gathered[i] = e end
        BuildLookup()
        version = version + 1
    end
    return removed
end

-- Deletes these entries (History's right-click)
function addon:RemoveGathered(entries)
    local gone = {}
    for _, e in ipairs(entries) do gone[e] = true end
    local kept = {}
    for _, e in ipairs(GoldsmithDB.gathered) do
        if not gone[e] then kept[#kept + 1] = e end
    end
    wipe(GoldsmithDB.gathered)
    for i, e in ipairs(kept) do GoldsmithDB.gathered[i] = e end
    BuildLookup()
    version = version + 1
    if addon.Refresh then addon.Refresh() end
end

function addon:InitializeGathered()
    GoldsmithDB.gathered = GoldsmithDB.gathered or {}
    GoldsmithDB.gatheredLog = GoldsmithDB.gatheredLog or {}
    recent = GoldsmithDB.gatheredLog
    BuildLookup()

    -- Opening a bag of loot from your bags. The hook runs after the game
    -- has used the item; a bag that gives its loot is still there then.
    if C_Container and C_Container.UseContainerItem then
        hooksecurefunc(C_Container, "UseContainerItem", function(bag, slot)
            local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
            if ok and type(info) == "table" and not (canaccesstable and not canaccesstable(info)) and info.hasLoot then
                OpenedBag()
            end
        end)
    end

    -- Crafts and salvage: what they make isn't gathered. Only casts started
    -- from these count: asking the game whether a spell is a recipe also
    -- said yes to gathering (mined ore went uncounted, 2026-10-08).
    for _, fn in ipairs({ "CraftRecipe", "CraftSalvage", "CraftEnchant" }) do
        if C_TradeSkillUI[fn] then hooksecurefunc(C_TradeSkillUI, fn, StartCast) end
    end

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("CHAT_MSG_LOOT")
    frame:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT")
    local windows = {
        MERCHANT_SHOW = "MERCHANT_CLOSED", MAIL_SHOW = "MAIL_CLOSED", TRADE_SHOW = "TRADE_CLOSED",
        AUCTION_HOUSE_SHOW = "AUCTION_HOUSE_CLOSED",
    }
    local closes = {}
    for show, close in pairs(windows) do
        frame:RegisterEvent(show)
        frame:RegisterEvent(close)
        closes[close] = show
    end
    frame:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_START", "player")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_CHANNEL_STOP", "player")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")

    local function IsSalvageSpell(spellID)
        if not spellID or (issecretvalue and issecretvalue(spellID)) then return false end
        return SALVAGE_SPELLS[spellID] == true
    end

    -- A loot window whose loot comes from an item is a bag you opened
    frame:RegisterEvent("LOOT_OPENED")
    frame:RegisterEvent("LOOT_CLOSED")
    local function LootFromItem()
        if not (GetNumLootItems and GetLootSourceInfo) then return false end
        for slot = 1, GetNumLootItems() or 0 do
            local guid = GetLootSourceInfo(slot)
            if guid and not (issecretvalue and issecretvalue(guid)) and type(guid) == "string"
                and guid:find("^Item%-") then
                return true
            end
        end
        return false
    end
    local lootFromItem = false

    frame:SetScript("OnEvent", function(_, event, ...)
        if event == "CHAT_MSG_LOOT" then
            OnLoot(...)
        elseif event == "LOOT_OPENED" then
            lootFromItem = LootFromItem()
            if lootFromItem then OpenedBag() end
        elseif event == "LOOT_CLOSED" then
            -- Messages for what you took can come just after
            if lootFromItem then OpenedBag() end
            lootFromItem = false
        elseif event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
            Busy()
        elseif windows[event] then
            open[event] = true
        elseif closes[event] then
            open[closes[event]] = nil
        elseif event == "UNIT_SPELLCAST_START" or event == "UNIT_SPELLCAST_CHANNEL_START" then
            if IsSalvageSpell(select(3, ...)) then StartCast() end
        elseif castingSince or (event == "UNIT_SPELLCAST_SUCCEEDED" and IsSalvageSpell(select(3, ...))) then
            -- Done, stopped or interrupted: loot may still be on its way
            Busy()
        end
    end)
end

_G.Goldsmith = addon
