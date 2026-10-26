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
-- Room for the cost's concentration note and the profit's two lines
local SUMMARY_HEIGHT = 160
local AH_CUT = 0.05

local Money, Signed = function(c) return addon:FormatMoney(c) end, function(c) return addon:FormatSignedMoney(c) end
local CharName = function(key) return addon.QueueCharName(key) end

local COLUMNS = {
    { key = "item", label = "Item" },
    -- Kept to what they show, so long names fit (user, 2026-10-23: "Sun-
    -- Blessed Blacksmith's T..."); the item takes the rest
    { key = "make", label = "Make", width = 44, justify = "RIGHT" },
    { key = "crafts", label = "Crafts", width = 48, justify = "RIGHT" },
    -- Centered between Crafts and the cost's figures (user, 2026-10-23):
    -- the gap before it makes up for the space at the left of the
    -- right-aligned costs
    -- Wide enough for the icon and "1,364" (40 cut it off, 2026-10-23)
    { key = "conc", label = "Conc", width = 56, gap = 6, justify = "CENTER" },
    -- Room for "978.66g" and "12,345g" (big amounts drop the silver)
    { key = "cost", label = "Cost", width = 64, justify = "RIGHT" },
    { key = "profit", label = "Profit", width = 76, justify = "RIGHT" },
    -- Wide enough for "Needs Scribe's Drafting Table" (user, 2026-10-16)
    { key = "next", label = "Next", width = 205, gap = 16 },
}

local view

-- A queued craft's concentration: the full cost to start its crafts (what
-- crafts are counted at, like the top of a plan) and the average after
-- ingenuity (like the plan's cost line), or nil without concentration
local function RowConcentration(row)
    local ti, plan = row.tierInfo, row.plan
    if not (row.entry.concentrate and ti and ti.concentrate and plan and plan.crafts > 0) then return nil end
    local full = ti.scenario and ti.scenario.concentration or ti.concentration
    if not full then return nil end
    return full * plan.crafts, (ti.concentration or full) * plan.crafts
end

-- The concentration icon in place of the word "conc" (Core.lua)
local function ConcText(points)
    return (addon:ConcentrationIconText() or "") .. string.format("%d", math.floor(points + 0.5))
end

local function ItemText(row)
    local prof = row.recipe and row.recipe.profession and addon:ProfessionIconText(row.recipe.profession) or ""
    return prof .. addon:QueueRowName(row)
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
            tooltip:AddDoubleLine(string.format("    %.0f %s", o.quantity, o.name or addon:KnownItemName(o.itemID) or "?"),
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
        for _, line in ipairs(s.blockers) do addon:AddShoppingBlocker(tooltip, line, item.plan) end
    end
    tooltip:AddLine(" ")
    addon:ClickHint(tooltip, "Click to open its plan (change how many there). Right-click to move or remove it.")
end

-- A stock-up's hover: what's left to buy and what it costs now
local function StockTooltip(tooltip, item)
    local made = item.entry.made or 0
    tooltip:AddLine(ItemText(item), 1, 1, 1)
    tooltip:AddDoubleLine("To buy", made > 0 and string.format("%d more (%d of %d bought)", item.remaining, made,
        item.entry.quantity) or tostring(item.remaining), 0.8, 0.8, 0.8, 1, 1, 1)
    local plan = item.plan
    if plan and plan.complete then
        tooltip:AddDoubleLine("About", Money(plan.cost), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    addon:Explain(tooltip, "A cheap material to stock up on (Items > Cheap materials). Buy next buys it on top of what your crafts need, and it leaves the queue once bought. Not in the queue's cost or profit: it's for later crafts.")
    tooltip:AddLine(" ")
    addon:ClickHint(tooltip, "Click to open its page. Right-click to move or remove it.")
end

-- A queued craft's gap from the to-do's profit (HeldGap, a gold or more),
-- or nil: its profit is starred
function addon:QueueRowGap(item)
    local plan = item.plan
    if not plan or plan.stock then return nil end
    return addon:HeldGap(plan, true)
end

local function FillRow(row, item)
    local c = row.cells
    c.item:SetText(ItemText(item))
    -- The one Craft next is on in gold, as on the queue panel (user,
    -- 2026-10-25)
    c.item:SetTextColor(addon:Color(view.next == item and "gold" or "text"))
    local made = item.entry.made or 0
    c.make:SetText(made > 0 and string.format("%d of %d", item.remaining, item.entry.quantity) or tostring(item.remaining))
    local plan = item.plan
    local full = RowConcentration(item)
    c.conc:SetText(full and ConcText(full) or "")
    -- Orange past what the character has (Refresh)
    c.conc:SetTextColor(addon:Color(item.concShort and "warning" or "conc"))
    if plan and plan.stock then
        -- No crafts or profit: it's shopping
        c.crafts:SetText("-")
        c.cost:SetText(plan.complete and Money(plan.cost) or "-")
        c.cost:SetTextColor(addon:Color("muted"))
        c.profit:SetText("-")
        c.profit:SetTextColor(addon:Color("dim"))
    elseif plan then
        c.crafts:SetText(tostring(plan.crafts))
        c.cost:SetText(Money(plan.cost) .. (plan.complete and "" or "+"))
        if plan.profit then
            -- * : what you hold makes it differ from the to-do (the
            -- footer and the hover say why)
            c.profit:SetText(Signed(plan.profit) .. (item.heldGap and addon:Colorize("*", "muted") or ""))
            c.profit:SetTextColor(addon:Color(addon:MoneyColor(plan.profit)))
        else
            c.profit:SetText("-")
            c.profit:SetTextColor(addon:Color("dim"))
        end
    else
        -- No plan (the queued quality isn't readable now): clear what a
        -- reused row showed before
        c.crafts:SetText("-")
        c.cost:SetText("-")
        c.profit:SetText("-")
        c.profit:SetTextColor(addon:Color("dim"))
    end
    local status, color = addon:QueueRowStatus(item, view.q)
    if view.next == item and item.state and item.state.enabled then color = "gold" end
    c.next:SetText(status)
    c.next:SetTextColor(addon:Color(color))
end

local function RowTooltip(tooltip, item)
    if item.entry.stockID then return StockTooltip(tooltip, item) end
    if item.entry.salvageID then return SalvageTooltip(tooltip, item) end
    tooltip:AddLine(ItemText(item), 1, 1, 1)
    addon:AddItemDescription(tooltip, item.recipe and item.recipe.outputItemID)
    local order = item.entry.orderID and item.entry
    if order then
        tooltip:AddDoubleLine("Crafting order", order.customer or "", 0.8, 0.8, 0.8, 1, 1, 1)
        if order.expires then
            tooltip:AddDoubleLine("Expires in", SecondsToTime(math.max(order.expires - time(), 0), true),
                0.8, 0.8, 0.8, 1, 1, 1)
        end
        addon:Explain(tooltip, "Goldsmith shops for your part of the materials (not the customer's). Craft it in the game's crafting orders window; it leaves the queue once crafted. Profit is the commission and rewards less your materials.")
    end
    local plan = item.plan
    local made = item.entry.made or 0
    tooltip:AddDoubleLine("To make", made > 0 and string.format("%d more (%d of %d made)", item.remaining, made,
        item.entry.quantity) or tostring(item.remaining), 0.8, 0.8, 0.8, 1, 1, 1)
    if plan then
        tooltip:AddDoubleLine("Crafts", string.format("%d, about %.1f made", plan.crafts, plan.expectedOutput),
            0.8, 0.8, 0.8, 1, 1, 1)
        -- A set mix (a split's other mix): the list only has room for icons
        if item.entry.mix then
            tooltip:AddDoubleLine("Mix", item.entry.mix, 0.8, 0.8, 0.8, 0.91, 0.76, 0.35)
            addon:Explain(tooltip, "A different mix for the concentration left after the entry above: too little for another craft of that one.")
        end
        local full = RowConcentration(item)
        if full then
            tooltip:AddDoubleLine("Concentration", string.format("%d to start", math.floor(full + 0.5)),
                0.8, 0.8, 0.8, 0.91, 0.76, 0.35)
            if item.concShort then
                tooltip:AddLine("More than this character has left after the crafts above it. The rest waits for concentration to come back (about 250 a day).",
                    1, 0.6, 0.2, true)
            end
            addon:Explain(tooltip, "Each craft needs its full cost to start. Planned as if ingenuity never gives any back: when it does, the rest is yours for later.")
        end
        tooltip:AddDoubleLine("Cost", Money(plan.cost), 0.8, 0.8, 0.8, 1, 1, 1)
        if plan.revenue then
            tooltip:AddDoubleLine("Sells for", Money(plan.revenue), 0.8, 0.8, 0.8, 1, 1, 1)
            local r, g, b = addon:Color(addon:MoneyColor(plan.profit))
            tooltip:AddDoubleLine("Profit", Signed(plan.profit), 0.8, 0.8, 0.8, r, g, b)
            -- The same gaps as the star on its profit (QueueRowGap)
            local gap, gapItem = addon:HeldGap(plan, true)
            if gap then
                local today = plan.profit + gap
                r, g, b = addon:Color(addon:MoneyColor(today))
                tooltip:AddDoubleLine("At today's prices", Signed(today), 0.8, 0.8, 0.8, r, g, b)
                tooltip:AddLine(addon:HeldGapText(gap, gapItem), 0.8, 0.8, 0.8, true)
            end
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
        for _, line in ipairs(s.blockers) do addon:AddShoppingBlocker(tooltip, line, item.plan) end
    end
    tooltip:AddLine(" ")
    addon:ClickHint(tooltip, "Click to open its plan (change how many there). Right-click to move or remove it.")
end

local function RowMenu(item)
    local key = view.q.charKey
    MenuUtil.CreateContextMenu(UIParent, function(_, root)
        root:CreateTitle(item.recipe and item.recipe.outputName or "Queued craft")
        if item.entry.stockID then
            root:CreateButton("Change how many", function()
                addon:AskStockUp(key, item.entry.stockID, item.stockName, item.entry.quantity)
            end)
        end
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
            elseif item.entry.stockID then
                addon:OpenItem(item.stockName, item.entry.stockID)
            elseif item.entry.salvageID then
                addon:OpenSalvagePlan(item.entry.salvageID, view.q.charKey, item.remaining, "queue")
            elseif item.recipe then
                addon:OpenCraftPlan(item.recipe, { tier = item.entry.tier, concentrate = item.entry.concentrate },
                    view.q.charKey, item.remaining, "queue")
            end
        end,
        empty = "Nothing queued. Right-click a craft on the Crafts tab to add it.",
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
    -- Concentration under the cost, like a plan's
    view.cost.note = UI.Text(summary, "small", "muted")
    view.cost.note:SetPoint("TOPLEFT", view.cost.value, "BOTTOMLEFT", 0, -4)
    view.cost.note:SetWidth(360)
    view.cost.note:SetWordWrap(false)
    -- Under the profit: at today's prices, and why it differs (HeldGap)
    view.profit.note = UI.Text(summary, "small", "text")
    view.profit.note:SetPoint("TOPLEFT", view.profit.value, "BOTTOMLEFT", 0, -4)
    view.profit.note:SetWidth(360)
    view.profit.note:SetWordWrap(false)
    -- Why, on a line of its own: one text with a line break showed only
    -- "+860.80g at today's prices..." in game (user, 2026-10-26)
    view.profit.why = UI.Text(summary, "small", "text")
    view.profit.why:SetPoint("TOPLEFT", view.profit.note, "BOTTOMLEFT", 0, -2)
    view.profit.why:SetWidth(360)
    view.profit.why:SetWordWrap(false)
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
    view.warnLine:SetWordWrap(true)
    view.warnLine:SetMaxLines(2)
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
        -- Without Auctionator the button is greyed out; the hover says
        -- what it would do (user, 2026-10-09: encourage Auctionator)
        if not addon:HasAuctionator() then
            addon:AuctionatorPitch(tooltip)
            return
        end
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
                tooltip:AddDoubleLine("    " .. (item.name or addon:KnownItemName(item.itemID) or "?"), describe(item),
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
    -- The next craft's crafting buff when it's off, as on the plan
    view.buffWarn = UI.Text(summary, "small", "warning", "RIGHT")
    view.buffWarn:SetPoint("BOTTOMRIGHT", view.craft, "TOPRIGHT", 0, 6)
    view.buffWarn:SetWidth(320)
    -- The tool swap or buff button (Prep.lua) in the buff warning's spot,
    -- as on the plan and the queue panel (user, 2026-10-24: it showed in
    -- the panel but not here)
    view.prep = UI.Button(summary, "", 260, 22, function()
        addon:RunPrep(view.prepAction)
    end)
    -- The Craft button's size, not wider (user, 2026-10-24: "looks weird")
    view.prep:SetPoint("BOTTOMLEFT", view.craft, "TOPLEFT", 0, 6)
    view.prep:SetPoint("BOTTOMRIGHT", view.craft, "TOPRIGHT", 0, 6)
    view.prep:SetHeight(view.craft:GetHeight())
    view.prep.label:SetTextColor(addon:Color("warning"))
    view.prep:Hide()
    UI.SetTooltip(view.prep, function(tooltip)
        local action = view.prepAction
        if not action then return end
        tooltip:AddLine(action.label, 1, 1, 1)
        for _, line in ipairs(action.lines or {}) do tooltip:AddLine(line, 0.8, 0.8, 0.8, true) end
    end, "ANCHOR_TOP")
    function view:UpdatePrep()
        local row = view.mine and view.next or nil
        local action = row and addon:CraftPrep(row.state, row.recipe or {}, row.entry.concentrate) or nil
        view.prepAction = action
        view.prep:SetShown(action ~= nil)
        if action then addon:SetPrepLabel(view.prep, action) end
        local buff = not action and addon:QueueMissingBuff(view.next, view.mine)
        local nextLine = not buff and view.mine and addon:QueueNextLine(view.next)
        view.buffWarn:SetText(buff and (buff .. " isn't active") or nextLine or "")
        view.buffWarn:SetTextColor(addon:Color(buff and "warning" or "muted"))
        -- Above the tool button when it shows
        view.buffWarn:ClearAllPoints()
        view.buffWarn:SetPoint("BOTTOMRIGHT", action and view.prep or view.craft, "TOPRIGHT", 0, 6)
    end
    addon.UpdateQueueTabPrep = function()
        if view.craft:IsVisible() then view:UpdatePrep() end
    end
    local auraWatch = CreateFrame("Frame", nil, view.craft)
    auraWatch:RegisterUnitEvent("UNIT_AURA", "player")
    auraWatch:SetScript("OnEvent", function()
        if not view.craft:IsVisible() then return end
        view:UpdatePrep()
    end)
    UI.Style(view.craft, "highlight", "borderGold")
    view.craft.label:SetTextColor(addon:Color("gold"))
    view.craft:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderGold")) end)
    UI.SetTooltip(view.craft, function(tooltip)
        tooltip:AddLine("Craft next", 1, 1, 1)
        addon:Explain(tooltip, "One step per click: mill, make materials, then the craft, down the queue. Crafts for the open profession go first. Set a key in Options > Keybindings > Goldsmith.",
            0.8, 0.8, 0.8, true)
        local row = view.next
        if row and row.state then
            tooltip:AddLine(" ")
            tooltip:AddLine(row.recipe.outputName, addon:Color("gold"))
            for _, line in ipairs(row.state.notes) do tooltip:AddLine(line, 0.8, 0.8, 0.8, true) end
            for _, line in ipairs(row.state.blockers) do
                addon:AddShoppingBlocker(tooltip, line, row.plan)
            end
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
        -- By name, like the planner ("hover Send" meant nothing without
        -- Auctionator)
        local parts = {}
        for i, item in ipairs(w.stale) do
            if i > 2 then
                table.insert(parts, string.format("%d more", #w.stale - 2))
                break
            end
            table.insert(parts, addon:KnownItemName(item.itemID))
        end
        w.text = string.format("Old or missing AH prices: %s. Search the AH for %s before buying.",
            table.concat(parts, ", "), #w.stale == 1 and "it" or "them")
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
    -- Concentration by profession (each has its own), at the full cost:
    -- planned as if ingenuity never procs, like shopping lists. A proc
    -- leaves some over for tomorrow; counting on one leaves you stuck
    -- mid-queue (user, 2026-10-16: "1026 concentration looks wrong" with
    -- 1000). Rows past what the character has are marked (row.concShort).
    local byProf, order, have = {}, {}, {}
    for _, row in ipairs(q.rows) do
        local full = RowConcentration(row)
        local prof = full and row.recipe and row.recipe.profession
        row.concShort = nil
        if prof then
            if not byProf[prof] then
                table.insert(order, prof)
                have[prof] = (key == addon.charKey and addon:GetConcentration(prof))
                    or addon:GetCharacterConcentration(key, prof)
            end
            byProf[prof] = (byProf[prof] or 0) + full
            if have[prof] and byProf[prof] > have[prof] then row.concShort = true end
        end
    end
    -- Rows whose profit differs from the to-do's because of what you
    -- hold, by a gold or more: Blooming Feast +148.51g against +126.60g,
    -- while the whole queue's gap was too small to mention (user,
    -- 2026-10-26: "if there is a mismatch we need to make it clear why").
    -- Not only clear gaps: a 13g one under the 10% line went unexplained.
    local starred = false
    for _, row in ipairs(q.rows) do
        row.heldGap = addon:QueueRowGap(row)
        starred = starred or row.heldGap ~= nil
    end
    v.list:SetItems(q.rows)

    local empty = #q.rows == 0
    -- Only stock-ups: they're shopping, not in the cost or profit, so
    -- "0.00g" read as broken
    local crafts = false
    for _, row in ipairs(q.rows) do
        if not row.entry.stockID then crafts = true break end
    end
    local noTotals = empty or not crafts
    v.cost.value:SetText(noTotals and "-" or (Money(q.cost) .. (q.complete and "" or "+")))
    local parts, short = {}, false
    for _, prof in ipairs(order) do
        local over = have[prof] and byProf[prof] > have[prof]
        short = short or over
        table.insert(parts, addon:ProfessionIconText(prof) .. string.format("%d", math.floor(byProf[prof] + 0.5))
            .. (over and string.format(" (you have %d)", math.floor(have[prof])) or ""))
    end
    v.cost.note:SetText(#parts > 0 and ("needs " .. table.concat(parts, " + ") .. " concentration") or "")
    v.cost.note:SetTextColor(addon:Color(short and "warning" or "muted"))
    v.sells.value:SetText(noTotals and "-" or Money(q.revenue))
    v.profit.value:SetText(noTotals and "-" or Signed(q.profit))
    v.profit.value:SetTextColor(addon:Color(noTotals and "dim" or addon:MoneyColor(q.profit)))
    -- The to-do counts today's prices; the queue, what you paid. When what
    -- you hold makes them clearly differ, say by how much and why.
    local plans = {}
    for _, row in ipairs(q.rows) do
        if row.plan and not row.plan.stock then table.insert(plans, row.plan) end
    end
    local gap, gapItem
    if not noTotals then gap, gapItem = addon:HeldGap(plans, starred) end
    if gap then
        local today = q.profit + gap
        -- "as on the to-do": what the star is measured against
        v.profit.note:SetText(string.format("%s at today's prices, as on the to-do",
            addon:Colorize(Signed(today), addon:MoneyColor(today))))
        v.profit.why:SetText((starred and "* " or "") .. addon:HeldGapText(gap, gapItem))
    elseif starred and not noTotals then
        -- Rows that differ both ways, adding up to nothing
        v.profit.note:SetText("* What you hold changes these: hover for why")
        v.profit.why:SetText("")
    else
        v.profit.note:SetText("")
        v.profit.why:SetText("")
    end

    if empty then
        v.spendLine:SetText("")
    else
        local live, short = 0, false
        for _, entry in ipairs(q.buyAH) do
            if entry.live then live = live + 1 end
            if entry.short then short = true end
        end
        local text = #q.buyAH == 0 and "Nothing to buy on the AH"
            or string.format("AH: %d item%s, about %s", #q.buyAH, #q.buyAH == 1 and "" or "s",
                Money(q.spend))
        if live > 0 then text = text .. string.format(" (%d priced from live listings)", live) end
        if short then text = text .. ". Not enough listed for all of it." end
        if not q.mine then
            local c = GoldsmithDB.characters[q.charKey]
            local when = c and c.stockTime and date("%b %d", c.stockTime)
            text = text .. (when and string.format(". Counts what they held at their last login (%s)", when)
                or ". Their bags aren't counted yet: log in on them once")
            if #q.buyAH > 0 and addon:Setting("buyFor") == "all" then
                text = text .. ". Buy next on any of your characters buys them"
            end
        end
        v.spendLine:SetText(text)
        v.spendLine:SetTextColor(addon:Color(short and "warning" or "muted"))
    end
    if #q.buyVendor > 0 then
        local parts = {}
        for _, entry in ipairs(q.buyVendor) do table.insert(parts, entry.quantity .. " " .. entry.name) end
        -- Orange and "first": 53 Luminant Flux in muted text was missed and
        -- the queue stalled on Needs materials (user, 2026-10-22)
        v.vendorLine:SetText("Vendor: " .. table.concat(parts, ", "))
        v.vendorLine:SetTextColor(addon:Color("warning"))
    else
        v.vendorLine:SetText("")
    end

    local canSend = #q.buyAH > 0 and addon:HasAuctionator()
    v.shop:SetEnabled(canSend)
    v.shop:SetAlpha(canSend and 1 or 0.5)
    v.warnings = not empty and Warnings(q) or nil
    v.warnLine:SetText(v.warnings and v.warnings.text or "")

    local busy = addon.QueueBusy()
    local state = v.next and v.next.state
    local enabled = q.mine and not busy and state ~= nil and state.enabled == true
    -- Its key in the button, "Craft 1 (F5)", when it can craft and the
    -- step still fits (user, 2026-10-17). Not on a plan's Craft button:
    -- the key crafts the queue, not the plan.
    local label = addon:QueueButtonLabel(v.next, q)
    local key = enabled and addon:BindingKeyText("GOLDSMITH_CRAFT_NEXT")
    if key then
        v.craft.label:SetText(label .. " (" .. key .. ")")
        if v.craft.label:GetUnboundedStringWidth() > v.craft:GetWidth() - 16 then key = nil end
    end
    v.craft:SetLabel(key and (label .. " (" .. key .. ")") or label)
    v.craft:SetEnabled(enabled)
    v.craft:SetAlpha(enabled and 1 or 0.5)
    v.mine = q.mine
    v:UpdatePrep()
end

local function Reset(v)
    v.charKey = nil
    v.list:ScrollToTop()
end

-- What clicks do, for the window's click legend
local function Legend()
    return {
        { "click", ": plan" },
        { "right", ": move or remove" },
        { "hover", ": details" },
    }
end

addon:RegisterView("queue", { create = Create, refresh = Refresh, reset = Reset, legend = Legend })

-- Walking up to an anvil fires no event, so while the next craft needs one
-- nearby the tab is checked every second, like the plan and the panel:
-- only whether it's there now (Crafts.lua's StationsMet), then redrawn
-- once. Redrawing every second dropped frames all the way to the anvil
-- (user, 2026-10-19).
C_Timer.NewTicker(1, function()
    local screen = addon.GetTabScreen and addon:GetTabScreen("queue")
    local v = screen and screen.view
    local state = v and v.next and v.next.state
    if state and state.nearby and screen.frame and screen.frame:IsVisible()
        and addon.StationsMet(state.nearbyRecipes) then
        Refresh(v)
    end
end)

_G.Goldsmith = addon
