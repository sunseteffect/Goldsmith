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
        key = "2.6",
        title = "What's new in Goldsmith 2.6",
        items = {
            { "Buy next", "At the AH, Goldsmith's panel scans every price and buys what your queue needs, one item per click. Queue a few crafts and try it." },
            { "Vendor materials in one click", "At a vendor, the Goldsmith panel buys the exact amounts your queue needs." },
            { "Queue from anywhere", "Right-click a craft in Do this next or on the Characters tab to queue it." },
            { "Choices stay with the plan", "Right-clicking a material to buy, craft or salvage it now applies to that plan and its queue entry only." },
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
