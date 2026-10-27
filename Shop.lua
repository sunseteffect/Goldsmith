local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Buy next
--
-- Shopping for the queue at the AH, the way Craft next crafts it: one
-- button down the list (user, 2026-10-18: Auctionator's list means clicking
-- each item). It lives under the scan panel by the AH window (Scan.lua).
-- One click asks the AH what the next item costs for the amount the queue
-- needs (C_AuctionHouse.StartCommoditiesPurchase, which needs a click or
-- key). At or under the plan's cost it's bought right away
-- (ConfirmCommoditiesPurchase needs no click); over it, the panel says how
-- much more and what the queue would earn then, and a second click buys
-- (user, 2026-10-19: "if its cheaper buy it. only display warning if the
-- price is higher"). The confirm waits for the AH to be ready for another
-- message, as the game's own examples do: the first try sent it at once,
-- got no answer and sat on "Buying..." with nothing bought.
-- What to buy is the queue's own list (BuildQueue's buyAH), worked out
-- again after every purchase, so what's in your bags is never bought and a
-- bought item drops off by itself. Core.lua records what each purchase
-- really cost, as for any AH purchase. Send to Auctionator stays as the
-- other way to shop.
-- Settings' Buy next for: every character's queue (user, 2026-10-24:
-- buying on a bank alt for the crafters) adds their lists to yours, each
-- item tagged with whose queue it's for. What's bought for another
-- character is kept as on the way to them (GoldsmithDB.boughtFor) until
-- it's mailed, so neither queue buys it again.

local QUOTE_LIFE = 60           -- seconds a price is kept before asking again
local ANSWER_WAIT = 10          -- seconds without an answer before giving up
local FRESH = 3                 -- a price older than this is asked again before buying
local LINES = 12                 -- the whole list for most queues (user, 2026-10-19: see every item)
local LINE_HEIGHT = 16

local ahOpen = false
local section
local q                         -- the queue, as last planned
local asking                    -- { itemID, quantity, name } waiting for a price
local quote                     -- { itemID, quantity, name, total, unit, planCost, at }
local buying                    -- the purchase sent, until it succeeds or fails
local skipped = {}              -- itemID -> why, for this visit to the AH
local listingQty                -- { itemID, quantity } to fill in once the listings arrive
local lossAccepted = {}         -- queue entry -> its loss you clicked through, this visit
local Update, RefreshSoon       -- below

local function Money(copper) return addon:FormatMoney(copper) end

local function ItemName(entry)
    local icon = entry.qualityTier and (addon:TierIconText(entry.qualityTier, entry.tierCount) .. " ") or ""
    return icon .. (entry.name or ("item " .. entry.itemID))
end

-- Your queue is empty but another character's isn't: Buy next only shops
-- for the character you're on, and "Nothing to buy" on a bank alt reads as
-- broken (error review, 2026-10-23)
-- The All queues box in Buy next: starts as the setting says, and a click
-- flips it for now, either way (user, 2026-10-24: a toggle at hand, both
-- ways, without it getting confusing). Back to the setting once the list
-- it shows is bought (after at least one purchase, so unticking with
-- nothing of your own to buy doesn't tick itself again at once). Not
-- saved: /reload or logout goes back too.
local override                  -- nil (the setting), true (all queues) or false (just you)
local overrideBought = false
local function SettingAll() return addon:Setting("buyFor") == "all" end
local function BuyForAll()
    if override ~= nil then return override end
    return SettingAll()
end

-- Whether another character's queue still has something to buy at the AH
-- (bought for it and on the way counts as had): after buying all of it,
-- "tick All queues to buy for it" read as more to buy (user, 2026-10-24).
-- Planned once per data change.
local needsCache
local function NeedsBuying(key)
    needsCache = needsCache or addon:NewCache()
    local store = needsCache:Get()
    if store[key] == nil then
        local ok, plan = pcall(addon.BuildQueue, addon, key)
        store[key] = not ok or #(plan and plan.buyAH or {}) > 0
    end
    return store[key]
end

local function OtherQueueNote(also)
    if BuyForAll() then return nil end
    if not also and #addon:GetQueue(addon.charKey) > 0 then return nil end
    local names = {}
    for _, key in ipairs(addon:GetQueuedCharacters()) do
        if key ~= addon.charKey and NeedsBuying(key) then table.insert(names, addon.QueueCharName(key)) end
    end
    if #names == 0 then return nil end
    local who = #names == 1 and names[1] or (table.concat(names, ", ", 1, #names - 1) .. " and " .. names[#names])
    -- Your queue is covered: a reminder that theirs isn't shopped here
    -- (user, 2026-10-24)
    if also then return string.format("Tick All queues to buy for %s too.", who) end
    return string.format("Nothing queued here. Tick All queues to buy for %s.", who)
end

-- Your other characters holding the next item, when mailing it over would
-- save at least ALT_WORTH: plans only count this character's bags, bank,
-- warband bank and mail, so Buy next can buy 40 ore an alt holds 200 of.
-- Said, not planned around: most times rebuying beats logging over, but
-- not for a pile worth a lot (user, 2026-10-23). The warband bank is
-- already counted.
local ALT_WORTH = 100 * 10000

-- Who else an item on the list is for ("Maddoxius"), or nil when it's
-- only for you
local function ForWhom(entry)
    local names = {}
    for _, part in ipairs(entry and entry.parts or {}) do
        if part.key ~= addon.charKey then table.insert(names, addon.QueueCharName(part.key)) end
    end
    return #names > 0 and table.concat(names, ", ") or nil
end

-- Whether a queued craft of yours uses the item: then what you hold may be
-- spoken for, and isn't offered to someone else
local function OwnQueueUses(itemID)
    for _, e in ipairs(addon:GetQueue(addon.charKey)) do
        local recipe = e.recipeID and GoldsmithDB.recipes[e.recipeID]
        for _, r in ipairs(recipe and recipe.reagents or {}) do
            for _, id in ipairs(r.itemIDs or {}) do
                if id == itemID then return true end
            end
        end
    end
    return false
end

-- Bought here only for other characters' queues while you hold some
-- yourself: mail yours instead. On Maddoxynn with 18 Azeroot, Buy next
-- offered 7 more for Mysticmead (user, 2026-10-24: "it should probably
-- say send to mysticmead"). Not the warband bank (their plan counts it).
local function OwnStockNote(entry, unit)
    for _, part in ipairs(entry.parts or {}) do
        if part.key == addon.charKey then return nil end
    end
    local who = ForWhom(entry)
    if not who or OwnQueueUses(entry.itemID) then return nil end
    local have = (C_Item.GetItemCount(entry.itemID, true, false, true, false) or 0)
        - (addon.ReservedCount and addon:ReservedCount(entry.itemID) or 0)
    if have <= 0 then return nil end
    local send = math.min(have, entry.quantity)
    return string.format("You have %d %s: mail them to %s (saves %s). Right-click to skip.",
        have, entry.name or "of these", who, Money(send * unit))
end

local function AltStockNote(entry)
    if not (entry and entry.quantity and entry.quantity > 0 and entry.cost) then return nil end
    local unit = entry.cost / entry.quantity
    local mine = OwnStockNote(entry, unit)
    if mine then return mine end
    local _, list = addon:GetStock(entry.itemID)
    -- Not the characters it's bought for: their plans already count what
    -- they hold ("Trypttamine has 22 ore" on Trypttamine's own ore; user,
    -- 2026-10-24)
    local forThem = {}
    for _, part in ipairs(entry.parts or {}) do forThem[part.key] = true end
    local best
    for _, s in ipairs(list or {}) do
        if s.key ~= addon.charKey and s.key ~= "warband" and not forThem[s.key]
            and (not best or s.count > best.count) then best = s end
    end
    if not best then return nil end
    local saves = math.min(best.count, entry.quantity) * unit
    if saves < ALT_WORTH then return nil end
    -- How to act on it, right there (user, 2026-10-24: "i can't skip it")
    return string.format("%s has %d %s (saves %s). Right-click to skip.",
        best.name or "Another character", best.count, entry.name or "of these", Money(saves))
end


-- The first item on the queue's list not skipped this visit
local function NextEntry()
    for _, entry in ipairs(q and q.buyAH or {}) do
        if not skipped[entry.itemID] then return entry end
    end
end

local function Cancel()
    if quote or asking then pcall(C_AuctionHouse.CancelCommoditiesPurchase) end
    quote, asking = nil, nil
end

-- What the price means for the plan: extra over the plan's cost, and the
-- queue's profit then (nil when the queue has no profit to show)
local function Gap()
    if not quote then return end
    local extra = quote.total - (quote.planCost or quote.total)
    -- A stock-up isn't in the queue's profit, so its price doesn't change it
    local stock = q and q.stockOnly and q.stockOnly[quote.itemID]
    local profitThen = not stock and q and q.complete and q.profit and (q.profit - extra) or nil
    return extra, extra > 0, profitThen
end

-- A queued craft this item is for loses gold at current prices: what it
-- sells for dropped since you queued it. Buy next buys at or under the
-- plan without asking, so it bought for losing crafts (error review,
-- 2026-10-23). Per craft, not the whole queue: one loser among good crafts
-- is still a loser (user, 2026-10-23). Asks once a visit for each, and
-- again only if its loss grows by over LOSS_WORSE of its cost. Crafting
-- orders are left out (their pay is fixed once taken) and stock-ups (no
-- profit). A craft without a sale price: no check.
local LOSS_WORSE = 0.10
-- The craft's profit with everything at today's prices (the plan's
-- marketCost), not with what you hold at what you paid: buying is a
-- decision, made on today's prices. 8 Glimmering Gemdust bought at 61g,
-- now 32g, made a Kaleidoscopic Prism that earns 251g today show -57g,
-- and the check would have stopped for it (user, 2026-10-24).
local function NowCost(plan) return plan.marketCost or plan.cost or 0 end
local function NowProfit(plan)
    if not plan.revenue then return nil end
    return plan.revenue - NowCost(plan)
end

local function LossNeedsAsking(qt)
    if not qt then return nil end
    local ask = {}
    for _, row in ipairs(q and q.rows or {}) do
        local plan, e = row.plan, row.entry
        local now = plan and not plan.stock and not e.orderID and NowProfit(plan)
        if now and now < 0 then
            for _, b in ipairs(plan.buyAH or {}) do
                if b.itemID == qt.itemID then
                    local took = lossAccepted[e]
                    if not (took and -now <= took + NowCost(plan) * LOSS_WORSE) then
                        table.insert(ask, row)
                    end
                    break
                end
            end
        end
    end
    return #ask > 0 and ask or nil
end

local function LossNote(rows)
    local row = rows[1]
    local more = #rows > 1 and string.format(" (and %d more queued craft%s)", #rows - 1, #rows == 2 and "" or "s") or ""
    local whose = row.charKey and (" (" .. addon.QueueCharName(row.charKey) .. "'s queue)") or ""
    return string.format("%s%s loses %s now%s. Click again to buy anyway.",
        addon:QueueRowName(row), whose, Money(-NowProfit(row.plan)), more)
end

-- A price the player has said to buy without asking: at or under the
-- plan, the price already accepted, or a little over the plan (Settings'
-- Buy without asking): under that % of the item's cost or of the queue's
-- profit (user, 2026-10-19: a second click for 1.75g over 820g, and 3.38g
-- over a 1.20g item on a 1,000g queue). Never when the queue would lose.
local function BuyWithoutAsking(qt, total)
    if qt.accepted and total <= qt.accepted then return true end
    if LossNeedsAsking(qt) then return false end
    if not qt.planCost then return false end
    local extra = total - qt.planCost
    if extra <= 0 then return true end
    local share = (addon:Setting("buyOver") or 0) / 100
    if share <= 0 then return false end
    -- A stock-up: only its own cost counts (it isn't in the queue's profit)
    local stock = q and q.stockOnly and q.stockOnly[qt.itemID]
    local profit = not stock and q and q.complete and q.profit or nil
    if profit and profit - extra < 0 then return false end
    return extra <= qt.planCost * share or (profit and profit > 0 and extra <= profit * share) or false
end

-- Buys at the price the AH gave, once it's ready for another message
local function Confirm(qt)
    buying, quote = qt, nil
    buying.sent = GetTime()
    -- For the chat line Core.lua writes when the purchase is recorded
    addon.buyNextPlanned = { itemID = qt.itemID, quantity = qt.quantity, cost = qt.planCost }
    local okT, ready = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
    if okT and ready == false then
        buying.waitThrottle = true
    else
        C_AuctionHouse.ConfirmCommoditiesPurchase(buying.itemID, buying.quantity)
    end
    Update()
end

-- The item's listings in the AH window, as clicking it in Browse does,
-- with the amount filled in (user, 2026-10-19: see what you're buying).
-- On the click, before the price request, so its search can't upset it.
-- The AH window needs the item's AH details first (GetItemKeyInfo): without
-- them it errors ("attempt to index local 'itemKeyInfo'", 2026-10-19), which
-- is why the listings sometimes never showed. They're asked for as the list
-- is planned (Prefetch), and if they're still missing on the click the
-- listings open when they arrive (ITEM_KEY_ITEM_INFO_RECEIVED). The AH
-- window's own functions: if a patch renames them, the listings just don't
-- show; why is said in chat, once a visit.
local listingsError
local waitingKey                -- the entry whose listings wait for its AH details
local function KeyInfo(itemID)
    if not C_AuctionHouse.MakeItemKey or not C_AuctionHouse.GetItemKeyInfo then return end
    local ok, itemKey = pcall(C_AuctionHouse.MakeItemKey, itemID)
    if not ok or not itemKey then return end
    local okInfo, info = pcall(C_AuctionHouse.GetItemKeyInfo, itemKey)
    return itemKey, okInfo and info or nil
end

local function Prefetch(list)
    for _, entry in ipairs(list) do KeyInfo(entry.itemID) end
end

local function ShowListings(entry)
    local f = AuctionHouseFrame
    if not (f and f:IsShown() and f.SelectBrowseResult) then return end
    local itemKey, info = KeyInfo(entry.itemID)
    if not itemKey then return end
    if not info then
        waitingKey = entry
        return
    end
    waitingKey = nil
    local price = addon:GetMarketPrice(entry.itemID) or entry.unit or 0
    local shown, err = pcall(f.SelectBrowseResult, f, { itemKey = itemKey, minPrice = price, totalQuantity = 0 })
    if not shown then
        if not listingsError then
            listingsError = true
            addon:Notify("info", "Couldn't open the listings in the AH window: %s", tostring(err))
        end
        return
    end
    -- The amount once the listings arrive: the AH window caps it at what's
    -- listed, so set any sooner it showed 1 (user, 2026-10-19)
    listingQty = { itemID = entry.itemID, quantity = entry.quantity, entry = entry, at = GetTime(),
                   tries = listingQty and listingQty.itemID == entry.itemID and listingQty.tries or 0 }
end

-- Kept (not cleared) once filled: the refresh below may come after it
local function FillQuantity()
    local f = AuctionHouseFrame
    local display = f and f.CommoditiesBuyFrame and f.CommoditiesBuyFrame.BuyDisplay
    if listingQty and display and display.SetQuantitySelected then
        pcall(display.SetQuantitySelected, display, listingQty.quantity)
    end
end

-- The AH window's own Refresh button on the listings, as you'd press it
-- (user, 2026-10-19: Umbral Tin Ore sat on "Searching..." after it was
-- bought, and Refresh fixed it). Its parts' names are the AH window's:
-- if a patch renames them, the listings are asked for again instead.
local function RefreshListings(l)
    local f = AuctionHouseFrame
    local list = f and f.CommoditiesBuyFrame and f.CommoditiesBuyFrame.ItemList
    local button = list and list.RefreshFrame and list.RefreshFrame.RefreshButton
    if button and button.IsEnabled and button:IsEnabled() and button.Click then
        if pcall(button.Click, button) then return end
    end
    ShowListings(l.entry)
end

-- Bought but still in the mailbox
--
-- AH purchases go to the mailbox, not the bags ("You won an auction"), so
-- the queue still counted 23 Cellular Slab as needed after buying them and
-- Buy next would have bought them again (2026-10-19). What Buy next bought
-- is kept per character in GoldsmithDB.inMail[charKey][itemID] =
-- { quantity, last (bag count last seen), time } and taken off the list
-- until it arrives: each rise in the bag count takes that much off; a drop
-- (crafting) only moves `last`. Forgotten after MAIL_DAYS.
local MAIL_DAYS = 3

local function MailBook()
    GoldsmithDB.inMail = GoldsmithDB.inMail or {}
    GoldsmithDB.inMail[addon.charKey] = GoldsmithDB.inMail[addon.charKey] or {}
    return GoldsmithDB.inMail[addon.charKey]
end

local function BagCount(itemID)
    return C_Item.GetItemCount(itemID, true, false, true, true) or 0
end

local function MailBought(itemID, quantity)
    local book = MailBook()
    local e = book[itemID]
    if e then
        e.quantity, e.time = e.quantity + quantity, time()
    else
        book[itemID] = { quantity = quantity, last = BagCount(itemID), time = time() }
    end
end

-- Bags changed: what arrived comes off
local function TrackMail()
    local book = GoldsmithDB.inMail and GoldsmithDB.inMail[addon.charKey]
    if not book then return end
    for itemID, e in pairs(book) do
        local count = BagCount(itemID)
        -- Mailed from another of your characters: its bags weren't seen
        -- until now, so this is where it starts
        if e.last and count > e.last then e.quantity = e.quantity - (count - e.last) end
        e.last = count
        if e.quantity <= 0 or time() - e.time > MAIL_DAYS * 86400 then book[itemID] = nil end
    end
end

-- How many of an item Buy next bought that are still in the mailbox. The
-- planner counts them as yours (Planner.lua's GetOnHand): only a check on
-- the same item kept 7 Photosynthesized Scrap from being bought twice,
-- and the plan, not seeing them, switched to buying Cellular Slab instead
-- (2026-10-19).
-- Mailed to another of your characters: in their mailbox until they log in
-- and take it (Forever has no warband bank, so cloth mailed to an alt
-- vanished from Goldsmith's count; user, 2026-10-21). Forever names can
-- have a surname ("Namo Dormammu"), so the first word is matched too.
local sendSnapshot = {}
local function ReadSendItems()
    local items = {}
    for i = 1, ATTACHMENTS_MAX_SEND or 12 do
        local _, itemID, _, count = GetSendMailItem(i)
        if itemID and count and count > 0 then table.insert(items, { itemID, count }) end
    end
    return items
end
local mailWatch = CreateFrame("Frame")
mailWatch:RegisterEvent("MAIL_SEND_INFO_UPDATE")
mailWatch:SetScript("OnEvent", function() sendSnapshot = ReadSendItems() end)
hooksecurefunc("SendMail", function(recipient)
    if type(recipient) ~= "string" or recipient == "" then return end
    local who = (strsplit("-", recipient)):lower()
    local first = who:match("^(%S+)")
    local realm = GetRealmName()
    local key
    for k, c in pairs(GoldsmithDB.characters or {}) do
        local name = c.name and c.name:lower()
        if name and (name == who or name == first) and (not c.realm or c.realm == realm) then key = k end
    end
    if not key or key == addon.charKey then return end
    local items = ReadSendItems()
    if #items == 0 then items = sendSnapshot end
    GoldsmithDB.inMail = GoldsmithDB.inMail or {}
    GoldsmithDB.inMail[key] = GoldsmithDB.inMail[key] or {}
    local book = GoldsmithDB.inMail[key]
    local onTheWay = GoldsmithDB.boughtFor and GoldsmithDB.boughtFor[key]
    for _, it in ipairs(items) do
        local e = book[it[1]]
        if e then
            e.quantity, e.time = e.quantity + it[2], time()
        else
            book[it[1]] = { quantity = it[2], time = time() }
        end
        -- Bought for them here: now it's in their mail instead
        local w = onTheWay and onTheWay[it[1]]
        if w and w.holder == addon.charKey then
            w.quantity = w.quantity - it[2]
            if w.quantity <= 0 then onTheWay[it[1]] = nil end
        end
    end
    sendSnapshot = {}
    if addon.DataChanged then addon:DataChanged() end
end)

function addon:InMailCount(itemID)
    local book = GoldsmithDB.inMail and GoldsmithDB.inMail[addon.charKey]
    local e = book and book[itemID]
    return e and e.quantity > 0 and e.quantity or 0
end

function addon:InMailCountFor(charKey, itemID)
    local book = GoldsmithDB.inMail and GoldsmithDB.inMail[charKey]
    local e = book and book[itemID]
    return e and e.quantity > 0 and e.quantity or 0
end

-- Bought for another character's queue, held by the buyer until mailed:
-- GoldsmithDB.boughtFor[crafter][itemID] = { quantity, holder, time }.
-- The crafter's plans count it as theirs; the holder's own plans leave it
-- alone (its bags and mail count it, ReservedCount takes it off). Dropped
-- once mailed (the SendMail hook above), after ON_THE_WAY_DAYS, or when
-- the crafter's queue is empty.
local ON_THE_WAY_DAYS = 7

local function OnTheWay(crafter, itemID)
    local book = GoldsmithDB.boughtFor and GoldsmithDB.boughtFor[crafter]
    local e = book and book[itemID]
    if not e or e.quantity <= 0 then return nil end
    if time() - e.time > ON_THE_WAY_DAYS * 86400 or #addon:GetQueue(crafter) == 0 then return nil end
    return e
end

-- For the crafter: how many are on the way, and who holds them
function addon:OnTheWayFor(crafter, itemID)
    local e = OnTheWay(crafter, itemID)
    if not e then return 0 end
    local c = GoldsmithDB.characters[e.holder]
    return e.quantity, c and c.name or e.holder
end

-- For the holder: how many of their own are set aside for others
function addon:ReservedCount(itemID)
    local n = 0
    for crafter in pairs(GoldsmithDB.boughtFor or {}) do
        local e = OnTheWay(crafter, itemID)
        if e and e.holder == addon.charKey then n = n + e.quantity end
    end
    return n
end

local function BoughtFor(crafter, itemID, quantity)
    GoldsmithDB.boughtFor = GoldsmithDB.boughtFor or {}
    GoldsmithDB.boughtFor[crafter] = GoldsmithDB.boughtFor[crafter] or {}
    local book = GoldsmithDB.boughtFor[crafter]
    -- The name kept too: right after a /reload the game hasn't loaded it,
    -- and the mailbox said "40 item 243599" (user, 2026-10-24)
    local name = C_Item.GetItemNameByID(itemID)
    if OnTheWay(crafter, itemID) and book[itemID].holder == addon.charKey then
        book[itemID].quantity, book[itemID].time = book[itemID].quantity + quantity, time()
        book[itemID].name = book[itemID].name or name
    else
        book[itemID] = { quantity = quantity, holder = addon.charKey, time = time(), name = name }
    end
end

-- What to mail from this character, a line per character: "Mail to
-- Trypttamine: 38 Refulgent Copper Ore, 24 Umbral Tin Ore". One sentence
-- for everyone was hard to read (user, 2026-10-24).
-- What to mail from here, for the mailbox panel (Mail.lua): per
-- character, what Buy next bought here for their queue, then what their
-- queue would buy on the AH that you hold (when no queued craft of yours
-- uses it). Returns { { key, name, items = { { itemID, name, quantity,
-- bought } } } }, by name. Their queue is planned once per data change.
local mailPlanCache
function addon:MailJobs()
    mailPlanCache = mailPlanCache or addon:NewCache()
    local plans = mailPlanCache:Get()
    local jobs, byKey = {}, {}
    local function Add(key, itemID, quantity, bought, name)
        if quantity <= 0 or key == addon.charKey then return end
        local job = byKey[key]
        if not job then
            job = { key = key, name = addon.QueueCharName(key), items = {} }
            byKey[key] = job
            table.insert(jobs, job)
        end
        for _, it in ipairs(job.items) do
            if it.itemID == itemID then
                it.quantity = it.quantity + quantity
                it.bought = it.bought or bought
                return
            end
        end
        table.insert(job.items, { itemID = itemID, quantity = quantity, bought = bought,
                                  name = C_Item.GetItemNameByID(itemID) or name or ("item " .. itemID) })
    end
    for crafter in pairs(GoldsmithDB.boughtFor or {}) do
        for itemID in pairs(GoldsmithDB.boughtFor[crafter]) do
            local e = OnTheWay(crafter, itemID)
            if e and e.holder == addon.charKey then Add(crafter, itemID, e.quantity, true, e.name) end
        end
    end
    -- Yours, beyond what's set aside for others and already listed
    local spare = {}
    local function Spare(itemID)
        if spare[itemID] == nil then
            spare[itemID] = OwnQueueUses(itemID) and 0
                or math.max((C_Item.GetItemCount(itemID, true, false, true, false) or 0) - addon:ReservedCount(itemID), 0)
        end
        return spare[itemID]
    end
    for _, key in ipairs(addon:GetQueuedCharacters()) do
        if key ~= addon.charKey then
            if plans[key] == nil then
                local ok, plan = pcall(addon.BuildQueue, addon, key)
                plans[key] = ok and plan or false
            end
            for _, entry in ipairs(plans[key] and plans[key].buyAH or {}) do
                local n = math.min(Spare(entry.itemID), entry.quantity)
                if n > 0 then
                    spare[entry.itemID] = spare[entry.itemID] - n
                    Add(key, entry.itemID, n, false, entry.name)
                end
            end
        end
    end
    table.sort(jobs, function(a, b) return a.name < b.name end)
    return jobs
end

local function ToMail()
    local lines = {}
    for crafter in pairs(GoldsmithDB.boughtFor or {}) do
        local items = {}
        for itemID in pairs(GoldsmithDB.boughtFor[crafter]) do
            local e = OnTheWay(crafter, itemID)
            if e and e.holder == addon.charKey then
                local name = C_Item.GetItemNameByID(itemID) or e.name
                if not name then C_Item.RequestLoadItemDataByID(itemID) end
                table.insert(items, { e.quantity, name or ("item " .. itemID) })
            end
        end
        if #items > 0 then
            table.sort(items, function(a, b) return a[1] > b[1] end)
            local parts = {}
            for _, it in ipairs(items) do table.insert(parts, it[1] .. " " .. it[2]) end
            table.insert(lines, string.format("Mail to %s: %s.", addon.QueueCharName(crafter), table.concat(parts, ", ")))
        end
    end
    table.sort(lines)
    return lines
end

-- Another character's queue into yours: rows tagged with whose, the same
-- item bought once for all (parts say how many for whom), profit summed
local function MergeQueue(into, other, key)
    for _, row in ipairs(other.rows or {}) do
        row.charKey = key
        table.insert(into.rows, row)
    end
    into.complete = into.complete and other.complete
    into.profit = (into.profit or 0) + (other.profit or 0)
    into.cost = (into.cost or 0) + (other.cost or 0)
    into.revenue = (into.revenue or 0) + (other.revenue or 0)
    into.spend = (into.spend or 0) + (other.spend or 0)
    into.stockOnly = into.stockOnly or {}
    local byID = {}
    for _, e in ipairs(into.buyAH) do byID[e.itemID] = e end
    for _, e in ipairs(other.buyAH or {}) do
        local isStock = other.stockOnly and other.stockOnly[e.itemID] == true
        local mine = byID[e.itemID]
        if mine then
            mine.quantity = mine.quantity + e.quantity
            mine.cost = (mine.cost or 0) + (e.cost or 0)
            mine.unit = mine.quantity > 0 and mine.cost / mine.quantity or mine.unit
            mine.short = mine.short or e.short
            table.insert(mine.parts, { key = key, quantity = e.quantity })
            into.stockOnly[e.itemID] = into.stockOnly[e.itemID] == true and isStock
        else
            e.parts = { { key = key, quantity = e.quantity } }
            table.insert(into.buyAH, e)
            byID[e.itemID] = e
            into.stockOnly[e.itemID] = isStock or nil
        end
    end
end

-- Excluded characters too: a queue is something you asked for. Leaving
-- them out kept the All queues box hidden while the note said to tick it,
-- so there was no way to buy for them (user, 2026-10-24)
local function OtherQueueKeys()
    local keys = {}
    for _, key in ipairs(addon:GetQueuedCharacters()) do
        if key ~= addon.charKey then table.insert(keys, key) end
    end
    return keys
end

-- The queue, and what's in the mailbox for the note
local function PlanQueue()
    TrackMail()
    local plan = addon:BuildQueue(addon.charKey)
    if BuyForAll() then
        local others = OtherQueueKeys()
        if #others > 0 then
            for _, e in ipairs(plan.buyAH) do e.parts = { { key = addon.charKey, quantity = e.quantity } } end
            for _, key in ipairs(others) do MergeQueue(plan, addon:BuildQueue(key), key) end
        end
    end
    local mailed = {}
    for itemID, e in pairs(MailBook()) do
        if e.quantity > 0 then
            table.insert(mailed, string.format("%dx %s", e.quantity, C_Item.GetItemNameByID(itemID) or "?"))
        end
    end
    table.sort(mailed)
    plan.inMail = mailed
    return plan
end

-- /gsm buylist [name]: each queued entry and what it buys on the AH, with
-- what it counts as held, to see which entry asks for what (2026-10-24:
-- 42 Refulgent Copper Ore where about 30 looked right)
function addon:PrintBuyList(who)
    local keys = {}
    for _, key in ipairs(addon:GetQueuedCharacters()) do
        if who == "" or addon.QueueCharName(key):lower():find(who:lower(), 1, true) then table.insert(keys, key) end
    end
    for _, key in ipairs(keys) do
        local plan = addon:BuildQueue(key)
        print(string.format("|cffd4af37Goldsmith|r %s's queue:", addon.QueueCharName(key)))
        for _, row in ipairs(plan.rows) do
            local parts = {}
            for _, b in ipairs(row.plan and row.plan.buyAH or {}) do
                table.insert(parts, string.format("%d %s", b.quantity, b.name or ("item " .. b.itemID)))
            end
            print(string.format("  %s (%d): %s", addon:QueueRowName(row), row.remaining or 0,
                #parts > 0 and table.concat(parts, ", ") or "nothing"))
            -- What it counted as held, for the items it buys
            local function Walk(nodes, depth)
                for _, n in ipairs(nodes or {}) do
                    if n.toGet and n.toGet > 0 or (n.have or 0) > 0 then
                        print(string.format("    %s%s: need %s, held %s, get %s", string.rep("  ", depth), n.name or "?",
                            tostring(n.need), tostring(n.have), tostring(n.toGet)))
                    end
                    Walk(n.children, depth + 1)
                end
            end
            Walk(row.plan and row.plan.nodes, 0)
        end
    end
end

-- From a click or the key binding (the game only buys from one)
function addon:BuyNext()
    if addon:TourBlocks("buy the next item for the queue") then return end
    -- The key with the panel off (you don't use Buy next) or away from the
    -- AH (nothing to buy, and everyone knows it) does nothing (user,
    -- 2026-10-25)
    if not addon:Setting("ahScan") or not ahOpen then return end
    if buying or asking or addon:PurchaseSettling() then return end
    if addon:IsScanning() then
        -- No sound: the panel says so too; sounds are for what matters
        -- (user, 2026-10-25)
        addon:Notify("info", "Buy next waits for the Goldsmith scan to finish.")
        return
    end
    -- Second click: buy at the price shown. A price more than a few
    -- seconds old may have run out on the AH's side: twice a confirm sent
    -- after looking at the price got no answer and nothing was bought
    -- (2026-10-19). So it asks again and buys at once if it's no higher
    -- than the price you accepted.
    if quote and GetTime() - quote.at < QUOTE_LIFE then
        local entry = NextEntry()
        if entry and entry.itemID == quote.itemID then
            for _, row in ipairs(LossNeedsAsking(quote) or {}) do lossAccepted[row.entry] = -NowProfit(row.plan) end
            if GetTime() - quote.at < FRESH then
                Confirm(quote)
                return
            end
            asking = { itemID = quote.itemID, quantity = quote.quantity, name = quote.name,
                       planCost = quote.planCost, accepted = quote.total, sent = GetTime(), parts = quote.parts }
            quote = nil
            if not pcall(C_AuctionHouse.StartCommoditiesPurchase, asking.itemID, asking.quantity) then
                asking = nil
            end
            Update()
            return
        end
    end
    Cancel()
    -- The item the button shows: planning again here bought Photosynthesized
    -- Scrap with the button on Winged Stalk (2026-10-19). The list is kept
    -- up to date by bag, price and queue changes instead.
    if not q then q = PlanQueue() end
    local entry = NextEntry()
    if not entry then
        addon:Notify("info", #(q.buyAH or {}) > 0 and "Everything else was skipped this visit."
            or OtherQueueNote() or "Nothing to buy for the queue.")
        Update()
        return
    end
    asking = { itemID = entry.itemID, quantity = entry.quantity, name = ItemName(entry), planCost = entry.cost,
               sent = GetTime(), parts = entry.parts }
    -- The listings first: their search mustn't come after the price request
    ShowListings(entry)
    local ok = pcall(C_AuctionHouse.StartCommoditiesPurchase, entry.itemID, entry.quantity)
    if not ok then
        skipped[entry.itemID] = "The AH wouldn't sell it here"
        asking = nil
    end
    Update()
end

-- The queue changed (Queue.lua): a price waiting for a click is let go
-- and the list planned again (user, 2026-10-19: Update queue didn't show
-- until Buy next was clicked, the shown price kept the old list). A
-- purchase already sent finishes first; its answer replans anyway.
function addon.ShopQueueChanged()
    if not buying then
        Cancel()
        q = nil
    end
    Update()
end

-- Right-click: skip the item for this visit
local function Skip()
    local entry = NextEntry()
    if not entry or buying then return end
    Cancel()
    skipped[entry.itemID] = "Skipped"
    Update()
end

-- The section under the scan panel

local function Line(i)
    local line = CreateFrame("Frame", nil, section)
    line:SetHeight(LINE_HEIGHT)
    line:SetPoint("TOPLEFT", 10, -(22 + (i - 1) * LINE_HEIGHT))
    line:SetPoint("RIGHT", section, "RIGHT", -10, 0)
    line.status = UI.Text(line, "small", "muted", "RIGHT")
    line.status:SetPoint("RIGHT")
    -- Whose queue (All queues), never cut short: the item name gives way
    -- instead ("Maddox..." hid which of Maddoxius and Maddoxynn; user,
    -- 2026-10-24)
    line.who = UI.Text(line, "small", "dim", "RIGHT")
    line.who:SetPoint("RIGHT", line.status, "LEFT", -8, 0)
    line.text = UI.Text(line, "small", "text")
    line.text:SetPoint("LEFT")
    line.text:SetPoint("RIGHT", line.who, "LEFT", -6, 0)
    return line
end

local function KeyText()
    local key = GetBindingKey and GetBindingKey("GOLDSMITH_BUY_NEXT")
    return key and GetBindingText and GetBindingText(key) or key
end

-- Built into the scan panel (Scan.lua calls it once)
function addon.CreateShopSection(panel, width)
    section = CreateFrame("Frame", nil, panel)
    section:SetPoint("TOPLEFT", 0, -104)
    section:SetWidth(width)
    section.rule = section:CreateTexture(nil, "ARTWORK")
    section.rule:SetColorTexture(addon:Color("borderGold"))
    section.rule:SetHeight(1)
    section.rule:SetPoint("TOPLEFT", 10, 0)
    section.rule:SetPoint("TOPRIGHT", -10, 0)
    section.title = UI.Text(section, "label", "gold")
    section.title:SetPoint("TOPLEFT", 10, -8)
    section.title:SetText("BUY NEXT")
    section.allQueues = UI.Checkbox(section, "All queues", function(checked)
        if checked == SettingAll() then override = nil else override = checked end
        overrideBought = false
        Cancel()
        q = nil
        Update()
    end)
    section.allQueues:SetPoint("TOPRIGHT", -10, -3)
    section.allQueues:Hide()
    UI.SetTooltip(section.allQueues, function(tooltip)
        tooltip:AddLine("All queues", 1, 1, 1)
        tooltip:AddLine("Buy for your other characters' queues too, from this character. Each item says whose queue it's for; mail them over after.", 0.8, 0.8, 0.8, true)
        tooltip:AddLine("Ticked: every character's queue. Unticked: just this character's.", 0.8, 0.8, 0.8, true)
        tooltip:AddLine("A click is for now: it goes back to your setting (Settings > Buy next for) once the list is bought.", 0.6, 0.6, 0.6, true)
    end, "ANCHOR_TOP")
    section.lines = {}
    for i = 1, LINES do section.lines[i] = Line(i) end
    section.note = UI.Text(section, "small", "muted")
    section.note:SetJustifyH("LEFT")
    section.note:SetWordWrap(true)
    section.note:SetPoint("LEFT", 10, 0)
    section.note:SetPoint("RIGHT", -10, 0)

    section.button = UI.Button(section, "Buy next", width - 20, 28, function(_, mouseButton)
        if mouseButton == "RightButton" then Skip() else addon:BuyNext() end
    end)
    UI.Style(section.button, "highlight", "borderGold")
    section.button.label:SetTextColor(addon:Color("gold"))
    section.button:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderGold")) end)
    section.hint = UI.Text(section, "small", "dim", "CENTER")
    section.hint:SetPoint("LEFT", 10, 0)
    section.hint:SetPoint("RIGHT", -10, 0)

    UI.SetTooltip(section.button, function(tooltip)
        tooltip:AddLine("Buy next", 1, 1, 1)
        addon:Explain(tooltip, "Buys what your queue needs, one item per click. What's in your bags isn't bought.", 0.8, 0.8, 0.8, true)
        addon:Explain(tooltip, "At or under the plan's cost it buys right away, and a little over too (Settings: Buy without asking). If the AH asks more, it says how much and waits for a second click.", 0.6, 0.6, 0.6, true)

        addon:Explain(tooltip, "Right-click to skip an item until you next open the AH.", 0.6, 0.6, 0.6, true)
        tooltip:AddLine(KeyText() and ("Key: " .. KeyText()) or "Set a key: Options > Keybindings > Goldsmith.",
            0.6, 0.6, 0.6, true)
        tooltip:ClearAllPoints()
        tooltip:SetPoint("TOPRIGHT", section, "BOTTOMRIGHT", 0, -4)
    end, "ANCHOR_NONE")
end

-- Fills the section; returns its height (0 when hidden)
function addon.UpdateShopSection()
    if not section then return 0 end
    local entries = GoldsmithDB.queues and GoldsmithDB.queues[addon.charKey]
    local others = #OtherQueueKeys() > 0
    section.allQueues:SetShown(others)
    section.allQueues:SetChecked(BuyForAll())
    if (not entries or #entries == 0) and not (BuyForAll() and others) then
        -- Only another character's queue: say so instead of no box at all
        -- (user, 2026-10-24: "i don't see any buy next")
        local other = OtherQueueNote()
        -- Their queues have all they need: say that too, a missing panel
        -- read as Buy next being broken (user, 2026-10-24: Maddoxynn's
        -- Sienna Ink was covered by her pigments and Mana Lily to mill)
        if not other and others then
            other = "Nothing to buy."
            section.allQueues:Hide()
        end
        if not other then
            section:Hide()
            return 0
        end
        q = nil
        for _, line in ipairs(section.lines) do line:Hide() end
        section.button:Hide()
        section.hint:Hide()
        section.note:ClearAllPoints()
        section.note:SetPoint("TOPLEFT", 10, -26)
        section.note:SetPoint("RIGHT", -10, 0)
        if section:GetWidth() > 60 then section.note:SetWidth(section:GetWidth() - 20) end
        section.note:SetText(other)
        section.note:SetTextColor(addon:Color("muted"))
        section.note:Show()
        local y = 30 + section.note:GetStringHeight()
        section:SetHeight(y + 10)
        section:Show()
        return y + 10
    end
    -- Planned again unless a purchase is under way, or a scan is (prices
    -- change once it's done; the scan updates the panel every second)
    if not (quote or asking or buying) and not (q and addon:IsScanning()) then
        q = PlanQueue()
    end
    local list = q and q.buyAH or {}
    -- The flipped list bought: back to the setting
    if override ~= nil and overrideBought and #list == 0 and not (quote or asking or buying) then
        override, overrideBought = nil, false
        q = PlanQueue()
        list = q.buyAH or {}
        section.allQueues:SetChecked(BuyForAll())
    end
    local nextEntry = NextEntry()
    if ahOpen then Prefetch(list) end

    local shown = math.min(#list, LINES)
    for i, line in ipairs(section.lines) do
        local entry = list[i]
        if entry and i <= shown then
            line.text:SetText(string.format("%dx %s", entry.quantity, ItemName(entry)))
            line.who:SetText(ForWhom(entry) or "")
            line.text:SetTextColor(addon:Color(entry == nextEntry and "gold" or (skipped[entry.itemID] and "dim" or "text")))
            line.status:SetText(skipped[entry.itemID] or Money(entry.cost or 0))
            line.status:SetTextColor(addon:Color(skipped[entry.itemID] and "dim" or "muted"))
            line:Show()
        else
            line:Hide()
        end
    end
    if #list > LINES then
        local last = section.lines[LINES]
        last.text:SetText(string.format("and %d more", #list - LINES + 1))
        last.who:SetText("")
        last.text:SetTextColor(addon:Color("muted"))
        last.status:SetText("")
    end
    -- From the top: the button (and its key), the note, then the list.
    -- The button used to be under the list and moved up each time an item
    -- was bought (user, 2026-10-23: "so that it doesn't move on you")
    local y = 22

    -- The note: nothing to buy, the price against the plan, or what's next
    local note, color = nil, "muted"
    local mailed = q and q.inMail and #q.inMail > 0 and ("In your mailbox: " .. table.concat(q.inMail, ", ") .. ".")
    if #list == 0 then
        -- "Everything else is here" read as unclear (user, 2026-10-21)
        note = mailed and ("Nothing left to buy. " .. mailed)
            or OtherQueueNote() or "The queue has everything it needs."
        local others = OtherQueueNote(true)
        if others then note = note .. " " .. others end
    elseif not nextEntry then
        note = "All skipped. Reopen the AH to retry."
    elseif quote then
        local extra, warn, profitThen = Gap()
        if warn then
            -- "(0%)" read oddly for 1.75g over 820.75g (2026-10-19)
            local pct = math.floor(extra / quote.planCost * 100 + 0.5)
            note = string.format("%s over plan (%s).", Money(extra),
                pct < 1 and "under 1%" or (pct .. "%"))
            if profitThen then
                -- "Queue profit then" was unclear (user, 2026-10-25)
                note = note .. (profitThen >= 0
                    and string.format(" Queue still makes %s.", addon:FormatSignedMoney(profitThen))
                    or string.format(" Queue would lose %s.", Money(-profitThen)))
            end
            color = profitThen and profitThen < 0 and "loss" or "warning"
        elseif LossNeedsAsking(quote) then
            note, color = LossNote(LossNeedsAsking(quote)), "loss"
        end
    elseif nextEntry.short then
        note, color = "The AH may not have all of it right now.", "warning"
    elseif AltStockNote(nextEntry) then
        note, color = AltStockNote(nextEntry), "warning"
    elseif ForWhom(nextEntry) then
        note = string.format("For %s: mail after.", ForWhom(nextEntry))
    elseif mailed then
        note = mailed
    end
    -- Vendor items, so they aren't forgotten on the way out (the vendor
    -- panel, Vendor.lua, buys them). Not under a price warning.
    local vendorList = q and q.buyVendor or {}
    if #vendorList > 0 and color == "muted" then
        local names = {}
        for _, e in ipairs(vendorList) do table.insert(names, string.format("%dx %s", e.quantity, e.name)) end
        note = (note and (note .. " ") or "") .. "From vendor: " .. table.concat(names, ", ") .. "."
    end
    -- The button: ask for a price, confirm it, or why it can't
    local label, enabled = "Buy next", nextEntry ~= nil
    if buying then
        label, enabled = "Buying...", false
    elseif asking then
        label, enabled = "Getting the price...", false
    elseif quote then
        label = string.format("Buy %d %s for %s", quote.quantity, quote.name, Money(quote.total))
    elseif nextEntry then
        label = string.format("Buy %d %s", nextEntry.quantity, nextEntry.name or "")
    end
    if addon:IsScanning() then label, enabled = "Waiting for the scan", false end
    section.button:SetLabel(label)
    section.button:SetEnabled(enabled)
    section.button:SetAlpha(enabled and 1 or 0.5)
    local warn = quote and (select(2, Gap()) or LossNeedsAsking(quote))
    section.button.label:SetTextColor(addon:Color(warn and "warning" or "gold"))
    section.button:ClearAllPoints()
    if nextEntry then
        section.button:SetPoint("TOPLEFT", 10, -(y + 4))
        y = y + 4 + 28
        section.hint:SetText(KeyText() and ("or press " .. KeyText()) or "set a key in Keybindings > Goldsmith")
        section.hint:ClearAllPoints()
        section.hint:SetPoint("TOPLEFT", 10, -(y + 4))
        section.hint:SetPoint("RIGHT", -10, 0)
        section.hint:Show()
        y = y + 4 + 14
        section.button:Show()
    else
        section.button:Hide()
        section.hint:Hide()
    end

    if note then
        section.note:ClearAllPoints()
        section.note:SetPoint("TOPLEFT", 10, -(y + 4))
        section.note:SetPoint("RIGHT", -10, 0)
        -- A set width, so the height is measured for the wrap you see: a
        -- three-line note was measured as two and ran over the list
        -- (user, 2026-10-24)
        if section:GetWidth() > 60 then section.note:SetWidth(section:GetWidth() - 20) end
        section.note:SetText(note)
        section.note:SetTextColor(addon:Color(color))
        section.note:Show()
        y = y + 8 + section.note:GetStringHeight()
    else
        section.note:Hide()
    end

    -- The list, under all of that
    if shown > 0 then y = y + 6 end
    for i = 1, shown do
        local line = section.lines[i]
        line:ClearAllPoints()
        line:SetPoint("TOPLEFT", 10, -(y + (i - 1) * LINE_HEIGHT))
        line:SetPoint("RIGHT", section, "RIGHT", -10, 0)
    end
    y = y + shown * LINE_HEIGHT
    section:SetHeight(y + 10)
    section:Show()
    return y + 10
end

-- A short wait groups bursts of bag updates
local pending = false
local function UpdateSoon()
    if pending then return end
    pending = true
    C_Timer.After(0.3, function()
        pending = false
        Update()
    end)
end

Update = function()
    if addon.UpdateScanPanel then addon.UpdateScanPanel() end
end

-- Slower, for item details, which come in bursts while you browse
local refreshing = false
RefreshSoon = function()
    if refreshing then return end
    refreshing = true
    C_Timer.After(2, function()
        refreshing = false
        if not (quote or asking or buying) then Update() end
    end)
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "COMMODITY_PRICE_UPDATED",
    "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
    "BAG_UPDATE_DELAYED", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
    "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_RECEIVED",
    "ITEM_KEY_ITEM_INFO_RECEIVED", "GET_ITEM_INFO_RECEIVED", "MAIL_SHOW" }) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event, unit, total)
    if event == "MAIL_SHOW" then
        -- Bought here for another character's queue and not mailed yet:
        -- in chat only when the mailbox panel (Mail.lua) can't show it
        if not addon.MailPanelShown then
            for _, line in ipairs(ToMail()) do addon:Notify("info", "%s", line) end
        end
        return
    elseif event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
        skipped, listingsError, waitingKey, lossAccepted = {}, nil, nil, {}
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ahOpen = false
        quote, asking, buying, listingQty, waitingKey = nil, nil, nil, nil, nil
        skipped = {}
        return
    elseif event == "COMMODITY_PRICE_UPDATED" then
        -- Only the price Buy next asked for (the AH's own buy screen asks too)
        if not asking then return end
        quote = asking
        quote.unit, quote.total, quote.at = unit, total, GetTime()
        asking = nil
        -- Planned again with the price in: the list on screen was planned
        -- as the AH opened, and right after a /reload that was before the
        -- game had sent the finishing reagent's details: 2 crafts making 4
        -- with no Bazaar Bites, queue profit -915g against the Queue tab's
        -- +1,001g (2026-10-19). Not the item's planned cost: the new plan
        -- prices it from the listings just fetched, so it matched what was
        -- paid ("on plan" for 12.50g against the 13.25g shown, 2026-10-19).
        q = PlanQueue()
        -- At or under the plan (or a little over): buy it now; more: wait for a click
        if BuyWithoutAsking(quote, total) then
            Confirm(quote)
        else
            -- Waits for a second click: a popup too when you'd lose gold
            local _, _, profitThen = Gap()
            local losers = LossNeedsAsking(quote)
            -- The losing craft first: it names the cause
            if losers then
                addon:Alert("loss", string.format("%s loses %s at current prices.",
                    addon:QueueRowName(losers[1]), Money(-NowProfit(losers[1].plan))))
            elseif profitThen and profitThen < 0 then
                addon:Alert("loss", string.format("buying %s puts the queue at %s.", quote.name,
                    addon:FormatSignedMoney(profitThen)))
            else
                addon:Alert("stop")
            end
            Update()
        end
    elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" or event == "COMMODITY_SEARCH_RESULTS_RECEIVED" then
        -- After the AH window's own handling of the same event
        if listingQty and (unit == nil or unit == listingQty.itemID) then C_Timer.After(0, FillQuantity) end
    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        if buying and buying.waitThrottle then
            buying.waitThrottle = nil
            buying.sent = GetTime()
            C_AuctionHouse.ConfirmCommoditiesPurchase(buying.itemID, buying.quantity)
        end
    elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
        if not asking then return end
        addon:Notify("info", "%s: the AH can't sell %d right now, so it's skipped.", asking.name, asking.quantity)
        skipped[asking.itemID] = "Not enough listed"
        asking = nil
        Update()
    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
        if not buying then return end
        -- All of it is in your mailbox; what's for others is set aside
        MailBought(buying.itemID, buying.quantity)
        if override ~= nil then overrideBought = true end
        for _, part in ipairs(buying.parts or {}) do
            if part.key ~= addon.charKey and part.quantity > 0 then
                BoughtFor(part.key, buying.itemID, part.quantity)
                -- After Core.lua's "Bought ..." line, which waits for your
                -- gold to drop (it came first and read backwards; user,
                -- 2026-10-24)
                local itemID, quantity, who = buying.itemID, part.quantity, addon.QueueCharName(part.key)
                C_Timer.After(2, function()
                    addon:Notify("info", "Mail %d %s to %s.", quantity,
                        C_Item.GetItemNameByID(itemID) or "of these", who)
                end)
            end
        end
        buying = nil
        UpdateSoon()
    elseif event == "COMMODITY_PURCHASE_FAILED" then
        if not buying then return end
        addon:Notify("info", "Couldn't buy %s (price changed). Try again.", buying.name)
        addon:Alert("stop")
        buying = nil
        Update()
    elseif event == "BAG_UPDATE_DELAYED" then
        TrackMail()
        if ahOpen and not (quote or asking or buying) then UpdateSoon() end
    elseif event == "ITEM_KEY_ITEM_INFO_RECEIVED" then
        -- The AH details the clicked item's listings waited for
        local entry = waitingKey
        if entry and unit == entry.itemID then
            C_Timer.After(0, function() if waitingKey == entry then ShowListings(entry) end end)
        end
    elseif event == "GET_ITEM_INFO_RECEIVED" then
        -- Item details arriving can change the plan (a finishing reagent's,
        -- above): planned again once they settle, while nothing's under way
        if ahOpen and not (quote or asking or buying) then RefreshSoon() end
    end
end)

-- A price kept too long is let go: the next click asks again. No answer
-- to a price request or a purchase: give up, so the button never sticks
-- (core.lua's money check records nothing when nothing was paid)
C_Timer.NewTicker(1, function()
    if quote and GetTime() - quote.at >= QUOTE_LIFE then
        Cancel()
        Update()
    elseif asking and GetTime() - asking.sent >= ANSWER_WAIT then
        local name = asking.name
        Cancel()
        addon:Notify("info", "The AH didn't send a price for %s. Press Buy next to try again.", name)
        Update()
    elseif buying and GetTime() - buying.sent >= ANSWER_WAIT then
        addon:Notify("info", "The AH didn't answer, so %s wasn't bought. Press Buy next to try again.", buying.name)
        pcall(C_AuctionHouse.CancelCommoditiesPurchase)
        buying = nil
        Update()
    end
    -- The listings refreshed once, 2 s after they were asked for and
    -- nothing else is under way: after a purchase they sat on
    -- "Searching..." (4 times, 2026-10-19) even when results came back,
    -- so it doesn't wait for a sign they're stuck. Then let go.
    local l = listingQty
    if l and ahOpen and not (asking or buying) and GetTime() - l.at >= 2 and l.tries < 1 then
        local okT, ready = pcall(C_AuctionHouse.IsThrottledMessageSystemReady)
        if not okT or ready ~= false then
            l.tries = l.tries + 1
            RefreshListings(l)
        end
    elseif l and GetTime() - l.at >= 15 then
        listingQty = nil
    end
end)

_G.Goldsmith = addon
