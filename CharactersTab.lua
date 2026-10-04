local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Characters tab
--
-- A card per character: professions and skill, concentration, when you
-- were last on it, an Exclude switch (the same as Settings > Characters),
-- and its to-do list: what "Do this next" suggests, split by who should do
-- it (GetCharacterTodo). Excluded characters go to the bottom. Click a
-- to-do line to plan that craft; right-click a card to remove a character
-- you no longer have.
-- The header's profession filter applies to the to-do lists.

local WIDTH = 860
local GAP = 12
local COLUMNS = 3
local ROWS = 2
local TOP = 30
local CARD_WIDTH = (WIDTH - (COLUMNS - 1) * GAP) / COLUMNS
local CARD_HEIGHT = 232
local PROFESSION_LINES = 3
local TODO_LINES = 5
local LINE_HEIGHT = 16
local STALE_DAYS = 14

local Signed = function(c) return addon:FormatSignedMoney(c) end

-- The tier goes before the name, so a long name cut short never hides it
local function ItemText(itemID, name, tier, tierCount)
    local icon = tier and tierCount and (addon:TierIconText(tier, tierCount) .. " ") or ""
    return icon .. (name or (itemID and C_Item.GetItemNameByID(itemID)) or "?")
end

local function TodoText(item)
    return string.format("%dx %s", item.crafts,
        ItemText(item.itemID, item.recipe.outputName, item.row.tier, item.tierCount))
end

-- Profit, with "conc" in front for concentration crafts (on the right, so a
-- long item name cut short never hides it)
local function TodoProfitText(item)
    local profit = addon:Colorize(Signed(item.profit), "profit")
    return item.concentration and (addon:Colorize("conc ", "conc") .. profit) or profit
end

local function DaysAgo(t)
    return t and math.floor((time() - t) / 86400)
end

-- "Online now", "Seen today", "Seen 3 days ago"; stale when it's been long
-- enough that recipes and stats may be out of date
local function SeenText(key, c)
    if key == addon.charKey then return "Online now", "profit" end
    local days = DaysAgo(c.lastSeen)
    if not days then return "Not seen since Goldsmith was installed", "warning" end
    if days >= STALE_DAYS then
        return string.format("Seen %d days ago, log in to refresh", days), "warning"
    end
    if days == 0 then return "Seen today", "muted" end
    return string.format("Seen %d day%s ago", days, days == 1 and "" or "s"), "muted"
end

local function Concentration(key, profession)
    if key == addon.charKey then
        local current, max, minutesToFull = addon:GetConcentration(profession)
        if current then return current, max, minutesToFull end
    end
    local current, max, minutesToFull = addon:GetCharacterConcentration(key, profession)
    return current, max, minutesToFull
end

local function ClassColor(class)
    local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if color then return color.r, color.g, color.b end
    return addon:Color("text")
end

StaticPopupDialogs["GOLDSMITH_REMOVE_CHARACTER"] = {
    text = "Remove %s from Goldsmith?\n\nIts recipes, stats, concentration, stock and gold are forgotten. Its sales and purchases stay in History. If you log in on it again it comes back excluded.",
    button1 = REMOVE or "Remove",
    button2 = CANCEL or "Cancel",
    OnAccept = function(_, key) addon:RemoveCharacter(key) end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

local function ShowCardMenu(card)
    local key, c = card.key, card.data
    if not (key and MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(card, function(_, root)
        root:CreateTitle(c.name or key)
        root:CreateCheckbox("Exclude this character",
            function() return not addon:IsCharacterIncluded(key) end,
            function() addon:SetCharacterIncluded(key, not addon:IsCharacterIncluded(key)) end)
        if key ~= addon.charKey then
            root:CreateButton("Remove from Goldsmith...", function()
                StaticPopup_Show("GOLDSMITH_REMOVE_CHARACTER", c.name or key, nil, key)
            end)
        end
    end)
end

-- Card

local function CreateTodoLine(card, i)
    local line = CreateFrame("Button", nil, card)
    line:SetHeight(LINE_HEIGHT)
    line:SetPoint("TOPLEFT", 10, -(136 + (i - 1) * LINE_HEIGHT))
    line:SetPoint("RIGHT", card, "RIGHT", -10, 0)
    line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    local hover = line:CreateTexture(nil, "HIGHLIGHT")
    hover:SetAllPoints()
    hover:SetColorTexture(addon:Color("hover"))
    line.profit = UI.Text(line, "small", "profit", "RIGHT")
    line.profit:SetPoint("RIGHT", -2, 0)
    line.text = UI.Text(line, "small", "text")
    line.text:SetPoint("LEFT", 2, 0)
    line.text:SetPoint("RIGHT", line.profit, "LEFT", -6, 0)
    line:SetScript("OnClick", function(self, button)
        if button == "RightButton" then
            ShowCardMenu(card)
        elseif self.item then
            local item = self.item
            addon:OpenCraftPlan(item.recipe, item.row, card.key, item.quantity)
        end
    end)
    UI.SetTooltip(line, function(tooltip)
        local item = line.item
        if not item then return end
        tooltip:AddLine(ItemText(item.itemID, item.recipe.outputName, item.row.tier, item.tierCount), 1, 1, 1)
        tooltip:AddDoubleLine("Crafts", tostring(item.crafts), 0.8, 0.8, 0.8, 1, 1, 1)
        tooltip:AddDoubleLine("Makes about", tostring(item.quantity), 0.8, 0.8, 0.8, 1, 1, 1)
        tooltip:AddDoubleLine("Profit", Signed(item.profit), 0.8, 0.8, 0.8, 0.37, 0.81, 0.48)
        local perPoint = item.concentration and item.row.concentrationValue
        if item.concentration then
            tooltip:AddDoubleLine("Concentration", tostring(math.floor(item.concentration + 0.5)),
                0.8, 0.8, 0.8, 0.91, 0.76, 0.35)
        end
        if perPoint then
            -- Extra profit concentrating earns, per point spent; colored by
            -- how good a use of concentration that is
            local r, g, b = addon:Color(addon:ConcentrationValueColor(perPoint))
            tooltip:AddDoubleLine("Gold per concentration", addon:FormatMoney(perPoint),
                0.8, 0.8, 0.8, r, g, b)
        end
        local demand, source = addon:GetDemand(item.itemID, item.recipe.outputName)
        if demand then
            local r, g, b = addon:Color(addon:DemandColor(demand, item.itemID))
            tooltip:AddDoubleLine("Sold per day", string.format("%s (%s)", addon:FormatDemand(demand), source),
                0.8, 0.8, 0.8, r, g, b)
        end
        local saleRate = item.row.saleRate or addon:GetSaleRate(item.itemID)
        if saleRate then
            local r, g, b = addon:Color(addon:SaleRateColor(saleRate))
            tooltip:AddDoubleLine("Sale rate", addon:FormatSaleRate(saleRate) .. " of listings sell",
                0.8, 0.8, 0.8, r, g, b)
        end
        if item.concentration then
            tooltip:AddLine("The best use of this character's concentration right now.", 0.6, 0.6, 0.6, true)
            if perPoint and addon:ConcentrationValueColor(perPoint) == "warning" then
                local r, g, b = addon:Color("warning")
                tooltip:AddLine("A low rate: suggested only because concentration is full or nearly full, so it would go to waste otherwise.",
                    r, g, b, true)
            end
        else
            tooltip:AddLine("How many: " .. (item.why or "?") .. ".", 0.6, 0.6, 0.6, true)
            tooltip:AddLine("Once you've made them it drops off, and comes back when they've all sold.",
                0.6, 0.6, 0.6, true)
        end
        tooltip:AddLine("Click to plan it: materials and shopping list.", 0.37, 0.81, 0.48)
    end)
    return line
end

local function CreateCard(parent)
    local card = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    card:SetSize(CARD_WIDTH, CARD_HEIGHT)
    card:EnableMouse(true)

    card.name = UI.Text(card, "heading")
    card.name:SetPoint("TOPLEFT", 12, -12)
    card.exclude = UI.Checkbox(card, "Exclude", function(checked)
        if card.key then addon:SetCharacterIncluded(card.key, not checked) end
    end)
    card.exclude:SetPoint("TOPRIGHT", -10, -7)
    card.name:SetPoint("RIGHT", card.exclude, "LEFT", -8, 0)
    UI.SetTooltip(card.exclude, function(tooltip)
        tooltip:AddLine("Exclude this character", 1, 1, 1)
        tooltip:AddLine("Leaves it out of Gold in stock, concentration, total gold, the Crafts tab and Do this next: a bank alt, or one you've stopped playing. Its sales still count.",
            0.8, 0.8, 0.8, true)
    end, "ANCHOR_BOTTOM")

    card.seen = UI.Text(card, "small", "muted")
    card.seen:SetPoint("TOPLEFT", card.name, "BOTTOMLEFT", 0, -5)
    card.seen:SetPoint("RIGHT", card, "RIGHT", -12, 0)

    card.professions = {}
    for i = 1, PROFESSION_LINES do
        local name = UI.Text(card, "small", "text")
        name:SetPoint("TOPLEFT", 12, -(56 + (i - 1) * LINE_HEIGHT))
        local conc = UI.Text(card, "small", "conc", "RIGHT")
        conc:SetPoint("TOPRIGHT", -12, -(56 + (i - 1) * LINE_HEIGHT))
        name:SetPoint("RIGHT", conc, "LEFT", -6, 0)
        card.professions[i] = { name = name, conc = conc }
    end

    local divider = UI.Line(card, "border")
    divider:SetHeight(1)
    divider:SetPoint("TOPLEFT", 12, -110)
    divider:SetPoint("TOPRIGHT", -12, -110)

    card.todoTitle = UI.Text(card, "label", "muted")
    card.todoTitle:SetPoint("TOPLEFT", 12, -119)
    card.todoTitle:SetText("TO DO")
    card.total = UI.Text(card, "small", "profit", "RIGHT")
    card.total:SetPoint("TOPRIGHT", -12, -118)

    card.lines = {}
    for i = 1, TODO_LINES do card.lines[i] = CreateTodoLine(card, i) end
    card.message = UI.Text(card, "small", "muted")
    card.message:SetPoint("TOPLEFT", 12, -138)
    card.message:SetPoint("RIGHT", card, "RIGHT", -12, 0)
    card.message:SetWordWrap(true)
    card.message:SetJustifyV("TOP")

    card:SetScript("OnMouseUp", function(self, button)
        if button == "RightButton" then ShowCardMenu(self) end
    end)
    UI.SetTooltip(card, function(tooltip)
        if not card.key then return end
        local c = card.data
        tooltip:AddLine(c.name or card.key, ClassColor(c.class))
        tooltip:AddLine(c.realm or "", 0.6, 0.6, 0.6)
        local todo = card.todo
        if todo and #todo.items > 0 then
            tooltip:AddLine(" ")
            tooltip:AddDoubleLine("To do", Signed(todo.total), 1, 1, 1, 0.37, 0.81, 0.48)
            for _, item in ipairs(todo.items) do
                tooltip:AddDoubleLine(TodoText(item), TodoProfitText(item), 0.9, 0.9, 0.9, 0.37, 0.81, 0.48)
            end
        end
        tooltip:AddLine(" ")
        if card.key ~= addon.charKey then
            tooltip:AddLine("Right-click to leave it out or remove it.", 0.6, 0.6, 0.6, true)
        end
        tooltip:AddLine("Click a to-do line to plan that craft.", 0.37, 0.81, 0.48)
    end)
    return card
end

local function FillCard(card, entry, todo)
    local key, c = entry.key, entry.data
    local included = addon:IsCharacterIncluded(key)
    card.key, card.data, card.todo = key, c, included and todo or nil

    UI.Style(card, key == addon.charKey and "highlight" or "panel",
        key == addon.charKey and "borderGold" or "border")
    card:SetAlpha(included and 1 or 0.6)
    card.name:SetText(c.name or key)
    card.name:SetTextColor(ClassColor(c.class))
    card.exclude:SetChecked(not included)
    local seen, seenColor = SeenText(key, c)
    card.seen:SetText(seen)
    card.seen:SetTextColor(addon:Color(seenColor))

    local names = {}
    for name in pairs(c.professions) do table.insert(names, name) end
    table.sort(names)
    for i, line in ipairs(card.professions) do
        local name = names[i]
        if name then
            local p = c.professions[name]
            line.name:SetText(string.format("%s%s  %s", addon:ProfessionIconText(name), name,
                p.skill and string.format("%d/%d", p.skill, p.maxSkill or 0) or ""))
            local current, max, minutesToFull = Concentration(key, name)
            if current and max and max > 0 then
                line.conc:SetText(string.format("Conc %d/%d%s", current, max,
                    minutesToFull and "" or " full"))
            else
                line.conc:SetText("")
            end
        else
            line.name:SetText(i == 1 and "No crafting professions" or "")
            line.name:SetTextColor(addon:Color(i == 1 and "muted" or "text"))
            line.conc:SetText("")
        end
        if name then line.name:SetTextColor(addon:Color("text")) end
    end

    local items = card.todo and card.todo.items or {}
    card.total:SetText(#items > 0 and Signed(card.todo.total) or "")
    local shown = #items > TODO_LINES and TODO_LINES - 1 or #items
    for i, line in ipairs(card.lines) do
        local item = i <= shown and items[i]
        line.item = item or nil
        if item then
            line.text:SetText(TodoText(item))
            line.text:SetTextColor(addon:Color("text"))
            line.profit:SetText(TodoProfitText(item))
            line:Show()
        elseif i == shown + 1 and #items > shown then
            line.text:SetText(string.format("and %d more (hover the card)", #items - shown))
            line.text:SetTextColor(addon:Color("muted"))
            line.profit:SetText("")
            line:Show()
        else
            line:Hide()
        end
    end

    local message
    if not included then
        message = "Excluded: not counted in stock, concentration, total gold, Crafts or Do this next."
    elseif #items == 0 then
        message = next(c.professions) and "Nothing worth crafting right now."
            or "Nothing to craft. Log in on it and open its professions if it has any."
    end
    card.message:SetText(message or "")
    card.message:SetShown(message ~= nil)
    card:Show()
end

-- View

local function Create(parent)
    local view = { offset = 0 }

    local title = UI.Text(parent, "heading")
    title:SetPoint("TOPLEFT", 0, -4)
    title:SetText("To do by character")
    view.note = UI.Text(parent, "label", "dim")
    view.note:SetPoint("LEFT", title, "RIGHT", 10, -1)
    view.note:SetText("most profit first; click a line to plan it, right-click a card for options")
    view.page = UI.Text(parent, "label", "dim", "RIGHT")
    view.page:SetPoint("TOPRIGHT", 0, -6)

    view.cards = {}
    for i = 1, COLUMNS * ROWS do
        local card = CreateCard(parent)
        local col, row = (i - 1) % COLUMNS, math.floor((i - 1) / COLUMNS)
        card:SetPoint("TOPLEFT", col * (CARD_WIDTH + GAP), -(TOP + row * (CARD_HEIGHT + GAP)))
        view.cards[i] = card
    end

    -- More characters than fit: the mouse wheel moves a row of cards at a time
    parent:EnableMouseWheel(true)
    parent:SetScript("OnMouseWheel", function(_, delta)
        view.offset = view.offset - delta * COLUMNS
        addon.RefreshWindow()
    end)
    return view
end

local function Refresh(view, state)
    local todo = addon:GetCharacterTodo(state.profession)
    -- You first, then the others by name, excluded characters at the bottom
    local list = addon:GetCharacters()
    table.sort(list, function(a, b)
        local ia, ib = addon:IsCharacterIncluded(a.key), addon:IsCharacterIncluded(b.key)
        if ia ~= ib then return ia end
        if (a.key == addon.charKey) ~= (b.key == addon.charKey) then return a.key == addon.charKey end
        return a.key < b.key
    end)
    local maxOffset = math.max(math.ceil((#list - COLUMNS * ROWS) / COLUMNS) * COLUMNS, 0)
    view.offset = math.min(math.max(view.offset, 0), maxOffset)
    for i, card in ipairs(view.cards) do
        local entry = list[view.offset + i]
        if entry then
            FillCard(card, entry, todo[entry.key])
        else
            card.key = nil
            card:Hide()
        end
    end
    view.page:SetText(#list > COLUMNS * ROWS
        and string.format("%d-%d of %d, scroll for more", view.offset + 1,
            math.min(view.offset + COLUMNS * ROWS, #list), #list) or "")
end

-- Clicking the Characters tab again: back to the first cards
local function Reset(view) view.offset = 0 end

addon:RegisterView("characters", { create = Create, refresh = Refresh, reset = Reset })

_G.Goldsmith = addon
