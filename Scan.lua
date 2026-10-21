local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Goldsmith's own AH scan
--
-- Every price on the AH in one go, so Goldsmith needs no other addon for
-- prices (WoW Forever has no Goldsmith Data; user, 2026-10-18). Two ways,
-- both tested on retail with GoldsmithProbe:
--   - full: C_AuctionHouse.ReplicateItems, every listing (344,512 on
--     retail; the game took 46 s to send them). The server allows one
--     every 15 minutes. Each item gets a fair price: the lowest with real
--     quantity behind it (addon:RobustBookPrice, as live order books).
--   - page by page: an empty browse search paged to the end (24,437 items
--     in 25 s). Only each item's lowest price, so fair = lowest.
-- The full scan's data event fires again and again while item details load
-- (181,471 times in the probe), so the listings are read once, a moment
-- after the first, and in chunks a frame apart so the game never freezes.
-- When Auctionator asks for a full scan, its data is read too (no second
-- request). Gear isn't priced (one item ID covers every item level).
-- Saved in GoldsmithDB.ownScan (see Pricing.lua); the panel by the AH
-- window shows the last scan and starts one. GoldsmithDB.ui2.scanPanel
-- is the panel's spot when dragged.

local FULL_COOLDOWN = 15 * 60   -- the server's limit on full scans
local FULL_WAIT = 120           -- seconds for the full scan's data before paging instead
local SETTLE = 2                -- seconds after the first data event before reading
local PAGE_STALL = 20           -- seconds without a page before stopping
local PAGES_GUESS = 40          -- pages in a page scan, until one has run
local LOW_KEEP = 0.5            -- a page scan's price under half the last one keeps the last
-- Reading and pricing stop for the frame once FRAME_MS is used (checked
-- every CHECK_EVERY rows or items): fixed counts of 15,000 auctions and
-- 3,000 items a frame stuttered near the end of a scan (user, 2026-10-20).
-- At 8 ms the game still fell from 100 to 30 fps while reading (it loads
-- each auction's item too), so 4.
local FRAME_MS = 4
local CHECK_EVERY = 100
local BORROW_AFTER = 10 * 60    -- read Auctionator's full scan when ours is older
local AUTO_AFTER = 60 * 60      -- scan on opening the AH when the last is older
local AUTO_DELAY = 3            -- wait first: Auctionator may be scanning already
local PANEL_WIDTH = 280

local run       -- the scan in progress: { phase, method, started, ... }
local ahOpen = false
local panel
local UpdatePanel -- below

-- Gear only on retail: one item ID there covers every item level and
-- quality, so one price per ID is wrong. WoW Forever's gear is one fixed
-- item per ID, and stays relevant longer there (slower progression; user,
-- 2026-10-18), so it's priced. Its random-stat versions ("of the Bear")
-- share an ID: to price per version once the stress test shows how the AH
-- lists them.
local SKIP_CLASS = { [2] = true, [4] = true } -- weapons, armor
local RETAIL = (select(4, GetBuildInfo()) or 0) >= 100000

local function Priced(itemID)
    if type(itemID) ~= "number" or itemID == 82800 then return false end -- pet cages
    if not RETAIL then return true end
    local classID = select(6, C_Item.GetItemInfoInstant(itemID))
    return not SKIP_CLASS[classID]
end

-- How long each part of the last scan took, and its longest frame (ms)
local timing
local function Timed(key, started, into)
    into = into or timing
    local ms = debugprofilestop() - started
    if into then into[key] = math.max(into[key] or 0, math.floor(ms + 0.5)) end
end

local function Finish(prices, auctions, method)
    local items = 0
    for _ in pairs(prices) do items = items + 1 end
    if items == 0 then
        -- Nothing came back: keep the last scan as it was
        addon:Notify("info", "Goldsmith scan: the AH sent nothing back, so the last scan is kept.")
        run = nil
        UpdatePanel()
        return
    end
    GoldsmithDB.ownScan = {
        time = time(), method = method, auctions = auctions, items = items,
        seconds = time() - run.started, borrowed = run.borrowed or nil, prices = prices,
    }
    run = nil
    addon:Notify("info", "Goldsmith scan: %s items priced.", BreakUpLargeNumbers(items))
    -- Buy to vendor (below): Forever only for now; retail's 350,000
    -- listings would need the chunked tally and a look at what it finds
    if addon.isForever then
        C_Timer.After(0.5, function() if addon.FindVendorFlips then addon:FindVendorFlips(method) end end)
    end
    UpdatePanel()
    -- One part a frame, so the end of a scan doesn't freeze the game. The
    -- times go to GoldsmithDB.scanTiming (a page scan has only these).
    local t = timing or {}
    timing = nil
    t.method = method
    C_Timer.After(0, function()
        local started = debugprofilestop()
        addon:RecordScanHistory()
        Timed("history", started, t)
        C_Timer.After(0, function()
            started = debugprofilestop()
            addon:MatchEnchantScrolls()
            Timed("scrolls", started, t)
            C_Timer.After(0, function()
                started = debugprofilestop()
                addon:DataChanged()
                if addon.Refresh then addon.Refresh() end
                Timed("refresh", started, t)
                t.time = time()
                GoldsmithDB.scanTiming = t
            end)
        end)
    end)
end

-- Full scan

-- Each item's listings as price levels, then its fair price
local function PriceBooks(books, auctions)
    local prices, ids = {}, {}
    for itemID in pairs(books) do ids[#ids + 1] = itemID end
    local i = 0
    local function Step()
        if not run then return end
        local started = debugprofilestop()
        local stop = #ids
        for n = i + 1, #ids do
            local itemID = ids[n]
            local levels, total = {}, 0
            for price, qty in pairs(books[itemID]) do
                levels[#levels + 1] = { price = price, qty = qty }
                total = total + qty
            end
            table.sort(levels, function(a, b) return a.price < b.price end)
            local fair = addon:RobustBookPrice({ total = total, levels = levels })
            prices[itemID] = { math.floor(fair + 0.5), math.floor(levels[1].price + 0.5), total }
            if n % CHECK_EVERY == 0 and debugprofilestop() - started > FRAME_MS then
                stop = n
                break
            end
        end
        Timed("pricing", started)
        i = stop
        run.progress = 0.5 + 0.5 * (#ids > 0 and i / #ids or 1)
        UpdatePanel()
        if i < #ids then C_Timer.After(0, Step) else Finish(prices, auctions, "full") end
    end
    Step()
end

local function ReadFullScan()
    if not run or run.phase ~= "waiting" then return end
    local api = C_AuctionHouse
    local ok, num = pcall(api.GetNumReplicateItems)
    if not ok or type(num) ~= "number" or num == 0 then
        run.settling = nil
        return
    end
    run.phase = "reading"
    timing = {}
    local books, i = {}, 0
    local function Step()
        if not run then return end
        local started = debugprofilestop()
        local stop = num
        for n = i, num - 1 do
            -- name, texture, count, quality, usable, level, levelType, minBid,
            -- minIncrement, buyout, bid, highBidder, bidder, owner, ownerFull,
            -- saleStatus, itemID, hasAllInfo
            local okI, _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID =
                pcall(api.GetReplicateItemInfo, n)
            if okI and type(buyout) == "number" and buyout > 0 and type(count) == "number" and count > 0
                and Priced(itemID) then
                local unit = buyout / count
                local book = books[itemID]
                if not book then book = {}; books[itemID] = book end
                book[unit] = (book[unit] or 0) + count
            end
            if n % CHECK_EVERY == 0 and debugprofilestop() - started > FRAME_MS then
                stop = n + 1
                break
            end
        end
        Timed("reading", started)
        i = stop
        run.progress = 0.5 * i / num
        UpdatePanel()
        if i < num then C_Timer.After(0, Step) else PriceBooks(books, num) end
    end
    Step()
end

-- Page by page

local function FinishPages()
    local started = debugprofilestop()
    local ok, results = pcall(C_AuctionHouse.GetBrowseResults)
    local prices = {}
    for _, r in ipairs(ok and type(results) == "table" and results or {}) do
        local key = r.itemKey
        local itemID, price = key and key.itemID, r.minPrice
        if (key and key.battlePetSpeciesID or 0) == 0 and type(price) == "number" and price > 0 and Priced(itemID) then
            local p = prices[itemID]
            if not p then
                prices[itemID] = { price, price, r.totalQuantity or 0 }
            else
                if price < p[1] then p[1], p[2] = price, price end
                p[3] = p[3] + (r.totalQuantity or 0)
            end
        end
    end
    -- Paging sees only each item's lowest listing, so one unit at 1.40g
    -- priced all of Winged Stalk (about 10g; user, 2026-10-19). An item
    -- under half its last fair price keeps that price (the lowest stays
    -- as p[2]); the next full scan says whether it really dropped.
    local last = GoldsmithDB.ownScan and GoldsmithDB.ownScan.prices
    for itemID, p in pairs(prices) do
        local before = last and last[itemID]
        if before and before[1] and p[1] < before[1] * LOW_KEEP then p[1] = before[1] end
    end
    -- How many pages it took, for the next page scan's percent
    if run and (run.pages or 0) > 1 then GoldsmithDB.scanPages = run.pages end
    timing = {}
    Timed("pricing", started)
    Finish(prices, #(ok and type(results) == "table" and results or {}), "pages")
end

local function NextPage()
    if not run or run.phase ~= "pages" then return end
    local api = C_AuctionHouse
    local okF, full = pcall(api.HasFullBrowseResults)
    if okF and full then
        FinishPages()
        return
    end
    local okT, ready = pcall(api.IsThrottledMessageSystemReady)
    if not okT or ready then
        pcall(api.RequestMoreBrowseResults)
    else
        run.waitingThrottle = true
    end
end

local function StartPages()
    run = run or { started = time() }
    run.phase, run.method, run.pages, run.lastPage = "pages", "pages", 0, GetTime()
    run.progress = nil
    local query = {
        searchString = "", minLevel = 0, maxLevel = 0, filters = {}, itemClassFilters = {},
        sorts = { { sortOrder = Enum.AuctionHouseSortOrder.Price, reverseSort = false } },
    }
    local ok, err = pcall(C_AuctionHouse.SendBrowseQuery, query)
    if not ok then
        addon:Notify("info", "Goldsmith scan couldn't start: %s", tostring(err))
        run = nil
    end
    UpdatePanel()
end

-- Starting

function addon:IsScanning()
    return run ~= nil
end

-- auto: opening the AH started it (no message when it can't)
function addon:ScanAH(auto)
    if run then
        if not auto then addon:Notify("info", "A Goldsmith scan is already running.") end
        return
    end
    if not addon:Setting("ahScan") then
        if not auto then addon:Notify("info", "Goldsmith's AH scan is off (Settings > Crafting and prices).") end
        return
    end
    if not ahOpen then
        if not auto then addon:Notify("info", "Open the auction house first.") end
        return
    end
    local api = C_AuctionHouse
    local lastFull = GoldsmithDB.lastFullRequest or 0
    if api.ReplicateItems and time() - lastFull >= FULL_COOLDOWN then
        GoldsmithDB.lastFullRequest = time()
        run = { phase = "waiting", method = "full", started = time() }
        local ok = pcall(api.ReplicateItems)
        if not ok then StartPages() end
    else
        StartPages()
    end
    UpdatePanel()
end

-- Auctionator (or anything) asked for a full scan: read it too
local function Borrow()
    if run or not ahOpen or not addon:Setting("ahScan") then return end
    local last = addon:GetOwnScanTime()
    if last and time() - last < BORROW_AFTER then return end
    run = { phase = "waiting", method = "full", started = time(), borrowed = true }
    UpdatePanel()
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED", "REPLICATE_ITEM_LIST_UPDATE",
    "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED",
    "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" }) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event)
    if event == "AUCTION_HOUSE_SHOW" then
        ahOpen = true
        UpdatePanel()
        if addon:Setting("ahScan") and addon:Setting("autoScan") then
            C_Timer.After(AUTO_DELAY, function()
                local last = addon:GetOwnScanTime()
                if ahOpen and not run and (not last or time() - last >= AUTO_AFTER) then addon:ScanAH(true) end
            end)
        end
    elseif event == "AUCTION_HOUSE_CLOSED" then
        ahOpen = false
        -- Reading carries on (the listings are already here); waiting and
        -- paging need the AH open
        if run and (run.phase == "waiting" or run.phase == "pages") then
            if run.phase == "pages" then addon:Notify("info", "Goldsmith scan stopped: the AH closed.") end
            run = nil
        end
        UpdatePanel()
    elseif event == "REPLICATE_ITEM_LIST_UPDATE" then
        if not run then Borrow() end
        if run and run.phase == "waiting" and not run.settling then
            run.settling = true
            C_Timer.After(SETTLE, ReadFullScan)
        end
    elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
        if run and run.phase == "pages" then
            run.pages = run.pages + 1
            run.lastPage = GetTime()
            UpdatePanel()
            NextPage()
        end
    elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
        if run and run.phase == "pages" and run.waitingThrottle then
            run.waitingThrottle = nil
            NextPage()
        end
    end
end)

-- A full scan that never answers (asked too soon) pages instead; paging
-- that stops answering saves what came back
C_Timer.NewTicker(1, function()
    if not run then return end
    if run.phase == "waiting" and time() - run.started > FULL_WAIT then
        if run.borrowed then run = nil else StartPages() end
        UpdatePanel()
    elseif run.phase == "pages" and GetTime() - run.lastPage > PAGE_STALL then
        FinishPages()
    elseif run.phase == "waiting" then
        UpdatePanel() -- the seconds counting up
    end
end)

-- Panel by the AH window

local function When(ts)
    if date("%Y-%m-%d", ts) == date("%Y-%m-%d") then return "today " .. date("%H:%M", ts) end
    local days = math.max(1, math.floor((time() - ts) / 86400))
    return string.format("%d day%s ago", days, days == 1 and "" or "s")
end

local function PlacePanel()
    panel:ClearAllPoints()
    local pos = GoldsmithDB.ui2.scanPanel
    if pos then
        panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPLEFT", pos.x, pos.y)
    else
        panel:SetPoint("TOPLEFT", AuctionHouseFrame, "TOPRIGHT", 4, 0)
    end
end

local function ButtonLabel()
    if not run then return "Scan the AH" end
    if run.phase == "waiting" then
        return string.format("Waiting for the AH... %ds", time() - run.started)
    elseif run.phase == "reading" then
        return string.format("Reading %d%%", math.floor((run.progress or 0) * 100))
    elseif run.phase == "pages" then
        -- The game doesn't say how many pages there are, so the last page
        -- scan's count (a guess the first time); never 100% until done
        local total = GoldsmithDB.scanPages or PAGES_GUESS
        return string.format("Scanning %d%%", math.min(99, math.floor((run.pages or 0) / total * 100)))
    end
    return "Scanning..."
end

local function CreatePanel()
    if panel or not AuctionHouseFrame then return end
    panel = CreateFrame("Frame", nil, AuctionHouseFrame, "BackdropTemplate")
    -- Above the whole AH window when dragged over it (user, 2026-10-19:
    -- its buttons, then its border and close button, showed through)
    UI.RaiseAbove(panel, AuctionHouseFrame)
    panel:SetSize(PANEL_WIDTH, 104)
    UI.Style(panel, "panel", "borderGold")
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        GoldsmithDB.ui2.scanPanel = { x = self:GetLeft() - AuctionHouseFrame:GetLeft(),
                                      y = self:GetTop() - AuctionHouseFrame:GetTop() }
        PlacePanel()
    end)
    panel:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and MenuUtil and MenuUtil.CreateContextMenu then
            MenuUtil.CreateContextMenu(panel, function(_, root)
                root:CreateTitle("Goldsmith")
                root:CreateButton("Put it back beside the AH", function()
                    GoldsmithDB.ui2.scanPanel = nil
                    PlacePanel()
                end)
            end)
        end
    end)
    PlacePanel()

    panel.title = UI.Text(panel, "label", "gold")
    panel.title:SetPoint("TOPLEFT", 10, -10)
    panel.title:SetText("GOLDSMITH")
    panel.status = UI.Text(panel, "small", "muted")
    panel.status:SetPoint("TOPLEFT", panel.title, "BOTTOMLEFT", 0, -6)
    panel.status:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
    panel.status:SetJustifyH("LEFT")
    panel.status:SetWordWrap(true)
    panel.status:SetMaxLines(2)

    panel.button = UI.Button(panel, "Scan the AH", PANEL_WIDTH - 20, 28, function() addon:ScanAH(false) end)
    panel.button:SetPoint("TOPLEFT", 10, -66)
    UI.Style(panel.button, "highlight", "borderGold")
    panel.button.label:SetTextColor(addon:Color("gold"))
    panel.button:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderGold")) end)

    UI.SetTooltip(panel.button, function(tooltip)
        tooltip:AddLine("Scan the AH", 1, 1, 1)
        addon:Explain(tooltip, "Every price on the AH, for every Goldsmith number: costs, profits, Cheap materials and the price charts.", 0.8, 0.8, 0.8, true)
        addon:Explain(tooltip, "A full scan sees every listing, so a few cheap undercuts don't set the price. The game allows one every 15 minutes; in between, Goldsmith scans page by page, which sees only each item's lowest price.", 0.6, 0.6, 0.6, true)
        local last = GoldsmithDB.lastFullRequest
        if last and time() - last < FULL_COOLDOWN then
            tooltip:AddLine(string.format("Next full scan in %d min.", math.ceil((FULL_COOLDOWN - (time() - last)) / 60)),
                1, 0.6, 0.2, true)
        end
        addon:Explain(tooltip, "Goldsmith also scans by itself when you open the AH and the last scan is over an hour old (Settings).", 0.6, 0.6, 0.6, true)
        -- Below the panel, right edges lined up, so it stays on screen when
        -- the panel sits at the screen's edge
        tooltip:ClearAllPoints()
        tooltip:SetPoint("TOPRIGHT", panel, "BOTTOMRIGHT", 0, -4)
    end, "ANCHOR_NONE")
    UI.SetTooltip(panel, function(tooltip)
        tooltip:AddLine("Goldsmith", 1, 1, 1)
        addon:Explain(tooltip, "Drag to move it. Right-click to put it back.", 0.6, 0.6, 0.6, true)
    end)
    -- Buy next, under the scan (Shop.lua)
    if addon.CreateShopSection then addon.CreateShopSection(panel, PANEL_WIDTH) end
end

UpdatePanel = function()
    if not (AuctionHouseFrame and AuctionHouseFrame:IsShown()) then return end
    -- Off in Settings: no panel (and no Buy next)
    if not addon:Setting("ahScan") then
        if panel then panel:Hide() end
        return
    end
    CreatePanel()
    if not panel then return end
    local scan = GoldsmithDB.ownScan
    if run and run.borrowed then
        panel.status:SetText("Reading Auctionator's scan too")
    elseif scan and scan.time then
        panel.status:SetText(string.format("Last scan %s, %s items%s", When(scan.time),
            BreakUpLargeNumbers(scan.items or 0), scan.method == "pages" and " (page by page)" or ""))
    else
        panel.status:SetText("No scan yet")
    end
    panel.button:SetLabel(ButtonLabel())
    panel.button:SetEnabled(run == nil)
    panel.button:SetAlpha(run == nil and 1 or 0.7)
    panel:SetHeight(104 + (addon.UpdateShopSection and addon.UpdateShopSection() or 0))
    panel:Show()
end
addon.UpdateScanPanel = function() UpdatePanel() end

-- Buy to vendor (Forever, tested at the stress test 2026-10-21)
--
-- After each scan: listings whose price each is under what a vendor pays
-- for the item, in a list under the panel. Click a row to search it on the
-- AH, buy it there, sell it to any vendor. A full scan sees every listing;
-- a page scan only each item's cheapest, so its counts are "at least".

local FLIP_ROWS = 8
local FLIP_ROW_HEIGHT = 18
local flipFrame
local flipList = {}
local flipMethod

local function SellPrice(itemID)
    local sell = select(11, C_Item.GetItemInfo(itemID))
    if sell == nil and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    return sell
end

local function SearchItem(itemID)
    local ah = AuctionHouseFrame
    local bar = ah and ah:IsShown() and ah.SearchBar
    local name = C_Item.GetItemNameByID(itemID)
    if not (bar and bar.SearchBox and name) then return end
    if ah.SetDisplayMode and AuctionHouseFrameDisplayMode then
        pcall(ah.SetDisplayMode, ah, AuctionHouseFrameDisplayMode.Buy)
    end
    bar.SearchBox:SetText(name)
    if bar.StartSearch then pcall(bar.StartSearch, bar) end
end

local function ShowFlips()
    if not panel or not panel:IsShown() then return end
    if not flipFrame then
        flipFrame = CreateFrame("Frame", nil, panel, "BackdropTemplate")
        UI.Style(flipFrame, "panel", "borderGold")
        flipFrame:SetWidth(PANEL_WIDTH)
        flipFrame:SetPoint("TOPLEFT", panel, "BOTTOMLEFT", 0, -4)
        flipFrame.title = UI.Text(flipFrame, "label", "gold")
        flipFrame.title:SetPoint("TOPLEFT", 10, -10)
        flipFrame.title:SetText("BUY TO VENDOR")
        flipFrame.note = UI.Text(flipFrame, "small", "muted")
        flipFrame.note:SetPoint("TOPLEFT", flipFrame.title, "BOTTOMLEFT", 0, -4)
        flipFrame.note:SetPoint("RIGHT", -10, 0)
        flipFrame.rows = {}
        for i = 1, FLIP_ROWS do
            local row = CreateFrame("Button", nil, flipFrame)
            row:SetHeight(FLIP_ROW_HEIGHT)
            row:SetPoint("TOPLEFT", 10, -44 - (i - 1) * FLIP_ROW_HEIGHT)
            row:SetPoint("RIGHT", -10, 0)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            row.name = UI.Text(row, "small", "text")
            row.name:SetPoint("LEFT", 0, 0)
            row.name:SetPoint("RIGHT", -70, 0)
            row.gain = UI.Text(row, "small", "profit", "RIGHT")
            row.gain:SetPoint("RIGHT", 0, 0)
            row:SetScript("OnClick", function(self) if self.itemID then SearchItem(self.itemID) end end)
            row:SetScript("OnEnter", function(self)
                if not self.entry then return end
                local e = self.entry
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetItemByID(e.itemID)
                GameTooltip:AddLine(" ")
                GameTooltip:AddLine(string.format("%s%d on the AH under vendor price", flipMethod == "pages" and "at least " or "", e.count), 1, 0.82, 0)
                GameTooltip:AddDoubleLine("Cheapest", addon:FormatMoney(e.low) .. " each", 0.8, 0.8, 0.8, 1, 1, 1)
                GameTooltip:AddDoubleLine("Vendor pays", addon:FormatMoney(e.sell) .. " each", 0.8, 0.8, 0.8, 1, 1, 1)
                GameTooltip:AddDoubleLine("Buy them all", addon:FormatMoney(e.cost), 0.8, 0.8, 0.8, 1, 1, 1)
                GameTooltip:AddDoubleLine("You make", addon:FormatMoney(e.gain), 0.8, 0.8, 0.8, 0.2, 1, 0.2)
                GameTooltip:AddLine("Click: search it on the AH", 0.6, 0.6, 0.6)
                GameTooltip:Show()
            end)
            row:SetScript("OnLeave", function() GameTooltip:Hide() end)
            flipFrame.rows[i] = row
        end
    end
    local total = 0
    for _, e in ipairs(flipList) do total = total + e.gain end
    if #flipList == 0 then
        flipFrame.note:SetText("Nothing under vendor price in the last scan.")
    else
        flipFrame.note:SetText(string.format("%d items, about %s to make", #flipList, addon:FormatMoney(total)))
    end
    local shown = math.min(#flipList, FLIP_ROWS)
    for i, row in ipairs(flipFrame.rows) do
        local e = flipList[i]
        row.entry, row.itemID = e, e and e.itemID
        if e then
            local name = C_Item.GetItemNameByID(e.itemID) or ("item " .. e.itemID)
            row.name:SetText(string.format("%s x%d", name, e.count))
            row.gain:SetText("+" .. addon:FormatMoney(e.gain))
            row:Show()
        else
            row:Hide()
        end
    end
    flipFrame:SetHeight(50 + shown * FLIP_ROW_HEIGHT)
    flipFrame:Show()
end

local function RankFlips(listings)
    flipList = {}
    for itemID, rows in pairs(listings) do
        local sell = SellPrice(itemID)
        if sell and sell > 0 then
            local e
            for _, r in ipairs(rows) do
                if r[1] < sell then
                    e = e or { itemID = itemID, sell = sell, count = 0, cost = 0, gain = 0, low = r[1] }
                    e.count = e.count + r[2]
                    e.cost = e.cost + r[1] * r[2]
                    e.gain = e.gain + (sell - r[1]) * r[2]
                    if r[1] < e.low then e.low = r[1] end
                end
            end
            if e then e.cost, e.gain = math.floor(e.cost + 0.5), math.floor(e.gain + 0.5); table.insert(flipList, e) end
        end
    end
    table.sort(flipList, function(a, b) return a.gain > b.gain end)
    local total = 0
    for _, e in ipairs(flipList) do total = total + e.gain end
    if #flipList > 0 then
        addon:Notify("info", "Goldsmith: %d items on the AH under vendor price, about %s to make.", #flipList, addon:FormatMoney(total))
    end
    ShowFlips()
end

-- Reads the scan's listings (a frame at a time), then waits for item data
-- so the vendor prices are known
function addon:FindVendorFlips(method)
    flipMethod = method
    local listings = {}
    local function Rank()
        for itemID in pairs(listings) do SellPrice(itemID) end
        C_Timer.After(2, function() RankFlips(listings) end)
    end
    local api = C_AuctionHouse
    if method == "full" then
        local ok, num = pcall(api.GetNumReplicateItems)
        if not ok or type(num) ~= "number" then return end
        local i = 0
        local function Step()
            local started = debugprofilestop()
            while i < num do
                local okI, _, _, count, _, _, _, _, _, _, buyout, _, _, _, _, _, _, itemID =
                    pcall(api.GetReplicateItemInfo, i)
                i = i + 1
                if okI and itemID and type(buyout) == "number" and buyout > 0 and type(count) == "number" and count > 0 then
                    listings[itemID] = listings[itemID] or {}
                    table.insert(listings[itemID], { buyout / count, count })
                end
                if debugprofilestop() - started > 6 then break end
            end
            if i < num then C_Timer.After(0, Step) else Rank() end
        end
        Step()
    else
        local ok, results = pcall(api.GetBrowseResults)
        for _, r in ipairs(ok and type(results) == "table" and results or {}) do
            local key = r.itemKey
            if key and key.itemID and (key.battlePetSpeciesID or 0) == 0 and type(r.minPrice) == "number" and r.minPrice > 0 then
                listings[key.itemID] = listings[key.itemID] or {}
                table.insert(listings[key.itemID], { r.minPrice, 1 })
            end
        end
        Rank()
    end
end

local flipEvents = CreateFrame("Frame")
flipEvents:RegisterEvent("AUCTION_HOUSE_SHOW")
flipEvents:SetScript("OnEvent", function()
    C_Timer.After(0.2, function() if flipMethod then ShowFlips() end end)
end)
