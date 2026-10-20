local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Goldsmith's columns in the game's list of patron orders
--
-- In place of the Patron Name column (user, 2026-10-18: "patron name is
-- completely useless"), with Goldsmith's own labels over it:
--   - Known: a check when you know the recipe (the game forgets the "not
--     learned" filter)
--   - Rewards: the rewards' icons (items, then currencies such as Artisan's
--     Moxie)
--   - Profit: to the gold, as the opened order counts it
--     (addon:GetOrderListPreview)
-- It saves clicking into every order (user, 2026-10-18). Earlier tries put
-- the marks in the Name column, where they covered long enchanting names;
-- the game's window can't be widened safely (it sets its own size per
-- tab). The patron names and their header are hidden, not removed, and
-- come back on the other tabs and with the setting off. The hover lists
-- the rewards, the commission and the profit; a click opens the order, as
-- its row does. Settings > Cost in the profession window turns it off with
-- the cost lines. If the game's window changes, this quietly shows nothing.

local ICON = 14
local MAX_REWARDS = 3
local ICON_GAP = 3
local CHECK = "Interface\\RaidFrame\\ReadyCheck-Ready"

-- The columns in the Patron Name column: Known at its left, Profit at its
-- right (kept off the Commission column, user, 2026-10-18), Rewards
-- between them with the same space on each side (user, 2026-10-18),
-- measured on what shows: the "Known" label, and the profits' width
local PAD = 6
local PROFIT_INSET = 14
local PROFIT_MIN = 36   -- about "+506g"

-- Where each column sits, from the column's left edge, for a column
-- `width` wide: { known (center), rewards (center), profit (right edge) }
local function Layout(width, knownText, profitText)
    local knownWidth = math.max(knownText, ICON)
    local profitRight = width - PROFIT_INSET
    local profitLeft = profitRight - math.max(profitText, PROFIT_MIN)
    local knownRight = PAD + knownWidth
    return { known = PAD + knownWidth / 2, rewards = (knownRight + profitLeft) / 2, profit = profitRight }
end

local Money = function(c) return addon:FormatMoney(c) end

-- Signed whole gold: "+12g", "-1,234g"
local function RoundGold(copper)
    local gold = math.floor(math.abs(copper) / 10000 + 0.5)
    local sign = copper < 0 and gold > 0 and "-" or "+"
    local digits = BreakUpLargeNumbers and BreakUpLargeNumbers(gold) or tostring(gold)
    return sign .. digits .. "g"
end

local function RewardName(r)
    if r.link and not r.link:find("[]", 1, true) then return r.link end
    C_Item.RequestLoadItemDataByID(r.itemID)
    return C_Item.GetItemNameByID(r.itemID) or ("item " .. r.itemID)
end

local function Tooltip(tooltip, line)
    local p = line.preview
    if not p then return end
    tooltip:AddLine("Goldsmith: this order", addon:Color("gold"))
    tooltip:AddLine(p.learned and "You know this recipe." or "You haven't learned this recipe.",
        addon:Color(p.learned and "text" or "warning"))
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Your materials", (#p.mats == 0 and "none")
        or ((p.complete and "" or "at least ") .. Money(p.cost)), 1, 1, 1, 1, 1, 1)
    tooltip:AddDoubleLine("Commission (after the consortium's cut)", Money(p.commission), 1, 1, 1, 1, 1, 1)
    for _, r in ipairs(p.rewards) do
        local value = r.value > 0 and Money(r.value) or "can't be sold"
        if r.opened then value = string.format("about %s (avg of %d opened)", Money(r.value), r.opened) end
        tooltip:AddDoubleLine("Reward: " .. RewardName(r) .. (r.count > 1 and (" x" .. r.count) or ""),
            value, 1, 1, 1, 0.8, 0.8, 0.8)
    end
    for _, c in ipairs(line.currencies or {}) do
        tooltip:AddDoubleLine("Reward: " .. c.name .. (c.count > 1 and (" x" .. c.count) or ""),
            "can't be sold", 1, 1, 1, 0.8, 0.8, 0.8)
    end
    local profit = p.commission + p.rewardsValue - p.cost
    tooltip:AddDoubleLine("Profit", (p.complete and "" or "at most ")
        .. addon:Colorize(addon:FormatSignedMoney(profit), addon:MoneyColor(profit)), 1, 1, 1, 1, 1, 1)
    if line.patron then tooltip:AddLine("Patron: " .. line.patron, 0.6, 0.6, 0.6) end
    addon:Explain(tooltip, "Your materials count at their lowest quality, at what yours cost you or today's price. "
        .. "Open the order to see the cost at the qualities you pick.")
end

local list, box, labels

-- The Patron Name column's header: the second from the left
local function PatronHeader()
    local headers = list.HeaderContainer
    if not headers then return nil end
    local sorted = {}
    for _, h in ipairs({ headers:GetChildren() }) do
        if h:IsShown() and h:GetLeft() then table.insert(sorted, h) end
    end
    table.sort(sorted, function(a, b) return a:GetLeft() < b:GetLeft() end)
    return sorted[2]
end

-- What's hidden of the game's (patron names, the header's text), to show
-- again: { [object] = true }
local hidden = {}

local function Hide(object)
    if not hidden[object] then
        hidden[object] = true
        object:SetAlpha(0)
    end
end

local function ShowAllHidden(keep)
    for object in pairs(hidden) do
        if not (keep and keep[object]) then
            object:SetAlpha(1)
            hidden[object] = nil
        end
    end
end

-- Goldsmith's labels over the Patron Name header
local function CreateLabels()
    labels = CreateFrame("Frame", nil, list)
    for _, key in ipairs({ "known", "rewards", "profit" }) do
        labels[key] = labels:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    end
    labels.known:SetText("Known")
    labels.rewards:SetText("Rewards")
    labels.profit:SetText("Profit")
end

local function PlaceLabels(at)
    labels.known:ClearAllPoints()
    labels.known:SetPoint("CENTER", labels, "LEFT", at.known, 0)
    labels.rewards:ClearAllPoints()
    labels.rewards:SetPoint("CENTER", labels, "LEFT", at.rewards, 0)
    labels.profit:ClearAllPoints()
    labels.profit:SetPoint("RIGHT", labels, "LEFT", at.profit, 0)
end

-- A line's check, icons and profit where the layout puts them
local function PlaceLine(line, at)
    line.at = at
    line.check:ClearAllPoints()
    line.check:SetPoint("CENTER", line, "LEFT", at.known, 0)
    line.profit:ClearAllPoints()
    line.profit:SetPoint("RIGHT", line, "LEFT", at.profit, 0)
    -- The icons centered on the Rewards column, however many there are
    local n = math.min(line.shownCount or 0, MAX_REWARDS)
    local start = at.rewards - (n * ICON + (n - 1) * ICON_GAP) / 2
    for i, icon in ipairs(line.icons) do
        icon:ClearAllPoints()
        icon:SetPoint("LEFT", line, "LEFT", start + (i - 1) * (ICON + ICON_GAP), 0)
    end
end

-- One line per order row, over its Patron Name cell. On the list, not the
-- row (the game moves cells and rows around as it redraws).
local function CreateLine(row)
    local line = CreateFrame("Button", nil, list)
    line.goldsmithOwn = true
    local hl = line:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.08)
    line.profit = UI.Text(line, "small", "text", "RIGHT")
    line.check = line:CreateTexture(nil, "ARTWORK")
    line.check:SetSize(ICON, ICON)
    line.check:SetTexture(CHECK)
    line.icons = {}
    for i = 1, MAX_REWARDS do
        local icon = line:CreateTexture(nil, "ARTWORK")
        icon:SetSize(ICON, ICON)
        icon.count = line:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
        icon.count:SetPoint("BOTTOMRIGHT", icon, "BOTTOMRIGHT", 2, -2)
        line.icons[i] = icon
    end
    UI.SetTooltip(line, Tooltip)
    -- A click opens the order, as its row does
    line:SetScript("OnClick", function()
        if row.Click then pcall(row.Click, row) end
    end)
    row.goldsmithLine = line
    return line
end

-- Currency rewards (Artisan's Moxie): the game lists them with the items
-- but with a currency, not an item link, so the item rewards leave them
-- out (user, 2026-10-18: Moxie didn't show). { name, icon, count }
local function Currencies(order)
    local found = {}
    for _, r in ipairs(order.npcOrderRewards or {}) do
        local id = r.currencyType or r.currencyID
        if id and not r.itemLink then
            local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
            if ok and type(info) == "table" then
                table.insert(found, { name = info.name or ("currency " .. id), icon = info.iconFileID, count = r.count or 1 })
            end
        end
    end
    return found
end

-- The profit as the opened order counts it, to the nearest gold (user,
-- 2026-10-18: the Cauldron should say -828g; whole gold is enough here)
local function Fill(line, p, order)
    line.preview = p
    line.currencies = Currencies(order)
    line.patron = order.npcCustomerName or order.customerName
    local profit = p.commission + p.rewardsValue - p.cost
    line.profit:SetText(addon:Colorize((p.complete and "" or "~") .. RoundGold(profit), addon:MoneyColor(profit)))
    local shown = {}
    for _, r in ipairs(p.rewards) do
        local texture = select(5, C_Item.GetItemInfoInstant(r.itemID))
        if texture then table.insert(shown, { icon = texture, count = r.count }) end
    end
    for _, c in ipairs(line.currencies) do
        -- No count on currencies: "30" covered the whole Moxie icon (user,
        -- 2026-10-18); the hover has it
        if c.icon then table.insert(shown, { icon = c.icon, count = 1 }) end
    end
    line.shownCount = #shown
    for i, icon in ipairs(line.icons) do
        local r = shown[i]
        icon:SetShown(r ~= nil)
        icon.count:SetShown(r ~= nil)
        if r then
            icon:SetTexture(r.icon)
            icon.count:SetText(r.count > 1 and r.count or "")
        end
    end
    line.check:SetShown(p.learned)
    if line.at then PlaceLine(line, line.at) end
end

-- The order a row shows: the game keeps it as the element's option
local function RowOrder(elementData)
    if type(elementData) ~= "table" then return nil end
    local order = elementData.option or elementData.order
    return type(order) == "table" and order.spellID and order or nil
end

-- The order a row shows now, read from the row itself: the game reuses
-- rows as the list redraws (sorting, going back from an order)
local function OrderOf(row)
    if row.GetElementData then
        local ok, data = pcall(row.GetElementData, row)
        local order = ok and RowOrder(data)
        if order then return order end
    end
    return type(row.option) == "table" and row.option.spellID and row.option or nil
end

-- Which order a row's line was filled for: a row that now shows another
-- order (sorting swaps the orders under the same rows without telling
-- anyone, user, 2026-10-18) is filled again
local function OrderKey(order)
    return order and ((order.orderID or 0) .. ":" .. order.spellID) or nil
end

local function FillRow(row, order, force)
    local key = OrderKey(order)
    if not force and row.goldsmithKey == key then return end
    row.goldsmithKey = key
    local ok = pcall(function()
        local p = order and addon:GetOrderListPreview(order)
        if not p then
            if row.goldsmithLine then row.goldsmithLine.preview = nil end
            return
        end
        Fill(row.goldsmithLine or CreateLine(row), p, order)
    end)
    if not ok and row.goldsmithLine then row.goldsmithLine.preview = nil end
end

local function HideLines()
    for _, row in ipairs(box and box.GetFrames and box:GetFrames() or {}) do
        if row.goldsmithLine then row.goldsmithLine:Hide() end
    end
end

-- Turns the whole thing off: lines and labels hidden, the game's patron
-- names back
local function Off()
    HideLines()
    if labels then labels:Hide() end
    ShowAllHidden()
end

-- Every row on screen: checked a few times a second while the list shows,
-- refilled when its order changed (force: all of them, e.g. on opening,
-- as prices may have moved). Only on the Patron tab.
local CHECK_EVERY = 0.2
local function Update(force)
    if not (box and box:IsVisible() and box.GetFrames and addon:Setting("craftCost")) then
        Off()
        return
    end
    local rows, patron = {}, false
    for _, row in ipairs(box:GetFrames() or {}) do
        local order = row:IsVisible() and OrderOf(row)
        if order then
            table.insert(rows, { row = row, order = order })
            if Enum.CraftingOrderType and order.orderType == Enum.CraftingOrderType.Npc then patron = true end
        elseif row.goldsmithLine then
            row.goldsmithLine:Hide()
        end
    end
    local header = patron and PatronHeader()
    local listLeft = header and box:GetLeft()
    if not (header and listLeft and header:GetLeft() and box:GetTop()) then
        Off()
        return
    end

    -- The header's text hidden, Goldsmith's labels in its place
    local keep = {}
    local function HideHeaderText()
        for _, region in ipairs({ header:GetRegions() }) do
            if region:GetObjectType() == "FontString" then
                Hide(region)
                region:SetAlpha(0)
                keep[region] = true
            end
        end
    end
    HideHeaderText()
    -- Hovering the header redraws its text in the highlight style, and
    -- "Patron Name" came back over the labels (user, 2026-10-19): hidden
    -- again right after the game's own hover handling
    if not header.goldsmithHooked then
        header.goldsmithHooked = true
        -- At once (the hooks run after the game's handler, before the frame
        -- is drawn), and a frame later in case the game changes it then: a
        -- frame later alone let it flash (user, 2026-10-19)
        local function HideNow()
            if labels and labels:IsShown() then
                for _, region in ipairs({ header:GetRegions() }) do
                    if region:GetObjectType() == "FontString" then Hide(region); region:SetAlpha(0) end
                end
            end
        end
        local function Again()
            HideNow()
            C_Timer.After(0, HideNow)
        end
        header:HookScript("OnEnter", Again)
        header:HookScript("OnLeave", Again)
        if header.HookScript and header:HasScript("OnMouseDown") then header:HookScript("OnMouseDown", Again) end
        if header:HasScript("OnClick") then header:HookScript("OnClick", Again) end
    end
    if not labels then CreateLabels() end
    labels:ClearAllPoints()
    labels:SetAllPoints(header)
    labels:SetFrameLevel(header:GetFrameLevel() + 2)
    labels:Show()

    local colLeft, colRight = header:GetLeft(), header:GetRight()
    -- The patron names: any text in the list that starts in the column, at
    -- any depth (they aren't the rows' own children, user, 2026-10-18)
    local target = box.GetScrollTarget and box:GetScrollTarget() or box
    local function HideNames(frame, depth)
        for _, region in ipairs({ frame:GetRegions() }) do
            local left = region:GetObjectType() == "FontString" and region:GetLeft()
            if left and left >= colLeft - 2 and left < colRight then
                Hide(region)
                keep[region] = true
            end
        end
        if depth > 0 then
            for _, child in ipairs({ frame:GetChildren() }) do
                if not child.goldsmithOwn then HideNames(child, depth - 1) end
            end
        end
    end
    HideNames(target, 4)
    local profitText = labels.profit:GetUnboundedStringWidth()
    for _, r in ipairs(rows) do
        FillRow(r.row, r.order, force)
        local line = r.row.goldsmithLine
        if line and line.preview then profitText = math.max(profitText, line.profit:GetUnboundedStringWidth()) end
    end
    local at = Layout(colRight - colLeft, labels.known:GetUnboundedStringWidth(), profitText)
    PlaceLabels(at)
    for _, r in ipairs(rows) do
        local row = r.row
        local line = row.goldsmithLine
        if line then PlaceLine(line, at) end
        local top, bottom = row:GetTop(), row:GetBottom()
        if line and line.preview and top and bottom and row:GetLeft()
            and top <= box:GetTop() + 1 and bottom >= box:GetBottom() - 1 then
            line:ClearAllPoints()
            line:SetPoint("TOPLEFT", row, "TOPLEFT", colLeft - row:GetLeft(), 0)
            line:SetPoint("BOTTOMLEFT", row, "BOTTOMLEFT", colLeft - row:GetLeft(), 0)
            line:SetWidth(colRight - colLeft)
            line:SetFrameLevel(row:GetFrameLevel() + 5)
            line:Show()
        elseif line then
            line:Hide()
        end
    end
    -- Cells now in other columns (the game moves them) show again
    ShowAllHidden(keep)
end

local function UpdateSoon()
    C_Timer.After(0, function() Update(true) end)
end

local hooked = false
local function Hook()
    if hooked then return end
    local page = ProfessionsFrame and ProfessionsFrame.OrdersPage
    list = page and page.BrowseFrame and page.BrowseFrame.OrderList
    local found = list and list.ScrollBox
    if not (found and found.RegisterCallback and ScrollBoxListMixin and ScrollBoxListMixin.Event) then return end
    hooked = true
    box = found
    box:RegisterCallback(ScrollBoxListMixin.Event.OnInitializedFrame, UpdateSoon, addon)
    if ScrollBoxListMixin.Event.OnDataRangeChanged then
        box:RegisterCallback(ScrollBoxListMixin.Event.OnDataRangeChanged, UpdateSoon, addon)
    end
    box:HookScript("OnShow", UpdateSoon)
    box:HookScript("OnHide", Off)
    local since = 0
    box:HookScript("OnUpdate", function(_, elapsed)
        since = since + elapsed
        if since < CHECK_EVERY then return end
        since = 0
        Update(false)
    end)
end

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("TRADE_SKILL_SHOW")
events:SetScript("OnEvent", Hook)

_G.Goldsmith = addon
