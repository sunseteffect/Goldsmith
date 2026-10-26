local addon = _G.Goldsmith or {}

-- Gathered materials
--
-- Materials you got without buying them: herbs, ore and skins you
-- gathered, cloth from mobs, and what's inside bags you open (patron order
-- rewards, quest and event caches). Recorded from the game's loot messages
-- ("You receive loot: ..."), one running total per item, character and day:
--   GoldsmithDB.gathered = { { day = "YYYY-MM-DD", time (latest), itemID,
--     name, qty, value (copper at the AH price when gathered, for History),
--     character, realm, box (what came out of a box you crafted: kept
--     apart, with cost and costQty, see ShareBoxCost) } }
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

-- Boxes you craft (School of Gems, Box of Rocks, Bouquet of Herbs): bound,
-- so they're worth what's inside, and nobody publishes the odds (2026-10-11).
-- What comes out each time you open one is kept:
--   GoldsmithDB.boxContents[boxItemID] = { opened, items = { [itemID] = qty } }
-- GetBoxValue turns that into the box's worth (Pricing.lua prices it with
-- that, and Crafts lists the recipe once one has been opened).
-- Payout bags from crafting orders (Artisan's Consortium) are tracked the
-- same way, so an order's profit can count the bag at what's inside on
-- average (Pricing.lua, ValueRewards); what comes out of them stays
-- gathered (user, 2026-10-11).
local openingBox -- the box being opened, while its loot comes in
local openingCrafted -- it's one you crafted (its loot isn't gathered)
local boxUntil = 0

local function IsCraftedBox(itemID)
    for _, recipe in pairs(GoldsmithDB.recipes) do
        if recipe.outputItemID == itemID then return true end
    end
    return false
end

-- A bag you've had as a crafting order's reward
local function IsRewardBag(itemID)
    for _, lot in ipairs(GoldsmithDB.orderCrafts or {}) do
        for _, r in ipairs(lot.rewards or {}) do
            if r.itemID == itemID then return true end
        end
    end
    return false
end

-- What comes out of a box isn't gathered: it cost what the box cost to
-- make (user, 2026-10-11: "they weren't free"). Its materials are kept
-- apart (entry.box) with a share of that cost each, by value, so 11 cheap
-- herbs don't each cost as much as 5 dear ones: entry.cost (copper) for
-- entry.costQty of them. GetAcquiredCost counts them like a purchase.
local openingLoot -- { { entry, qty, value } } from the box being opened

local function ShareBoxCost(cost, loot)
    if not cost or #loot == 0 then return end
    local total, qty = 0, 0
    for _, l in ipairs(loot) do total, qty = total + l.value, qty + l.qty end
    for _, l in ipairs(loot) do
        local share = total > 0 and l.value / total or l.qty / qty
        l.entry.cost = (l.entry.cost or 0) + cost * share
        l.entry.costQty = (l.entry.costQty or 0) + l.qty
    end
    version = version + 1
end

-- crafted: a box you crafted (its loot is kept apart, with a cost); else
-- a payout bag (only what's inside is noted)
local function BoxOpened(itemID, crafted)
    GoldsmithDB.boxContents = GoldsmithDB.boxContents or {}
    local box = GoldsmithDB.boxContents[itemID] or { opened = 0, items = {} }
    GoldsmithDB.boxContents[itemID] = box
    box.opened = box.opened + 1
    openingBox, openingCrafted, boxUntil = itemID, crafted, GetTime() + OPENED_GRACE
    if not crafted then
        openingLoot = nil
        return
    end
    -- When each was opened (Followed counts a box when it's opened)
    box.openedAt = box.openedAt or {}
    table.insert(box.openedAt, time())
    -- Your newest craft of the box: what this one cost
    local cost = addon:GetCraftedCost(itemID, 1)
    local loot = {}
    openingLoot = loot
    C_Timer.After(OPENED_GRACE + 1, function() ShareBoxCost(cost, loot) end)
end

-- Returns the box it came out of if one you crafted, else true if it came
-- out of a payout bag
local function BoxLoot(itemID, qty)
    if not openingBox or GetTime() >= boxUntil then return nil end
    local box = GoldsmithDB.boxContents[openingBox]
    box.items[itemID] = (box.items[itemID] or 0) + qty
    if openingCrafted then return openingBox end
    return true
end

-- A box's worth: the average of what came out of it at today's prices.
-- Returns copper per box, times opened, and whether everything had a
-- price; nil if none has been opened.
function addon:GetBoxValue(itemID)
    local box = itemID and GoldsmithDB.boxContents and GoldsmithDB.boxContents[itemID]
    if not (box and box.opened > 0 and next(box.items)) then return nil end
    local total, complete = 0, true
    for id, qty in pairs(box.items) do
        local price = addon:GetMarketPrice(id)
        if price then total = total + price * qty else complete = false end
    end
    return total / box.opened, box.opened, complete
end

-- What's inside on average: { { itemID, each (per box) } }, most first
function addon:GetBoxContents(itemID)
    local box = itemID and GoldsmithDB.boxContents and GoldsmithDB.boxContents[itemID]
    if not (box and box.opened > 0) then return nil end
    local list = {}
    for id, qty in pairs(box.items) do table.insert(list, { itemID = id, each = qty / box.opened }) end
    table.sort(list, function(a, b) return a.each > b.each end)
    return list, box.opened
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

-- box: the box it came out of, payout: out of a payout bag (each kept
-- apart from what you gathered yourself)
local function Key(day, character, realm, itemID, box, payout)
    return day .. "|" .. tostring(character) .. "|" .. tostring(realm) .. "|" .. itemID .. "|"
        .. tostring(box or (payout and "payout") or "")
end

local function BuildLookup()
    lookup = {}
    for _, e in ipairs(GoldsmithDB.gathered) do
        lookup[Key(e.day, e.character, e.realm, e.itemID, e.box, e.payout)] = e
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

-- Returns true if recorded. box: the crafted box it came out of;
-- payout: it came out of a crafting order's payout bag (its worth counted
-- in the order's profit already, so selling it isn't profit again;
-- GetOwnCost)
function addon:RecordGathered(itemID, qty, link, box, payout)
    local name = C_Item.GetItemNameByID(itemID) or LinkName(link)
    if not name or qty <= 0 or not IsMaterial(itemID, name) then return false end
    local now = time()
    local day = date("%Y-%m-%d", now)
    local character, realm = UnitName("player"), GetRealmName()
    local key = Key(day, character, realm, itemID, box, payout)
    local e = lookup[key]
    if not e then
        e = { day = day, itemID = itemID, name = name, qty = 0, value = 0, character = character, realm = realm,
              box = box, payout = payout or nil }
        table.insert(GoldsmithDB.gathered, e)
        lookup[key] = e
    end
    local value = (addon:GetMarketPrice(itemID) or 0) * qty
    e.qty = e.qty + qty
    e.value = e.value + value
    e.time = now
    if box and openingLoot then table.insert(openingLoot, { entry = e, qty = qty, value = value }) end
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
            local from = fromBag and BoxLoot(itemID, tonumber(count) or 1)
            local box = type(from) == "number" and from or nil
            local payout = from == true
            if not fromBag and Crafting() then
                Note(text, "skipped: from a craft or salvage")
            elseif not fromBag and p.pushed and next(open) then
                Note(text, "skipped: a vendor, mailbox, trade or AH was open")
            elseif addon:RecordGathered(itemID, tonumber(count) or 1, link, box, payout) then
                Note(text, box and "counted (from a box you crafted)" or payout and "counted (from a payout bag)"
                    or fromBag and "counted (from a bag you opened)" or "counted")
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

-- How many of an item you hold: every character's saved stock, but at
-- least what this character holds now. The saved stock only covers
-- materials your recipes use (a Nocturnal Lotus counted as none held, so
-- only the newest, bought one, was looked at, 2026-10-09).
-- Mail counts too: bought with Buy next and not taken out yet, or mailed
-- from another of your characters. Without it, 7 Petrified Root in the
-- mail between your characters left 13 held, so only the cheap newest
-- purchases counted (69.58g each); taken out, 20 held reached back to the
-- 118g ones (96.17g; user, 2026-10-24).
function addon:HeldAnywhere(itemID)
    local here = C_Item.GetItemCount(itemID, true, false, true, true) or 0
    local mail = 0
    for key in pairs(GoldsmithDB.inMail or {}) do
        mail = mail + (addon.InMailCountFor and addon:InMailCountFor(key, itemID) or 0)
    end
    return math.max(addon.GetHeld and addon:GetHeld(itemID) or 0, here) + mail
end

-- Lots from your own salvage runs (mill, prospect, crush), for
-- GetAcquiredCost: each run's share of what went in, like a purchase, so
-- they take their turn by date with what you bought. Before, every
-- Gemdust ever crushed (9, from a few test crushes at gem prices) was
-- averaged with the 8 bought at 33g that you hold: 62g each, and a
-- Kaleidoscopic Prism showed -58g instead of about +170g (user,
-- 2026-10-24). From GoldsmithDB.salvageRuns (the last 120 runs); older
-- ones are left to the all-time average (GetMilledCost) for what these
-- don't cover. Returns { { time, qty, copper, itemID } } oldest first.
local salvageLotCache
local salvageBusy = {}
local function SalvageLots(itemName, exactItemID)
    salvageLotCache = salvageLotCache or addon:NewCache()
    local store = salvageLotCache:Get()
    local key = itemName .. ":" .. tostring(exactItemID)
    if store[key] then return store[key] end
    if salvageBusy[itemName] then return {} end
    salvageBusy[itemName] = true
    local lots = {}
    for _, run in ipairs(GoldsmithDB.salvageRuns or {}) do
        local record = run.itemID and GoldsmithDB.milling[run.itemID]
        local outputs = run.outputs
        if record and outputs and (run.used or 0) > 0 then
            for outID, qty in pairs(outputs) do
                local out = record.outputs and record.outputs[outID]
                local name = out and out.name or C_Item.GetItemNameByID(outID)
                if qty > 0 and name == itemName and (not exactItemID or outID == exactItemID) then
                    -- What the herbs cost when milled (older runs: now)
                    local unit = run.herbCost or addon:GetHerbUnitCost(run.itemID, record.name)
                    if unit then
                        -- This output's share of the run, by AH value (by
                        -- count when something has no price)
                        local sumValue, sumQty, priced = 0, 0, true
                        for id, q in pairs(outputs) do
                            sumQty = sumQty + q
                            local p = addon:GetMarketPrice(id)
                            if p then sumValue = sumValue + p * q else priced = false end
                        end
                        local mine = addon:GetMarketPrice(outID)
                        local share = (priced and sumValue > 0 and mine) and (mine * qty / sumValue) or (qty / sumQty)
                        table.insert(lots, { time = run.time or 0, qty = qty, copper = unit * run.used * share,
                                             itemID = outID })
                    end
                end
            end
        end
    end
    table.sort(lots, function(a, b) return a.time < b.time end)
    salvageBusy[itemName] = nil
    store[key] = lots
    return lots
end

-- How you got what you hold of an item: the newest purchases and gathered
-- lots, going back until they cover what you have on every character (or
-- just the newest one when you hold none, e.g. right after a craft used
-- them up). Returns
--   paid, paidQty         - copper per unit of the purchases covered
--                           (nil if none are)
--   gatheredQty, itemIDs  - units covered by gathering, and how many of
--                           each item ID (tiers are priced apart)
--   ownIDs                - of those, the ones you gathered yourself (not
--                           out of a payout bag), by item ID
--   uncovered             - units held that none of these cover
-- or nil if you've never bought or gathered it. Your own salvage runs
-- count as purchases here (SalvageLots).
-- exactItemID: only that item (one quality tier): silver and gold of a
-- material share a name, and by name a silver Munsell Ink was costed at
-- 37.50g, the average with gold ones, against 13.15g on the AH (2026-10-10)
-- skip: units of what you hold that came another way (your own crafts,
-- GetOwnCost), so only the rest is covered here; nil if that's all of it
-- (holding none, the newest one is still used, as without skip)
function addon:GetAcquiredCost(itemName, exactItemID, skip)
    local list, ids = {}, {}
    for _, e in ipairs(addon.ledger:index().purchases[itemName] or {}) do
        if (e.quantity or 0) > 0 and (not exactItemID or e.itemID == exactItemID) then
            list[#list + 1] = { time = e.timestamp or 0, qty = e.quantity, copper = e.totalCopper }
            if e.itemID then ids[e.itemID] = true end
        end
    end
    local gathered = addon:GatheredIndex()[itemName]
    local gatheredCount = 0
    for _, e in ipairs(gathered or {}) do
        if not exactItemID or e.itemID == exactItemID then
            if e.box and e.cost and (e.costQty or 0) > 0 then
                -- Out of a box you crafted: its share of the box's cost,
                -- like a purchase
                list[#list + 1] = { time = e.time or 0, qty = e.qty, copper = e.cost / e.costQty * e.qty }
            else
                list[#list + 1] = { time = e.time or 0, qty = e.qty, itemID = e.itemID, payout = e.payout }
            end
            ids[e.itemID] = true
            gatheredCount = gatheredCount + 1
        end
    end
    local listed = #list
    for _, lot in ipairs(SalvageLots(itemName, exactItemID)) do
        list[#list + 1] = { time = lot.time, qty = lot.qty, copper = lot.copper }
        ids[lot.itemID] = true
    end
    if exactItemID then ids = { [exactItemID] = true } end
    if #list == 0 then return nil end
    -- Each list is oldest first already; only a mix needs sorting
    if (gatheredCount > 0 and listed > gatheredCount) or (#list > listed and listed > 0) then
        table.sort(list, function(a, b) return a.time < b.time end)
    end

    local held = 0
    for itemID in pairs(ids) do held = held + addon:HeldAnywhere(itemID) end

    local remaining, copper, paidQty, gatheredQty, gatheredIDs, ownIDs = math.max(held, 1), 0, 0, 0, {}, {}
    if skip and skip > 0 and held > 0 then
        remaining = held - skip
        if remaining <= 0 then return nil, 0, 0, {}, {} end
    end
    for i = #list, 1, -1 do
        local a = list[i]
        local take = math.min(a.qty, remaining)
        if a.itemID then
            gatheredQty = gatheredQty + take
            gatheredIDs[a.itemID] = (gatheredIDs[a.itemID] or 0) + take
            if not a.payout then ownIDs[a.itemID] = (ownIDs[a.itemID] or 0) + take end
        else
            copper = copper + a.copper / a.qty * take
            paidQty = paidQty + take
        end
        remaining = remaining - take
        if remaining <= 0 then break end
    end
    return paidQty > 0 and copper / paidQty or nil, paidQty, gatheredQty, gatheredIDs, ownIDs,
        held > 0 and math.max(remaining, 0) or 0
end

-- What the ones you hold cost you in gold, gathered ones counting as free:
-- for break-even ("sell at this and you've made back what you spent"),
-- not for planning (that values gathered ones at the AH price, so a craft
-- never looks good just because its materials were free). Only when some
-- of what you hold was gathered. Returns cost per unit, units bought, what
-- each bought one cost, units gathered; or nil (user, 2026-10-09).
function addon:GetHeldCashCost(itemName)
    local paid, paidQty, gatheredQty = addon:GetAcquiredCost(itemName)
    if not gatheredQty or gatheredQty <= 0 then return nil end
    if not paid or (paidQty or 0) <= 0 then return 0, 0, nil, gatheredQty end
    return paid * paidQty / (paidQty + gatheredQty), paidQty, paid, gatheredQty
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
        for itemID in pairs(ids) do held = held + addon:HeldAnywhere(itemID) end
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

-- Deletes these entries (History's right-click). Returns what was removed
-- and where, for RestoreGathered (Undo).
function addon:RemoveGathered(entries)
    local gone = {}
    for _, e in ipairs(entries) do gone[e] = true end
    local kept, removed = {}, {}
    for i, e in ipairs(GoldsmithDB.gathered) do
        if gone[e] then
            removed[#removed + 1] = { entry = e, index = i }
        else
            kept[#kept + 1] = e
        end
    end
    wipe(GoldsmithDB.gathered)
    for i, e in ipairs(kept) do GoldsmithDB.gathered[i] = e end
    BuildLookup()
    version = version + 1
    if addon.Refresh then addon.Refresh() end
    return removed
end

-- Puts removed entries back where they were. Gathered again since (the
-- same day, character and item): added to that entry instead.
function addon:RestoreGathered(removed)
    for _, r in ipairs(removed or {}) do
        local e = r.entry
        local existing = lookup[Key(e.day, e.character, e.realm, e.itemID, e.box, e.payout)]
        if existing then
            existing.qty = existing.qty + (e.qty or 0)
            existing.value = (existing.value or 0) + (e.value or 0)
            if e.cost then
                existing.cost = (existing.cost or 0) + e.cost
                existing.costQty = (existing.costQty or 0) + (e.costQty or 0)
            end
        else
            table.insert(GoldsmithDB.gathered, math.min(r.index, #GoldsmithDB.gathered + 1), e)
        end
    end
    BuildLookup()
    version = version + 1
    if addon.Refresh then addon.Refresh() end
end

-- GoldsmithDB was swapped for another (the tour's sample data, Tour.lua)
function addon:GatheredSwapped()
    GoldsmithDB.gathered = GoldsmithDB.gathered or {}
    GoldsmithDB.gatheredLog = GoldsmithDB.gatheredLog or {}
    recent = GoldsmithDB.gatheredLog
    BuildLookup()
    version = version + 1
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
                if info.itemID and IsCraftedBox(info.itemID) then
                    BoxOpened(info.itemID, true)
                elseif info.itemID and IsRewardBag(info.itemID) then
                    BoxOpened(info.itemID, false)
                end
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
