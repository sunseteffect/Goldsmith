local addon = _G.Goldsmith or {}
local UI = addon.UI

-- The window
--
-- A header (title, profession, date and expansion filters, where prices
-- come from, settings), six tabs, and the tab's screen below. Each screen
-- is a view registered with addon:RegisterView; the window creates it the
-- first time its tab is opened and refreshes it when shown or when data
-- changes.
--
-- Remembered in GoldsmithDB.ui2: position, open or closed, tab,
-- profession ("All" or one), date range key and expansions (see
-- IsExpansionShown).

local WIDTH, HEIGHT = 900, 710
-- Height left for a tab's content (header, tabs and padding taken off)
addon.CONTENT_HEIGHT = HEIGHT - 114
local HEADER_HEIGHT = 48
local TAB_HEIGHT = 32

local TABS = {
    { key = "overview", label = "Overview" },
    { key = "crafts", label = "Crafts" },
    { key = "queue", label = "Queue" },
    { key = "items", label = "Items" },
    { key = "history", label = "History" },
    { key = "characters", label = "Characters" },
}

-- Views: key -> { create = function(parent) -> view, refresh = function(view, state),
--                 reset = function(view) (optional: back to the home view),
--                 ownLoading = true (optional: the view marks its own parts
--                 as loading; otherwise the whole screen is covered) }
-- state = { profession, range, since, setProfession(prof), loading (see
-- NewLoading) }. refresh runs as work spread over frames (addon:RunWork).
local views = {}

function addon:RegisterView(key, view)
    views[key] = view
end

-- Where AH prices come from, for the header (see GetAHPriceInfo and the
-- price source setting). Automatic: an Auctionator scan made this session
-- beats TSM; otherwise TSM. Without either, Blizzard AH data under a day
-- old beats an older Auctionator scan. Returns text and a theme color.
-- "at 14:32" today, else "2 days ago"
local function When(ts)
    if date("%Y-%m-%d", ts) == date("%Y-%m-%d") then return "at " .. date("%H:%M", ts) end
    local days = math.max(1, math.floor((time() - ts) / 86400))
    return string.format("%d day%s ago", days, days == 1 and "" or "s")
end

-- Auctionator updates after full scans and after any AH search, so the
-- text says which was last: "Auctionator full scan at 11:51", or "AH search
-- at 11:13, full scan 2 days ago". Also true if the full scan was today.
local function AuctionatorText(scan)
    local full = GoldsmithDB.lastFullScan
    local fresh = full and date("%Y-%m-%d", full) == date("%Y-%m-%d")
    if full and scan - full < 60 then
        return "Prices: Auctionator full scan " .. When(full), fresh
    end
    return "Prices: AH search " .. When(scan)
        .. (full and (", full scan " .. When(full)) or ", no full scan yet"), fresh
end

local function PriceSourceText()
    -- The saved scan time only counts while Auctionator is loaded
    local scan = addon:HasAuctionator() and GoldsmithDB.lastPriceUpdate
    local source = addon:Setting("priceSource")
    if source == "tsm" and addon:HasTSM() then
        return "Prices: TSM (preferred)", "muted"
    elseif source == "auctionator" and scan then
        local text, fresh = AuctionatorText(scan)
        return text .. " (preferred)", fresh and "muted" or "warning"
    end
    if addon:ScannedThisSession() then
        -- Items this update didn't see use TSM when it's installed
        local text, fresh = AuctionatorText(scan)
        return text, (fresh or addon:HasTSM()) and "muted" or "warning"
    elseif addon:HasTSM() then
        return "Prices: TSM", "muted"
    elseif scan and not addon:BlizzardDataBeatsScan() then
        return (AuctionatorText(scan)), "warning"
    elseif addon:GetBlizzardDataTime() then
        -- Blizzard AH data (commodities only) fills in without either addon's
        -- prices, or when it's newer than the last Auctionator scan
        local updated = addon:GetBlizzardDataTime()
        local days = math.floor((time() - updated) / 86400)
        return "Prices: Blizzard AH data " .. (date("%Y-%m-%d", updated) == date("%Y-%m-%d")
            and ("at " .. date("%H:%M", updated))
            or string.format("%d day%s ago", math.max(days, 1), days == 1 and "" or "s")),
            days >= 1 and "warning" or "muted"
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
    GoldsmithDB.ui2 = GoldsmithDB.ui2 or {}
    local ui = GoldsmithDB.ui2
    -- The window always starts closed on login and /reload; open it with
    -- /gsm, the key, or the minimap button
    ui.shown = nil
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
    -- The same layer as the game's own windows (the AH, professions, bags),
    -- so they can go on top: whichever was clicked last is in front
    -- (SetToplevel), and a game window that opens goes in front of Goldsmith
    -- (see below)
    frame:SetFrameStrata("MEDIUM")
    frame:SetToplevel(true)
    frame:SetClampedToScreen(true)
    frame:EnableMouse(true)
    frame:SetMovable(true)
    frame:Hide()
    UI.Style(frame, "window", "borderGold")
    -- Whether Goldsmith is in front of the game's windows. Drawing order
    -- can't be read reliably (a lowered Goldsmith can share a frame level
    -- with the AH), so it's tracked: opening or clicking Goldsmith puts it
    -- in front; a game window opening or being clicked puts it behind.
    local inFront = true

    -- Opening Goldsmith puts it in front
    frame:HookScript("OnShow", function(self)
        self:Raise()
        inFront = true
    end)

    -- A game window opening (the AH and Auctionator, a profession, mail, a
    -- vendor, the bank, bags) goes in front of Goldsmith, which stays open
    -- behind it; click Goldsmith to bring it back. Settings and Help sit on
    -- a higher layer, so they close.
    local function StepBack()
        if not frame:IsShown() then return end
        inFront = false
        frame:Lower()
        if GoldsmithSettings then GoldsmithSettings:Hide() end
        if GoldsmithHelp then GoldsmithHelp:Hide() end
    end
    hooksecurefunc("ShowUIPanel", function(panel)
        if panel and panel ~= frame then StepBack() end
    end)
    local stepBackEvents = CreateFrame("Frame")
    for _, event in ipairs({ "AUCTION_HOUSE_SHOW", "TRADE_SKILL_SHOW", "MAIL_SHOW", "MERCHANT_SHOW",
                             "BANKFRAME_OPENED" }) do
        stepBackEvents:RegisterEvent(event)
    end
    stepBackEvents:SetScript("OnEvent", StepBack)
    -- Bags aren't game panels, so watch them directly
    local bags = { ContainerFrameCombinedBags }
    for i = 1, NUM_TOTAL_EQUIPPED_BAG_SLOTS or 0 do table.insert(bags, _G["ContainerFrame" .. i]) end
    for _, bag in pairs(bags) do bag:HookScript("OnShow", StepBack) end

    -- Escape closes only what's in front: Settings or Help, else Goldsmith
    -- if no game window is in front of it. Otherwise the key goes on to the
    -- game, which closes its windows, and the next Escape closes Goldsmith.
    -- (In UISpecialFrames the game's Escape would close everything at once.)
    -- Addons can't hold on to keys in combat, so there it falls back to that.
    -- Game windows that can be open with Goldsmith (some load only when
    -- first opened, so they're looked up each time)
    local GAME_WINDOWS = { "AuctionHouseFrame", "ProfessionsFrame", "MailFrame", "MerchantFrame",
                           "BankFrame", "AccountBankPanel" }
    local function GameWindows()
        local list = {}
        for _, name in ipairs(GAME_WINDOWS) do
            if _G[name] then table.insert(list, _G[name]) end
        end
        for _, position in ipairs({ "left", "center", "right", "doublewide", "fullscreen" }) do
            local panel = GetUIPanel and GetUIPanel(position)
            if panel then table.insert(list, panel) end
        end
        for _, bag in pairs(bags) do table.insert(list, bag) end
        return list
    end
    local function AnyGameWindowOpen()
        for _, window in ipairs(GameWindows()) do
            if window ~= frame and window:IsShown() then return true end
        end
        return false
    end
    local function InFront()
        return inFront or not AnyGameWindowOpen()
    end

    -- A click on Goldsmith (or anything in it) brings it in front; a click
    -- on an open game window puts it behind. Clicks on the game world and
    -- other addons leave it as it was.
    local function IsInside(f, ancestor)
        while f do
            if f == ancestor then return true end
            f = f.GetParent and f:GetParent()
        end
        return false
    end
    local clicks = CreateFrame("Frame")
    clicks:RegisterEvent("GLOBAL_MOUSE_DOWN")
    clicks:SetScript("OnEvent", function()
        if not frame:IsShown() then return end
        local focus = (GetMouseFoci and GetMouseFoci()[1]) or (GetMouseFocus and GetMouseFocus())
        if not focus then return end
        if IsInside(focus, frame) then
            inFront = true
            return
        end
        for _, window in ipairs(GameWindows()) do
            if window ~= frame and window:IsShown() and IsInside(focus, window) then
                inFront = false
                return
            end
        end
    end)

    -- Every key goes on to the game except an Escape Goldsmith used, and
    -- that is let go again on the next frame, so Goldsmith never holds on to
    -- the keyboard (it would swallow movement keys in combat, where it can't
    -- be changed)
    local function PassKeysOn()
        if not InCombatLockdown() then frame:SetPropagateKeyboardInput(true) end
    end
    frame:SetScript("OnKeyDown", function(self, key)
        if key ~= "ESCAPE" or InCombatLockdown() then return end
        local handled = false
        if GoldsmithHelp and GoldsmithHelp:IsShown() then
            GoldsmithHelp:Hide(); handled = true
        elseif GoldsmithSettings and GoldsmithSettings:IsShown() then
            GoldsmithSettings:Hide(); handled = true
        elseif InFront() then
            self:Hide(); handled = true
        end
        if handled then
            self:SetPropagateKeyboardInput(false)
            C_Timer.After(0, PassKeysOn)
        end
    end)
    frame:HookScript("OnShow", PassKeysOn)

    -- Keyboard setup can't happen in combat (a /reload mid-fight); until
    -- it's done, and in any fight, the game's Escape closes Goldsmith along
    -- with everything else
    local keysReady = false
    local function SetUpKeys()
        if keysReady or InCombatLockdown() then return end
        frame:SetPropagateKeyboardInput(true)
        frame:EnableKeyboard(true)
        keysReady = true
    end
    local combat = CreateFrame("Frame")
    combat:RegisterEvent("PLAYER_REGEN_DISABLED")
    combat:RegisterEvent("PLAYER_REGEN_ENABLED")
    combat:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_REGEN_DISABLED" then
            if not tContains(UISpecialFrames, "GoldsmithWindow") then tinsert(UISpecialFrames, "GoldsmithWindow") end
        else
            tDeleteItem(UISpecialFrames, "GoldsmithWindow")
            SetUpKeys()
            PassKeysOn()
        end
    end)
    if InCombatLockdown() then
        tinsert(UISpecialFrames, "GoldsmithWindow")
    else
        SetUpKeys()
    end

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

    -- Logo mark (hammer and ingot, Media\Logo.tga) beside the name
    local logo = header:CreateTexture(nil, "ARTWORK")
    logo:SetSize(30, 30)
    logo:SetTexture("Interface\\AddOns\\Goldsmith\\Media\\Logo")
    logo:SetPoint("LEFT", 14, 0)
    local title = UI.Text(header, "title")
    title:SetPoint("LEFT", logo, "RIGHT", 8, 0)
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

    -- Which expansions' items every tab lists (IsExpansionShown); starts on
    -- the current one
    local expansionButton = UI.Dropdown(header, 130, function(root)
        root:CreateTitle("Show items from")
        for _, expansionID in ipairs(addon:GetFilterExpansions()) do
            root:CreateCheckbox(addon:GetExpansionName(expansionID),
                function() return addon:IsExpansionShown(expansionID) end,
                function()
                    addon:SetExpansionShown(expansionID, not addon:IsExpansionShown(expansionID))
                    Refresh()
                end)
        end
        root:CreateDivider()
        root:CreateButton("Current expansion only", function()
            ui.expansions = nil
            Refresh()
        end)
        root:CreateButton("All expansions", function()
            ui.expansions = {}
            for _, expansionID in ipairs(addon:GetFilterExpansions()) do ui.expansions[expansionID] = true end
            Refresh()
        end)
    end)
    expansionButton:SetPoint("LEFT", rangeButton, "RIGHT", 8, 0)

    local closeButton = UI.IconButton(header, 34, "X", "Close (Esc)", function() frame:Hide() end,
        { font = "close", hoverColor = "loss" })
    closeButton:SetPoint("RIGHT", -8, 0)

    local settings = addon:CreateSettingsPanel(frame)
    settings:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, -(HEADER_HEIGHT + 4))
    local settingsButton = UI.Button(header, "Settings", 80, 24, function()
        -- Help sits in the same spot (Settings > Help)
        if GoldsmithHelp then GoldsmithHelp:Hide() end
        settings:SetShown(not settings:IsShown())
    end)
    settingsButton:SetPoint("RIGHT", closeButton, "LEFT", -8, 0)
    UI.SetTooltip(settingsButton, function(tooltip)
        tooltip:AddLine("Settings", 1, 1, 1)
        tooltip:AddLine("Costs, prices and thresholds, item tooltips, chat messages, which characters count, and Help.", 0.8, 0.8, 0.8, true)
    end, "ANCHOR_BOTTOM")

    -- Between the filters and Settings, on two lines when it doesn't fit
    local priceText = UI.Text(header, "small", "muted", "RIGHT")
    priceText:SetPoint("LEFT", expansionButton, "RIGHT", 12, 0)
    priceText:SetPoint("RIGHT", settingsButton, "LEFT", -12, 0)
    priceText:SetWordWrap(true)
    priceText:SetMaxLines(2)

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

    -- Clicking the tab you're on takes it back to its home view (e.g. from a
    -- craft plan to the Crafts list)
    local ResetView -- defined below
    local tabBar = UI.TabBar(tabArea, TABS, function(key)
        if key == ui.tab then ResetView(key) end
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

    ResetView = function(key)
        local screen = created[key]
        if screen and screen.def.reset then screen.def.reset(screen.view) end
    end

    -- Parts of the screen still being worked out. A view calls
    -- state.loading:Begin(part) before the work for a part (a frame) and
    -- :Done(part) once it's filled in; views without ownLoading are
    -- covered whole. The "Loading" covers (UI.Loading) only show once the
    -- work has had to wait for a frame, so a quick refresh never flickers.
    local function HideLoading(part)
        if part.goldsmithLoading then part.goldsmithLoading:Hide() end
    end
    local function NewLoading(previous)
        -- Still loading from the refresh this replaces: keep showing it
        local loading = { pending = {}, slow = previous ~= nil and previous.slow }
        function loading:Begin(part)
            self.pending[part] = true
            if self.slow then UI.Loading(part):Show() end
        end
        function loading:Done(part)
            self.pending[part] = nil
            HideLoading(part)
        end
        function loading:ShowAll()
            self.slow = true
            for part in pairs(self.pending) do UI.Loading(part):Show() end
        end
        function loading:HideAll()
            for part in pairs(self.pending) do HideLoading(part) end
            self.pending = {}
        end
        return loading
    end
    local loading -- the refresh in progress, if any

    Refresh = function()
        if not frame:IsShown() then return end
        local valid = false
        for _, tab in ipairs(TABS) do
            if tab.key == ui.tab then valid = true end
        end
        if not valid then ui.tab = "overview" end

        professionButton:SetLabel(ProfessionLabel(ui.profession))
        rangeButton:SetLabel(addon:GetDateRange(ui.range).label)
        expansionButton:SetLabel(addon:ExpansionFilterLabel())
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
        -- Worked out over as many frames as it takes (addon:RunWork); a
        -- newer refresh stops this one
        local previous = loading
        local this = NewLoading(previous)
        loading = this
        local state = {
            profession = ui.profession,
            range = ui.range,
            since = addon:DateRangeStart(ui.range),
            setProfession = function(prof)
                ui.profession = prof
                Refresh()
            end,
            loading = this,
        }
        if not screen.def.ownLoading then this:Begin(screen.frame) end
        local tab = ui.tab
        addon:RunWork(function()
            screen.def.refresh(screen.view, state)
        end, function()
            this:ShowAll()
        end, function(work)
            this:HideAll()
            if loading == this then loading = nil end
            -- /gsm perf waits for this to time a tab
            if addon.OnTabRefreshed then addon.OnTabRefreshed(tab, work) end
        end, tab)
        -- Parts the replaced refresh was loading that this one has already
        -- filled in, or doesn't cover (another tab)
        if previous then
            for part in pairs(previous.pending) do
                if not this.pending[part] then HideLoading(part) end
            end
        end
    end

    frame:SetScript("OnShow", function()
        Refresh()
    end)
    frame:SetScript("OnHide", function()
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

    -- Opens the window with the settings panel (the minimap button's
    -- right-click)
    function addon:ShowSettings()
        frame:Show()
        settings:Show()
    end

    -- Other files call addon.Refresh when data changes. It empties the
    -- caches (Settings.lua) at once. Data changes come in bursts (AH
    -- searches, bag updates), so the window refreshes once, half a second
    -- after the first of a burst.
    local refreshPending = false
    addon.Refresh = function()
        addon:DataChanged()
        if frame:IsShown() and not refreshPending then
            refreshPending = true
            C_Timer.After(0.5, function()
                refreshPending = false
                Refresh()
            end)
        end
    end
end

function addon:ToggleWindow()
    if not addon.window then return end
    addon.window:SetShown(not addon.window:IsShown())
end

_G.Goldsmith = addon
