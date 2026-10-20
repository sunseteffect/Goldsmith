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
local Update, RefreshSoon       -- below

local function Money(copper) return addon:FormatMoney(copper) end

local function ItemName(entry)
    local icon = entry.qualityTier and (addon:TierIconText(entry.qualityTier, entry.tierCount) .. " ") or ""
    return icon .. (entry.name or ("item " .. entry.itemID))
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
    local profitThen = q and q.complete and q.profit and (q.profit - extra) or nil
    return extra, extra > 0, profitThen
end

-- A price the player has said to buy without asking: at or under the
-- plan, the price already accepted, or a little over the plan (Settings'
-- Buy without asking): under that % of the item's cost or of the queue's
-- profit (user, 2026-10-19: a second click for 1.75g over 820g, and 3.38g
-- over a 1.20g item on a 1,000g queue). Never when the queue would lose.
local function BuyWithoutAsking(qt, total)
    if qt.accepted and total <= qt.accepted then return true end
    if not qt.planCost then return false end
    local extra = total - qt.planCost
    if extra <= 0 then return true end
    local share = (addon:Setting("buyOver") or 0) / 100
    if share <= 0 then return false end
    local profit = q and q.complete and q.profit
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
        if count > e.last then e.quantity = e.quantity - (count - e.last) end
        e.last = count
        if e.quantity <= 0 or time() - e.time > MAIL_DAYS * 86400 then book[itemID] = nil end
    end
end

-- How many of an item Buy next bought that are still in the mailbox. The
-- planner counts them as yours (Planner.lua's GetOnHand): only a check on
-- the same item kept 7 Photosynthesized Scrap from being bought twice,
-- and the plan, not seeing them, switched to buying Cellular Slab instead
-- (2026-10-19).
function addon:InMailCount(itemID)
    local book = GoldsmithDB.inMail and GoldsmithDB.inMail[addon.charKey]
    local e = book and book[itemID]
    return e and e.quantity > 0 and e.quantity or 0
end

-- The queue, and what's in the mailbox for the note
local function PlanQueue()
    TrackMail()
    local plan = addon:BuildQueue(addon.charKey)
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

-- From a click or the key binding (the game only buys from one)
function addon:BuyNext()
    if not addon:Setting("ahScan") then
        addon:Notify("info", "Buy next is in the AH scan panel, which is off (Settings > Crafting and prices).")
        return
    end
    if not ahOpen then
        addon:Notify("info", "Open the auction house first.")
        return
    end
    if buying or asking then return end
    if addon:IsScanning() then
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
            if GetTime() - quote.at < FRESH then
                Confirm(quote)
                return
            end
            asking = { itemID = quote.itemID, quantity = quote.quantity, name = quote.name,
                       planCost = quote.planCost, accepted = quote.total, sent = GetTime() }
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
            or "Nothing to buy for the queue.")
        Update()
        return
    end
    asking = { itemID = entry.itemID, quantity = entry.quantity, name = ItemName(entry), planCost = entry.cost,
               sent = GetTime() }
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
    line.text = UI.Text(line, "small", "text")
    line.text:SetPoint("LEFT")
    line.text:SetPoint("RIGHT", line.status, "LEFT", -6, 0)
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
    if not entries or #entries == 0 then
        section:Hide()
        return 0
    end
    -- Planned again unless a purchase is under way, or a scan is (prices
    -- change once it's done; the scan updates the panel every second)
    if not (quote or asking or buying) and not (q and addon:IsScanning()) then
        q = PlanQueue()
    end
    local list = q and q.buyAH or {}
    local nextEntry = NextEntry()
    if ahOpen then Prefetch(list) end

    local shown = math.min(#list, LINES)
    for i, line in ipairs(section.lines) do
        local entry = list[i]
        if entry and i <= shown then
            line.text:SetText(string.format("%dx %s", entry.quantity, ItemName(entry)))
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
        last.text:SetTextColor(addon:Color("muted"))
        last.status:SetText("")
    end
    local y = 22 + shown * LINE_HEIGHT

    -- The note: nothing to buy, the price against the plan, or what's next
    local note, color = nil, "muted"
    local mailed = q and q.inMail and #q.inMail > 0 and ("In your mailbox: " .. table.concat(q.inMail, ", ") .. ".")
    if #list == 0 then
        note = mailed and (mailed .. " Everything else is here.") or "The queue has everything it needs."
    elseif not nextEntry then
        note = "Everything left was skipped. Open the AH again to try them again."
    elseif quote then
        local extra, warn, profitThen = Gap()
        if warn then
            -- "(0%)" read oddly for 1.75g over 820.75g (2026-10-19)
            local pct = math.floor(extra / quote.planCost * 100 + 0.5)
            note = string.format("%s: the AH asks %s more than the plan (%s).", quote.name, Money(extra),
                pct < 1 and "under 1%" or (pct .. "%"))
            if profitThen then
                note = note .. string.format(" Queue profit then: %s.", addon:FormatSignedMoney(profitThen))
            end
            color = profitThen and profitThen < 0 and "loss" or "warning"
        end
    elseif nextEntry.short then
        note, color = "The AH may not have all of it right now.", "warning"
    elseif mailed then
        note = mailed
    end
    -- Vendor items, so they aren't forgotten on the way out (the vendor
    -- panel, Vendor.lua, buys them). Not under a price warning.
    local vendorList = q and q.buyVendor or {}
    if #vendorList > 0 and color == "muted" then
        local names = {}
        for _, e in ipairs(vendorList) do table.insert(names, string.format("%dx %s", e.quantity, e.name)) end
        note = (note and (note .. " ") or "") .. "From a vendor: " .. table.concat(names, ", ") .. "."
    end
    if note then
        section.note:ClearAllPoints()
        section.note:SetPoint("TOPLEFT", 10, -(y + 4))
        section.note:SetPoint("RIGHT", -10, 0)
        section.note:SetText(note)
        section.note:SetTextColor(addon:Color(color))
        section.note:Show()
        y = y + 8 + section.note:GetStringHeight()
    else
        section.note:Hide()
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
    local warn = quote and select(2, Gap())
    section.button.label:SetTextColor(addon:Color(warn and "warning" or "gold"))
    section.button:ClearAllPoints()
    section.button:SetPoint("TOPLEFT", 10, -(y + 6))
    y = y + 6 + 28
    if nextEntry then
        section.hint:SetText(KeyText() and ("or press " .. KeyText()) or "set a key in Keybindings > Goldsmith")
        section.hint:ClearAllPoints()
        section.hint:SetPoint("TOPLEFT", 10, -(y + 4))
        section.hint:SetPoint("RIGHT", -10, 0)
        section.hint:Show()
        y = y + 4 + 14
    else
        section.button:Hide()
        section.hint:Hide()
        y = y - 34
    end
    if nextEntry then section.button:Show() end
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
    "ITEM_KEY_ITEM_INFO_RECEIVED", "GET_ITEM_INFO_RECEIVED" }) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event, unit, total)
    if event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
        skipped, listingsError, waitingKey = {}, nil, nil
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
        MailBought(buying.itemID, buying.quantity)
        buying = nil
        UpdateSoon()
    elseif event == "COMMODITY_PURCHASE_FAILED" then
        if not buying then return end
        addon:Notify("info", "Couldn't buy %s: the price may have changed. Buy next asks again.", buying.name)
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
