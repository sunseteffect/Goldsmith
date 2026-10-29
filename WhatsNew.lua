local addon = _G.Goldsmith or {}
local UI = addon.UI
-- What's new
--
-- A short box over the window the first time it opens after an update
-- with news, then never again until the next. Why (user, 2026-10-20): Buy
-- next made them go from almost never using the queue to always using
-- it, and nobody would know it's there. The full changelog stays on
-- CurseForge; this is the few things worth trying.
--
-- NEWS[1] is the latest. A release shows it only if its key changes, so a
-- fix-only release keeps the same key and shows nothing. Seen keys go in
-- GoldsmithDB.newsSeen. New players get the tour instead (Tour.lua) and
-- this is marked seen. /gsm news shows it again.
local NEWS = {
    {
        key = "2.7.3",
        title = "What's new in Goldsmith 2.7.3",
        items = {
            { "Concentration as the game counts it", "Plans and to-dos count what a craft needs to start, not an average after ingenuity. Ingenuity shows as a chance on the plan." },
            { "Plans say why", "When a plan uses a lower mix, it says so: to leave concentration for another craft, or because it's the mix in your queue." },
            { "The queue keeps your mix", "The queue crafts the mix the plan showed, including Do this next's." },
        },
    },
    {
        key = "2.7.2",
        title = "What's new in Goldsmith 2.7.2",
        items = {
            { "Sell now", "When something you've held for days sells above break-even, Goldsmith tells you in chat, mid-screen and in Do this next." },
            { "Held board", "Items > Held puts what sells above break-even first. Right-click what you keep for yourself to leave it out." },
            { "How the suggestions did", "Stats shows how much of the expected profit your crafted suggestions made." },
            { "Losses stand out", "Posting under break-even is now a red chat line with the loss each." },
        },
    },
    {
        key = "2.7.0",
        title = "What's new in Goldsmith 2.7",
        items = {
            { "Buy for every queue", "Tick All queues in Buy next to shop for all your characters in one trip." },
            { "Mail it to them", "At the mailbox, a panel lists what each character needs. Click once to fill in the mail, again to send it." },
            { "Warnings before you lose gold", "Buy next asks twice when a craft would lose money. Posting under break-even gets a line in chat." },
            { "Stock up on cheap materials", "Items > Cheap materials follows what you actually use. Right-click one to queue a stock-up." },
            { "New Settings", "Categories on the left, search, and Reset to recommended. Help and Support are in there too." },
        },
    },
    {
        key = "2.6.3",
        title = "What's new in Goldsmith 2.6.3",
        items = {
            { "Recommendations on today's prices", "What to craft is decided on what materials are worth today, not what you paid. Recommended keeps to easy crafts worth your time." },
            { "What your materials cost you", "Plans, the queue and Craft complete show profit on what you paid. An orange note says when selling the materials would make more." },
            { "Pick what to salvage", "Right-click a milled, prospected or recycled material in a plan to choose which item to salvage for it, like the potions in your bags." },
            { "Vendor items on the AH", "When the AH sells a vendor material for less, the plan buys it there." },
            { "Mailbox totals", "Open your mailbox for one line with your AH sales and the purchases waiting in it." },
        },
    },
}

local WIDTH = 420
-- The window behind the box is darkened so the box stands out (user,
-- 2026-10-22); clicking the dark part closes it like Got it
local SHADE_ALPHA = 0.6
local BORDER = 3
local box, shade

local function Build()
    local window = addon.window
    shade = CreateFrame("Button", nil, window)
    shade:SetAllPoints(window)
    shade:SetFrameStrata("DIALOG")
    shade:SetFrameLevel(1)
    local dark = shade:CreateTexture(nil, "BACKGROUND")
    dark:SetAllPoints()
    dark:SetColorTexture(0, 0, 0, SHADE_ALPHA)
    shade:SetScript("OnClick", function() box:Hide() end)
    shade:Hide()
    box = UI.Panel(window, "highlight")
    box:SetWidth(WIDTH)
    box:SetPoint("CENTER", window, "CENTER", 0, 20)
    box:SetFrameStrata("DIALOG")
    box:SetFrameLevel(10)
    box:EnableMouse(true)
    box:HookScript("OnHide", function() shade:Hide() end)
    -- A 3px gold frame just outside the box's own border
    local edges = {
        { "TOPLEFT", "TOPRIGHT", -BORDER, BORDER, BORDER, BORDER, nil, BORDER },
        { "BOTTOMLEFT", "BOTTOMRIGHT", -BORDER, -BORDER, BORDER, -BORDER, nil, BORDER },
        { "TOPLEFT", "BOTTOMLEFT", -BORDER, BORDER, -BORDER, -BORDER, BORDER, nil },
        { "TOPRIGHT", "BOTTOMRIGHT", BORDER, BORDER, BORDER, -BORDER, BORDER, nil },
    }
    for _, e in ipairs(edges) do
        local line = UI.Line(box, "borderGold")
        line:SetPoint(e[1], box, e[1], e[3], e[4])
        line:SetPoint(e[2], box, e[2], e[5], e[6])
        if e[7] then line:SetWidth(e[7]) else line:SetHeight(e[8]) end
    end
    box.title = UI.Text(box, "title", "gold")
    box.title:SetPoint("TOPLEFT", 18, -16)
    box.lines = {}
    box.close = UI.Button(box, "Got it", 120, 26, function() box:Hide() end)
    box.close:SetPoint("BOTTOM", 0, 14)
end

local function Line(i)
    local line = box.lines[i]
    if line then return line end
    line = {
        head = UI.Text(box, "heading", "gold"),
        body = UI.Text(box, "body", "text"),
    }
    line.body:SetWordWrap(true)
    line.body:SetWidth(WIDTH - 36)
    box.lines[i] = line
    return line
end

function addon:ShowNews()
    local news = NEWS[1]
    if not news or not addon.window then return end
    if not addon.window:IsShown() then addon.window:Show() end
    if not box then Build() end
    box.title:SetText(news.title)
    local y = -48
    for i, item in ipairs(news.items) do
        local line = Line(i)
        line.head:ClearAllPoints()
        line.head:SetPoint("TOPLEFT", 18, y)
        line.head:SetText(item[1])
        line.body:ClearAllPoints()
        line.body:SetPoint("TOPLEFT", line.head, "BOTTOMLEFT", 0, -3)
        line.body:SetText(item[2])
        line.head:Show()
        line.body:Show()
        y = y - 18 - line.body:GetStringHeight() - 12
    end
    for i = #news.items + 1, #box.lines do
        box.lines[i].head:Hide()
        box.lines[i].body:Hide()
    end
    box:SetHeight(-y + 50)
    shade:Show()
    box:Show()
    GoldsmithDB.newsSeen = GoldsmithDB.newsSeen or {}
    GoldsmithDB.newsSeen[news.key] = true
end

-- When the window opens (Window.lua), after the tour offer
function addon:OfferNews()
    local news = NEWS[1]
    if not news then return end
    GoldsmithDB.newsSeen = GoldsmithDB.newsSeen or {}
    if GoldsmithDB.newsSeen[news.key] then return end
    -- A new player: the tour is offered this time; nothing here is new to them
    if addon.newPlayer then
        GoldsmithDB.newsSeen[news.key] = true
        return
    end
    addon:ShowNews()
end

-- The window closing takes the box with it
function addon:HideNews()
    if box then box:Hide() end
end

_G.Goldsmith = addon
