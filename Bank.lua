local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Take out of the bank
--
-- A panel beside the bank listing what your whole queue needs out of it,
-- one item per line, and a Take all button that moves exactly that much
-- into your bags. Forever crafts from your bags only, and the Craft
-- button said "In the bank" for one entry at a time: the next entry's
-- bank items took a second trip (user, 2026-11-10: "i find myself having
-- to go to bank twice ... i just didn't know"). The list is the queue's
-- (Queue.lua's QueueFromBank).

local PANEL_WIDTH = 240
local LINE_HEIGHT = 15
local BAGS = NUM_TOTAL_EQUIPPED_BAG_SLOTS or 5   -- backpack, bags and the reagent bag
-- Between moves, so the slots taken from and put into have unlocked
local MOVE_GAP = 0.3

local panel
local bankOpen = false
local taking            -- the Take all in progress: { moves, taken, short }
local hadItems = false  -- this visit's list wasn't empty: say when it's done
local Update

-- The character's bank containers (not the warband bank)
local function BankBags()
    local list, seen = {}, {}
    for name, bag in pairs(Enum.BagIndex or {}) do
        if name:find("Bank") and not name:find("^Account") and not seen[bag] then
            seen[bag] = true
            table.insert(list, bag)
        end
    end
    table.sort(list)
    return list
end

-- A free bag slot: the bags first, the reagent bag last (it only takes
-- reagents)
local function EmptySlot(taken)
    for bag = 0, BAGS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
            if not taken[bag .. ":" .. slot] and not C_Container.GetContainerItemInfo(bag, slot) then
                return bag, slot
            end
        end
    end
end

-- Bank stacks to take for each item, smallest last so a part of a stack
-- is split from the last one
local function Moves(list)
    local moves = {}
    for _, need in ipairs(list) do
        local left = need.quantity
        for _, bag in ipairs(BankBags()) do
            for slot = 1, C_Container.GetContainerNumSlots(bag) or 0 do
                if left <= 0 then break end
                local info = C_Container.GetContainerItemInfo(bag, slot)
                if info and info.itemID == need.itemID and not info.isLocked then
                    local stack = info.stackCount or 1
                    local take = math.min(stack, left)
                    table.insert(moves, { bag = bag, slot = slot, take = take, whole = take >= stack,
                                          name = need.name })
                    left = left - take
                end
            end
        end
    end
    return moves
end
addon.BankMoves = Moves -- for the bench

-- One stack at a time: picked up from the bank (or split from it) and put
-- in an empty bag slot, then the next once it's had time to land
local function TakeNext(state)
    if taking ~= state then return end
    if not bankOpen then
        taking = nil
        return
    end
    local m = table.remove(state.moves, 1)
    if not m then
        taking = nil
        if #state.short > 0 then
            addon:Notify("info", "Not taken out of the bank: %s.", table.concat(state.short, ", "))
        end
        C_Timer.After(MOVE_GAP, Update)
        return
    end
    local bag, slot = EmptySlot(state.taken)
    if not bag then
        table.insert(state.short, string.format("%d %s (no empty bag slot)", m.take, m.name))
        return TakeNext(state)
    end
    state.taken[bag .. ":" .. slot] = true
    ClearCursor()
    if m.whole then
        C_Container.PickupContainerItem(m.bag, m.slot)
    else
        C_Container.SplitContainerItem(m.bag, m.slot, m.take)
    end
    C_Container.PickupContainerItem(bag, slot)
    ClearCursor()
    C_Timer.After(MOVE_GAP, function() TakeNext(state) end)
end

local function TakeAll(list)
    if taking or addon:TourBlocks("take items out of the bank") then return end
    taking = { moves = Moves(list), taken = {}, short = {} }
    Update()
    TakeNext(taking)
end

-- Beside the game's bank, else (a bag addon's bank window) on its own at
-- the left; dragged somewhere, it stays there (GoldsmithDB.ui2.bankPanel)
local function Place()
    panel:ClearAllPoints()
    local pos = GoldsmithDB.ui2.bankPanel
    if pos then
        panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", pos.x, pos.y)
    elseif BankFrame and BankFrame:IsShown() then
        panel:SetPoint("TOPLEFT", BankFrame, "TOPRIGHT", 4, 0)
    else
        panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -120)
    end
end

local function CreatePanel()
    if panel then return end
    panel = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    panel:SetWidth(PANEL_WIDTH)
    panel:SetFrameStrata("DIALOG")
    UI.Style(panel, "floating", "borderGold")
    panel:EnableMouse(true)
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        GoldsmithDB.ui2.bankPanel = { x = self:GetLeft(), y = self:GetTop() - UIParent:GetTop() }
        Place()
    end)
    panel:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and MenuUtil and MenuUtil.CreateContextMenu then
            MenuUtil.CreateContextMenu(panel, function(_, root)
                root:CreateTitle("Goldsmith")
                root:CreateButton("Put it back by the bank", function()
                    GoldsmithDB.ui2.bankPanel = nil
                    Place()
                end)
            end)
        end
    end)
    UI.SetTooltip(panel, function(tooltip)
        tooltip:AddLine("Goldsmith", 1, 1, 1)
        addon:Explain(tooltip, "What your queue needs from the bank. Drag to move it. Right-click to put it back.",
            0.6, 0.6, 0.6, true)
    end)

    panel.title = UI.Text(panel, "label", "gold")
    panel.title:SetPoint("TOPLEFT", 10, -10)
    panel.title:SetText("GOLDSMITH: BANK")
    panel.move = UI.MoveIcon(panel)
    panel.list = UI.Text(panel, "small", "text")
    panel.list:SetJustifyH("LEFT")
    panel.list:SetWordWrap(true)
    panel.list:SetPoint("TOPLEFT", 10, -30)
    panel.list:SetWidth(PANEL_WIDTH - 20)
    panel.button = UI.Button(panel, "Take all", PANEL_WIDTH - 20, 26, function()
        if panel.items and #panel.items > 0 then TakeAll(panel.items) end
    end)
    UI.SetTooltip(panel.button, function(tooltip)
        tooltip:AddLine("Take all", 1, 1, 1)
        addon:Explain(tooltip, "Moves these into your bags: just what the queue needs, splitting stacks.",
            0.6, 0.6, 0.6, true)
    end, "ANCHOR_RIGHT")
end

Update = function()
    if not panel then return end
    if not bankOpen then
        panel:Hide()
        return
    end
    local items = addon:QueueFromBank(addon:BuildQueue(addon.charKey))
    panel.items = items
    if #items == 0 and not hadItems then
        panel:Hide()
        return
    end
    hadItems = true
    Place()
    local lines = {}
    if #items == 0 then
        table.insert(lines, addon:Colorize("All in your bags.", "profit"))
    else
        table.insert(lines, addon:Colorize("For your queue:", "muted"))
        for _, it in ipairs(items) do table.insert(lines, it.quantity .. " " .. it.name) end
    end
    panel.list:SetText(table.concat(lines, "\n"))
    local y = 30 + math.max(panel.list:GetStringHeight(), LINE_HEIGHT) + 8
    if #items > 0 then
        panel.button:SetLabel(taking and "Taking..." or "Take all")
        panel.button:ClearAllPoints()
        panel.button:SetPoint("TOPLEFT", 10, -y)
        panel.button:Show()
        y = y + 26 + 10
    else
        panel.button:Hide()
    end
    panel:SetHeight(y)
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
for _, event in ipairs({ "BANKFRAME_OPENED", "BANKFRAME_CLOSED", "BAG_UPDATE_DELAYED" }) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event)
    if event == "BANKFRAME_OPENED" then
        if not addon.isForever then return end
        CreatePanel()
        bankOpen, taking, hadItems = true, nil, false
        -- The bank's slots can be read a moment after it opens
        C_Timer.After(0.3, Update)
    elseif event == "BANKFRAME_CLOSED" then
        bankOpen, taking = false, nil
        if panel then panel:Hide() end
    elseif bankOpen and not taking then
        UpdateSoon()
    end
end)

_G.Goldsmith = addon
