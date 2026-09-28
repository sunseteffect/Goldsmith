local addon = _G.Goldsmith or {}
local UI = addon.UI

-- History tab
--
-- "What happened?" Every sale, purchase, AH deposit and craft, newest
-- first. Filter by type (the chips) and character; the header's profession
-- and date filters apply too. Click an entry for its item's page;
-- right-click to assign the item to a profession or delete the entry
-- (carried over from v1's Log). The rows come from GetHistory
-- (Insights.lua).

local TOP_HEIGHT = 26

local Money, Signed = function(c) return addon:FormatMoney(c) end, function(c) return addon:FormatSignedMoney(c) end

local KINDS = {
    { key = nil, label = "All" },
    { key = "Sale", label = "Sales" },
    { key = "Purchase", label = "Purchases" },
    { key = "Deposit", label = "Deposits" },
    { key = "Craft", label = "Crafts" },
    { key = "Order", label = "Orders" },
}
local KIND_COLORS = { Sale = "profit", Purchase = "loss", Deposit = "warning", Craft = "line", Order = "muted" }
local KIND_LONG = { Sale = "Sale", Purchase = "Purchase", Deposit = "AH deposit", Craft = "Craft", Order = "Crafting order" }

-- Where a sale's cost came from, for the hover
local COST_LABELS = {
    free = "Cost you (got it for free)",
    crafted = "Cost you (your crafts)",
    paid = "Cost you (what you paid)",
    estimated = "Cost you (estimated)",
    today = "Cost you (today's estimate)",
}

local COLUMNS = {
    { key = "when", label = "When", width = 96 },
    { key = "kind", label = "Type", width = 70 },
    { key = "item", label = "Item" },
    { key = "qty", label = "Qty", width = 50, justify = "RIGHT" },
    { key = "gold", label = "Gold", width = 96, justify = "RIGHT" },
    { key = "profit", label = "Profit", width = 96, justify = "RIGHT" },
}

local function ItemText(row)
    local tier, tierCount = addon:GetItemTier(row.itemID)
    return addon:ProfessionIconText(row.profession) .. (row.item or "?")
        .. (tier and (" " .. addon:TierIconText(tier, tierCount)) or "")
end

local function FillRow(r, row)
    local c = r.cells
    c.when:SetText(date("%b %d %H:%M", row.time))
    c.when:SetTextColor(addon:Color("muted"))
    c.kind:SetText(row.kind)
    c.kind:SetTextColor(addon:Color(KIND_COLORS[row.kind]))
    c.item:SetText(ItemText(row))
    c.qty:SetText(tostring(row.qty or ""))
    if row.gold then
        -- No + or -: white is money in, red money out
        c.gold:SetText(Money(math.abs(row.gold)))
        c.gold:SetTextColor(addon:Color(row.gold >= 0 and "text" or "loss"))
    else
        c.gold:SetText("-")
        c.gold:SetTextColor(addon:Color("dim"))
    end
    if row.profit then
        -- No + or -: green is a profit, red a loss. ~ marks an estimated
        -- cost (see the hover)
        c.profit:SetText((row.profitEstimated and "~" or "") .. Money(math.abs(row.profit)) .. (row.partial and "*" or ""))
        c.profit:SetTextColor(addon:Color(addon:MoneyColor(row.profit)))
    end
end

local function Tooltip(tooltip, row)
    tooltip:AddLine(ItemText(row), 1, 1, 1)
    local function Line(left, right, color)
        local r, g, b = addon:Color(color or "text")
        tooltip:AddDoubleLine(left, right, 0.8, 0.8, 0.8, r, g, b)
    end
    Line("Type", KIND_LONG[row.kind], KIND_COLORS[row.kind])
    Line("Quantity", tostring(row.qty))
    if row.kind == "Craft" or row.kind == "Order" then
        Line("Materials cost", Money(row.cost) .. (row.partial and "+" or "") .. " each")
        if row.kind == "Order" then
            tooltip:AddLine("Crafted for a crafting order: the item went to the customer, so it isn't in your stock and doesn't count toward what yours cost you.", 0.6, 0.6, 0.6, true)
        else
            tooltip:AddLine("Crafts are kept for working out costs, so they can't be deleted here.", 0.6, 0.6, 0.6, true)
        end
    else
        Line("Total", Money(math.abs(row.gold)))
        if row.qty and row.qty > 0 then Line("Each", Money(math.abs(row.gold) / row.qty)) end
        if row.profit then
            Line(COST_LABELS[row.costSource] or "Cost you", Money(row.cost) .. (row.partial and "+" or ""))
            Line(row.partial and "Profit (at most)" or "Profit", Signed(row.profit), addon:MoneyColor(row.profit))
            if row.costSource == "estimated" then
                tooltip:AddLine("You didn't craft these while Goldsmith was watching, so the cost is the recipe at that day's prices.", 0.6, 0.6, 0.6, true)
            elseif row.costSource == "today" then
                tooltip:AddLine("Sold before Goldsmith saved costs with sales, so this is today's estimate.", 0.6, 0.6, 0.6, true)
            end
        elseif row.kind == "Sale" then
            tooltip:AddLine("No cost known, so this sale isn't in your profit. If it was loot or a reward, right-click and mark it as free.", 0.6, 0.6, 0.6, true)
        end
        if row.character then Line("Character", row.character) end
    end
    if row.profession then Line("Profession", row.profession) end
    Line("When", date("%Y-%m-%d %H:%M", row.time))
    tooltip:AddLine(" ")
    tooltip:AddLine("Click for the item's page, right-click for more", 0.37, 0.81, 0.48)
end

StaticPopupDialogs["GOLDSMITH_HISTORY_DELETE"] = {
    text = "Delete this entry?\n\n%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, id)
        addon.ledger:remove(id)
        if addon.Refresh then addon.Refresh() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function ConfirmDelete(row)
    local summary = string.format("%s: %s x%d (%s)", KIND_LONG[row.kind], row.item, row.qty, Money(math.abs(row.gold)))
    StaticPopup_Show("GOLDSMITH_HISTORY_DELETE", summary, nil, row.entry.id)
end

local function Menu(row)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(UIParent, function(_, root)
        root:CreateTitle(row.item)
        root:CreateButton("Open the item's page", function() addon:OpenItem(row.item, row.itemID) end)
        if row.kind == "Craft" then
            root:CreateButton("This was a crafting order", function() addon:MarkCraftAsOrder(row.itemID, row.lot) end)
        end
        if row.kind == "Sale" then
            root:CreateCheckbox("Got it for free (loot or reward)",
                function() return GoldsmithDB.freeItems[row.item] == true end,
                function() addon:SetFreeItem(row.item, not GoldsmithDB.freeItems[row.item]) end)
        end
        if row.entry then
            local assign = root:CreateButton("Assign to profession")
            assign:CreateRadio("Unassigned",
                function() return row.profession == "Unassigned" end,
                function() addon:AssignItem(row.item, "Unassigned") end)
            for _, prof in ipairs(addon:GetProfessions()) do
                assign:CreateRadio(prof,
                    function() return row.profession == prof end,
                    function() addon:AssignItem(row.item, prof) end)
            end
            root:CreateButton("Delete this entry", function() ConfirmDelete(row) end)
        end
    end)
end

-- A pill button for the type filter
local function Chip(parent, text, onClick)
    local chip = CreateFrame("Button", nil, parent, "BackdropTemplate")
    chip.label = UI.Text(chip, "small", "text", "CENTER")
    chip.label:SetPoint("CENTER")
    chip.label:SetText(text)
    chip:SetSize(chip.label:GetStringWidth() + 24, 24)
    chip:SetScript("OnClick", onClick)
    function chip:SetSelected(selected)
        chip.selected = selected
        UI.Style(chip, selected and "highlight" or "panelRaised", selected and "borderGold" or "borderStrong")
        chip.label:SetTextColor(addon:Color(selected and "gold" or "text"))
    end
    chip:SetScript("OnEnter", function(self) self:SetBackdropBorderColor(addon:Color("gold")) end)
    chip:SetScript("OnLeave", function(self)
        self:SetBackdropBorderColor(addon:Color(self.selected and "borderGold" or "borderStrong"))
    end)
    chip:SetSelected(false)
    return chip
end

-- Links from other screens

local pending = nil

-- Opens History. opts.item shows only that item's entries.
function addon:OpenHistory(opts)
    pending = opts or {}
    addon:ShowTab("history")
end

-- View

local function Create(parent)
    local ui = GoldsmithDB.ui2
    local view = {}

    view.chips = {}
    local previous
    for _, kind in ipairs(KINDS) do
        local chip = Chip(parent, kind.label, function()
            ui.historyKind = kind.key
            addon.RefreshWindow()
        end)
        chip.key = kind.key
        if previous then chip:SetPoint("LEFT", previous, "RIGHT", 6, 0) else chip:SetPoint("TOPLEFT", 0, 0) end
        previous = chip
        table.insert(view.chips, chip)
    end

    view.character = UI.Dropdown(parent, 150, function(root)
        root:CreateTitle("Show character")
        root:CreateRadio("All characters", function() return ui.historyCharacter == nil end, function()
            ui.historyCharacter = nil
            addon.RefreshWindow()
        end)
        for _, c in ipairs(addon:GetHistoryCharacters()) do
            root:CreateRadio(c.name, function() return ui.historyCharacter == c.key end, function()
                ui.historyCharacter = c.key
                addon.RefreshWindow()
            end)
        end
    end)
    view.character:SetPoint("LEFT", previous, "RIGHT", 16, 0)

    -- "Item: Sienna Ink  x" after following a link from an item page
    view.itemChip = UI.Button(parent, "", 200, 24, function()
        view.item = nil
        addon.RefreshWindow()
    end)
    UI.Style(view.itemChip, "highlight", "borderGold")
    view.itemChip:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderGold")) end)
    view.itemChip.label:SetTextColor(addon:Color("gold"))
    view.itemChip:SetPoint("LEFT", view.character, "RIGHT", 10, 0)

    view.summary = UI.Text(parent, "small", "muted", "RIGHT")
    view.summary:SetPoint("TOPRIGHT", 0, -6)

    view.list = UI.List(parent, {
        fill = FillRow,
        tooltip = Tooltip,
        onClick = function(row, button)
            if button == "RightButton" then Menu(row) else addon:OpenItem(row.item, row.itemID) end
        end,
    })
    view.list:SetPoint("TOPLEFT", 0, -(TOP_HEIGHT + 12))
    view.list:SetPoint("BOTTOMRIGHT", 0, 22)
    view.list:SetColumns(COLUMNS)
    view.footnote = UI.Text(parent, "small", "dim")
    view.footnote:SetPoint("BOTTOMLEFT", 2, 2)
    return view
end

local function Refresh(view, state)
    local ui = GoldsmithDB.ui2
    if pending then
        view.item = pending.item
        view.list:ScrollToTop()
        pending = nil
    end

    for _, chip in ipairs(view.chips) do chip:SetSelected(chip.key == ui.historyKind) end
    local characterName = "All characters"
    for _, c in ipairs(addon:GetHistoryCharacters()) do
        if c.key == ui.historyCharacter then characterName = c.name end
    end
    view.character:SetLabel(characterName)
    view.itemChip:SetShown(view.item ~= nil)
    if view.item then view.itemChip:SetLabel("Item: " .. view.item .. "   x") end

    -- One item's history (from its page) covers every date and profession
    local rows, totals = addon:GetHistory({
        prof = view.item and "All" or state.profession, since = not view.item and state.since or nil,
        kind = ui.historyKind, character = ui.historyCharacter, item = view.item,
    })
    view.list:SetEmptyText(#addon.ledger:getAll() == 0
        and "Nothing recorded yet. Purchases, sales and AH deposits are recorded as you make them."
        or "Nothing matches. Try another type, All characters, or a longer date range at the top.")
    view.list:SetItems(rows)
    view.summary:SetText(string.format("%d entr%s  ·  in %s  ·  out %s", #rows, #rows == 1 and "y" or "ies",
        addon:Colorize(Money(totals.goldIn), "profit"), addon:Colorize(Money(totals.goldOut), "loss")))

    local notes = {}
    for _, row in ipairs(rows) do
        if row.profitEstimated then table.insert(notes, "~ estimated cost (hover for why)") break end
    end
    for _, row in ipairs(rows) do
        if row.partial and row.profit then table.insert(notes, "* some material costs unknown") break end
    end
    if ui.historyCharacter then table.insert(notes, "crafts only show for All characters") end
    if view.item then table.insert(notes, "all dates and professions for this item") end
    view.footnote:SetText(table.concat(notes, "   "))
end

addon:RegisterView("history", { create = Create, refresh = Refresh })

_G.Goldsmith = addon
