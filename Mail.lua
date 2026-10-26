local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Mail to your other characters
--
-- A panel beside the mailbox listing what to send to whom, with a button
-- per character: the first click fills in a mail (recipient, subject, the
-- items, stacks split to the right count), the second sends it (user,
-- 2026-10-24: "are we able to help automate this part? the sending of
-- items?"). What to send is Shop.lua's MailJobs: what Buy next bought
-- here for their queue, and what their queue would buy that you hold. The
-- SendMail hook in Shop.lua records it as in their mail, so their plans
-- count it at once.

local PANEL_WIDTH = 280
local JOBS = 4
local LINE_HEIGHT = 16
local SUBJECT = "Goldsmith: for your queue"
local BAGS = NUM_TOTAL_EQUIPPED_BAG_SLOTS or 5   -- backpack, bags and the reagent bag

local panel
local jobs = {}
local filled            -- the job whose mail is filled in, waiting for Send
local sending = false

local Update

-- TSM's mailbox replaces the game's: it hides MailFrame and shows its own
-- window, which has no name to sit beside, so the panel showed nothing
-- (user, 2026-10-24: "i don't see anything when i open the mail box").
-- Then the panel stands on its own at the left, above TSM's window.
local function TSMMailShown()
    if not (TSM_API and TSM_API.IsUIVisible) then return false end
    local ok, shown = pcall(TSM_API.IsUIVisible, "MAILING")
    return ok and shown == true
end

local function MailboxShown()
    return (MailFrame and MailFrame:IsShown()) or TSMMailShown()
end

-- The game's send tab, or with TSM's window up, a mail made through the
-- game's functions (they work without its window)
local function SendTabShown()
    if TSMMailShown() and not (MailFrame and MailFrame:IsShown()) then return true end
    return SendMailFrame and SendMailFrame:IsShown()
end

-- Dragged somewhere (user, 2026-10-24: "make the goldsmith mail window
-- draggable and then persists in that spot"): GoldsmithDB.ui2.mailPanel =
-- { x, y } from the screen's top left, the same spot with either mailbox.
-- Right-click puts it back.
local placedBy
local function Place(force)
    local by = (MailFrame and MailFrame:IsShown()) and "game" or "tsm"
    if by == placedBy and not force then return end
    placedBy = by
    panel:ClearAllPoints()
    if by == "game" then
        panel:SetParent(MailFrame)
        UI.RaiseAbove(panel, MailFrame)
    else
        panel:SetParent(UIParent)
        -- TSM's window is HIGH
        panel:SetFrameStrata("DIALOG")
    end
    local pos = GoldsmithDB.ui2.mailPanel
    if pos then
        local scale = UIParent:GetEffectiveScale() / panel:GetEffectiveScale()
        panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", pos.x * scale, pos.y * scale)
    elseif by == "game" then
        panel:SetPoint("TOPLEFT", MailFrame, "TOPRIGHT", 4, 0)
    else
        panel:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 20, -120)
    end
end

local function MakeMovable()
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        -- In the screen's measure, whatever the panel's parent
        local scale = self:GetEffectiveScale() / UIParent:GetEffectiveScale()
        GoldsmithDB.ui2.mailPanel = { x = self:GetLeft() * scale, y = (self:GetTop() * scale) - UIParent:GetTop() }
        Place(true)
    end)
    panel:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and MenuUtil and MenuUtil.CreateContextMenu then
            MenuUtil.CreateContextMenu(panel, function(_, root)
                root:CreateTitle("Goldsmith")
                root:CreateButton("Put it back by the mailbox", function()
                    GoldsmithDB.ui2.mailPanel = nil
                    Place(true)
                end)
            end)
        end
    end)
    UI.SetTooltip(panel, function(tooltip)
        tooltip:AddLine("Goldsmith", 1, 1, 1)
        addon:Explain(tooltip, "Drag to move it. Right-click to put it back.", 0.6, 0.6, 0.6, true)
    end)
end

local function AttachmentCount()
    local n = 0
    for i = 1, ATTACHMENTS_MAX_SEND or 12 do
        if GetSendMailItem(i) then n = n + 1 end
    end
    return n
end

-- One item's whole stacks onto the mail now; a part of a stack is left in
-- `splits` for SplitNext. `used` marks attachment slots taken this time
-- (the game fills them a moment later). Returns how many were attached
-- or set to be.
local function Attach(itemID, quantity, name, used, splits)
    local left = quantity
    for bag = 0, BAGS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            if left <= 0 then return quantity end
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and not info.isLocked then
                local index
                for i = 1, ATTACHMENTS_MAX_SEND or 12 do
                    if not used[i] and not GetSendMailItem(i) then index = i break end
                end
                if not index then return quantity - left end
                used[index] = true
                local take = math.min(info.stackCount, left)
                if take == info.stackCount then
                    C_Container.PickupContainerItem(bag, slot)
                    ClickSendMailItemButton(index)
                    ClearCursor()
                else
                    table.insert(splits, { itemID = itemID, name = name, take = take, bag = bag, slot = slot, index = index })
                end
                left = left - take
            end
        end
    end
    return quantity - left
end

-- A free bag slot for a split stack: the bags first, the reagent bag last
-- (it only takes reagents)
local function EmptySlot(taken)
    for bag = 0, BAGS do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            if not taken[bag .. ":" .. slot] and not C_Container.GetContainerItemInfo(bag, slot) then
                return bag, slot
            end
        end
    end
end

-- Part of a stack: split it into an empty bag slot, wait for it to land,
-- then attach that stack. Attached straight from the split, the game puts
-- in the whole stack it came from: 7 Azeroot went into the mail for 3
-- (user, 2026-10-24).
local SPLIT_WAIT, SPLIT_CHECK = 3, 0.1
local splitting -- the fill waiting on split stacks: { job, splits, short, taken }

local function FillDone(state)
    splitting = nil
    if #state.short > 0 then
        addon:Notify("info", "Not put in the mail: %s.", table.concat(state.short, ", "))
    end
    filled = state.job
    C_Timer.After(0.3, Update)
end

local function SplitNext(state)
    local s = table.remove(state.splits, 1)
    if not s then return FillDone(state) end
    local bag, slot = EmptySlot(state.taken)
    if not bag then
        table.insert(state.short, string.format("%d %s (no empty bag slot to split a stack into)", s.take, s.name))
        return SplitNext(state)
    end
    state.taken[bag .. ":" .. slot] = true
    C_Container.SplitContainerItem(s.bag, s.slot, s.take)
    C_Container.PickupContainerItem(bag, slot)
    ClearCursor()
    local waited = 0
    local function Check()
        if splitting ~= state then return end
        if not MailboxShown() then
            splitting = nil
            return
        end
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.itemID == s.itemID and info.stackCount == s.take and not info.isLocked then
            C_Container.PickupContainerItem(bag, slot)
            ClickSendMailItemButton(s.index)
            ClearCursor()
            return SplitNext(state)
        end
        waited = waited + SPLIT_CHECK
        if waited >= SPLIT_WAIT then
            ClearCursor()
            table.insert(state.short, string.format("%d %s (the split stack didn't arrive; try again)", s.take, s.name))
            return SplitNext(state)
        end
        C_Timer.After(SPLIT_CHECK, Check)
    end
    C_Timer.After(SPLIT_CHECK, Check)
end

-- First click: the mail, filled in
local function Fill(job)
    if addon:TourBlocks("fill in a mail") then return end
    if splitting then return end
    if not SendTabShown() and MailFrameTab2 and MailFrame:IsShown() then MailFrameTab2:Click() end
    if AttachmentCount() > 0 and filled ~= job then
        addon:Notify("info", "Mail isn't empty: send or clear it first.")
        return
    end
    SendMailNameEditBox:SetText(job.name)
    SendMailSubjectEditBox:SetText(SUBJECT)
    local used, splits, short = {}, {}, {}
    for _, it in ipairs(job.items) do
        local attached = Attach(it.itemID, it.quantity, it.name, used, splits)
        if attached < it.quantity then
            table.insert(short, string.format("%d %s (not in your bags, or the mail is full)", it.quantity - attached, it.name))
        end
    end
    local state = { job = job, splits = splits, short = short, taken = {} }
    if #splits == 0 then return FillDone(state) end
    splitting = state
    Update()
    SplitNext(state)
end

-- Second click: send it
local function Send(job)
    if AttachmentCount() == 0 then
        filled = nil
        Update()
        return
    end
    sending = true
    SendMail(job.name, SendMailSubjectEditBox:GetText() ~= "" and SendMailSubjectEditBox:GetText() or SUBJECT, "")
    Update()
end

-- "3 [gold icon] Azeroot": the quality, since both are named Azeroot
local function ItemText(itemID, quantity, name)
    local tier, tierCount = addon:GetItemTier(itemID)
    local icon = tier and (addon:TierIconText(tier, tierCount) .. " ") or ""
    return string.format("%d %s%s", quantity, icon, name or C_Item.GetItemNameByID(itemID) or ("item " .. itemID))
end

local function JobText(job)
    local parts = {}
    for _, it in ipairs(job.items) do table.insert(parts, ItemText(it.itemID, it.quantity, it.name)) end
    return table.concat(parts, ", ")
end

-- What the mail holds now, as the game reports it: to check before
-- sending. With TSM's mailbox the game's send window is hidden behind it
-- (user, 2026-10-24: "the mailbox didn't change so i cant verify anything
-- before i send").
local function AttachedText()
    local counts, order = {}, {}
    for i = 1, ATTACHMENTS_MAX_SEND or 12 do
        local name, itemID, _, count = GetSendMailItem(i)
        if itemID and count then
            if not counts[itemID] then
                counts[itemID] = { n = 0, name = name }
                table.insert(order, itemID)
            end
            counts[itemID].n = counts[itemID].n + count
        end
    end
    local parts = {}
    for _, itemID in ipairs(order) do table.insert(parts, ItemText(itemID, counts[itemID].n, counts[itemID].name)) end
    return #parts > 0 and table.concat(parts, ", ") or nil
end

-- Right-click on a filled-in mail's button: the items back to the bags
local function TakeOut()
    for i = 1, ATTACHMENTS_MAX_SEND or 12 do
        if GetSendMailItem(i) then ClickSendMailItemButton(i, true) end
    end
    filled = nil
    C_Timer.After(0.3, Update)
end

local function CreatePanel()
    if panel or not MailFrame then return end
    panel = CreateFrame("Frame", nil, MailFrame, "BackdropTemplate")
    panel:SetWidth(PANEL_WIDTH)
    UI.Style(panel, "panel", "borderGold")
    panel:EnableMouse(true)
    MakeMovable()

    panel.title = UI.Text(panel, "label", "gold")
    panel.title:SetPoint("TOPLEFT", 10, -10)
    panel.title:SetText("GOLDSMITH: MAIL")
    panel.move = UI.MoveIcon(panel)

    panel.rows = {}
    for i = 1, JOBS do
        local row = {}
        row.text = UI.Text(panel, "small", "text")
        row.text:SetJustifyH("LEFT")
        row.text:SetWordWrap(true)
        row.button = UI.Button(panel, "", PANEL_WIDTH - 20, 26, function(_, mouseButton)
            local job = jobs[i]
            if not job or sending or splitting then return end
            local ready = filled and filled.key == job.key and SendTabShown()
            if mouseButton == "RightButton" then
                if ready then TakeOut() end
                return
            end
            if ready then Send(job) else Fill(job) end
        end)
        UI.SetTooltip(row.button, function(tooltip)
            local job = jobs[i]
            if not job then return end
            tooltip:AddLine("Mail to " .. job.name, 1, 1, 1)
            for _, it in ipairs(job.items) do
                tooltip:AddLine(ItemText(it.itemID, it.quantity, it.name), 0.8, 0.8, 0.8, true)
            end
            if filled and filled.key == job.key then
                addon:Explain(tooltip, "Check what's in the mail above, then click to send it. Right-click to take the items out again.",
                    0.6, 0.6, 0.6, true)
            else
                addon:Explain(tooltip, "First click fills in the mail and shows what's in it; check it, then click again to send it.",
                    0.6, 0.6, 0.6, true)
            end
        end, "ANCHOR_RIGHT")
        row.attached = UI.Text(panel, "small", "gold")
        row.attached:SetJustifyH("LEFT")
        row.attached:SetWordWrap(true)
        panel.rows[i] = row
    end
    panel.note = UI.Text(panel, "small", "muted")
    panel.note:SetJustifyH("LEFT")
    panel.note:SetWordWrap(true)
end

Update = function()
    if not panel then return end
    if not MailboxShown() then
        panel:Hide()
        return
    end
    Place()
    jobs = addon:MailJobs()
    -- The filled-in mail's job, kept while it's waiting for Send
    if filled then
        local still
        for _, job in ipairs(jobs) do if job.key == filled.key then still = job end end
        if still and AttachmentCount() > 0 then filled = still else filled = nil end
    end
    if #jobs == 0 then
        panel:Hide()
        return
    end
    local y = 28
    local width = PANEL_WIDTH - 20
    for i, row in ipairs(panel.rows) do
        local job = jobs[i]
        if job then
            row.text:ClearAllPoints()
            row.text:SetPoint("TOPLEFT", 10, -y)
            row.text:SetWidth(width)
            row.text:SetText(addon:Colorize(job.name .. ": ", "gold") .. JobText(job))
            row.text:Show()
            y = y + math.max(row.text:GetStringHeight(), LINE_HEIGHT) + 4
            local ready = filled and filled.key == job.key
            local attached = ready and AttachedText()
            if attached then
                row.attached:ClearAllPoints()
                row.attached:SetPoint("TOPLEFT", 10, -y)
                row.attached:SetWidth(width)
                row.attached:SetText("In the mail now: " .. attached)
                row.attached:Show()
                y = y + math.max(row.attached:GetStringHeight(), LINE_HEIGHT) + 4
            else
                row.attached:Hide()
            end
            row.button:SetLabel(splitting and splitting.job.key == job.key and "Filling in..."
                or sending and ready and "Sending..."
                or ready and ("Send to " .. job.name)
                or ("Fill in a mail to " .. job.name))
            row.button.label:SetTextColor(addon:Color(ready and "gold" or "text"))
            row.button:ClearAllPoints()
            row.button:SetPoint("TOPLEFT", 10, -y)
            row.button:Show()
            y = y + 26 + 10
        else
            row.text:Hide()
            row.attached:Hide()
            row.button:Hide()
        end
    end
    if #jobs > JOBS then
        panel.note:ClearAllPoints()
        panel.note:SetPoint("TOPLEFT", 10, -y)
        panel.note:SetWidth(width)
        panel.note:SetText(string.format("And %d more characters: send these first.", #jobs - JOBS))
        panel.note:Show()
        y = y + panel.note:GetStringHeight() + 6
    else
        panel.note:Hide()
    end
    panel:SetHeight(y + 4)
    panel:Show()
end

-- Shop.lua leaves its chat reminder to this panel
addon.MailPanelShown = true

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

-- While at the mailbox, whether a mailbox window is up, checked twice a
-- second: TSM's window closes without MAIL_CLOSED (you're still at the
-- mailbox), and the panel stayed up on its own (user, 2026-10-24: "i closed
-- TSM and that mail screen didn't go away"). It comes back when TSM's or
-- the game's window does.
-- Every frame: half a second was a noticeable wait after closing TSM's
-- window (user, 2026-10-24); it only runs while you're at a mailbox
local WATCH_EVERY = 0
local watcher = CreateFrame("Frame")
watcher:Hide()
local since, wasShown = 0, false
watcher:SetScript("OnUpdate", function(_, elapsed)
    since = since + elapsed
    if since < WATCH_EVERY then return end
    since = 0
    -- Which window, too: TSM's switch button swaps them while open, and the
    -- panel, still the game window's child, hid with it
    local shown = (MailFrame and MailFrame:IsShown() and "game") or (TSMMailShown() and "tsm") or false
    if shown ~= wasShown then
        wasShown = shown
        Update()
    end
end)

local events = CreateFrame("Frame")
for _, event in ipairs({ "MAIL_SHOW", "MAIL_CLOSED", "MAIL_SEND_SUCCESS", "MAIL_FAILED",
    "MAIL_SEND_INFO_UPDATE", "BAG_UPDATE_DELAYED" }) do
    events:RegisterEvent(event)
end
events:SetScript("OnEvent", function(_, event)
    if event == "MAIL_SHOW" then
        CreatePanel()
        filled, sending = nil, false
        C_Timer.After(0.2, Update)
        -- TSM shows its window a frame or more after the mailbox opens
        C_Timer.After(1, Update)
        since, wasShown = 0, false
        watcher:Show()
    elseif event == "MAIL_CLOSED" then
        filled, sending, splitting = nil, false, nil
        watcher:Hide()
        if panel then panel:Hide() end
    elseif event == "MAIL_SEND_SUCCESS" or event == "MAIL_FAILED" then
        filled, sending = nil, false
        -- The SendMail hook has recorded it; their queue is planned again
        C_Timer.After(0.5, Update)
    elseif MailboxShown() and not sending then
        UpdateSoon()
    end
end)

_G.Goldsmith = addon
