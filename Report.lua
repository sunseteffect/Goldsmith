local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Bug reports
--
-- Helps players send useful bug reports (user, 2026-10-06). WoW hides Lua
-- errors unless scriptErrors is on, so most players never see one:
--   - Goldsmith keeps its own errors: the game's error handler is wrapped,
--     and errors from Goldsmith's files are saved (the last MAX_ERRORS,
--     with how often and when, in GoldsmithDB.errorLog). With BugGrabber
--     (BugSack) installed it owns the handler, so its errors are read too.
--   - The first error of a session prints one chat line pointing at
--     /gsm report.
--   - The report (Settings > Support and feedback > Copy bug report, or
--     /gsm report) gathers versions, other addons, price data, the window's
--     filters, changed settings, how much data there is and the errors,
--     ready to paste into a CurseForge comment or a GitHub issue. Both are
--     public, so character and realm names are replaced and no gold
--     amounts or items are included.
-- Addons can't open a browser, so the player copies it with Ctrl+C.
-- CurseForge comments come first: players have a CurseForge account from
-- the app, few have GitHub (user, 2026-10-14).

local MAX_ERRORS = 10
local STACK_LINES = 12
local COMMENTS_URL = "https://www.curseforge.com/wow/addons/goldsmith-crafting-profit-planner/comments"
local ISSUES_URL = "https://github.com/sunseteffect/Goldsmith/issues"

addon.COMMENTS_URL = COMMENTS_URL
addon.ISSUES_URL = ISSUES_URL

-- Version from the TOC, or "development copy" when it isn't set
function addon:GetVersion(name)
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local ok, version = pcall(get, name or "Goldsmith", "Version")
    if not ok or not version or version:find("@", 1, true) then return "development copy" end
    return version
end

-- Error log

-- Errors from before saved data loads (a file's main chunk) wait here
local early = {}
local sessionCount = 0
local told = false

local function IsOurs(text)
    return type(text) == "string" and text:find("AddOns[/\\]Goldsmith[/\\]") ~= nil
end

-- "Interface/AddOns/Goldsmith/Pricing.lua:1815: ..." -> "Goldsmith/Pricing.lua:1815: ..."
local function Shorten(text)
    return (text:gsub("Interface[/\\]AddOns[/\\]", ""):gsub("%[string \"@?(.-)\"%]", "%1"))
end

local function TrimStack(stack)
    local lines = {}
    for line in (stack or ""):gmatch("[^\n]+") do
        -- "[C]: ?" says nothing about where it happened
        if not line:find("Goldsmith[/\\]Report%.lua") and not line:match("^%s*%[C%]: %?%s*$")
            and #lines < STACK_LINES then
            table.insert(lines, Shorten(line))
        end
    end
    return table.concat(lines, "\n")
end

local function Log()
    if not GoldsmithDB then return early end
    GoldsmithDB.errorLog = GoldsmithDB.errorLog or {}
    for _, e in ipairs(early) do table.insert(GoldsmithDB.errorLog, e) end
    wipe(early)
    return GoldsmithDB.errorLog
end

local function Record(message, stack)
    local log = Log()
    message = Shorten(tostring(message))
    local now = time()
    local found
    for _, e in ipairs(log) do
        if e.message == message then found = e end
    end
    if found then
        found.count = found.count + 1
        found.last = now
        found.version = addon:GetVersion()
    else
        table.insert(log, { message = message, stack = TrimStack(stack), count = 1,
            first = now, last = now, version = addon:GetVersion() })
    end
    table.sort(log, function(a, b) return a.last > b.last end)
    for i = #log, MAX_ERRORS + 1, -1 do log[i] = nil end

    sessionCount = sessionCount + 1
    C_Timer.After(0, function() addon:UpdateErrorDots() end)
    if not told then
        told = true
        -- Next frame: printing from inside an error handler can fail
        C_Timer.After(0, function()
            addon:Notify("info", "Goldsmith hit an error. Type /gsm report to copy the details for a bug report.")
        end)
    end
end

-- Wraps the game's handler: Goldsmith's errors are saved, and every error
-- still goes on to whoever showed it before. Never errors itself.
local previous = geterrorhandler()
local function OnError(message, ...)
    -- From whoever raised it, not from here
    local stack = debugstack and debugstack(2) or ""
    pcall(function()
        if IsOurs(message) or IsOurs(stack) then Record(message, stack) end
    end)
    if previous then return previous(message, ...) end
end
seterrorhandler(OnError)

-- BugGrabber (BugSack) keeps the handler to itself; listen to it instead
local function WatchBugGrabber()
    local grabber = _G.BugGrabber
    if not grabber or geterrorhandler() == OnError then return end
    if grabber.RegisterCallback then
        pcall(grabber.RegisterCallback, addon, "BugGrabber_BugGrabbed", function(_, err)
            if type(err) == "table" and (IsOurs(err.message) or IsOurs(err.stack)) then
                Record(err.message, err.stack)
            end
        end)
    end
end
local watcher = CreateFrame("Frame")
watcher:RegisterEvent("PLAYER_LOGIN")
watcher:SetScript("OnEvent", WatchBugGrabber)

-- Saved errors, newest first
function addon:GetErrors()
    return Log()
end

-- Errors this session
function addon:GetSessionErrorCount()
    return sessionCount
end

-- A red dot on the window's Settings button, the Support entry and its
-- dashboard card while an error is newer than your last look at Support
-- (user, 2026-10-27: "like a notification icon"). Opening Support or the
-- bug report clears it (GoldsmithDB.errorsSeen).
local dots = {}

function addon:HasNewErrors()
    if not GoldsmithDB then return false end
    local seen = GoldsmithDB.errorsSeen or 0
    for _, e in ipairs(Log()) do
        if (e.last or 0) > seen then return true end
    end
    return false
end

function addon:UpdateErrorDots()
    local show = addon:HasNewErrors()
    for _, dot in ipairs(dots) do dot:SetShown(show) end
end

-- A dot near the frame's top right corner (x, y: its center from there)
function addon:ErrorDot(frame, x, y, size)
    local dot = frame:CreateTexture(nil, "OVERLAY", nil, 7)
    dot:SetSize(size or 9, size or 9)
    dot:SetPoint("CENTER", frame, "TOPRIGHT", x or -3, y or -3)
    dot:SetColorTexture(addon:Color("loss"))
    local mask = frame:CreateMaskTexture()
    mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(dot)
    dot:AddMaskTexture(mask)
    table.insert(dots, dot)
    dot:SetShown(addon:HasNewErrors())
    return dot
end

function addon:MarkErrorsSeen()
    if GoldsmithDB then GoldsmithDB.errorsSeen = time() end
    addon:UpdateErrorDots()
end

function addon:ClearErrors()
    wipe(Log())
    sessionCount = 0
    addon:UpdateErrorDots()
end

-- The report

local REGIONS = { "US", "KR", "EU", "TW", "CN" }

-- Addons that change what Goldsmith does, with their versions
local KEY_ADDONS = { "GoldsmithData", "Auctionator", "TradeSkillMaster", "TradeSkillMaster_AppHelper", "BugGrabber", "BugSack" }

local function Ago(t)
    if not t then return "never" end
    local minutes = math.floor((time() - t) / 60)
    if minutes < 60 then return minutes .. "m ago" end
    if minutes < 48 * 60 then return math.floor(minutes / 60) .. "h ago" end
    return math.floor(minutes / 1440) .. " days ago"
end

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function LoadedAddons()
    local num = (C_AddOns and C_AddOns.GetNumAddOns or GetNumAddOns)()
    local info = C_AddOns and C_AddOns.GetAddOnInfo or GetAddOnInfo
    local loaded = C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded
    local key, names = {}, {}
    for _, name in ipairs(KEY_ADDONS) do key[name] = true end
    for i = 1, num do
        local name = info(i)
        if name and loaded(name) and name ~= "Goldsmith" and not key[name] then table.insert(names, name) end
    end
    table.sort(names)
    return names
end

-- Character and realm names in the text become <character> and <realm>
local function Anonymize(text)
    local names, realms = {}, {}
    for charKey, c in pairs(GoldsmithDB.characters or {}) do
        local name, realm = charKey:match("^(.-)%-(.+)$")
        if c.name then names[c.name] = true end
        if name and name ~= "" then names[name] = true end
        if realm and realm ~= "" then realms[realm] = true end
    end
    local me = UnitName and UnitName("player")
    if me then names[me] = true end
    local realm = GetRealmName and GetRealmName()
    if realm then realms[realm] = true; realms[realm:gsub("%s", "")] = true end
    local function ReplaceAll(set, with)
        local list = {}
        for word in pairs(set) do if #word >= 3 then table.insert(list, word) end end
        -- Longest first, so "Area 52" goes before "Area"
        table.sort(list, function(a, b) return #a > #b end)
        for _, word in ipairs(list) do
            text = text:gsub(word:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"), with)
        end
    end
    ReplaceAll(realms, "<realm>")
    ReplaceAll(names, "<character>")
    return text
end

function addon:BuildBugReport()
    local lines = {}
    local function Add(fmt, ...) table.insert(lines, select("#", ...) > 0 and string.format(fmt, ...) or fmt) end

    Add("### Goldsmith report")
    Add("```")
    local gameVersion, build = GetBuildInfo()
    local region = GetCurrentRegion and REGIONS[GetCurrentRegion()] or "?"
    Add("Goldsmith %s, game %s (%s), %s client, %s region", addon:GetVersion(), tostring(gameVersion),
        tostring(build), GetLocale(), region)

    -- Price data
    local data = GoldsmithPriceData
    Add("Goldsmith Data: %s", data and string.format("%s, %s, updated %s (%d items)", addon:GetVersion("GoldsmithData"),
        tostring(data.region), Ago(data.updated), Count(data.items)) or "not loaded")
    Add("Prices: source setting %s; Auctionator %s, last scan %s; TSM %s",
        addon:Setting("priceSource"), addon:HasAuctionator() and "yes" or "no",
        Ago(addon:HasAuctionator() and GoldsmithDB.lastPriceUpdate or nil), addon:HasTSM() and "yes" or "no")
    local own = GoldsmithDB.ownScan
    Add("Goldsmith scan: %s", own and string.format("%s, %s, %d items, %d auctions, %ds%s, newest: %s",
        Ago(own.time), tostring(own.method), own.items or 0, own.auctions or 0, own.seconds or 0,
        own.borrowed and ", read Auctionator's" or "", addon:OwnScanIsNewest() and "yes" or "no") or "none yet")

    -- Other addons
    local versions = {}
    for _, name in ipairs(KEY_ADDONS) do
        local loaded = (C_AddOns and C_AddOns.IsAddOnLoaded or IsAddOnLoaded)(name)
        if loaded and name ~= "GoldsmithData" then table.insert(versions, name .. " " .. addon:GetVersion(name)) end
    end
    if #versions > 0 then Add("Related addons: %s", table.concat(versions, ", ")) end
    local others = LoadedAddons()
    Add("Other addons (%d): %s", #others, #others > 0 and table.concat(others, ", ") or "none")

    -- Where they were
    local ui = GoldsmithDB.ui2 or {}
    Add("Window: %s tab, %s, %s, %s", tostring(ui.tab or "overview"), tostring(ui.profession or "All"),
        addon:GetDateRange(ui.range or "7d").label, addon:ExpansionFilterLabel())
    local changed = addon:ChangedSettings()
    Add("Settings changed: %s", #changed > 0 and table.concat(changed, ", ") or "none")

    -- How much data
    local included = 0
    for charKey in pairs(GoldsmithDB.characters or {}) do
        if addon:IsCharacterIncluded(charKey) then included = included + 1 end
    end
    local queued = 0
    for _, queue in pairs(GoldsmithDB.queues or {}) do queued = queued + #queue end
    local memory = ""
    if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
        UpdateAddOnMemoryUsage()
        memory = string.format(", memory %.0f MB", GetAddOnMemoryUsage("Goldsmith") / 1024)
    end
    Add("Data: %d characters (%d counted), %d recipes, %d transactions, %d items with price history, %d queued%s",
        Count(GoldsmithDB.characters), included, Count(GoldsmithDB.recipes), #addon.ledger:getAll(),
        Count(GoldsmithDB.priceHistory), queued, memory)

    -- Errors
    local errors = addon:GetErrors()
    if #errors == 0 then
        Add("Errors: none recorded")
    else
        Add("Errors (%d, newest first; %d this session):", #errors, sessionCount)
        for _, e in ipairs(errors) do
            Add("")
            Add("%dx, last %s, first %s, Goldsmith %s", e.count, date("%Y-%m-%d %H:%M", e.last),
                date("%Y-%m-%d %H:%M", e.first), e.version or "?")
            Add(e.message)
            if e.stack and e.stack ~= "" then Add(e.stack) end
        end
    end
    Add("```")
    return Anonymize(table.concat(lines, "\n"))
end

-- The Bug report page in Settings, under Support and feedback (user,
-- 2026-10-25: in the panel, not a window of its own; its intro is the
-- page's): the report in a box, selected to copy. page:Fill() builds it
-- afresh and selects it; onBack goes back to Support and feedback.

local BOX_HEIGHT = 330

function addon:BuildReportPage(parent, width, onBack)
    local page = CreateFrame("Frame", nil, parent)
    page:SetWidth(width)

    -- The box, scrolling inside a border
    local border = CreateFrame("Frame", nil, page, "BackdropTemplate")
    border:SetPoint("TOPLEFT", 0, 0)
    border:SetSize(width, BOX_HEIGHT)
    UI.Style(border, "panelRaised", "borderStrong")
    local ok, scroll = pcall(CreateFrame, "ScrollFrame", nil, border, "ScrollFrameTemplate")
    if not ok then scroll = CreateFrame("ScrollFrame", nil, border, "UIPanelScrollFrameTemplate") end
    scroll:SetPoint("TOPLEFT", 8, -8)
    scroll:SetPoint("BOTTOMRIGHT", -26, 8)
    local box = CreateFrame("EditBox", nil, scroll)
    box:SetMultiLine(true)
    box:SetAutoFocus(false)
    box:SetFontObject(addon:Font("small"))
    box:SetWidth(width - 34)
    box:SetTextColor(addon:Color("text"))
    scroll:SetScrollChild(box)
    local report = ""
    -- Typing can't change it
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            self:SetText(report)
            self:HighlightText()
        end
    end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- Clicking anywhere in the border selects it all again
    border:EnableMouse(true)
    border:SetScript("OnMouseDown", function() box:SetFocus(); box:HighlightText() end)

    local function SelectAll()
        box:SetFocus()
        box:HighlightText()
        C_Timer.After(0, function() if box:HasFocus() then box:HighlightText() end end)
    end

    local back = UI.Button(page, "Back", 80, 24, onBack)
    back:SetPoint("TOPRIGHT", border, "BOTTOMRIGHT", 0, -10)
    local selectButton = UI.Button(page, "Select all", 90, 24, SelectAll)
    selectButton:SetPoint("RIGHT", back, "LEFT", -8, 0)
    local clear = UI.Button(page, "Clear errors", 110, 24, function()
        addon:ClearErrors()
        page:Fill()
    end)
    clear:SetPoint("TOPLEFT", border, "BOTTOMLEFT", 0, -10)
    UI.SetTooltip(clear, function(tooltip)
        tooltip:AddLine("Clear errors", 1, 1, 1)
        tooltip:AddLine("Forget the saved errors, for example once you've reported them, so a new report only has new ones.", 0.8, 0.8, 0.8, true)
    end, "ANCHOR_RIGHT")

    function page:Fill()
        report = addon:BuildBugReport()
        box:SetText(report)
        scroll:SetVerticalScroll(0)
        clear:SetShown(#addon:GetErrors() > 0)
        SelectAll()
    end
    function page:Measure()
        page:SetHeight(BOX_HEIGHT + 10 + 24)
        return BOX_HEIGHT + 10 + 24
    end
    page:SetScript("OnHide", function() box:ClearFocus() end)
    return page
end

-- Opens Settings > Support and feedback > Bug report (/gsm report)
function addon:ShowBugReport()
    if not addon.ShowSettings then return end
    addon:ShowSettings()
    if GoldsmithSettings and GoldsmithSettings.Open then GoldsmithSettings:Open("report") end
end

_G.Goldsmith = addon
