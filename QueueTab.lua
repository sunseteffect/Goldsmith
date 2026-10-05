local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Queue tab
--
-- A character's craft queue (see Queue.lua): each craft with how many are
-- left, crafts, cost, profit and what Craft next would do for it; totals
-- for the whole queue; one shopping list for everything; and Craft next.
-- Shows the character you're on; the dropdown shows others' queues (planned
-- without their bags, and crafted when you log in on them). Click a craft
-- to open its plan, right-click to move or remove it. The header's
-- profession filter doesn't apply: the queue is one list.

local TOP_HEIGHT = 26
local SUMMARY_HEIGHT = 128
local AH_CUT = 0.05

local Money, Signed = function(c) return addon:FormatMoney(c) end, function(c) return addon:FormatSignedMoney(c) end
local CharName = function(key) return addon.QueueCharName(key) end

local COLUMNS = {
    { key = "item", label = "Item" },
    { key = "make", label = "Make", width = 70, justify = "RIGHT" },
    { key = "crafts", label = "Crafts", width = 52, justify = "RIGHT" },
    { key = "cost", label = "Cost", width = 84, justify = "RIGHT" },
    { key = "profit", label = "Profit", width = 84, justify = "RIGHT" },
    { key = "next", label = "Next", width = 150 },
}

local view

local function ItemText(row)
    local prof = row.recipe and row.recipe.profession and addon:ProfessionIconText(row.recipe.profession) or ""
    local conc = row.entry.concentrate and addon:Colorize("  conc", "conc") or ""
    return prof .. addon:QueueRowName(row) .. conc
end

-- A salvage batch's hover: the batch view (what goes in, what should come
-- out, worth and profit)
local function SalvageTooltip(tooltip, item)
    local plan = item.plan
    local made = item.entry.made or 0
    tooltip:AddLine(ItemText(item), 1, 1, 1)
    tooltip:AddDoubleLine("To salvage", made > 0 and string.format("%d more (%d of %d done)", item.remaining, made,
        item.entry.quantity) or tostring(item.remaining), 0.8, 0.8, 0.8, 1, 1, 1)
    if not plan then return end
    tooltip:AddDoubleLine("Salvages", string.format("%d clicks' worth, about %.0f with resourcefulness", plan.crafts, plan.casts),
        0.8, 0.8, 0.8, 1, 1, 1)
    if plan.have > 0 then
        tooltip:AddDoubleLine("You have", tostring(plan.have), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    if #plan.buyAH > 0 then
        local buy = plan.buyAH[1]
        tooltip:AddDoubleLine("To buy", string.format("%d for about %s", buy.quantity, Money(buy.cost)),
            0.8, 0.8, 0.8, 1, 1, 1)
    end
    if #plan.outputs > 0 then
        tooltip:AddLine(" ")
        tooltip:AddLine("Should come out:", 0.8, 0.8, 0.8)
        for _, o in ipairs(plan.outputs) do
            tooltip:AddDoubleLine(string.format("    %.0f %s", o.quantity, o.name or C_Item.GetItemNameByID(o.itemID) or "?"),
                o.value and Money(o.value) or "no price", 0.9, 0.9, 0.9, 1, 1, 1)
        end
    else
        tooltip:AddLine("No yields yet: salvage some first.", 1, 0.6, 0.2, true)
    end
    tooltip:AddLine(" ")
    tooltip:AddDoubleLine("Cost", Money(plan.cost), 0.8, 0.8, 0.8, 1, 1, 1)
    if plan.revenue then
        tooltip:AddDoubleLine("Worth, after the AH cut", Money(plan.revenue), 0.8, 0.8, 0.8, 1, 1, 1)
        local r, g, b = addon:Color(addon:MoneyColor(plan.profit))
        tooltip:AddDoubleLine("Profit", Signed(plan.profit), 0.8, 0.8, 0.8, r, g, b)
    end
    local found = item.salvageRow
    if found and found.whyNot then
        tooltip:AddLine(found.whyNot, 1, 0.6, 0.2, true)
    end
    local s = item.state
    if s then
        tooltip:AddLine(" ")
        for _, line in ipairs(s.notes) do tooltip:AddLine(line, 0.8, 0.8, 0.8, true) end
        for _, line in ipairs(s.blockers) do tooltip:AddLine(line, 1, 0.6, 0.2, true) end
    end
    tooltip:AddLine(" ")
    tooltip:AddLine("Click to change how many. Right-click to move or remove it.", 0.37, 0.81, 0.48, true)
end

local function FillRow(row, item)
    local c = row.cells
    c.item:SetText(ItemText(item))
    local made = item.entry.made or 0
    c.make:SetText(made > 0 and string.format("%d of %d", item.remaining, item.entry.quantity) or tostring(item.remaining))
    local plan = item.plan
    if plan then
        c.crafts:SetText(tostring(plan.crafts))
        c.cost:SetText(Money(plan.cost) .. (plan.complete and "" or "+"))
        if plan.profit then
            c.profit:SetText(Signed(plan.profit))
            c.profit:SetTextColor(addon:Color(addon:MoneyColor(plan.profit)))
        else
            c.profit:SetText("-")
            c.profit:SetTextColor(addon:Color("dim"))
        end
    end
    local status, color = addon:QueueRowStatus(item, view.q)
    if view.next == item and item.state and item.state.enabled then color = "gold" end
    c.next:SetText(status)
    c.next:SetTextColor(addon:Color(color))
end

local function RowTooltip(tooltip, item)
    if item.entry.salvageID then return SalvageTooltip(tooltip, item) end
    tooltip:AddLine(ItemText(item), 1, 1, 1)
    local plan = item.plan
    local made = item.entry.made or 0
    tooltip:AddDoubleLine("To make", made > 0 and string.format("%d more (%d of %d made)", item.remaining, made,
        item.entry.quantity) or tostring(item.remaining), 0.8, 0.8, 0.8, 1, 1, 1)
    if plan then
        tooltip:AddDoubleLine("Crafts", string.format("%d, about %.1f made", plan.crafts, plan.expectedOutput),
            0.8, 0.8, 0.8, 1, 1, 1)
        tooltip:AddDoubleLine("Cost", Money(plan.cost), 0.8, 0.8, 0.8, 1, 1, 1)
        if plan.revenue then
            tooltip:AddDoubleLine("Sells for", Money(plan.revenue), 0.8, 0.8, 0.8, 1, 1, 1)
            local r, g, b = addon:Color(addon:MoneyColor(plan.profit))
            tooltip:AddDoubleLine("Profit", Signed(plan.profit), 0.8, 0.8, 0.8, r, g, b)
        end
        if #plan.buyAH > 0 then
            tooltip:AddLine(" ")
            tooltip:AddLine("To buy for it (after the crafts above it):", 0.8, 0.8, 0.8)
            for _, entry in ipairs(plan.buyAH) do
                tooltip:AddDoubleLine("    " .. entry.name, "x" .. entry.quantity, 0.9, 0.9, 0.9, 1, 1, 1)
            end
        end
    end
    local s = item.state
    if s then
        tooltip:AddLine(" ")
        if s.steps then
            for i, step in ipairs(s.steps) do
                local r, g, b = 0.6, 0.6, 0.6
                if i == 1 then r, g, b = addon:Color("gold") end
                tooltip:AddLine(string.format("    %d. %s", i, step), r, g, b)
            end
        end
        for _, line in ipairs(s.notes) do tooltip:AddLine(line, 0.8, 0.8, 0.8, true) end
        for _, line in ipairs(s.blockers) do tooltip:AddLine(line, 1, 0.6, 0.2, true) end
    end
    tooltip:AddLine(" ")
    tooltip:AddLine("Click to change how many. Right-click to move or remove it.", 0.37, 0.81, 0.48, true)
end

local function RowMenu(item)
    local key = view.q.charKey
    MenuUtil.CreateContextMenu(UIParent, function(_, root)
        root:CreateTitle(item.recipe and item.recipe.outputName or "Queued craft")
        root:CreateButton("Move up", function() addon:MoveQueueEntry(key, item.entry, -1) end)
        root:CreateButton("Move down", function() addon:MoveQueueEntry(key, item.entry, 1) end)
        root:CreateButton("Remove", function() addon:RemoveQueueEntry(key, item.entry) end)
    end)
end

StaticPopupDialogs["GOLDSMITH_CLEAR_QUEUE"] = {
    text = "Clear %s's craft queue?",
    button1 = OKAY or "OK",
    button2 = CANCEL or "Cancel",
    OnAccept = function(_, key) addon:ClearQueue(key) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function Create(parent)
    view = { charKey = nil }

    view.title = UI.Text(parent, "heading")
    view.title:SetPoint("TOPLEFT", 0, -4)
    view.note = UI.Text(parent, "label", "dim")
    view.note:SetPoint("LEFT", view.title, "RIGHT", 10, -1)
    view.note:SetText("shop once for everything, then craft it all with Craft next")

    view.clear = UI.Button(parent, "Clear", 70, 24, function()
        if view.q and #view.q.rows > 0 then
            StaticPopup_Show("GOLDSMITH_CLEAR_QUEUE", CharName(view.q.charKey), nil, view.q.charKey)
        end
    end)
    view.clear:SetPoint("TOPRIGHT", 0, 0)
    view.who = UI.Dropdown(parent, 160, function(root)
        root:CreateTitle("Show the queue of")
        for _, key in ipairs(addon:GetQueuedCharacters()) do
            local n = #addon:GetQueue(key)
            root:CreateRadio(string.format("%s (%d)", CharName(key), n),
                function() return (view.charKey or addon.charKey) == key end,
                function()
                    view.charKey = key ~= addon.charKey and key or nil
                    addon.RefreshWindow()
                end)
        end
    end)
    view.who:SetPoint("RIGHT", view.clear, "LEFT", -8, 0)

    view.list = UI.List(parent, {
        fill = FillRow,
        tooltip = RowTooltip,
        onClick = function(item, button)
            if button == "RightButton" then
                if MenuUtil and MenuUtil.CreateContextMenu then RowMenu(item) end
            elseif item.entry.salvageID then
                addon:AskSalvageBatch(view.q.charKey, item.entry.salvageID, item.inputName, item.verb)
            elseif item.recipe then
                addon:OpenCraftPlan(item.recipe, { tier = item.entry.tier, concentrate = item.entry.concentrate },
                    view.q.charKey, item.remaining, "queue")
            end
        end,
        empty = "Nothing queued. Open a craft's plan and click Add to queue, or right-click a craft (or a mill or prospect row) on the Crafts tab.",
    })
    view.list:SetPoint("TOPLEFT", 0, -(TOP_HEIGHT + 12))
    view.list:SetPoint("BOTTOMRIGHT", 0, SUMMARY_HEIGHT + 12)
    view.list:SetColumns(COLUMNS)

    -- Totals, shopping and Craft next
    local summary = UI.Panel(parent)
    summary:SetPoint("BOTTOMLEFT")
    summary:SetPoint("BOTTOMRIGHT")
    summary:SetHeight(SUMMARY_HEIGHT)
    local function Figure(i)
        local f = {}
        f.label = UI.Text(summary, "label", "muted")
        f.label:SetPoint("TOPLEFT", 16 + (i - 1) * 190, -14)
        f.value = UI.Text(summary, "value")
        f.value:SetPoint("TOPLEFT", f.label, "BOTTOMLEFT", 0, -5)
        return f
    end
    view.cost, view.sells, view.profit = Figure(1), Figure(2), Figure(3)
    view.cost.label:SetText("COST")
    view.sells.label:SetText("SELLS FOR")
    view.profit.label:SetText("PROFIT")

    local function SummaryLine(y)
        local fs = UI.Text(summary, "small", "muted")
        fs:SetPoint("BOTTOMLEFT", 16, y)
        fs:SetPoint("RIGHT", summary, "RIGHT", -200, 0)
        return fs
    end
    view.warnLine = SummaryLine(46)
    view.warnLine:SetTextColor(addon:Color("warning"))
    view.spendLine = SummaryLine(28)
    view.vendorLine = SummaryLine(10)

    view.shop = UI.Button(summary, "Send to Auctionator", 170, 28, function()
        if not view.q then return end
        local ok, result = addon:SendShoppingList(view.q)
        if ok then
            print("|cFF00FF00[Goldsmith]|r Shopping list \"" .. result .. "\" sent to Auctionator's Shopping tab.")
            addon.RefreshWindow()
        else
            print("|cFF00FF00[Goldsmith]|r Couldn't create the shopping list: " .. result)
        end
    end)
    view.shop:SetPoint("BOTTOMRIGHT", -14, 12)
    UI.SetTooltip(view.shop, function(tooltip)
        tooltip:AddLine("Send to Auctionator", 1, 1, 1)
        tooltip:AddLine("One shopping list for everything in the queue. Items come off it as you buy them, and it's deleted once everything's bought.",
            0.8, 0.8, 0.8, true)
        local q = view.q
        if q and #q.buyAH > 0 then
            tooltip:AddLine(" ")
            for _, entry in ipairs(q.buyAH) do
                tooltip:AddDoubleLine("    " .. entry.name, string.format("x%d  %s", entry.quantity, Money(entry.cost)),
                    0.9, 0.9, 0.9, 1, 1, 1)
            end
        end
        local w = view.warnings
        if not w then return end
        local r, g, b = addon:Color("warning")
        local function Section(title, items, describe)
            if #items == 0 then return end
            tooltip:AddLine(" ")
            tooltip:AddLine(title, r, g, b, true)
            for _, item in ipairs(items) do
                tooltip:AddDoubleLine("    " .. (item.name or C_Item.GetItemNameByID(item.itemID) or "?"), describe(item),
                    0.9, 0.9, 0.9, 1, 1, 1)
            end
        end
        Section("The queue changed since you sent the list. Now also needs:", w.more,
            function(item) return "x" .. item.quantity end)
        Section("On the list but no longer needed:", w.extra,
            function(item) return "x" .. item.quantity end)
        Section("Old or missing AH prices. Scan the AH first, or the plans may change after you buy:", w.stale,
            function(item) return addon:AHPriceAgeText(item.itemID) end)
    end, "ANCHOR_TOP")

    view.craft = UI.Button(summary, "Craft next", 170, 28, function()
        addon:CraftNext()
    end)
    view.craft:SetPoint("BOTTOMRIGHT", view.shop, "TOPRIGHT", 0, 8)
    UI.Style(view.craft, "highlight", "borderGold")
    view.craft.label:SetTextColor(addon:Color("gold"))
    view.craft:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderGold")) end)
    UI.SetTooltip(view.craft, function(tooltip)
        tooltip:AddLine("Craft next", 1, 1, 1)
        tooltip:AddLine("One step per click: mill, make materials, then the craft, down the queue. Crafts for the profession that's open go first. The same button sits next to the profession window, and you can set a key for it (Options > Keybindings > AddOns > Goldsmith).",
            0.8, 0.8, 0.8, true)
        local row = view.next
        if row and row.state then
            tooltip:AddLine(" ")
            tooltip:AddLine(row.recipe.outputName, addon:Color("gold"))
            for _, line in ipairs(row.state.notes) do tooltip:AddLine(line, 0.8, 0.8, 0.8, true) end
            for _, line in ipairs(row.state.blockers) do tooltip:AddLine(line, 1, 0.6, 0.2, true) end
        elseif view.q and not view.q.mine then
            tooltip:AddLine("Log in on " .. CharName(view.q.charKey) .. " to craft their queue.", 1, 0.6, 0.2, true)
        end
    end, "ANCHOR_TOP")
    return view
end

local function Warnings(q)
    local more, extra = addon:ShoppingListChanges(q)
    local w = { more = more or {}, extra = extra or {}, stale = #q.buyAH > 0 and addon:QueueStalePrices(q) or {} }
    if #w.more > 0 then
        local parts = {}
        for i, item in ipairs(w.more) do
            if i > 2 then
                table.insert(parts, string.format("%d more", #w.more - 2))
                break
            end
            table.insert(parts, item.quantity .. " " .. (item.name or "?"))
        end
        w.text = "The queue changed since you sent the list. Also needs " .. table.concat(parts, ", ") .. ": send it again."
    elseif #w.extra > 0 then
        w.text = "The queue changed since you sent the list (it needs less now). Hover Send for details."
    elseif #w.stale > 0 then
        w.text = string.format("Old or missing AH prices for %d material%s (hover Send). Scan the AH first, or the plans may change after you buy.",
            #w.stale, #w.stale == 1 and "" or "s")
    else
        return nil
    end
    return w
end

local function Refresh(v)
    -- Back to your own queue once the other character's is empty
    if v.charKey and #addon:GetQueue(v.charKey) == 0 then v.charKey = nil end
    local key = v.charKey or addon.charKey
    local q = addon:BuildQueue(key)
    v.q = q
    v.next = q.mine and addon:QueueNextRow(q) or nil

    v.title:SetText(string.format("%s's queue", CharName(key)))
    v.who:SetLabel(CharName(key))
    v.who:SetShown(#addon:GetQueuedCharacters() > 1 or v.charKey ~= nil)
    v.clear:SetEnabled(#q.rows > 0)
    v.clear:SetAlpha(#q.rows > 0 and 1 or 0.5)
    v.list:SetItems(q.rows)

    local empty = #q.rows == 0
    v.cost.value:SetText(empty and "-" or (Money(q.cost) .. (q.complete and "" or "+")))
    v.sells.value:SetText(empty and "-" or Money(q.revenue))
    v.profit.value:SetText(empty and "-" or Signed(q.profit))
    v.profit.value:SetTextColor(addon:Color(empty and "dim" or addon:MoneyColor(q.profit)))

    if empty then
        v.spendLine:SetText("")
    else
        local live, short = 0, false
        for _, entry in ipairs(q.buyAH) do
            if entry.live then live = live + 1 end
            if entry.short then short = true end
        end
        local text = string.format("To buy on the AH: %d item%s, about %s", #q.buyAH, #q.buyAH == 1 and "" or "s",
            Money(q.spend))
        if live > 0 then text = text .. string.format(" (%d priced from live listings)", live) end
        if short then text = text .. ". Not enough listed for all of it." end
        if not q.mine then text = text .. ". Planned without their bags: log in on them for what they already have." end
        v.spendLine:SetText(text)
        v.spendLine:SetTextColor(addon:Color(short and "warning" or "muted"))
    end
    if #q.buyVendor > 0 then
        local parts = {}
        for _, entry in ipairs(q.buyVendor) do table.insert(parts, entry.quantity .. " " .. entry.name) end
        v.vendorLine:SetText("From a vendor: " .. table.concat(parts, ", "))
    else
        v.vendorLine:SetText("")
    end

    v.shop:SetEnabled(#q.buyAH > 0)
    v.shop:SetAlpha(#q.buyAH > 0 and 1 or 0.5)
    v.warnings = not empty and Warnings(q) or nil
    v.warnLine:SetText(v.warnings and v.warnings.text or "")

    local busy = addon.QueueBusy()
    local state = v.next and v.next.state
    local enabled = q.mine and not busy and state ~= nil and state.enabled == true
    v.craft:SetLabel(addon:QueueButtonLabel(v.next, q))
    v.craft:SetEnabled(enabled)
    v.craft:SetAlpha(enabled and 1 or 0.5)
end

local function Reset(v)
    v.charKey = nil
    v.list:ScrollToTop()
end

addon:RegisterView("queue", { create = Create, refresh = Refresh, reset = Reset })

_G.Goldsmith = addon
