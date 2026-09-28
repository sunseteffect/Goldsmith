local addon = _G.Goldsmith or {}
local UI = addon.UI

-- The window
--
-- A header (title, profession and date filters, where prices come from,
-- settings), four tabs, and the tab's screen below. Each screen is a view
-- registered with addon:RegisterView; the window creates it the first time
-- its tab is opened and refreshes it when shown or when data changes.
--
-- Remembered in GoldsmithDB.ui2: position, open or closed, tab,
-- profession ("All" or one) and date range key.

local WIDTH, HEIGHT = 900, 620
local HEADER_HEIGHT = 48
local TAB_HEIGHT = 32

local TABS = {
    { key = "overview", label = "Overview" },
    { key = "crafts", label = "Crafts" },
    { key = "items", label = "Items" },
    { key = "history", label = "History" },
}

-- Views: key -> { create = function(parent) -> view, refresh = function(view, state) }
-- state = { profession, range, since, setProfession(prof) }
local views = {}

function addon:RegisterView(key, view)
    views[key] = view
end

-- Where AH prices come from, for the header (see GetAHPriceInfo and the
-- price source setting). Automatic: an Auctionator scan made this session
-- beats TSM; otherwise TSM. Returns text and a theme color.
local function PriceSourceText()
    local scan = GoldsmithDB.lastPriceUpdate
    local scanText
    if scan then
        local days = math.floor((time() - scan) / 86400)
        scanText = date("%Y-%m-%d", scan) == date("%Y-%m-%d") and ("at " .. date("%H:%M", scan))
            or string.format("%d day%s ago", math.max(days, 1), days == 1 and "" or "s")
    end
    local source = addon:Setting("priceSource")
    if source == "tsm" and addon:HasTSM() then
        return "Prices: TSM (preferred)", "muted"
    elseif source == "auctionator" and scanText then
        return "Prices: Auctionator scan " .. scanText .. " (preferred)", "muted"
    end
    if addon:ScannedThisSession() then
        return "Prices: Auctionator scan " .. scanText, "muted"
    elseif addon:HasTSM() then
        return "Prices: TSM", "muted"
    elseif scanText then
        return "Prices: Auctionator scan " .. scanText, "warning"
    elseif addon:HasAuctionator() then
        return "Prices: no Auctionator scan yet", "warning"
    end
    return "Prices: install Auctionator or TSM", "warning"
end

local function ProfessionLabel(prof)
    if prof == "All" then return "All professions" end
    return addon:ProfessionIconText(prof) .. prof
end

function addon:CreateWindow()
    if not GoldsmithDB.ui2 then
        -- First time: open if the v1 window was open
        GoldsmithDB.ui2 = { shown = GoldsmithDB.ui and GoldsmithDB.ui.shown }
    end
    local ui = GoldsmithDB.ui2
    ui.tab = ui.tab or "overview"
    ui.profession = ui.profession or "All"
    ui.range = ui.range or "7d"

    local frame = CreateFrame("Frame", "GoldsmithWindow", UIParent, "BackdropTemplate")
    frame:SetSize(WIDTH, HEIGHT)
    if ui.point then
        frame:SetPoint(ui.point, UIParent, ui.relativePoint, ui.x, ui.y)
    else
        frame:SetPoint("CENTER")
    end
    frame:SetFrameStrata("HIGH")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:Hide()
    UI.Style(frame, "window", "borderGold")
    -- Escape closes it
    table.insert(UISpecialFrames, "GoldsmithWindow")

    -- Header: drag it to move the window
    local header = UI.Panel(frame, "header")
    header:SetPoint("TOPLEFT", 1, -1)
    header:SetPoint("TOPRIGHT", -1, -1)
    header:SetHeight(HEADER_HEIGHT)
    -- The header and the tab strip both move the window (buttons on them
    -- still take their own clicks)
    local function MakeDragHandle(handle)
        handle:EnableMouse(true)
        handle:RegisterForDrag("LeftButton")
        handle:SetScript("OnDragStart", function() frame:StartMoving() end)
        handle:SetScript("OnDragStop", function()
            frame:StopMovingOrSizing()
            local point, _, relativePoint, x, y = frame:GetPoint()
            ui.point, ui.relativePoint, ui.x, ui.y = point, relativePoint, x, y
        end)
    end
    MakeDragHandle(header)

    local title = UI.Text(header, "title")
    title:SetPoint("LEFT", 18, 0)
    title:SetText("GOLDSMITH")

    local Refresh -- defined below

    local professionButton = UI.Dropdown(header, 170, function(root)
        root:CreateTitle("Show profession")
        local options = { "All" }
        for _, prof in ipairs(addon:GetProfessions()) do table.insert(options, prof) end
        for _, prof in ipairs(options) do
            root:CreateRadio(ProfessionLabel(prof),
                function() return ui.profession == prof end,
                function() ui.profession = prof; Refresh() end)
        end
    end)
    professionButton:SetPoint("LEFT", title, "RIGHT", 20, 0)

    local rangeButton = UI.Dropdown(header, 120, function(root)
        root:CreateTitle("Show")
        for _, r in ipairs(addon.DATE_RANGES) do
            root:CreateRadio(r.label,
                function() return ui.range == r.key end,
                function() ui.range = r.key; Refresh() end)
        end
    end)
    rangeButton:SetPoint("LEFT", professionButton, "RIGHT", 8, 0)

    local closeButton = UI.IconButton(header, 34, "X", "Close (Esc)", function() frame:Hide() end,
        { font = "close", hoverColor = "loss" })
    closeButton:SetPoint("RIGHT", -8, 0)

    local settings = addon:CreateSettingsPanel(frame)
    settings:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -(HEADER_HEIGHT + 4))
    local settingsButton = UI.Button(header, "Settings", 80, 24, function() settings:SetShown(not settings:IsShown()) end)
    settingsButton:SetPoint("RIGHT", closeButton, "LEFT", -8, 0)
    UI.SetTooltip(settingsButton, function(tooltip)
        tooltip:AddLine("Settings", 1, 1, 1)
        tooltip:AddLine("Which cost to show, where prices come from, and the ROI a craft needs to be worth it.", 0.8, 0.8, 0.8, true)
    end, "ANCHOR_BOTTOM")

    local priceText = UI.Text(header, "small", "muted", "RIGHT")
    priceText:SetPoint("RIGHT", settingsButton, "LEFT", -12, 0)

    -- Tabs
    local tabArea = UI.Panel(frame, "header")
    tabArea:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, 0)
    tabArea:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT", 0, 0)
    tabArea:SetHeight(TAB_HEIGHT)
    MakeDragHandle(tabArea)
    local headerLine = UI.Line(frame, "border")
    headerLine:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
    headerLine:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT")
    headerLine:SetHeight(1)
    -- A gold line under the tabs separates the header from the screen
    local tabLine = UI.Line(frame, "borderGold")
    tabLine:SetPoint("TOPLEFT", tabArea, "BOTTOMLEFT")
    tabLine:SetPoint("TOPRIGHT", tabArea, "BOTTOMRIGHT")
    tabLine:SetHeight(2)

    local tabBar = UI.TabBar(tabArea, TABS, function(key)
        ui.tab = key
        Refresh()
    end)
    tabBar:SetPoint("TOPLEFT", 10, 0)
    tabBar:SetPoint("TOPRIGHT", 0, 0)

    -- Screens
    local content = CreateFrame("Frame", nil, frame)
    content:SetPoint("TOPLEFT", tabArea, "BOTTOMLEFT", 20, -16)
    content:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 16)

    local created = {} -- key -> { frame, view, def }
    local function GetScreen(key)
        if created[key] then return created[key] end
        local def = views[key]
        local screen = CreateFrame("Frame", nil, content)
        screen:SetAllPoints()
        local view = def.create(screen)
        created[key] = { frame = screen, view = view, def = def }
        return created[key]
    end

    Refresh = function()
        if not frame:IsShown() then return end
        local valid = false
        for _, tab in ipairs(TABS) do
            if tab.key == ui.tab then valid = true end
        end
        if not valid then ui.tab = "overview" end

        professionButton:SetLabel(ProfessionLabel(ui.profession))
        rangeButton:SetLabel(addon:GetDateRange(ui.range).label)
        local text, color = PriceSourceText()
        priceText:SetText(text)
        priceText:SetTextColor(addon:Color(color))
        if settings:IsShown() then settings:Update() end
        tabBar:Select(ui.tab)

        for key, screen in pairs(created) do
            screen.frame:SetShown(key == ui.tab)
        end
        local screen = GetScreen(ui.tab)
        screen.frame:Show()
        screen.def.refresh(screen.view, {
            profession = ui.profession,
            range = ui.range,
            since = addon:DateRangeStart(ui.range),
            setProfession = function(prof)
                ui.profession = prof
                Refresh()
            end,
        })
    end

    frame:SetScript("OnShow", function()
        ui.shown = true
        Refresh()
    end)
    frame:SetScript("OnHide", function()
        ui.shown = false
        settings:Hide()
    end)

    addon.window = frame
    addon.RefreshWindow = Refresh

    -- Opens the window on a tab, for links between screens (e.g. the
    -- Overview's "Best crafts" opening Crafts)
    function addon:ShowTab(key)
        ui.tab = key
        if frame:IsShown() then Refresh() else frame:Show() end
    end

    -- Other files call addon.Refresh when data changes. Data changes come in
    -- bursts (AH searches, bag updates), so the window refreshes once, half
    -- a second after the first of a burst.
    local refreshPending = false
    addon.Refresh = function()
        if frame:IsShown() and not refreshPending then
            refreshPending = true
            C_Timer.After(0.5, function()
                refreshPending = false
                Refresh()
            end)
        end
    end

    if ui.shown then
        frame:Show()
    end
end

function addon:ToggleWindow()
    if not addon.window then return end
    addon.window:SetShown(not addon.window:IsShown())
end

_G.Goldsmith = addon
