local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Buy from a vendor
--
-- Buy next's vendor side: a panel beside the vendor window listing what
-- the queue needs from this vendor, with one button that buys exactly that
-- (user, 2026-10-19: the Queue tab said 40 Ripened Vegetable Assortment
-- and 89 Tavern Fixings, 40 of each got bought, and the crafts ran 49
-- Tavern Fixings short; "then i don't have to remember"). The list is the
-- queue's own (BuildQueue's buyVendor), planned again as bags change, so
-- what's bought drops off. Core.lua records each purchase as for any
-- vendor purchase. Items bought with currencies are left to you.

local PANEL_WIDTH = 280
local LINES = 8
local LINE_HEIGHT = 16
local BUY_GAP = 0.2             -- seconds between purchases, so none is dropped

local panel
local here, elsewhere = {}, {}  -- what the queue needs that this vendor sells, and doesn't
local buyingNow = false

local function Money(copper) return addon:FormatMoney(copper) end

-- This vendor's items by itemID: { index, price (each), maxStack, available }
local function VendorItems()
    local items = {}
    for i = 1, (GetMerchantNumItems and GetMerchantNumItems() or 0) do
        local itemID = GetMerchantItemID and GetMerchantItemID(i)
        local price, stackCount, available, extended
        if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
            local info = C_MerchantFrame.GetItemInfo(i)
            if info then
                price, stackCount, available, extended = info.price, info.stackCount, info.numAvailable, info.hasExtendedCost
            end
        elseif GetMerchantItemInfo then
            local _
            _, _, price, stackCount, available, _, _, extended = GetMerchantItemInfo(i)
        end
        if itemID and price and price > 0 and not extended and not items[itemID] then
            stackCount = (stackCount and stackCount > 0) and stackCount or 1
            items[itemID] = { index = i, price = price / stackCount, stackCount = stackCount,
                              maxStack = math.max(GetMerchantItemMaxStack and GetMerchantItemMaxStack(i) or 1, 1),
                              available = available }
        end
    end
    return items
end

-- What the queue needs, split by whether this vendor sells it
local function Plan()
    here, elsewhere = {}, {}
    local entries = GoldsmithDB.queues and GoldsmithDB.queues[addon.charKey]
    if not entries or #entries == 0 then return end
    local q = addon:BuildQueue(addon.charKey)
    local sold = VendorItems()
    for _, entry in ipairs(q.buyVendor or {}) do
        local item = sold[entry.itemID]
        if item then
            local quantity = entry.quantity
            if item.available and item.available >= 0 then quantity = math.min(quantity, item.available) end
            table.insert(here, { itemID = entry.itemID, name = entry.name, quantity = quantity,
                                 cost = math.floor(item.price * quantity + 0.5), item = item,
                                 limited = quantity < entry.quantity })
        else
            table.insert(elsewhere, entry)
        end
    end
end

local function Total()
    local total = 0
    for _, e in ipairs(here) do total = total + e.cost end
    return total
end

local Update

-- Every item in the list, a stack at a time, a moment apart. From the
-- button's click: the game may want one for buying.
local function BuyAll()
    if buyingNow or #here == 0 then return end
    local total = Total()
    if GetMoney() < total then
        addon:Notify("info", "You need %s for this and have %s.", Money(total), Money(GetMoney()))
        return
    end
    local steps = {}
    for _, e in ipairs(here) do
        local left = e.quantity
        while left > 0 do
            -- Whole purchases for items sold several at a time
            local n = math.min(left, e.item.maxStack)
            if e.item.stackCount > 1 then
                n = math.max(math.floor(n / e.item.stackCount), 1) * e.item.stackCount
            end
            table.insert(steps, { index = e.item.index, itemID = e.itemID, quantity = n })
            left = left - n
        end
    end
    buyingNow = true
    Update()
    local i = 0
    local function Next()
        i = i + 1
        local step = steps[i]
        if not step or not (MerchantFrame and MerchantFrame:IsShown()) then
            buyingNow = false
            C_Timer.After(0.5, Update)
            return
        end
        -- The vendor's list can change while buying (limited stock)
        if GetMerchantItemID(step.index) == step.itemID then
            BuyMerchantItem(step.index, step.quantity)
        end
        C_Timer.After(BUY_GAP, Next)
    end
    Next()
end

local function CreatePanel()
    if panel or not MerchantFrame then return end
    panel = CreateFrame("Frame", nil, MerchantFrame, "BackdropTemplate")
    UI.RaiseAbove(panel, MerchantFrame)
    panel:SetWidth(PANEL_WIDTH)
    UI.Style(panel, "panel", "borderGold")
    panel:EnableMouse(true)
    panel:SetPoint("TOPLEFT", MerchantFrame, "TOPRIGHT", 4, 0)

    panel.title = UI.Text(panel, "label", "gold")
    panel.title:SetPoint("TOPLEFT", 10, -10)
    panel.title:SetText("GOLDSMITH: FOR YOUR QUEUE")

    panel.lines = {}
    for i = 1, LINES do
        local line = CreateFrame("Frame", nil, panel)
        line:SetHeight(LINE_HEIGHT)
        line:SetPoint("TOPLEFT", 10, -(28 + (i - 1) * LINE_HEIGHT))
        line:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
        line.status = UI.Text(line, "small", "muted", "RIGHT")
        line.status:SetPoint("RIGHT")
        line.text = UI.Text(line, "small", "text")
        line.text:SetPoint("LEFT")
        line.text:SetPoint("RIGHT", line.status, "LEFT", -6, 0)
        panel.lines[i] = line
    end

    panel.note = UI.Text(panel, "small", "muted")
    panel.note:SetJustifyH("LEFT")
    panel.note:SetWordWrap(true)

    panel.button = UI.Button(panel, "Buy all", PANEL_WIDTH - 20, 28, BuyAll)
    UI.Style(panel.button, "highlight", "borderGold")
    panel.button.label:SetTextColor(addon:Color("gold"))
    panel.button:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderGold")) end)
    UI.SetTooltip(panel.button, function(tooltip)
        tooltip:AddLine("Buy all", 1, 1, 1)
        addon:Explain(tooltip, "Buys exactly what your queue still needs from this vendor. What's in your bags isn't bought.", 0.8, 0.8, 0.8, true)
        addon:Explain(tooltip, "The list updates as your bags change, so bought items drop off.", 0.6, 0.6, 0.6, true)
    end, "ANCHOR_BOTTOM")
end

Update = function()
    if not panel then return end
    if not (MerchantFrame and MerchantFrame:IsShown()) then
        panel:Hide()
        return
    end
    if not buyingNow then Plan() end
    if #here == 0 and #elsewhere == 0 then
        panel:Hide()
        return
    end

    local shown = math.min(#here, LINES)
    for i, line in ipairs(panel.lines) do
        local e = here[i]
        if e and i <= shown then
            line.text:SetText(string.format("%dx %s", e.quantity, e.name or ("item " .. e.itemID)))
            line.status:SetText(Money(e.cost))
            line:Show()
        else
            line:Hide()
        end
    end
    if #here > LINES then
        local last = panel.lines[LINES]
        last.text:SetText(string.format("and %d more", #here - LINES + 1))
        last.status:SetText("")
    end
    local y = 28 + shown * LINE_HEIGHT

    -- What this vendor doesn't sell, so it isn't forgotten
    local notes = {}
    if #here == 0 then table.insert(notes, "Nothing your queue needs is sold here.") end
    for _, e in ipairs(here) do
        if e.limited then table.insert(notes, string.format("%s: only %d in stock.", e.name, e.quantity)) end
    end
    if #elsewhere > 0 then
        local names = {}
        for _, e in ipairs(elsewhere) do table.insert(names, string.format("%dx %s", e.quantity, e.name)) end
        table.insert(notes, "From another vendor: " .. table.concat(names, ", ") .. ".")
    end
    if #notes > 0 then
        panel.note:ClearAllPoints()
        panel.note:SetPoint("TOPLEFT", 10, -(y + 4))
        panel.note:SetPoint("RIGHT", -10, 0)
        panel.note:SetText(table.concat(notes, " "))
        panel.note:Show()
        y = y + 8 + panel.note:GetStringHeight()
    else
        panel.note:Hide()
    end

    if #here > 0 then
        panel.button:SetLabel(buyingNow and "Buying..." or ("Buy all for " .. Money(Total())))
        panel.button:SetEnabled(not buyingNow)
        panel.button:SetAlpha(buyingNow and 0.5 or 1)
        panel.button:ClearAllPoints()
        panel.button:SetPoint("TOPLEFT", 10, -(y + 6))
        panel.button:Show()
        y = y + 6 + 28
    else
        panel.button:Hide()
    end
    panel:SetHeight(y + 10)
    panel:Show()
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

local events = CreateFrame("Frame")
for _, event in ipairs({ "MERCHANT_SHOW", "MERCHANT_CLOSED", "MERCHANT_UPDATE", "BAG_UPDATE_DELAYED" }) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event)
    if event == "MERCHANT_SHOW" then
        CreatePanel()
        -- The vendor's list fills in a moment after the window opens
        C_Timer.After(0.2, Update)
    elseif event == "MERCHANT_CLOSED" then
        buyingNow = false
        if panel then panel:Hide() end
    elseif MerchantFrame and MerchantFrame:IsShown() and not buyingNow then
        UpdateSoon()
    end
end)

-- The queue changed (Queue.lua) while the vendor is open
function addon.VendorQueueChanged()
    if MerchantFrame and MerchantFrame:IsShown() and not buyingNow then UpdateSoon() end
end

_G.Goldsmith = addon
