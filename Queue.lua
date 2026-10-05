local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Craft queue
--
-- Each character has a queue of crafts: what to make, how many, which
-- tier, with or without concentration. Add from the plan screen ("Add to
-- queue") or by right-clicking a craft on the Crafts tab. Salvage goes in
-- as batches ("prospect 1,000 Umbral Tin Ore"): right-click a salvage row.
-- The queue is planned as a whole: each entry uses what's left of your
-- materials after the ones above it, and one Auctionator list covers
-- everything to buy. Then "Craft next" (the Queue tab, a panel by the
-- profession window, or a key) does one step per press: mill, make the
-- materials, then the craft, going through the queue in order, starting
-- with the profession that's open. A craft leaves the queue once enough are
-- made (counted from craft results, so multicraft extras count); a batch
-- once that many items are salvaged.
--
-- Saved in GoldsmithDB.queues[charKey] = list of { recipeID, quantity,
-- made, tier, concentrate, added } for crafts, or { salvageID, quantity
-- (items to salvage), made, added } for salvage batches.
-- The panel's position: GoldsmithDB.ui2.queuePanel = { x, y } from the
-- profession window's top left (nil: under it, right edges lined up).

local AH_CUT = 0.05
local PANEL_WIDTH = 280
local PANEL_LINES = 8
local LINE_HEIGHT = 16
local DEFAULT_BATCH = 500

local function Queue(charKey, create)
    GoldsmithDB.queues = GoldsmithDB.queues or {}
    local q = GoldsmithDB.queues[charKey]
    if not q and create then
        q = {}
        GoldsmithDB.queues[charKey] = q
    end
    return q
end

local function CharName(charKey)
    local c = GoldsmithDB.characters[charKey]
    return (c and c.name) or (charKey and charKey:match("^[^%-]+")) or "?"
end
addon.QueueCharName = CharName

local UpdateSoon -- defined below

local function Changed()
    UpdateSoon()
    if addon.Refresh then addon.Refresh() end
end

function addon:GetQueue(charKey)
    return Queue(charKey) or {}
end

-- Characters with something queued, you first
function addon:GetQueuedCharacters()
    local keys = {}
    for key, entries in pairs(GoldsmithDB.queues or {}) do
        if #entries > 0 and key ~= addon.charKey then table.insert(keys, key) end
    end
    table.sort(keys)
    table.insert(keys, 1, addon.charKey)
    return keys
end

local function Same(e, recipeID, tier, concentrate, salvageID)
    if salvageID then return e.salvageID == salvageID end
    return e.recipeID ~= nil and e.recipeID == recipeID and e.tier == tier
        and (e.concentrate == true) == (concentrate == true)
end

-- The queued craft (recipe, tier, concentration) or salvage batch
-- (salvageID = the item salvaged), or nil
function addon:FindQueueEntry(charKey, recipeID, tier, concentrate, salvageID)
    for _, e in ipairs(Queue(charKey) or {}) do
        if Same(e, recipeID, tier, concentrate, salvageID) then return e end
    end
end

-- Queues `quantity` of a craft, or, if it's already queued the same way,
-- sets it to make `quantity` more from now. Returns true when it was
-- already queued.
function addon:AddToQueue(charKey, recipeID, quantity, tier, concentrate)
    local e = addon:FindQueueEntry(charKey, recipeID, tier, concentrate)
    if e then
        e.quantity, e.made = quantity, 0
    else
        table.insert(Queue(charKey, true), { recipeID = recipeID, quantity = quantity, made = 0, tier = tier,
                                             concentrate = concentrate == true, added = time() })
    end
    Changed()
    return e ~= nil
end

-- Same for a salvage batch: `quantity` items to salvage
function addon:AddSalvageToQueue(charKey, itemID, quantity)
    local e = addon:FindQueueEntry(charKey, nil, nil, nil, itemID)
    if e then
        e.quantity, e.made = quantity, 0
    else
        table.insert(Queue(charKey, true), { salvageID = itemID, quantity = quantity, made = 0, added = time() })
    end
    GoldsmithDB.ui2.salvageBatch = GoldsmithDB.ui2.salvageBatch or {}
    GoldsmithDB.ui2.salvageBatch[itemID] = quantity
    Changed()
    return e ~= nil
end

-- Asks how many to salvage, then queues the batch
local function PopupBox(popup)
    return popup.GetEditBox and popup:GetEditBox() or popup.editBox
end

local function AcceptBatch(popup, data)
    data = data or popup.data
    local n = tonumber(PopupBox(popup):GetText())
    if data and n and n > 0 then
        addon:AddSalvageToQueue(data.charKey, data.itemID, n)
        addon:Notify("info", "Queued: %s %d %s for %s.", data.verb, n, data.name, CharName(data.charKey))
    end
end

StaticPopupDialogs["GOLDSMITH_SALVAGE_BATCH"] = {
    text = "%s",
    button1 = OKAY or "OK",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    OnShow = function(self, data)
        data = data or self.data
        local box = PopupBox(self)
        box:SetNumeric(true)
        box:SetText(tostring(data and data.quantity or DEFAULT_BATCH))
        box:HighlightText()
        box:SetFocus()
    end,
    OnAccept = AcceptBatch,
    EditBoxOnEnterPressed = function(box, data)
        local popup = box:GetParent()
        AcceptBatch(popup, data)
        popup:Hide()
    end,
    EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function addon:AskSalvageBatch(charKey, itemID, name, verb)
    local queued = addon:FindQueueEntry(charKey, nil, nil, nil, itemID)
    local remembered = GoldsmithDB.ui2.salvageBatch and GoldsmithDB.ui2.salvageBatch[itemID]
    local quantity = queued and math.max(queued.quantity - (queued.made or 0), 1) or remembered or DEFAULT_BATCH
    StaticPopup_Show("GOLDSMITH_SALVAGE_BATCH",
        string.format("How many %s to %s? (for %s)", name, (verb or "salvage"):lower(), CharName(charKey)), nil,
        { charKey = charKey, itemID = itemID, name = name, verb = verb or "Salvage", quantity = quantity })
end

function addon:RemoveQueueEntry(charKey, entry)
    local q = Queue(charKey) or {}
    for i, e in ipairs(q) do
        if e == entry then table.remove(q, i) break end
    end
    Changed()
end

-- delta -1 moves it up, 1 down
function addon:MoveQueueEntry(charKey, entry, delta)
    local q = Queue(charKey) or {}
    for i, e in ipairs(q) do
        local j = i + delta
        if e == entry and q[j] then
            q[i], q[j] = q[j], q[i]
            break
        end
    end
    Changed()
end

function addon:ClearQueue(charKey)
    if GoldsmithDB.queues then GoldsmithDB.queues[charKey] = nil end
    Changed()
end

-- Counts toward the first matching entry on this character; it leaves
-- the queue once its quantity is reached
local function Progress(match, quantity, describe)
    local q = Queue(addon.charKey)
    if not q then return end
    for i, e in ipairs(q) do
        if match(e) then
            e.made = (e.made or 0) + (quantity or 0)
            if e.made >= e.quantity then
                table.remove(q, i)
                addon:Notify("info", "Queue: %s, done.", describe(e))
                if #q == 0 then addon:Notify("info", "Queue: everything's crafted.") end
            end
            Changed()
            return
        end
    end
end

-- A craft finished (Pricing.lua's craft result)
function addon:QueueCrafted(recipeID, quantity)
    Progress(function(e) return e.recipeID == recipeID end, quantity, function(e)
        local recipe = GoldsmithDB.recipes[recipeID]
        return string.format("made %d %s", e.made, recipe and recipe.outputName or "items")
    end)
end

-- Items used up by salvaging (Milling.lua, as bags change)
function addon:QueueSalvaged(itemID, used)
    Progress(function(e) return e.salvageID == itemID end, used, function(e)
        return string.format("salvaged %d %s", e.made, C_Item.GetItemNameByID(itemID) or "items")
    end)
end

-- Planning

local function Merge(map, entry)
    local m = map[entry.itemID]
    if not m then
        m = { itemID = entry.itemID, name = entry.name, quantity = 0, cost = 0, unit = entry.unit,
              qualityTier = entry.qualityTier, tierCount = entry.tierCount }
        map[entry.itemID] = m
    end
    m.quantity = m.quantity + entry.quantity
    m.cost = m.cost + (entry.cost or 0)
    m.live = m.live or entry.live
    m.short = m.short or entry.short
end

local function Sorted(map)
    local list = {}
    for _, m in pairs(map) do table.insert(list, m) end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- A salvage batch as a plan: buy what you don't have of the input; cost,
-- worth and profit from the salvage row's yields (GetSalvageRows), scaled
-- to the batch. Resourcefulness stretches the input, so the batch gets
-- through more salvages than items ÷ items per salvage.
local function SalvagePlan(row, salvageRows, useOnHand, pool)
    local itemID, remaining = row.entry.salvageID, row.remaining
    local found = salvageRows[itemID]
    local s = found and found.salvage
    local name = (s and s.inputName) or C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
    row.verb = found and found.recipe.outputName:match("^(%S+)") or "Salvage"
    row.inputName = name
    row.recipe = { outputName = row.verb .. " " .. name,
                   profession = found and found.recipe.profession or (GoldsmithDB.milling[itemID] or {}).profession }
    row.salvageRow = found

    local have = 0
    if useOnHand then
        have = math.max((C_Item.GetItemCount(itemID, true, false, true, true) or 0) - (pool[itemID] or 0), 0)
        have = math.min(have, remaining)
        pool[itemID] = (pool[itemID] or 0) + have
    end
    local perCast = s and s.perCast or 1
    local casts = remaining / math.max(s and s.inputPerCast or perCast, 0.01)
    local plan = { salvage = true, crafts = math.ceil(remaining / perCast - 0.0001), casts = casts, have = have,
                   buyAH = {}, buyVendor = {}, cost = 0, complete = false, outputs = {} }
    local unit = s and s.unitPrice
    if unit then
        plan.cost = unit * remaining
        if remaining > have then
            table.insert(plan.buyAH, { itemID = itemID, name = name, quantity = remaining - have, unit = unit,
                                       cost = unit * (remaining - have) })
        end
    end
    if found and found.info.price and unit then
        plan.revenue = found.info.price * (1 - AH_CUT) * casts
        plan.profit = plan.revenue - plan.cost
        plan.complete = not found.info.partial
    end
    for _, o in ipairs(s and s.outputs or {}) do
        table.insert(plan.outputs, { itemID = o.itemID, name = o.name, quantity = o.perCast * casts,
                                     value = o.unit and o.unit * o.perCast * casts })
    end
    return plan
end

-- The whole queue planned in order. Returns { charKey, mine, rows = { {
-- entry, recipe, remaining, p, tierInfo, plan, state } }, cost, revenue,
-- profit, complete, buyAH, buyVendor, spend, listName, listKey }.
-- Another character's queue is planned without what you have (only their
-- own bags count, and those aren't known here) and has no craft states.
function addon:BuildQueue(charKey)
    local mine = charKey == addon.charKey
    local useOnHand = mine and GoldsmithDB.ui2.planUseOnHand ~= false
    local pool = {}
    local q = { charKey = charKey, mine = mine, rows = {}, cost = 0, revenue = 0, profit = 0, complete = true,
                listName = "Goldsmith: Queue (" .. CharName(charKey) .. ")", listKey = "queue:" .. charKey }
    local ah, vendor = {}, {}
    local salvageRows
    for _, e in ipairs(Queue(charKey) or {}) do
        local row = { entry = e, remaining = math.max(e.quantity - (e.made or 0), 0) }
        local plan
        if e.salvageID and row.remaining > 0 then
            if not salvageRows then
                salvageRows = {}
                for _, r in ipairs(addon:GetSalvageRows("All", {})) do salvageRows[r.itemID] = r end
            end
            plan = SalvagePlan(row, salvageRows, useOnHand, pool)
            if mine then
                row.state = addon.SalvageState(e.salvageID, row.inputName, row.remaining, row.verb)
            end
        else
            row.recipe = e.recipeID and GoldsmithDB.recipes[e.recipeID]
            if row.recipe and row.remaining > 0 then
                row.p = { recipe = row.recipe, charKey = charKey, tier = e.tier, concentrate = e.concentrate }
                row.tierInfo = addon:WithCharacter(charKey, addon.FindTierInfo, row.p)
                plan = addon:WithCharacter(charKey, addon.BuildPlan, addon, row.recipe, row.remaining, useOnHand,
                    row.tierInfo, pool)
                if mine then row.state = addon.GetCraftState(row.p, row.tierInfo, plan) end
            end
        end
        row.plan = plan
        if plan then
            q.cost = q.cost + plan.cost
            if not plan.complete then q.complete = false end
            if plan.revenue then
                q.revenue = q.revenue + plan.revenue
                q.profit = q.profit + plan.profit
            else
                q.complete = false
            end
            for _, entry in ipairs(plan.buyAH) do Merge(ah, entry) end
            for _, entry in ipairs(plan.buyVendor) do Merge(vendor, entry) end
        end
        table.insert(q.rows, row)
    end
    q.buyAH, q.buyVendor = Sorted(ah), Sorted(vendor)
    q.spend = 0
    for _, entry in ipairs(q.buyAH) do q.spend = q.spend + entry.cost end
    return q
end

-- Materials across the queue with a missing or old AH price
function addon:QueueStalePrices(q)
    local seen, stale = {}, {}
    local function Add(itemID)
        if seen[itemID] then return end
        seen[itemID] = true
        table.insert(stale, { itemID = itemID })
    end
    for _, row in ipairs(q.rows) do
        local plan = row.plan
        if plan and plan.salvage then
            -- The input and what comes out
            local ids = { row.entry.salvageID }
            for _, o in ipairs(plan.outputs) do table.insert(ids, o.itemID) end
            for _, itemID in ipairs(ids) do
                local price, source, age = addon:GetAHPriceInfo(itemID)
                if not price or ((source == "Auctionator" or source == "Blizzard") and (age or 0) >= 1) then
                    Add(itemID)
                end
            end
        elseif plan then
            for _, item in ipairs(addon.StalePrices(plan)) do Add(item.itemID) end
        end
    end
    return stale
end

-- A queued entry's name, with tier icon
function addon:QueueRowName(row)
    local name = row.recipe and row.recipe.outputName
        or (row.entry.recipeID and ("recipe " .. row.entry.recipeID)) or "?"
    local icon = row.tierInfo and (addon:TierIconText(row.tierInfo.tier, row.tierInfo.tierCount) .. " ") or ""
    return icon .. name
end

-- A short status for a queued entry and its color: what Craft next would
-- do for it, or why it can't
function addon:QueueRowStatus(row, q)
    if not row.recipe then return "recipe not loaded", "warning" end
    if not q.mine then return "on " .. CharName(q.charKey), "muted" end
    local s = row.state
    if not s then return "", "muted" end
    if s.enabled and s.open then return s.label, "muted" end
    if s.enabled then return s.label, "profit" end
    local blocker = s.blockers[1] or ""
    local station = blocker:match("^Needs (.+) nearby")
    if station then
        return "needs " .. station, "warning"
    elseif blocker:find("^Missing") or blocker:find("^Not enough") and not blocker:find("concentration") then
        return "needs materials", "warning"
    elseif blocker:find("concentration") then
        return "needs concentration", "warning"
    elseif blocker:find("^Open") then
        return blocker:match("^(Open %S+)") or "open profession", "muted"
    elseif blocker:find("bank") then
        return "in the bank", "warning"
    end
    return "can't craft yet", "warning"
end

-- What the Craft next button says for the entry it's on: the step, or why
-- it can't ("Needs Alchemist's Lab Bench")
function addon:QueueButtonLabel(row, q)
    if addon.QueueBusy() then return "Crafting..." end
    local s = row and row.state
    if not s then return "Craft next" end
    if s.enabled then return s.label end
    local status = addon:QueueRowStatus(row, q)
    return (status:gsub("^%l", string.upper))
end

-- The entry Craft next would work on: the first one ready to craft (or
-- salvage) with the profession that's open, else the first that needs a
-- profession opened, else the first that's stuck (for its reason)
function addon:QueueNextRow(q)
    local open, stuck
    for _, row in ipairs(q.rows) do
        local s = row.state
        if s then
            if s.enabled and not s.open then return row end
            if s.enabled then open = open or row else stuck = stuck or row end
        end
    end
    return open or stuck
end

-- Crafting in progress (a batch still casting)
local function Busy()
    if C_TradeSkillUI.IsRecipeRepeating and C_TradeSkillUI.IsRecipeRepeating() then return true end
    return UnitCastingInfo("player") ~= nil
end
addon.QueueBusy = Busy

-- One step of the queue: from a click or the key binding (the game only
-- crafts from one)
function addon:CraftNext()
    if Busy() then return end
    local q = addon:BuildQueue(addon.charKey)
    if #q.rows == 0 then
        addon:Notify("info", "Nothing in the queue.")
        return
    end
    local row = addon:QueueNextRow(q)
    if not row then
        addon:Notify("info", "Nothing in the queue can be crafted yet.")
        return
    end
    if not row.state.enabled then
        addon:Notify("info", "%s: %s", row.recipe.outputName, row.state.blockers[1] or "can't craft yet")
        return
    end
    addon.PerformCraftState(row.state, row.recipe, UpdateSoon)
end

-- Panel by the profession window

local panel

local function PanelLine(i)
    local line = CreateFrame("Frame", nil, panel)
    line:SetHeight(LINE_HEIGHT)
    line:SetPoint("TOPLEFT", 10, -(30 + (i - 1) * LINE_HEIGHT))
    line:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
    line.status = UI.Text(line, "small", "muted", "RIGHT")
    line.status:SetPoint("RIGHT")
    line.text = UI.Text(line, "small", "text")
    line.text:SetPoint("LEFT")
    line.text:SetPoint("RIGHT", line.status, "LEFT", -6, 0)
    return line
end

local function KeyText()
    local key = GetBindingKey and GetBindingKey("GOLDSMITH_CRAFT_NEXT")
    return key and GetBindingText and GetBindingText(key) or key
end

-- Saved spot (dragged there), or under the profession window with the
-- right edges lined up
local function PlacePanel()
    panel:ClearAllPoints()
    local pos = GoldsmithDB.ui2.queuePanel
    if pos then
        panel:SetPoint("TOPLEFT", ProfessionsFrame, "TOPLEFT", pos.x, pos.y)
    else
        panel:SetPoint("TOPRIGHT", ProfessionsFrame, "BOTTOMRIGHT", 0, -4)
    end
end

local function PanelMenu()
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(panel, function(_, root)
        root:CreateTitle("Goldsmith queue")
        root:CreateButton("Open the Queue tab", function() addon:ShowTab("queue") end)
        root:CreateButton("Put it back under the profession window", function()
            GoldsmithDB.ui2.queuePanel = nil
            PlacePanel()
        end)
    end)
end

local function CreatePanel()
    if panel or not ProfessionsFrame then return end
    panel = CreateFrame("Frame", nil, ProfessionsFrame, "BackdropTemplate")
    panel:SetWidth(PANEL_WIDTH)
    UI.Style(panel, "panel", "borderGold")
    panel:EnableMouse(true)

    -- Drag it anywhere; it stays put relative to the profession window
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        GoldsmithDB.ui2.queuePanel = { x = self:GetLeft() - ProfessionsFrame:GetLeft(),
                                       y = self:GetTop() - ProfessionsFrame:GetTop() }
        PlacePanel()
    end)
    panel:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then PanelMenu() end
    end)
    PlacePanel()

    panel.title = UI.Text(panel, "label", "gold")
    panel.title:SetPoint("TOPLEFT", 10, -10)
    panel.title:SetText("GOLDSMITH QUEUE")
    panel.open = UI.IconButton(panel, 18, ">", "Open the Queue tab", function() addon:ShowTab("queue") end,
        { font = "small" })
    panel.open:SetPoint("TOPRIGHT", -6, -6)
    UI.SetTooltip(panel, function(tooltip)
        tooltip:AddLine("Goldsmith queue", 1, 1, 1)
        tooltip:AddLine("Drag to move it. Right-click to put it back or open the Queue tab.", 0.6, 0.6, 0.6, true)
    end)

    panel.lines = {}
    for i = 1, PANEL_LINES do panel.lines[i] = PanelLine(i) end

    panel.button = UI.Button(panel, "Craft next", PANEL_WIDTH - 20, 28, function(_, mouseButton)
        if mouseButton == "RightButton" then addon:ShowTab("queue") else addon:CraftNext() end
    end)
    panel.button:SetPoint("BOTTOMLEFT", 10, 24)
    UI.Style(panel.button, "highlight", "borderGold")
    panel.button.label:SetTextColor(addon:Color("gold"))
    panel.button:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderGold")) end)
    panel.hint = UI.Text(panel, "small", "dim", "CENTER")
    panel.hint:SetPoint("BOTTOMLEFT", 10, 8)
    panel.hint:SetPoint("BOTTOMRIGHT", -10, 8)

    UI.SetTooltip(panel.button, function(tooltip)
        local row = panel.row
        tooltip:AddLine("Craft next", 1, 1, 1)
        tooltip:AddLine("One step per click: mill, make materials, then the craft, down the queue.", 0.8, 0.8, 0.8, true)
        if row and row.state then
            tooltip:AddLine(" ")
            tooltip:AddLine(row.recipe.outputName, addon:Color("gold"))
            for i, step in ipairs(row.state.steps or {}) do
                local r, g, b = 0.6, 0.6, 0.6
                if i == 1 then r, g, b = addon:Color("gold") end
                tooltip:AddLine(string.format("    %d. %s", i, step), r, g, b)
            end
            for _, line in ipairs(row.state.notes) do tooltip:AddLine(line, 0.8, 0.8, 0.8, true) end
            for _, line in ipairs(row.state.blockers) do tooltip:AddLine(line, 1, 0.6, 0.2, true) end
        end
        tooltip:AddLine(" ")
        tooltip:AddLine(KeyText() and ("Key: " .. KeyText()) or "Set a key: Options > Keybindings > AddOns > Goldsmith.",
            0.6, 0.6, 0.6, true)
        tooltip:AddLine("Right-click for the Queue tab.", 0.6, 0.6, 0.6)
    end, "ANCHOR_BOTTOM")
end

local syncedKey

local function UpdatePanel()
    if not (ProfessionsFrame and ProfessionsFrame:IsShown()) then return end
    CreatePanel()
    if not panel then return end
    local entries = Queue(addon.charKey)
    if not entries or #entries == 0 then
        panel:Hide()
        return
    end
    local q = addon:BuildQueue(addon.charKey)
    local row = addon:QueueNextRow(q)
    panel.row = row

    local shown = math.min(#q.rows, PANEL_LINES)
    for i, line in ipairs(panel.lines) do
        local r = q.rows[i]
        if r and i <= shown then
            line.text:SetText(string.format("%dx %s", r.remaining, addon:QueueRowName(r)))
            line.text:SetTextColor(addon:Color(r == row and "gold" or "text"))
            local status, color = addon:QueueRowStatus(r, q)
            line.status:SetText(status)
            line.status:SetTextColor(addon:Color(color))
            line:Show()
        else
            line:Hide()
        end
    end
    if #q.rows > PANEL_LINES then
        local last = panel.lines[PANEL_LINES]
        last.text:SetText(string.format("and %d more", #q.rows - PANEL_LINES + 1))
        last.text:SetTextColor(addon:Color("muted"))
        last.status:SetText("")
    end
    panel:SetHeight(30 + shown * LINE_HEIGHT + 64)

    local busy = Busy()
    local state = row and row.state
    local enabled = not busy and state ~= nil and state.enabled == true
    panel.button:SetLabel(addon:QueueButtonLabel(row, q))
    panel.button:SetEnabled(enabled)
    panel.button:SetAlpha(enabled and 1 or 0.5)
    panel.hint:SetText(KeyText() and ("or press " .. KeyText()) or "set a key in Keybindings > AddOns")
    panel:Show()

    -- Show the next craft in the profession window, once per change (never
    -- mid-craft)
    if not busy and state and state.enabled and state.reagents and not state.open then
        local recipeID = state.recipeID or row.recipe.recipeID
        local parts = { recipeID, tostring(state.concentrate), state.crafts or 0 }
        for _, e in ipairs(state.reagents) do table.insert(parts, e.reagent.itemID .. "x" .. e.quantity) end
        local key = table.concat(parts, "|")
        if key ~= syncedKey then
            syncedKey = key
            addon.SyncProfessionWindow(recipeID, state)
        end
    end
end

-- Bags, professions, concentration and casting all change what Craft next
-- does; a short wait groups bursts of updates
local updatePending = false
UpdateSoon = function()
    if updatePending then return end
    updatePending = true
    C_Timer.After(0.3, function()
        updatePending = false
        UpdatePanel()
        if addon.window and addon.window:IsShown() and GoldsmithDB.ui2.tab == "queue" and addon.RefreshWindow then
            addon.RefreshWindow()
        end
    end)
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "BAG_UPDATE_DELAYED", "CURRENCY_DISPLAY_UPDATE" }) do
    events:RegisterEvent(event)
end
for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_INTERRUPTED" }) do
    events:RegisterUnitEvent(event, "player")
end
events:SetScript("OnEvent", function(_, event)
    if event == "TRADE_SKILL_CLOSE" then syncedKey = nil end
    UpdateSoon()
end)

_G.Goldsmith = addon
