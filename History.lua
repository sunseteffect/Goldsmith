local addon = _G.Goldsmith or {}
local UI = addon.UI

-- History tab
--
-- "What happened?" Every sale, purchase, AH deposit and craft, newest
-- first, and one line a day for materials you gathered (Gathered.lua). Filter by type (the chips) and character; the header's
-- profession, date and expansion filters apply too (not to one item's
-- history, from its page). Click an entry for its item's page;
-- right-click to assign the item to a profession or delete the entry
-- (carried over from v1's Log). The rows come from GetHistory
-- (Insights.lua).

local TOP_HEIGHT = 26
-- The search line above the filters (user, 2026-11-10: "put the search
-- above the filters in its own line"), then the filters' line
local SEARCH_HEIGHT = TOP_HEIGHT + 8
local SEARCH_MIN_LETTERS = 2
local SEARCH_DELAY = 0.3

local Money, Signed = function(c) return addon:FormatMoney(c) end, function(c) return addon:FormatSignedMoney(c) end

local KINDS = {
    { key = nil, label = "All" },
    { key = "Sale", label = "Sales" },
    { key = "Purchase", label = "Purchases" },
    { key = "Deposit", label = "Deposits" },
    { key = "Craft", label = "Crafts" },
    { key = "Order", label = "Orders" },
    { key = "Gathered", label = "Gathered" },
    { key = "Opened", label = "Opened" },
}
local KIND_COLORS = { Sale = "profit", Purchase = "loss", Deposit = "warning", Craft = "line", Order = "muted",
                      Gathered = "gold", Opened = "gold" }

-- Where a sale's cost came from, for the hover
local COST_LABELS = {
    free = "Cost you (got it for free)",
    crafted = "Cost you (your crafts)",
    paid = "Cost you (what you paid)",
    estimated = "Cost you (estimated)",
    today = "Cost you (today's estimate)",
    reward = "Order counted it at",
}

local COLUMNS = {
    { key = "when", label = "When", width = 96 },
    { key = "kind", label = "Type", width = 70 },
    { key = "item", label = "Item" },
    { key = "qty", label = "Qty", width = 50, justify = "RIGHT" },
    { key = "gold", label = "Gold", width = 96, justify = "RIGHT" },
    { key = "profit", label = "Profit", width = 96, justify = "RIGHT" },
}

-- The tier goes before the name, so a long name cut short never hides it
local function ItemText(row)
    local tier, tierCount = addon:GetItemTier(row.itemID)
    return addon:ProfessionIconText(row.profession)
        .. (tier and (addon:TierIconText(tier, tierCount) .. " ") or "") .. (row.item or "?")
end

local function FillRow(r, row)
    local c = r.cells
    -- A deleted entry, kept greyed where it was until you leave History:
    -- click it to undo (user, 2026-10-10)
    if row.deleted then
        c.when:SetText(date("%b %d %H:%M", row.time))
        c.kind:SetText("Deleted")
        c.item:SetText(ItemText(row))
        c.qty:SetText(tostring(row.qty or ""))
        c.gold:SetText(row.gold and ((row.gold < 0 and "-" or "") .. Money(math.abs(row.gold))) or "-")
        c.profit:SetText("Undo")
        for _, cell in pairs(c) do cell:SetTextColor(addon:Color("dim")) end
        c.profit:SetTextColor(addon:Color("hint"))
        return
    end
    c.when:SetText(date("%b %d %H:%M", row.time))
    c.when:SetTextColor(addon:Color("muted"))
    c.kind:SetText(row.kind)
    c.kind:SetTextColor(addon:Color(KIND_COLORS[row.kind]))
    c.item:SetText(ItemText(row) .. (row.crafts and row.crafts > 1
        and addon:Colorize(string.format("  %d crafts", row.crafts), "dim") or ""))
    c.qty:SetText(tostring(row.qty or ""))
    if row.gold then
        -- White is money in, red and a minus money out: the sign too, so
        -- it reads without telling red from green (design review, user
        -- 2026-10-10: minus on losses only)
        c.gold:SetText((row.gold < 0 and "-" or "") .. Money(math.abs(row.gold)))
        c.gold:SetTextColor(addon:Color(row.gold >= 0 and "text" or "loss"))
    elseif row.worth and row.worth > 0 then
        -- Gathered: what it's worth, grey because no gold moved
        c.gold:SetText(Money(row.worth))
        c.gold:SetTextColor(addon:Color("muted"))
    elseif row.kind == "Craft" and row.cost and row.qty then
        -- What the batch's materials cost, grey with no minus: crafting
        -- moves no gold (the materials were Purchase rows), so it's not in
        -- the in/out totals. Each is in the hover (Idea Board, Reddit
        -- feedback 2026-10-29: the cost only showed on hover)
        c.gold:SetText(Money(row.cost * row.qty) .. (row.partial and "+" or ""))
        c.gold:SetTextColor(addon:Color("muted"))
    else
        c.gold:SetText("-")
        c.gold:SetTextColor(addon:Color("dim"))
    end
    if row.profit then
        -- Green is a profit, red and a minus a loss. ~ marks an estimated
        -- cost (see the hover)
        c.profit:SetText((row.profitEstimated and "~" or "") .. (row.profit < 0 and "-" or "")
            .. Money(math.abs(row.profit)) .. (row.partial and "*" or ""))
        c.profit:SetTextColor(addon:Color(addon:MoneyColor(row.profit)))
    end
end

-- A gathered day's hover lists this many materials, most valuable first;
-- all of them with Ctrl (user, 2026-10-11: "and 14 more" hid the rest)
local GATHERED_LINES = 15

addon.HistoryFillRow = FillRow -- for the bench

local function Tooltip(tooltip, row)
    if row.deleted then
        tooltip:AddLine(ItemText(row), 1, 1, 1)
        tooltip:AddLine("Deleted. It stays here until you leave History.", 0.6, 0.6, 0.6, true)
        addon:ClickHint(tooltip, "Click to undo", true)
        return
    end
    tooltip:AddLine(ItemText(row), 1, 1, 1)
    -- What the item does (a gathered day of several materials has no one item)
    addon:AddItemDescription(tooltip, row.itemID)
    local function Line(left, right, color)
        local r, g, b = addon:Color(color or "text")
        tooltip:AddDoubleLine(left, right, 0.8, 0.8, 0.8, r, g, b)
    end
    if row.kind == "Gathered" or row.kind == "Opened" then
        local all = IsControlKeyDown()
        for i, item in ipairs(row.items) do
            if not all and i > GATHERED_LINES and #row.items > GATHERED_LINES + 1 then
                tooltip:AddLine(string.format("and %d more (hold Ctrl to see them all)", #row.items - GATHERED_LINES),
                    0.6, 0.6, 0.6)
                break
            end
            -- Its quality before the name, as in the lists (user,
            -- 2026-10-11; silver and gold of a material are separate lines)
            local tier, tierCount = addon:GetItemTier(item.itemID)
            local tierIcon = tier and tierCount and tierCount > 1 and (addon:TierIconText(tier, tierCount) .. " ") or ""
            local right = item.value > 0 and Money(item.value) or "no price"
            -- Out of a box: what each cost you, its share of the box
            if item.cost and item.qty > 0 then right = Money(item.cost / item.qty) .. " each, worth " .. right end
            Line(addon:ProfessionIconText(item.profession) .. tierIcon .. item.name .. " x" .. item.qty,
                right, item.value > 0 and "text" or "dim")
        end
        Line("Worth at the AH price", Money(row.worth))
        if row.kind == "Opened" then
            if row.cost then
                Line("The box cost you", Money(row.cost))
                Line("Profit after the AH cut", addon:FormatSignedMoney(row.profit), addon:MoneyColor(row.profit))
            else
                Line("The box cost you", "not known", "dim")
            end
            addon:Explain(tooltip, "From a box you crafted. The box's cost is shared over what came out by value, like a purchase.")
        else
            addon:Explain(tooltip, "Materials you got without buying: gathering, loot and opened bags (patron rewards, caches). They count at the AH price, since you could sell them instead.", 0.6, 0.6, 0.6, true)
        end
        tooltip:AddLine(" ")
        if row.itemID then addon:ClickHint(tooltip, "Click for the item's page") end
        addon:RightClickHint(tooltip, "Right-click for more")
        return
    elseif row.kind == "Order" then
        -- Your materials only; the customer's aren't a cost of yours
        Line("Your materials", Money((row.cost or 0) * (row.qty or 0)) .. (row.partial and "+" or ""))
        if row.gold then
            Line("Commission", Money(row.gold))
            local lot = row.lot
            if lot.kept then Line("Materials you kept", Money(lot.kept)) end
            for _, r in ipairs(lot.rewards or {}) do
                local name = C_Item.GetItemNameByID(r.itemID) or "Reward"
                -- A payout bag: what's inside on average
                local value, opened = addon:RewardValueNow(r)
                local text = value > 0 and Money(value) or "can't be sold"
                if opened then text = string.format("about %s (avg of %d opened)", Money(value), opened) end
                Line("Reward: " .. name .. (r.count > 1 and (" x" .. r.count) or ""), text, value > 0 and "text" or "dim")
            end
            Line(row.partial and "Profit (at most)" or "Profit", Signed(row.profit), addon:MoneyColor(row.profit))
        else
            addon:Explain(tooltip, "Crafted before Goldsmith recorded commissions, so the gold isn't known.", 0.6, 0.6, 0.6, true)
        end
        addon:Explain(tooltip, "Crafted for an order: it went to the customer, so it isn't in your stock or your costs.", 0.6, 0.6, 0.6, true)
    elseif row.kind == "Craft" then
        -- A batch: crafts of this item close together, one row
        if row.crafts and row.crafts > 1 then
            Line("Crafts", string.format("%d, %s to %s", row.crafts, date("%H:%M", row.first), date("%H:%M", row.time)))
        end
        Line("Materials cost", Money(row.cost) .. (row.partial and "+" or "") .. " each")
        if row.crafts and row.crafts > 1 then
            Line("Total", Money(row.cost * row.qty) .. (row.partial and "+" or ""))
        end
        addon:Explain(tooltip, "Crafts are kept for working out costs, so they can't be deleted here.", 0.6, 0.6, 0.6, true)
    else
        if row.qty and row.qty > 0 then Line("Each", Money(math.abs(row.gold) / row.qty)) end
        if row.profit then
            Line(COST_LABELS[row.costSource] or "Cost you", Money(row.cost) .. (row.partial and "+" or ""))
            Line(row.partial and "Profit (at most)" or "Profit", Signed(row.profit), addon:MoneyColor(row.profit))
            if row.costSource == "estimated" then
                addon:Explain(tooltip, "You didn't craft these while Goldsmith was watching, so the cost is the recipe at that day's prices.", 0.6, 0.6, 0.6, true)
            elseif row.costSource == "today" then
                addon:Explain(tooltip, "Sold before Goldsmith saved costs with sales, so this is today's estimate.", 0.6, 0.6, 0.6, true)
            elseif row.costSource == "reward" then
                addon:Explain(tooltip, "A crafting order's reward. The order's profit already counted it at its AH price then, so this sale's profit is what it sold for over that.", 0.6, 0.6, 0.6, true)
            end
        elseif row.kind == "Sale" then
            tooltip:AddLine("No cost known, so this sale isn't in your profit. If it was loot or a reward, right-click and mark it as free.", 0.6, 0.6, 0.6, true)
        end
        if row.entry and row.entry.vendor then Line("Sold to", "A vendor") end
        if row.entry and row.entry.trade then
            Line(row.entry.type == "REVENUE" and "Sold to" or "Got from", row.entry.trade .. " (trade)")
            if row.entry.swap then tooltip:AddLine("Includes items you got, at their AH price.", 0.6, 0.6, 0.6, true) end
            if row.entry.type ~= "REVENUE" then tooltip:AddLine("At its AH price. No gold spent.", 0.6, 0.6, 0.6, true) end
        end
        if row.character then Line("Character", row.character) end
    end
    tooltip:AddLine(" ")
    addon:ClickHint(tooltip, "Click for the item's page")
    addon:RightClickHint(tooltip, "Right-click for more")
end

-- Deleting: done at once, no "Are you sure?" (people click through those
-- without reading; design review). The entry stays in the list, greyed,
-- where it was, until you leave History: click it to undo. Several can be
-- deleted and each undone (user, 2026-10-10: in the list, not one button).
local deletedRows = {}
-- The filters the list was last drawn with: a deleted row shows only under
-- the filters it was deleted from (it ignored them, code review 2026-10-14)
local currentFilter

local function Deleted(row, restore)
    local ghost = {}
    for k, v in pairs(row) do ghost[k] = v end
    ghost.deleted, ghost.restore, ghost.filter = true, restore, currentFilter
    table.insert(deletedRows, ghost)
end

local function ConfirmDelete(row)
    if row.kind == "Gathered" or row.kind == "Opened" then
        local removed = addon:RemoveGathered(row.entries)
        Deleted(row, function() addon:RestoreGathered(removed) end)
        return
    end
    local entry = addon.ledger:remove(row.entry.id)
    if entry then
        Deleted(row, function()
            addon.ledger:restore(entry)
            if addon.Refresh then addon.Refresh() end
        end)
    end
    if addon.Refresh then addon.Refresh() end
end

local function Undo(ghost)
    for i, g in ipairs(deletedRows) do
        if g == ghost then table.remove(deletedRows, i) break end
    end
    if ghost.restore then ghost.restore() end
end

local function Menu(row)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(UIParent, function(_, root)
        root:CreateTitle(row.item)
        if row.kind == "Gathered" or row.kind == "Opened" then
            if row.itemID then
                root:CreateButton("Open the item's page", function() addon:OpenItem(row.item, row.itemID) end)
            end
            root:CreateButton("Delete these entries", function() ConfirmDelete(row) end)
            return
        end
        root:CreateButton("Open the item's page", function() addon:OpenItem(row.item, row.itemID) end)
        if row.kind == "Craft" then
            -- Worded as what it does: "This was a crafting order" read like
            -- a statement about a row already marked Craft (user, 2026-10-14)
            -- A batch moves as a whole
            root:CreateButton((row.crafts or 1) > 1 and "Move to Orders (they were made for crafting orders)"
                    or "Move to Orders (it was made for a crafting order)",
                function()
                    for _, lot in ipairs(row.lots or { row.lot }) do addon:MarkCraftAsOrder(row.itemID, lot) end
                end)
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

    -- Find entries by item name. Waits for a pause in typing: each search
    -- reads the whole ledger once.
    view.search = ""
    view.searchBox = UI.SearchBox(parent, 260, "Find an item", function(text)
        view.search = text
        if view.searchTimer then view.searchTimer:Cancel() end
        view.searchTimer = C_Timer.NewTimer(text == "" and 0 or SEARCH_DELAY, function()
            view.searchTimer = nil
            view.list:ScrollToTop()
            addon.RefreshWindow()
        end)
    end)
    view.searchBox:SetPoint("TOPLEFT", 0, 0)
    UI.SetTooltip(view.searchBox, function(tooltip)
        tooltip:AddLine("Find an item", 1, 1, 1)
        addon:Explain(tooltip, "Two letters or more, anywhere in the item's name. The type, character and the filters at the top still apply. Escape clears it.",
            0.6, 0.6, 0.6, true)
    end)

    view.chips = {}
    local previous
    for _, kind in ipairs(KINDS) do
        -- Forever has no crafting orders or crafted boxes
        if not (addon.isForever and (kind.key == "Order" or kind.key == "Opened")) then
            local chip = Chip(parent, kind.label, function()
                ui.historyKind = kind.key
                addon.RefreshWindow()
            end)
            chip.key = kind.key
            if previous then chip:SetPoint("LEFT", previous, "RIGHT", 6, 0) else chip:SetPoint("TOPLEFT", 0, -SEARCH_HEIGHT) end
            previous = chip
            table.insert(view.chips, chip)
        end
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
    view.itemChip.label:SetWordWrap(false)
    view.itemChip.label:SetJustifyH("LEFT")
    -- On the search line, after the box (user, 2026-11-10), as wide as its
    -- text up to the window's edge (Refresh): at a fixed 200 it ran past
    -- the edge (Reddit feedback, Harandar Celebration, 2026-10-29); long
    -- names end in "..."
    view.itemChip:SetPoint("LEFT", view.searchBox, "RIGHT", 10, 0)
    view.parent = parent

    -- Bottom right, on the footnote's line: by the filters, long totals ran
    -- under the character dropdown (user 2026-10-14, "plenty of space there")
    view.summary = UI.Text(parent, "small", "muted", "RIGHT")

    view.list = UI.List(parent, {
        fill = FillRow,
        tooltip = Tooltip,
        onClick = function(row, button)
            if row.deleted then
                if button ~= "RightButton" then Undo(row) end
            elseif button == "RightButton" then
                Menu(row)
            elseif (row.kind ~= "Gathered" and row.kind ~= "Opened") or row.itemID then
                addon:OpenItem(row.item, row.itemID)
            end
        end,
    })
    view.list:SetPoint("TOPLEFT", 0, -(SEARCH_HEIGHT + TOP_HEIGHT + 12))
    view.list:SetPoint("BOTTOMRIGHT", 0, 22)
    view.list:SetColumns(COLUMNS)
    view.footnote = UI.Text(parent, "small", "dim")
    -- Both clear of the window's carved corners, which covered the gold
    -- out (user, 2026-11-07) and the notes on the left (2026-11-10: "all
    -- dates and professions for this item" started under the silver corner)
    -- 35 in: 40 left a gap (user, 2026-11-10: "5 pixels closer")
    view.footnote:SetPoint("BOTTOMLEFT", 35, 2)
    view.summary:SetPoint("BOTTOMRIGHT", -35, 2)
    -- Deleted entries are kept to undo until you leave History (another
    -- tab, or the window closes)
    parent:HookScript("OnHide", function() wipe(deletedRows) end)
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
    if view.item then
        view.itemChip:SetLabel("Item: " .. view.item .. "   x")
        local room = (view.parent:GetWidth() or 0) - view.searchBox:GetWidth() - 10
        local label = view.itemChip.label
        local want = (label.GetUnboundedStringWidth and label:GetUnboundedStringWidth() or label:GetStringWidth()) + 20
        view.itemChip:SetWidth(math.max(math.min(want, room > 0 and room or want), 80))
    end

    -- Runs as work over frames (Window.lua): the list shows "Loading" if
    -- it takes more than a frame; the filters above stay usable
    state.loading:Begin(view.list)
    -- One item's history (from its page) covers every date and profession
    local needle = view.search:lower():match("^%s*(.-)%s*$")
    local filter = {
        prof = view.item and "All" or state.profession, since = not view.item and state.since or nil,
        kind = ui.historyKind, character = ui.historyCharacter, item = view.item,
        search = #needle >= SEARCH_MIN_LETTERS and needle or nil,
    }
    currentFilter = table.concat({ tostring(filter.prof), tostring(filter.since), tostring(filter.kind),
        tostring(filter.character), tostring(filter.item), addon:ExpansionFilterKey(), tostring(filter.search) }, "|")
    local rows, totals = addon:GetHistory(filter)
    view.list:SetEmptyText(#addon.ledger:getAll() == 0
        and "Nothing recorded yet. Purchases, sales and AH deposits are recorded as you make them."
        or filter.search and string.format("No item matching \"%s\". Try another type, All characters, or a longer date range or All expansions at the top.", needle)
        or "Nothing matches. Try another type, All characters, or a longer date range or All expansions at the top.")
    -- Deleted ones back in their place, newest first like the list (the
    -- history rows are shared until data changes, so a new list)
    local shown = rows
    local ghosts = {}
    for _, ghost in ipairs(deletedRows) do
        if ghost.filter == currentFilter then ghosts[#ghosts + 1] = ghost end
    end
    if #ghosts > 0 then
        shown = {}
        for _, row in ipairs(rows) do shown[#shown + 1] = row end
        for _, ghost in ipairs(ghosts) do shown[#shown + 1] = ghost end
        table.sort(shown, addon.HistoryNewest)
    end
    view.list:SetItems(shown)
    state.loading:Done(view.list)
    -- A side with nothing in it is left out: Sales alone read "out 0.00g",
    -- as if something were broken (user, 2026-10-27)
    local summary = { string.format("%d entr%s", #rows, #rows == 1 and "y" or "ies") }
    if totals.goldIn > 0 then table.insert(summary, "in " .. addon:Colorize(Money(totals.goldIn), "profit")) end
    if totals.goldOut > 0 then table.insert(summary, "out " .. addon:Colorize(Money(totals.goldOut), "loss")) end
    -- Gathered: no gold moved, but what it was worth (user,
    -- 2026-10-27: "i feel like it should not be zero")
    if (totals.worth or 0) > 0 then table.insert(summary, "gathered worth " .. addon:Colorize(Money(totals.worth), "gold")) end
    view.summary:SetText(table.concat(summary, "  ·  "))

    local notes = {}
    for _, row in ipairs(rows) do
        if row.profitEstimated then table.insert(notes, "~ estimated cost (hover for why)") break end
    end
    for _, row in ipairs(rows) do
        if row.partial and row.profit then table.insert(notes, "* some material costs unknown") break end
    end
    if ui.historyCharacter then table.insert(notes, "crafts only show for All characters") end
    -- Only the newest crafts of each item are kept (for costs), so 300 sold
    -- against 61 crafted read as lost crafts (user, 2026-11-01)
    for _, row in ipairs(rows) do
        if row.kind == "Craft" then
            table.insert(notes, string.format("crafts: your last %d of each item", addon.CRAFT_LOT_LIMIT))
            break
        end
    end
    if view.item then table.insert(notes, "all dates and professions for this item") end
    view.footnote:SetText(table.concat(notes, "   "))
end

-- Clicking the History tab again: everything (all types, all characters,
-- no item) from the top
local function Reset(view)
    local ui = GoldsmithDB.ui2
    view.item = nil
    ui.historyKind, ui.historyCharacter = nil, nil
    view.search = ""
    view.searchBox:SetText("")
    view.searchBox:ClearFocus()
    view.list:ScrollToTop()
end

-- What narrows the list right now, for the window's Filtered marker
local function Filters(view)
    local ui, list = GoldsmithDB.ui2, {}
    if ui.historyKind then
        for _, kind in ipairs(KINDS) do
            if kind.key == ui.historyKind then
                table.insert(list, { label = kind.label, clear = function() ui.historyKind = nil end })
            end
        end
    end
    if ui.historyCharacter then
        local name = ui.historyCharacter
        for _, c in ipairs(addon:GetHistoryCharacters()) do
            if c.key == ui.historyCharacter then name = c.name end
        end
        table.insert(list, { label = name, clear = function() ui.historyCharacter = nil end })
    end
    if view.item then
        table.insert(list, { label = view.item, clear = function() view.item = nil end })
    end
    if #view.search:match("^%s*(.-)%s*$") >= SEARCH_MIN_LETTERS then
        table.insert(list, { label = "\"" .. view.search .. "\"", clear = function()
            view.search = ""
            view.searchBox:SetText("")
        end })
    end
    return list
end

-- What clicks do, for the window's click legend
local function Legend()
    local parts = {
        { "click", "an entry: item page" },
        { "right", ": fix it (profession, free, crafting order, delete)" },
    }
    if #deletedRows > 0 then table.insert(parts, { "click", "a deleted one: undo" }) end
    table.insert(parts, { "hover", ": details" })
    return parts
end

addon:RegisterView("history", { create = Create, refresh = Refresh, reset = Reset, filters = Filters,
    legend = Legend, ownLoading = true })

_G.Goldsmith = addon
