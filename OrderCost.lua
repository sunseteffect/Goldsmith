local addon = _G.Goldsmith or {}
local UI = addon.UI

-- What a craft costs you, in the game's profession window
--
-- Under the materials (the empty space below the last one), two lines in
-- the window's own font:
--   - on a crafting order: what you'd actually pay (only the materials you
--     supply, not the customer's, at the qualities the window has chosen)
--     and the profit (commission and sellable rewards less that). CraftSim
--     shows the full recipe cost there, which on a patron order counts the
--     customer's materials as yours (idea board, 2026-10-10). Valued like
--     History values the craft afterwards (addon:GetOrderPreview).
--   - on your own crafts (user, 2026-10-11: Box of Rocks isn't in
--     Goldsmith, so what does it cost?): the materials one craft uses and
--     the profit on what it makes at the quality the window shows, or that
--     it can't be sold, counted as the Crafts tab counts them
--     (addon:GetCraftPreview).
-- The hover lists each material and the rest. Updates when the recipe,
-- order or allocations change. If the game's window changes, this quietly
-- shows nothing.

local LOGO = "Interface\\AddOns\\Goldsmith\\Media\\Logo"
-- Beside the two cost lines: about their height together
local LOGO_BESIDE, LOGO_GAP = 30, 8
local WIDTH = 330
local NOTE_WIDTH = 260
local AH_CUT = 0.05

local Money = function(c) return addon:FormatMoney(c) end

local function ItemName(itemID)
    return C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
end

-- A reward's link, unless the game hasn't loaded its name yet (the link
-- then reads "[]"): the name, or "item N" while it loads
local function RewardName(r)
    if r.link and not r.link:find("[]", 1, true) then return r.link end
    C_Item.RequestLoadItemDataByID(r.itemID)
    return ItemName(r.itemID)
end

local function AddMaterials(tooltip, mats)
    if #mats == 0 then return end
    tooltip:AddLine("Your materials", addon:Color("muted"))
    for _, m in ipairs(mats) do
        local value = m.unit and Money(m.unit * m.qty) or "no price"
        tooltip:AddDoubleLine(m.qty .. "x " .. ItemName(m.itemID), value, 1, 1, 1, 1, 1, 1)
    end
end

-- The font of the window's own material names ("35/5 Sunglass Vial"), so
-- the lines read as part of the window (user, 2026-10-11); the game's
-- standard highlight font if the slots can't be read
local function NativeFont(form)
    local ok, font = pcall(function()
        for _, slots in pairs(form.reagentSlots or {}) do
            for _, slot in ipairs(slots) do
                local name = slot.Name or (slot.Button and slot.Button.Name)
                if name and name.GetFontObject and name:GetFontObject() then return name:GetFontObject() end
            end
        end
    end)
    return ok and font or GameFontHighlight
end

-- The item a craft makes at the quality the window shows (its details
-- panel), or nil to use the recipe's own
local function ShownOutput(form, recipeID)
    local okO, op = pcall(form.GetRecipeOperationInfo, form)
    local quality = okO and type(op) == "table" and op.craftingQualityID
    if not quality then return nil end
    local ok, out = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, {}, nil, quality)
    return ok and type(out) == "table" and out.itemID or nil
end

-- Pages

local ORDER = {
    view = function()
        local page = ProfessionsFrame and ProfessionsFrame.OrdersPage
        return page and page.OrderView
    end,
    form = function(view) return view.OrderDetails and view.OrderDetails.SchematicForm end,
    preview = function(view, tx) return addon:GetOrderPreview(view.order, tx) end,
    lines = function(p)
        local cost = #p.mats == 0 and "none" or ((p.complete and "" or "at least ") .. Money(p.cost))
        local profit = p.commission + p.rewardsValue - p.cost
        -- Just your cost and the profit: the window already marks what the
        -- customer supplies and shows the commission (user, 2026-10-11)
        -- When the game filled a slot from your bags with a dearer quality
        -- than the orders list counts: why the two differ (user,
        -- 2026-10-18: "i could think its an error")
        local note
        if p.cheapest then
            note = addon:Colorize(string.format("Cheapest qualities: %s. The game picked %s from your bags.",
                Money(p.cheapest), table.concat(p.pricier, ", ")), "warning")
        end
        return "Your materials: " .. cost, "Profit: " .. (p.complete and "" or "at most ")
            .. addon:Colorize(addon:FormatSignedMoney(profit), addon:MoneyColor(profit)), note
    end,
    tooltip = function(tooltip, p)
        tooltip:AddLine("Goldsmith: this order", addon:Color("gold"))
        AddMaterials(tooltip, p.mats)
        tooltip:AddLine(" ")
        tooltip:AddDoubleLine("Commission (after the consortium's cut)", Money(p.commission), 1, 1, 1, 1, 1, 1)
        for _, r in ipairs(p.rewards) do
            local value = r.value > 0 and Money(r.value) or "can't be sold"
            -- A payout bag: what's inside on average (user, 2026-10-11)
            if r.opened then value = string.format("about %s (avg of %d opened)", Money(r.value), r.opened) end
            tooltip:AddDoubleLine("Reward: " .. RewardName(r) .. (r.count > 1 and (" x" .. r.count) or ""),
                value, 1, 1, 1, 0.8, 0.8, 0.8)
        end
        addon:Explain(tooltip, "Your materials are valued at what yours cost you, or today's price "
            .. "if you have none: the same way History counts the order once it's crafted. "
            .. "A material you don't have yet counts at its lowest quality. "
            .. "Resourcefulness may give some back (History shows it as kept).")
    end,
}

-- What one craft makes, after the AH cut
local function CraftWorth(p)
    return p.unitPrice and p.unitPrice * p.perCraft * (1 - AH_CUT)
end

local CRAFT = {
    view = function() return ProfessionsFrame and ProfessionsFrame.CraftingPage end,
    form = function(view) return view.SchematicForm end,
    preview = function(view, tx, form)
        local okR, recipeID = pcall(tx.GetRecipeID, tx)
        return addon:GetCraftPreview(tx, okR and recipeID and ShownOutput(form, recipeID))
    end,
    -- Totals for one craft with the per-item figure beside them, as the
    -- Crafts tab's "each" (user, 2026-10-11: "is that per tonic or for
    -- all 5?")
    lines = function(p)
        local cost = (p.complete and "" or "at least ") .. Money(p.cost)
            .. string.format(" (%s each)", Money(p.cost / p.perCraft))
        local second
        if not p.sellable then
            second = addon:Colorize("Can't be sold on the AH", "muted")
        elseif not p.unitPrice then
            second = addon:Colorize("No AH price for what it makes", "muted")
        else
            local profit = CraftWorth(p) - p.cost
            second = "Profit: " .. (p.complete and "" or "at most ")
                .. addon:Colorize(addon:FormatSignedMoney(profit), addon:MoneyColor(profit))
                .. string.format(" (%s each)", addon:FormatSignedMoney(profit / p.perCraft))
        end
        return "Your materials: " .. cost, second
    end,
    -- Short enough to sit in the empty space under the lines, clear of the
    -- Crafting Details panel, and everything shown at once: no Ctrl
    -- explanation (user, 2026-10-11: it ran over the panel, and Ctrl did
    -- nothing on it). The AH price always shows; the profit comes from it.
    tooltip = function(tooltip, p)
        tooltip:AddLine("Goldsmith: one craft", addon:Color("gold"))
        AddMaterials(tooltip, p.mats)
        if p.saved > 0 then
            tooltip:AddDoubleLine("Resourcefulness (average)", "-" .. Money(p.saved), 1, 1, 1, 1, 1, 1)
        end
        local made = p.perCraft == math.floor(p.perCraft) and tostring(p.perCraft)
            or string.format("%.1f", p.perCraft)
        if not p.sellable then
            tooltip:AddDoubleLine("Makes " .. made, "can't be sold", 1, 1, 1, 0.8, 0.8, 0.8)
        elseif p.unitPrice then
            tooltip:AddDoubleLine("Makes " .. made, Money(CraftWorth(p)) .. " after AH cut", 1, 1, 1, 1, 1, 1)
            if p.opened then
                -- A bound box: what's inside, not an AH price (user,
                -- 2026-10-11: how does a soulbound bag have a price?)
                tooltip:AddDoubleLine("What's inside", Money(p.unitPrice) .. " each", 1, 1, 1, 1, 1, 1)
                tooltip:AddLine(string.format("Average of %d opened, at AH prices", p.opened), 0.6, 0.6, 0.6)
            else
                tooltip:AddDoubleLine("AH price", Money(p.unitPrice) .. " each", 1, 1, 1, 1, 1, 1)
            end
        else
            tooltip:AddDoubleLine("Makes " .. made, "no price", 1, 1, 1, 0.8, 0.8, 0.8)
        end
        if p.perCraft ~= p.base then
            tooltip:AddLine(string.format("%d a craft, plus multicraft on average", p.base), 0.6, 0.6, 0.6)
        end
    end,
}

-- One holder per page
local function Create(page, form)
    local holder = CreateFrame("Frame", nil, form)
    holder:SetSize(WIDTH, 40)
    -- The logo beside both lines, as tall as the pair, so both start at
    -- the same place (in front of the first one only, they didn't, user,
    -- 2026-10-11) and it isn't alone on a line of its own (2026-10-16)
    local logo = holder:CreateTexture(nil, "ARTWORK")
    logo:SetTexture(LOGO)
    logo:SetSize(LOGO_BESIDE, LOGO_BESIDE)
    logo:SetPoint("TOPLEFT", 0, 0)
    holder.line1 = UI.Text(holder, "small", "text")
    holder.line1:SetPoint("TOPLEFT", logo, "TOPRIGHT", LOGO_GAP, 0)
    holder.line1:SetWidth(WIDTH - LOGO_BESIDE - LOGO_GAP)
    holder.line2 = UI.Text(holder, "small", "text")
    holder.line2:SetPoint("TOPLEFT", holder.line1, "BOTTOMLEFT", 0, -4)
    holder.line2:SetWidth(WIDTH - LOGO_BESIDE - LOGO_GAP)
    -- A note under the two, on orders only (ORDER.lines)
    holder.line3 = UI.Text(holder, "small", "text")
    holder.line3:SetPoint("TOPLEFT", holder.line2, "BOTTOMLEFT", 0, -4)
    holder:EnableMouse(true)
    UI.SetTooltip(holder, function(tooltip)
        local p = page.preview
        if not p then return end
        -- Under the line, not over the window's Crafting Details (user, 2026-10-11)
        tooltip:ClearAllPoints()
        tooltip:SetPoint("TOPLEFT", holder, "BOTTOMLEFT", 0, -4)
        page.def.tooltip(tooltip, p)
        if not p.complete then
            tooltip:AddLine("Some materials have no price, so the cost is at least this.", addon:Color("warning"))
        end
    end, "ANCHOR_NONE")
    page.holder = holder
end

local function SetLineWidth(holder, width)
    for _, line in ipairs({ holder.line1, holder.line2, holder.line3 }) do
        line:SetWidth(width - LOGO_BESIDE - LOGO_GAP)
        line:SetWordWrap(true)
    end
end

-- Auctionator's "To Craft / Profit" lines on this form, when showing
local function AuctionatorLines(form)
    for _, name in ipairs({ "AuctionatorCraftingInfoProfessionsFrame", "AuctionatorCraftingInfoProfessionsOrderFrame" }) do
        local f = _G[name]
        if f and f:GetParent() == form and f:IsShown() then return f end
    end
end

-- Where the lines go (called after the text is set; sized to it, so they
-- never wrap). Under the materials, the spot the user prefers, below
-- Auctionator's "To Craft / Profit" when it's there (they overlapped on
-- the orders page). Enchants' target slot takes that room: there they sat
-- on the Use Best Quality Reagents checkbox (user, 2026-10-16), so when
-- they don't fit above it they go on the checkbox's row, ending at the
-- Crafting Details panel's right edge, lined up with both.
local DETAILS_INSET = 16
local GAP = 8

local function Place(holder, form)
    local reagents = form.Reagents
    if not reagents then return false end
    holder:ClearAllPoints()
    local w = math.ceil(math.max(holder.line1:GetUnboundedStringWidth(), holder.line2:GetUnboundedStringWidth())) + 2
    local width = w + LOGO_BESIDE + LOGO_GAP
    SetLineWidth(holder, width)
    -- The note wraps, at least NOTE_WIDTH wide so it isn't a tall column
    holder.line3:SetWidth(math.max(w, NOTE_WIDTH))
    local extra = holder.line3:IsShown() and (holder.line3:GetStringHeight() + 4) or 0
    holder:SetSize(width, LOGO_BESIDE + extra)

    -- The lowest of the materials, optional materials, enchant target and
    -- Auctionator's lines
    local below = reagents
    local others = { form.OptionalReagents, AuctionatorLines(form) }
    for _, f in ipairs(form.extraSlotFrames or {}) do table.insert(others, f) end
    for _, f in pairs(others) do
        if f and f:IsShown() and f:GetBottom() and below:GetBottom() and f:GetBottom() < below:GetBottom() then
            below = f
        end
    end

    local box, details = form.AllocateBestQualityCheckbox, form.Details
    local top = below:GetBottom() and below:GetBottom() - GAP
    local tooLow = box and box:IsShown() and box:GetTop() and top and top - LOGO_BESIDE < box:GetTop()
    if tooLow and details and details:IsShown() and details:GetRight() and box:GetLeft() then
        holder:SetPoint("BOTTOMRIGHT", box, "BOTTOMLEFT", details:GetRight() - DETAILS_INSET - box:GetLeft(), 0)
        return true
    end
    local x = (reagents:GetLeft() and below:GetLeft()) and (reagents:GetLeft() - below:GetLeft()) or 0
    holder:SetPoint("TOPLEFT", below, "BOTTOMLEFT", x, -GAP)
    return true
end

local function Update(page)
    page.pending = false
    local def = page.def
    local view = def.view()
    local form = view and def.form(view)
    -- Settings > Cost in the profession window
    if not (view and form and view:IsShown() and form:IsShown()) or not addon:Setting("craftCost") then
        if page.holder then page.holder:Hide() end
        return
    end
    if not page.holder then Create(page, form) end
    local holder = page.holder
    local tx = form.GetTransaction and form:GetTransaction()
    local ok, p = pcall(def.preview, view, tx, form)
    page.preview = ok and tx and p or nil
    if not page.preview then
        holder:Hide()
        return
    end

    -- In the window's font, set each time: the slots exist only once a
    -- recipe has been shown
    local font = NativeFont(form)
    for _, line in ipairs({ holder.line1, holder.line2, holder.line3 }) do
        line:SetFontObject(font)
        line:SetTextColor(1, 1, 1)
    end
    local first, second, third = def.lines(page.preview)
    holder.line1:SetText(first)
    holder.line2:SetText(second)
    holder.line3:SetText(third or "")
    holder.line3:SetShown(third ~= nil)
    if not Place(holder, form) then
        holder:Hide()
        return
    end
    holder:Show()
    if GameTooltip:IsOwned(holder) and UI.RedrawTooltip then UI.RedrawTooltip(holder) end
end

local function UpdateSoon(page)
    if page.pending then return end
    page.pending = true
    C_Timer.After(0.05, function() Update(page) end)
end

-- The windows are part of Blizzard_Professions, loaded the first time a
-- profession or the crafting orders open
local pages = { { def = ORDER }, { def = CRAFT } }

-- After the setting changes, with the window open
function addon:UpdateCraftCostLines()
    for _, page in ipairs(pages) do UpdateSoon(page) end
end

local function Hook(page)
    local view = page.def.view()
    local form = view and page.def.form(view)
    if page.hooked or not (view and form) then return end
    page.hooked = true
    local soon = function() UpdateSoon(page) end
    if view.SetOrder then hooksecurefunc(view, "SetOrder", soon) end
    -- A recipe picked in the list, and the details panel (quality,
    -- concentration) redrawn
    if form.Init then hooksecurefunc(form, "Init", soon) end
    if form.UpdateDetailsStats then hooksecurefunc(form, "UpdateDetailsStats", soon) end
    view:HookScript("OnShow", soon)
    view:HookScript("OnHide", soon)
    form:HookScript("OnShow", soon)
    if form.RegisterCallback and ProfessionsRecipeSchematicFormMixin and ProfessionsRecipeSchematicFormMixin.Event then
        pcall(form.RegisterCallback, form, ProfessionsRecipeSchematicFormMixin.Event.AllocationsModified, soon, page)
    end
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "ADDON_LOADED", "TRADE_SKILL_SHOW", "BAG_UPDATE_DELAYED" }) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event)
    for _, page in ipairs(pages) do
        Hook(page)
        if event == "BAG_UPDATE_DELAYED" and page.holder and page.holder:IsShown() then UpdateSoon(page) end
    end
end)

_G.Goldsmith = addon
