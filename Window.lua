local addon = _G.Goldsmith or {}
local UI = addon.UI

-- The v2 window
--
-- A header (title, profession and date filters, where prices come from),
-- four tabs, and the tab's screen below. Each screen is a view registered
-- with addon:RegisterView; the window creates it the first time its tab is
-- opened and refreshes it when shown or when data changes.
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

-- Tabs without a finished screen yet say what's coming and where to find
-- it in the meantime
local COMING_SOON = {
    overview = { "Overview is on its way",
        "Your profit, what to craft next, and concentration across all your characters.\n\nThe old window is still available with /gsm old." },
    crafts = { "Crafts is on its way",
        "What's worth crafting right now, with an optional concentration view.\n\nThe old window is still available with /gsm old." },
    items = { "Items is on its way",
        "Your most profitable items, and a page for each item: break-even, price history and your stock.\n\nThe old window is still available with /gsm old." },
    history = { "History is on its way",
        "Every purchase, sale and deposit, filterable.\n\nThe old window is still available with /gsm old." },
}

local function ComingSoonView(key)
    return {
        create = function(parent)
            local empty = UI.EmptyState(parent)
            empty:SetPoint("CENTER", 0, 30)
            empty:Set(COMING_SOON[key][1], COMING_SOON[key][2])
            return empty
        end,
        refresh = function() end,
    }
end

-- Where AH prices come from, for the header: an Auctionator scan made this
-- session beats TSM; otherwise TSM (see GetMarketPriceInfo).
-- Returns text and a theme color.
local function PriceSourceText()
    local scan = GoldsmithDB.lastPriceUpdate
    local scanText
    if scan then
        local days = math.floor((time() - scan) / 86400)
        scanText = date("%Y-%m-%d", scan) == date("%Y-%m-%d") and ("at " .. date("%H:%M", scan))
            or string.format("%d day%s ago", math.max(days, 1), days == 1 and "" or "s")
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
        -- First time: the new window takes over from the v1 window
        GoldsmithDB.ui2 = { shown = GoldsmithDB.ui and GoldsmithDB.ui.shown }
        if addon.mainFrame then addon.mainFrame:Hide() end
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

    local priceText = UI.Text(header, "small", "muted", "RIGHT")
    priceText:SetPoint("RIGHT", closeButton, "LEFT", -12, 0)

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
        local def = views[key] or ComingSoonView(key)
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
    frame:SetScript("OnHide", function() ui.shown = false end)

    addon.window = frame
    addon.RefreshWindow = Refresh

    -- Other files call addon.Refresh when data changes. Refresh whichever
    -- window is open; the v1 window's refresh only runs while it's shown.
    -- Data changes come in bursts (AH searches, bag updates), so the new
    -- window refreshes once, half a second after the last of a burst starts.
    local refreshOld = addon.Refresh
    local refreshPending = false
    addon.Refresh = function()
        if refreshOld and addon.mainFrame and addon.mainFrame:IsShown() then
            refreshOld()
        end
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
