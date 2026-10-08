local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Settings
--
-- Few settings, strong defaults. Saved for the account in
-- GoldsmithDB.settings; anything not set uses its default:
--   costMode    - "estimated" (from your stats) or "worst" (no procs)
--   priceSource - "auto" (whichever is newer), "auctionator" or "tsm"
--   minROI      - ROI (%) a craft needs to count as worth crafting
--   dealPercent - how far below its usual price a material counts as cheap
--   heldDays    - days unsold before a crafted item is held too long
--   keepDays    - days of transactions and daily gold kept; 0 = forever
--                 (addon:TrimHistory, Data.lua)
--   tooltips   - Goldsmith lines in item tooltips: "full", "short" or "off"
--   chat        - chat messages: "all", "money" (sales, purchases,
--                 deposits) or "off"
--   excluded    - { [charKey] = true } for characters left out of stock,
--                 concentration and the Overview
--   showMinimap - the minimap button (Minimap.lua)
-- Concentration in Crafts isn't here: the Crafts tab's switch remembers it.

local DEFAULTS = {
    costMode = "estimated",
    priceSource = "auto",
    minROI = 15,
    dealPercent = 10,
    heldDays = 7,
    keepDays = 0,
    tooltips = "full",
    explain = "always",
    chat = "all",
    showMinimap = true,
}

function addon:Setting(key)
    local settings = GoldsmithDB and GoldsmithDB.settings
    local value = settings and settings[key]
    if value == nil then return DEFAULTS[key] end
    return value
end

-- Settings that differ from the defaults, as "key = value" lines for the
-- bug report (Report.lua). Characters and items are counted, not named.
function addon:ChangedSettings()
    local list = {}
    for key, default in pairs(DEFAULTS) do
        local value = addon:Setting(key)
        if value ~= default then table.insert(list, key .. " = " .. tostring(value)) end
    end
    table.sort(list)
    local excluded = 0
    for _ in pairs(addon:Setting("excluded") or {}) do excluded = excluded + 1 end
    if excluded > 0 then table.insert(list, excluded .. " characters excluded") end
    local ignored = #addon:GetIgnoredItems()
    if ignored > 0 then table.insert(list, ignored .. " items ignored") end
    return list
end

function addon:SetSetting(key, value)
    GoldsmithDB.settings = GoldsmithDB.settings or {}
    GoldsmithDB.settings[key] = value
    if addon.Refresh then addon.Refresh() end
end

-- Caches
--
-- Working out every character's crafts and concentration plans takes long
-- enough to stutter the game, so results are kept until data changes:
-- addon.Refresh (prices, stock, recipes, crafts, settings) calls
-- DataChanged. Switching tabs, scrolling and excluding a character only
-- redraw. As a safety net a cache also empties after CACHE_SECONDS.
local CACHE_SECONDS = 300
addon.dataVersion = 0

function addon:DataChanged()
    addon.dataVersion = addon.dataVersion + 1
end

-- cache:Get() returns a table to keep results in, emptied when data has
-- changed since; cache:Clear() empties it now. A new table rather than
-- wiping the old one: work paused across frames (addon:Yield) may still
-- hold the old one, and must not put results from old data in the new.
function addon:NewCache()
    local cache = { store = {}, version = -1, time = 0 }
    function cache:Get()
        if self.version ~= addon.dataVersion or GetTime() - self.time > CACHE_SECONDS then
            self.store = {}
            self.version, self.time = addon.dataVersion, GetTime()
        end
        return self.store
    end
    function cache:Clear() self.version = -1 end
    return cache
end

-- Work spread over frames
--
-- Never a stutter: the user would rather see something load than have
-- the game freeze, even if it takes a little longer (2026-10-06). A
-- window refresh runs as work (addon:RunWork), in a coroutine: loops that
-- can run long call addon:Yield(), which waits for the next frame once
-- this frame's FRAME_BUDGET_MS is used. Outside work, Yield does nothing,
-- so the same functions still answer at once for tooltips and events.
--
-- Rules for code that yields:
--   - never inside a pcall (Lua can't pause there): code that needs one
--     counts itself in addon.noYield and Yield waits until it's 0.
--     WithCharacter skips its pcall inside work (addon:InWork) instead
--   - whose stats are in use (addon.statsChar) belongs to the work: it's
--     put back while the work waits and restored when it carries on, so
--     other code never sees an alt's stats
--   - build shared indexes in a local and store them when complete, so
--     nothing else sees half of one while the work is paused
--   - loop over a list, not pairs() of a shared table (addon:Keys)
local FRAME_BUDGET_MS = 6
addon.noYield = 0
local current            -- the newest work
local works = setmetatable({}, { __mode = "k" }) -- coroutine -> its work

-- True when running as work that can wait for frames
function addon:InWork()
    local co = coroutine.running()
    return co ~= nil and works[co] ~= nil
end

function addon:Yield()
    if addon.noYield > 0 then return end
    local co = coroutine.running()
    local work = co and works[co]
    if not work then return end
    -- Replaced by newer work: stop here for good
    if work ~= current then coroutine.yield() end
    if debugprofilestop() - work.sliceStart >= FRAME_BUDGET_MS then coroutine.yield() end
end

-- The longest single frame any work has taken this session, by label
-- (the tab), for /gsm perf: { [label] = ms }, and where that frame's
-- work stopped (where to look for a hitch): { [label] = "file:line < ..." }
addon.workLongest = {}
addon.workLongestWhere = {}

-- Where a paused or failed coroutine is, as "File.lua:123 < File.lua:45"
-- (the game's debugstack, else Lua's traceback; "" if neither works)
local function WhereIs(co)
    local ok, stack = false, nil
    if debugstack then ok, stack = pcall(debugstack, co, 1, 8, 0) end
    if not ok and debug and debug.traceback then ok, stack = pcall(debug.traceback, co) end
    if not ok or type(stack) ~= "string" then return "" end
    local places = {}
    for place in stack:gmatch("([%w_]+%.lua\"?%]?:%d+)") do
        place = place:gsub("[\"%]]", "")
        if not place:match("^Settings%.lua") and #places < 5 then table.insert(places, place) end
    end
    return table.concat(places, " < ")
end

-- Runs fn spread over frames. Newer work stops older work where it is.
-- onSlow() runs the first time it has to wait for a frame (show loading);
-- onDone(work) when it finishes, with work.totalMs, work.longestMs and
-- work.frames. Errors go to the game's error display. label names it in
-- addon.workLongest.
function addon:RunWork(fn, onSlow, onDone, label)
    local work = { co = coroutine.create(fn), statsChar = addon.statsChar,
        totalMs = 0, longestMs = 0, frames = 0 }
    works[work.co] = work
    current = work
    local slow = false
    local function Step()
        if current ~= work then return end
        work.sliceStart = debugprofilestop()
        -- The work's own stats while it runs (see the rules above)
        local outside = addon.statsChar
        addon.statsChar = work.statsChar
        local ok, err = coroutine.resume(work.co)
        work.statsChar = addon.statsChar
        addon.statsChar = outside
        local ms = debugprofilestop() - work.sliceStart
        work.totalMs, work.frames = work.totalMs + ms, work.frames + 1
        work.longestMs = math.max(work.longestMs, ms)
        if label and ms > (addon.workLongest[label] or 0) then
            addon.workLongest[label] = ms
            addon.workLongestWhere[label] = WhereIs(work.co)
        end
        if not ok then
            if current == work then current = nil end
            local where = WhereIs(work.co)
            geterrorhandler()(tostring(err) .. (where ~= "" and ("\nin " .. where) or ""))
            if onDone then onDone(work) end
            return
        end
        if coroutine.status(work.co) == "dead" then
            if current == work then current = nil end
            if onDone then onDone(work) end
            return
        end
        if current ~= work then return end
        if not slow then
            slow = true
            if onSlow then onSlow() end
        end
        C_Timer.After(0, Step)
    end
    Step()
end

-- A table's keys as a list (in pairs order), for loops that yield:
-- something may add to the table while the work waits, which a pairs()
-- loop can't survive
function addon:Keys(t)
    local list = {}
    for k in pairs(t) do list[#list + 1] = k end
    return list
end

-- table.sort, except for long lists inside work: table.sort can't wait for
-- a frame, so those get a merge sort that can (stable, so equal items may
-- come out in a different order than table.sort would give)
local SORT_IN_ONE_GO = 1000
function addon:Sort(list, less)
    local n = #list
    if n <= SORT_IN_ONE_GO or not addon:InWork() then
        table.sort(list, less)
        return
    end
    local from, to = list, {}
    local width, steps = 1, 0
    while width < n do
        for left = 1, n, 2 * width do
            local mid, right = math.min(left + width, n + 1), math.min(left + 2 * width, n + 1)
            local i, j, k = left, mid, left
            while i < mid and j < right do
                if less(from[j], from[i]) then
                    to[k], j = from[j], j + 1
                else
                    to[k], i = from[i], i + 1
                end
                k = k + 1
            end
            while i < mid do to[k], i, k = from[i], i + 1, k + 1 end
            while j < right do to[k], j, k = from[j], j + 1, k + 1 end
            steps = steps + (right - left)
            if steps >= 512 then
                steps = 0
                addon:Yield()
            end
        end
        from, to = to, from
        width = width * 2
    end
    if from ~= list then
        for i = 1, n do list[i] = from[i] end
    end
end

-- True while work is waiting for the next frame
function addon:IsWorking()
    return current ~= nil
end

-- False for a character excluded (Settings or the Characters tab)
function addon:IsCharacterIncluded(charKey)
    local excluded = addon:Setting("excluded")
    return not (excluded and excluded[charKey])
end

-- Also on the Characters tab. Cached results are kept for every character,
-- so excluding one only redraws.
function addon:SetCharacterIncluded(charKey, included)
    GoldsmithDB.settings = GoldsmithDB.settings or {}
    GoldsmithDB.settings.excluded = GoldsmithDB.settings.excluded or {}
    GoldsmithDB.settings.excluded[charKey] = (not included) or nil
    if addon.RefreshWindow then addon.RefreshWindow() end
end
local function SetCharacterIncluded(charKey, included) addon:SetCharacterIncluded(charKey, included) end

-- Ignored items: crafts you never want suggested, such as gear nobody buys.
-- Right-click a craft on the Crafts tab > Ignore this item. They're left
-- out of Do this next (WhyNotRecommended) and the Crafts list (unless Show
-- ignored is ticked there). Undo from the same menu, or Settings > Ignored
-- items. Keyed by the recipe's item ID, so every quality tier goes:
-- GoldsmithDB.ignored[itemID] = { name, time }
function addon:IsIgnored(itemID)
    return itemID ~= nil and GoldsmithDB.ignored ~= nil and GoldsmithDB.ignored[itemID] ~= nil
end

function addon:SetIgnored(itemID, name, ignored)
    if not itemID then return end
    GoldsmithDB.ignored = GoldsmithDB.ignored or {}
    GoldsmithDB.ignored[itemID] = ignored and { name = name, time = time() } or nil
    if ignored then
        print("|cFF00FF00[Goldsmith]|r Ignoring " .. (name or "that item")
            .. ". To undo: right-click it on Crafts (tick Show ignored in the Show menu), or Settings > Ignored items.")
    else
        print("|cFF00FF00[Goldsmith]|r No longer ignoring " .. (name or "that item") .. ".")
    end
    -- Suggestions are cached; this makes them work it out again
    addon:DataChanged()
    if addon.RefreshWindow then addon.RefreshWindow() end
end

-- { { itemID, name } }, by name
function addon:GetIgnoredItems()
    local list = {}
    for itemID, entry in pairs(GoldsmithDB.ignored or {}) do
        table.insert(list, { itemID = itemID, name = entry.name or C_Item.GetItemNameByID(itemID) or ("item " .. itemID) })
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- Chat messages Goldsmith prints by itself (not answers to /gsm commands).
-- kind is "money" (a sale, purchase or deposit) or "info" (anything else).
function addon:Notify(kind, msg, ...)
    local chat = addon:Setting("chat")
    if chat == "off" or (chat == "money" and kind ~= "money") then return end
    print("|cFF00FF00[Goldsmith]|r " .. string.format(msg, ...))
end

-- Keybinding

-- The key that opens Goldsmith ("CTRL-G"), or nil if none is set
function addon:ToggleKeyText()
    local key = GetBindingKey("GOLDSMITH_TOGGLE")
    return key and GetBindingText(key)
end

-- Opens the game's Keybindings page. Goldsmith closes so it isn't in the
-- way; the new key brings it back.
function addon:OpenKeybindings()
    local ok = Settings and Settings.OpenToCategory and Settings.KEYBINDINGS_CATEGORY_ID
        and pcall(Settings.OpenToCategory, Settings.KEYBINDINGS_CATEGORY_ID)
    if not ok then
        print("|cFF00FF00[Goldsmith]|r Set a key in Options > Keybindings > AddOns > Goldsmith.")
        return
    end
    if addon.window then addon.window:Hide() end
    print("|cFF00FF00[Goldsmith]|r Scroll down to AddOns > Goldsmith and pick a key for \"Show or hide Goldsmith\".")
end

-- Panel

local COLUMN_WIDTH = 400
local WIDTH = 2 * COLUMN_WIDTH + 16
local ROW_HEIGHT = 74
local ROWS_TOP = -78

local CHOICES = {
    costMode = {
        { value = "estimated", label = "Estimated (recommended)" },
        { value = "worst", label = "Worst case" },
    },
    priceSource = {
        { value = "auto", label = "Automatic (recommended)" },
        { value = "auctionator", label = "Prefer Auctionator" },
        { value = "tsm", label = "Prefer TSM" },
    },
    minROI = {},
    dealPercent = {},
    heldDays = {},
    keepDays = {
        { value = 0, label = "Forever" },
        { value = 730, label = "2 years" },
        { value = 365, label = "1 year" },
        { value = 180, label = "6 months" },
        { value = 90, label = "3 months" },
    },
    tooltips = {
        { value = "full", label = "Full (recommended)" },
        { value = "short", label = "Short" },
        { value = "off", label = "Off" },
    },
    explain = {
        { value = "always", label = "Always (recommended)" },
        { value = "ctrl", label = "Hold Ctrl" },
    },
    chat = {
        { value = "all", label = "Everything (recommended)" },
        { value = "money", label = "Sales and purchases" },
        { value = "off", label = "Off" },
    },
}
for _, value in ipairs({ 0, 5, 10, 15, 20, 30, 50 }) do
    table.insert(CHOICES.minROI, { value = value,
        label = value == 0 and "Any profit" or string.format("%d%%", value) })
end
for _, value in ipairs({ 5, 10, 15, 20, 25 }) do
    table.insert(CHOICES.dealPercent, { value = value, label = string.format("%d%% below usual", value) })
end
for _, value in ipairs({ 3, 5, 7, 14, 21, 30 }) do
    table.insert(CHOICES.heldDays, { value = value, label = string.format("%d days", value) })
end
-- Mark the defaults
for key, list in pairs(CHOICES) do
    for _, c in ipairs(list) do
        if c.value == DEFAULTS[key] and not c.label:find("recommended") then
            c.label = c.label .. " (recommended)"
        end
    end
end

local function LabelFor(choices, value)
    for _, c in ipairs(choices) do
        if c.value == value then return c.label end
    end
    return choices[1].label
end

-- Hover text for each setting: a title, then paragraphs
local HELP = {
    costMode = {
        "Show cost as",
        "Estimated: what a craft costs you on average, using your multicraft (extra items) and resourcefulness (materials back). The most accurate number for deciding what to craft.",
        "Worst case: no multicraft or resourcefulness at all, like TSM's crafting cost. Cautious: it makes every craft look less profitable than it usually is.",
        "Used for Cost, Profit and ROI on the Crafts tab and the Overview's best crafts, and for break-even when you haven't crafted an item yet. The craft hover and item pages always show both.",
    },
    priceSource = {
        "Price source",
        "Automatic: an Auctionator scan made since you logged in wins; otherwise TSM's price, which its app updates about hourly. Live prices from AH searches you've just made are used first.",
        "Prefer Auctionator: Auctionator's last scan even if it's days old, TSM only for items it hasn't seen.",
        "Prefer TSM: TSM's price, Auctionator only for items TSM has no price for. Live AH searches are ignored.",
        "Either way, a listing far below or above the usual price is replaced by TSM's market value when TSM is installed.",
    },
    minROI = {
        "Worth crafting at",
        "The ROI (profit as a share of what the craft costs) a craft needs to count as worth doing.",
        "Used by Profitable only on the Crafts tab and by Best crafts right now on the Overview.",
        "Higher leaves room for undercuts and slow sales; 15% is a good start.",
    },
    dealPercent = {
        "Cheap materials",
        "How far below its usual price a material has to be for the Overview's Cheap materials today.",
        "The usual price is the middle of the prices saved each day Auctionator scans, so it needs a few days of history.",
    },
    heldDays = {
        "Held too long",
        "How many days a crafted item can sit unsold before Goldsmith flags it: the Overview's Gold in stock, the Items tab's Held board and the Held column turn orange.",
        "Slow-selling gear might want 14 or more; fast consumables less.",
    },
    keepDays = {
        "Keep history for",
        "How long Goldsmith keeps your purchases, sales and AH deposits, and each day's gold. Older ones are deleted when you log in.",
        "Forever is fine for most players: Goldsmith handles years of busy goldmaking. A shorter time keeps its saved data smaller.",
        "Profit charts, gold per hour and History only go back as far as what's kept. Purchases of items you still hold are always kept, since what those items cost you comes from them.",
    },
    tooltips = {
        "Item tooltips",
        "Full: everything Goldsmith knows about the item, such as your average cost, how today's price compares, what yours cost to make, break-even, and craft cost and profit with your stats.",
        "Short: craft cost and profit for things you craft, otherwise your average cost and today's price against usual.",
        "Off: no Goldsmith lines. Everything is still on the item's page in /gsm.",
    },
    explain = {
        "Hover explanations",
        "Always: Goldsmith's hovers explain what each number means and how it's worked out, and what clicking does.",
        "Hold Ctrl: hovers show just the numbers and warnings. Hold Ctrl over one to see its explanations; let go and they're gone. Once you know how Goldsmith works.",
    },
    chat = {
        "Chat messages",
        "Everything: each sale, purchase and AH deposit, saved recipes and milling results.",
        "Sales and purchases: only messages about money (sales with their profit, purchases, deposits).",
        "Off: none. Everything is still recorded; see the History tab. Answers to /gsm commands always show.",
    },
    characters = {
        "Exclude characters",
        "Tick a character to leave it out of Gold in stock, concentration, total gold, the Crafts tab and Do this next: a bank alt, or one you've stopped playing.",
        "Its sales and purchases still count, and Goldsmith keeps recording it while you play it.",
        "The Characters tab has the same switch, and can remove a character you've deleted.",
    },
    ignored = {
        "Ignored items",
        "Crafts you've told Goldsmith to ignore: they're never suggested in Do this next and are hidden on the Crafts tab.",
        "Untick one here to stop ignoring it. To ignore a craft, right-click it on the Crafts tab. Tick Show ignored in the Crafts tab's Show menu to see ignored crafts there.",
    },
    showMinimap = {
        "Minimap button",
        "The Goldsmith button on the edge of the minimap: click to show or hide Goldsmith, right-click for these settings, drag to move it.",
        "Other ways to open Goldsmith: /gsm, a key (Options > Keybindings > AddOns > Goldsmith), or the addons button by the minimap.",
    },
    keybind = {
        "Key to open Goldsmith",
        "Set key opens the game's Keybindings. Goldsmith is under AddOns, near the bottom: click the box next to Show or hide Goldsmith and press the key you want.",
        "Goldsmith closes while you do it; press your new key to bring it back.",
    },
}

local function AddHelp(tooltip, key)
    local help = HELP[key]
    tooltip:AddLine(help[1], 1, 1, 1)
    for i = 2, #help do
        tooltip:AddLine(help[i], 0.8, 0.8, 0.8, true)
    end
end

-- A setting row: name and a one-line description on the left, the control
-- on the right; hovering anywhere on the row explains it in full
-- (placed by panel:Update, which skips rows that don't apply)
local function Row(panel, key, title, description)
    local row = CreateFrame("Frame", nil, panel)
    row:SetSize(COLUMN_WIDTH - 32, ROW_HEIGHT - 8)
    row:EnableMouse(true)
    row.title = UI.Text(row, "body", "text")
    row.title:SetPoint("TOPLEFT", 0, -4)
    row.title:SetText(title)
    row.description = UI.Text(row, "small", "muted")
    row.description:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -5)
    row.description:SetWidth(COLUMN_WIDTH - 32 - 180)
    row.description:SetWordWrap(true)
    row.description:SetMaxLines(3)
    row.description:SetText(description)
    UI.SetTooltip(row, function(tooltip) AddHelp(tooltip, key) end, "ANCHOR_LEFT")
    return row
end

local function Dropdown(row, key, build)
    local dropdown = UI.Dropdown(row, 170, build)
    dropdown:SetPoint("TOPRIGHT", 0, 0)
    UI.SetTooltip(dropdown, function(tooltip) AddHelp(tooltip, key) end, "ANCHOR_LEFT")
    return dropdown
end

-- A row whose dropdown picks one of CHOICES[key]
local function ChoiceRow(panel, key, title, description)
    local row = Row(panel, key, title, description)
    row.control = Dropdown(row, key, function(root)
        for _, c in ipairs(CHOICES[key]) do
            root:CreateRadio(c.label, function() return addon:Setting(key) == c.value end,
                function() addon:SetSetting(key, c.value); panel:Update() end)
        end
    end)
    function row:Update() row.control:SetLabel(LabelFor(CHOICES[key], addon:Setting(key))) end
    return row
end

local function CharacterLabel(entry)
    local c = entry.data
    local realm = c.realm ~= GetRealmName() and (" (" .. (c.realm or "?") .. ")") or ""
    return (c.name or entry.key) .. realm .. (entry.key == addon.charKey and ", you" or "")
end

-- Keep history for: a shorter time deletes old transactions, so it asks
-- first when there are any to delete
local function ApplyKeepDays(value, panel)
    addon:SetSetting("keepDays", value)
    local removed = addon:TrimHistory()
    if removed > 0 then
        addon:Notify("info", "Deleted %d transactions from before %s.", removed,
            date("%Y-%m-%d", time() - value * 86400))
    end
    panel:Update()
end

StaticPopupDialogs["GOLDSMITH_KEEP_DAYS"] = {
    text = "Keep history for %s?\n\n%s transactions older than that will be deleted now. This can't be undone.",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, data) ApplyKeepDays(data.value, data.panel) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function SetKeepDays(value, panel)
    local count = addon:CountOldHistory(value)
    if count == 0 then
        ApplyKeepDays(value, panel)
    else
        StaticPopup_Show("GOLDSMITH_KEEP_DAYS", LabelFor(CHOICES.keepDays, value):lower(),
            BreakUpLargeNumbers(count), { value = value, panel = panel })
    end
end

local COLUMNS = {
    { title = "Crafting and prices", rows = { "costMode", "priceSource", "minROI", "dealPercent", "heldDays", "ignored", "keepDays" } },
    { title = "Display", rows = { "tooltips", "explain", "chat", "characters", "showMinimap", "keybind" } },
}

function addon:CreateSettingsPanel(parent)
    local panel = CreateFrame("Frame", "GoldsmithSettings", parent, "BackdropTemplate")
    panel:SetWidth(WIDTH)
    UI.Style(panel, "dialog", "borderGold")
    panel:SetFrameStrata("DIALOG")
    panel:EnableMouse(true)
    panel:Hide()

    local title = UI.Text(panel, "heading")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Settings")
    local close = UI.IconButton(panel, 26, "X", "Close", function() panel:Hide() end, { hoverColor = "loss" })
    close:SetPoint("TOPRIGHT", -8, -8)

    for i, column in ipairs(COLUMNS) do
        local heading = UI.Text(panel, "label", "dim")
        heading:SetPoint("TOPLEFT", 16 + (i - 1) * COLUMN_WIDTH, -50)
        heading:SetText(column.title:upper())
    end

    -- A gold bar between the columns, from the headings to above the footer
    local divider = UI.Line(panel, "borderGold")
    divider:SetWidth(2)
    divider:SetPoint("TOPLEFT", COLUMN_WIDTH - 1, -46)
    divider:SetPoint("BOTTOMLEFT", COLUMN_WIDTH - 1, 44)

    local rows = {}

    rows.costMode = ChoiceRow(panel, "costMode", "Show cost as", "Estimated uses your stats; worst case assumes no procs.")
    rows.priceSource = ChoiceRow(panel, "priceSource", "Price source", "Where AH prices come from when both Auctionator and TSM have one.")
    rows.minROI = ChoiceRow(panel, "minROI", "Worth crafting at", "The ROI a craft needs for Profitable only and Best crafts.")
    rows.dealPercent = ChoiceRow(panel, "dealPercent", "Cheap materials", "How far below usual a material's price counts as cheap.")
    rows.heldDays = ChoiceRow(panel, "heldDays", "Held too long", "Days unsold before a crafted item is flagged.")
    rows.keepDays = Row(panel, "keepDays", "Keep history for", "How long purchases, sales and deposits are kept.")
    rows.keepDays.control = Dropdown(rows.keepDays, "keepDays", function(root)
        for _, c in ipairs(CHOICES.keepDays) do
            root:CreateRadio(c.label, function() return addon:Setting("keepDays") == c.value end,
                function() SetKeepDays(c.value, panel) end)
        end
    end)
    function rows.keepDays:Update() self.control:SetLabel(LabelFor(CHOICES.keepDays, addon:Setting("keepDays"))) end
    rows.tooltips = ChoiceRow(panel, "tooltips", "Item tooltips", "Goldsmith's lines in the game's item tooltips.")
    rows.explain = ChoiceRow(panel, "explain", "Hover explanations", "What the numbers in hovers mean, or only while you hold Ctrl.")
    rows.chat = ChoiceRow(panel, "chat", "Chat messages", "What Goldsmith says in chat as things happen.")

    rows.characters = Row(panel, "characters", "Exclude characters", "Characters left out of stock, concentration, Crafts and Do this next.")
    rows.characters.control = Dropdown(rows.characters, "characters", function(root)
        root:CreateTitle("Tick to exclude")
        for _, entry in ipairs(addon:GetCharacters()) do
            root:CreateCheckbox(CharacterLabel(entry),
                function() return not addon:IsCharacterIncluded(entry.key) end,
                function()
                    SetCharacterIncluded(entry.key, not addon:IsCharacterIncluded(entry.key))
                    panel:Update()
                end)
        end
    end)
    function rows.characters:Update()
        local excluded = 0
        for _, entry in ipairs(addon:GetCharacters()) do
            if not addon:IsCharacterIncluded(entry.key) then excluded = excluded + 1 end
        end
        self.control:SetLabel(excluded == 0 and "None excluded" or string.format("%d excluded", excluded))
    end

    rows.ignored = Row(panel, "ignored", "Ignored items", "Crafts never suggested and hidden on Crafts. Untick to undo.")
    rows.ignored.control = Dropdown(rows.ignored, "ignored", function(root)
        local list = addon:GetIgnoredItems()
        if #list == 0 then
            root:CreateTitle("Nothing ignored. Right-click a craft on the Crafts tab to ignore it.")
            return
        end
        root:CreateTitle("Untick to stop ignoring")
        -- Ten at a time, with a scroll bar, once the list gets long
        if #list > 10 and root.SetScrollMode then root:SetScrollMode(11 * 20) end
        for _, entry in ipairs(list) do
            root:CreateCheckbox(entry.name,
                function() return addon:IsIgnored(entry.itemID) end,
                function()
                    addon:SetIgnored(entry.itemID, entry.name, not addon:IsIgnored(entry.itemID))
                    panel:Update()
                end)
        end
    end)
    function rows.ignored:Update()
        local count = #addon:GetIgnoredItems()
        self.control:SetLabel(count == 0 and "None ignored" or string.format("%d ignored", count))
    end

    rows.showMinimap = Row(panel, "showMinimap", "Minimap button", "A button by the minimap that opens Goldsmith.")
    rows.showMinimap.control = UI.Checkbox(rows.showMinimap, "Show", function(checked)
        addon:SetSetting("showMinimap", checked)
        addon:UpdateMinimapButton()
        panel:Update()
    end)
    rows.showMinimap.control:SetPoint("TOPRIGHT", 0, 0)
    UI.SetTooltip(rows.showMinimap.control, function(tooltip) AddHelp(tooltip, "showMinimap") end, "ANCHOR_LEFT")
    function rows.showMinimap:Update() self.control:SetChecked(addon:Setting("showMinimap")) end

    rows.keybind = Row(panel, "keybind", "Key to open Goldsmith", "")
    rows.keybind.control = UI.Button(rows.keybind, "Set key", 170, 24, function() addon:OpenKeybindings() end)
    rows.keybind.control:SetPoint("TOPRIGHT", 0, 0)
    UI.SetTooltip(rows.keybind.control, function(tooltip) AddHelp(tooltip, "keybind") end, "ANCHOR_LEFT")
    function rows.keybind:Update()
        local key = addon:ToggleKeyText()
        self.description:SetText(key and ("Opens with " .. key .. ".") or "No key set yet.")
        self.control:SetLabel(key and "Change key" or "Set key")
    end

    local help = addon:CreateHelpPanel(parent, panel)
    local helpButton = UI.Button(panel, "Help", 80, 24, function()
        panel:Hide()
        help:Show()
    end)
    helpButton:SetPoint("BOTTOMRIGHT", -16, 10)
    UI.SetTooltip(helpButton, function(tooltip)
        tooltip:AddLine("Help", 1, 1, 1)
        tooltip:AddLine("How to get started, what each tab is for, and the /gsm commands.", 0.8, 0.8, 0.8, true)
    end, "ANCHOR_LEFT")

    local support = addon:CreateSupportPanel(parent, panel)
    local supportButton = UI.Button(panel, "Support and feedback", 160, 24, function()
        panel:Hide()
        support:Show()
    end)
    supportButton:SetPoint("RIGHT", helpButton, "LEFT", -8, 0)
    UI.SetTooltip(supportButton, function(tooltip)
        tooltip:AddLine("Support and feedback", 1, 1, 1)
        tooltip:AddLine("Report a bug or suggest an idea on GitHub.", 0.8, 0.8, 0.8, true)
        local errors = #addon:GetErrors()
        if errors > 0 then
            tooltip:AddLine(string.format("Goldsmith has saved %d error%s. Copy bug report there includes them.",
                errors, errors == 1 and "" or "s"), 1, 0.6, 0.2, true)
        end
    end, "ANCHOR_LEFT")

    local footer = UI.Text(panel, "label", "dim")
    footer:SetPoint("BOTTOMLEFT", 16, 16)
    footer:SetText("Saved for all your characters. Hover a setting for details.")

    function panel:Update()
        for _, row in pairs(rows) do row:Update() end
        supportButton.label:SetTextColor(addon:Color(#addon:GetErrors() > 0 and "warning" or "text"))

        -- Price source only matters with both price addons installed. Laid
        -- out here rather than once: TSM can finish loading after Goldsmith.
        local hasAuctionator = Auctionator and Auctionator.API and Auctionator.API.v1
        rows.priceSource:SetShown(hasAuctionator and addon:HasTSM() and true or false)
        local lowest = ROWS_TOP
        for i, column in ipairs(COLUMNS) do
            local top = ROWS_TOP
            for _, key in ipairs(column.rows) do
                local row = rows[key]
                if row:IsShown() then
                    row:ClearAllPoints()
                    row:SetPoint("TOPLEFT", 16 + (i - 1) * COLUMN_WIDTH, top)
                    top = top - ROW_HEIGHT
                end
            end
            lowest = math.min(lowest, top)
        end
        panel:SetHeight(-lowest + 40)
    end
    panel:SetScript("OnShow", function() panel:Update() end)
    return panel
end

-- Help
--
-- What a new player needs, inside the game: WoW can't open a web page, so
-- a link to the README would only be text to copy.

local HELP_WIDTH = 560

local HELP_SECTIONS = {
    { "Getting started",
      "Open each profession once on every crafter (press K) so Goldsmith loads its recipes and crafting stats. Prices come with Goldsmith Data from the start; scan the AH with Auctionator for live ones. From then on, purchases, sales, crafts and AH deposits are recorded by themselves." },
    { "Opening Goldsmith",
      "/gsm, the Goldsmith button on the minimap, the addons button by the minimap, or a key of your own (Settings > Key to open Goldsmith)." },
    -- One line per tab, its name in the text color (Theme.lua loads first)
    { "The tabs", table.concat({
        addon:Colorize("Overview", "text") .. ": how you're doing and what to do next.",
        addon:Colorize("Crafts", "text") .. ": what you can make, with its cost, profit and how well it sells. Show picks Recommended, Profitable, All crafts or Not learned yet (recipes worth going to learn), and can hide gear. Click a craft for a shopping plan.",
        addon:Colorize("Queue", "text") .. ": crafts lined up to make, with one shopping list and a button that does the next step.",
        addon:Colorize("Items", "text") .. ": any item's page, and In my bags for everything you hold.",
        addon:Colorize("History", "text") .. ": every purchase, sale, craft and deposit; right-click an entry to fix it.",
        addon:Colorize("Characters", "text") .. ": a to-do list for each character, its craft cooldowns, and which characters count.",
      }, "\n") },
    { "Hovers",
      "Hover any number to see what it means and how it's worked out. Once you know, Settings > Hover explanations > Hold Ctrl keeps hovers short: hold Ctrl over one to see the explanations again." },
    { "Item tooltips",
      "Show your cost, profit and break-even price. Hold Shift for each material's cost. Settings > Item tooltips makes them shorter or turns them off." },
    { "Recommended: Auctionator",
      "Goldsmith works without it: Goldsmith Data brings the region's AH prices, refreshed with each daily update, and how well each item sells. Auctionator adds two things. Its scans give live prices for the moment you buy and sell. And its Shopping tab is where Goldsmith's shopping lists go: Send to Auctionator in a plan or the Queue makes a list there, and Auctionator searches the AH for every item on it. The game's own AH has no shopping lists." },
    { "Recommended: TSM",
      "Goldsmith works without it too. With TSM installed, Goldsmith uses its region sales per day and sale rates instead of Goldsmith Data's Sells / Slow / Hardly sells, a check on listings far from the usual price, and prices between Auctionator scans. TSM's numbers are probably more accurate, but Goldsmith's own sell levels work well without it." },
    { "Commands",
      "/gsm help lists them all. Handy ones: /gsm chars (your characters and concentration), /gsm cooldowns (craft cooldowns on every character), /gsm recipes, /gsm milling, /gsm setup (the getting started checklist), /gsm tour (a short tour of the window)." },
}

function addon:CreateHelpPanel(parent, settings)
    local panel = CreateFrame("Frame", "GoldsmithHelp", parent, "BackdropTemplate")
    panel:SetWidth(HELP_WIDTH)
    panel:SetPoint("TOPRIGHT", settings, "TOPRIGHT")
    UI.Style(panel, "dialog", "borderGold")
    panel:SetFrameStrata("DIALOG")
    panel:EnableMouse(true)
    panel:Hide()

    local title = UI.Text(panel, "heading")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Help")
    local close = UI.IconButton(panel, 26, "X", "Close", function() panel:Hide() end, { hoverColor = "loss" })
    close:SetPoint("TOPRIGHT", -8, -8)

    local above
    local texts = {}
    for _, section in ipairs(HELP_SECTIONS) do
        local heading = UI.Text(panel, "body", "text")
        if above then
            heading:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -14)
        else
            heading:SetPoint("TOPLEFT", 16, -50)
        end
        heading:SetText(section[1])
        local text = UI.Text(panel, "small", "muted")
        text:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)
        text:SetWidth(HELP_WIDTH - 32)
        text:SetWordWrap(true)
        text:SetSpacing(2)
        text:SetText(section[2])
        table.insert(texts, heading)
        table.insert(texts, text)
        above = text
    end

    local setupButton = UI.Button(panel, "Show getting started", 160, 24, function()
        panel:Hide()
        addon:ShowSetup()
    end)
    setupButton:SetPoint("BOTTOMLEFT", 16, 12)
    local tourButton = UI.Button(panel, "Take the tour", 120, 24, function()
        panel:Hide()
        addon:StartTour()
    end)
    tourButton:SetPoint("LEFT", setupButton, "RIGHT", 8, 0)
    local back = UI.Button(panel, "Back to settings", 130, 24, function()
        panel:Hide()
        settings:Show()
    end)
    back:SetPoint("BOTTOMRIGHT", -16, 12)

    -- Tall enough for the text, however it wrapped: the title, each
    -- heading and paragraph with the gaps between them, and the buttons
    panel:SetScript("OnShow", function()
        local height = 50 + 52 + (#HELP_SECTIONS - 1) * 14 + #HELP_SECTIONS * 4
        for _, fs in ipairs(texts) do height = height + fs:GetStringHeight() end
        panel:SetHeight(height)
    end)
    return panel
end

-- Support and feedback
--
-- Where to report bugs and ideas: GitHub issues. Addons can't open a web
-- page, so the link is in a box to copy. No donation link here: Blizzard's
-- add-on policy doesn't allow asking for donations in game, so that lives
-- on the CurseForge page (2026-10-06).

local SUPPORT_WIDTH = 560

-- A box showing text to copy: clicking selects all of it, and typing
-- can't change it
local function CopyBox(parent, width, text)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetSize(width, 26)
    UI.Style(box, "panelRaised", "borderStrong")
    box:SetFontObject(addon:Font("body"))
    box:SetTextInsets(8, 8, 0, 0)
    box:SetAutoFocus(false)
    box:SetText(text)
    box:SetCursorPosition(0)
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput then
            self:SetText(text)
            self:HighlightText()
        end
    end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- Again next frame: the click that gave focus can move the cursor
    box:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(addon:Color("gold"))
        self:HighlightText()
        C_Timer.After(0, function() if self:HasFocus() then self:HighlightText() end end)
    end)
    box:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(addon:Color("borderStrong"))
        self:HighlightText(0, 0)
        self:SetCursorPosition(0)
    end)
    return box
end

function addon:CreateSupportPanel(parent, settings)
    local panel = CreateFrame("Frame", "GoldsmithSupport", parent, "BackdropTemplate")
    panel:SetWidth(SUPPORT_WIDTH)
    panel:SetPoint("TOPRIGHT", settings, "TOPRIGHT")
    UI.Style(panel, "dialog", "borderGold")
    panel:SetFrameStrata("DIALOG")
    panel:EnableMouse(true)
    panel:Hide()

    local title = UI.Text(panel, "heading")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Support and feedback")
    local close = UI.IconButton(panel, 26, "X", "Close", function() panel:Hide() end, { hoverColor = "loss" })
    close:SetPoint("TOPRIGHT", -8, -8)

    local intro = UI.Text(panel, "small", "muted")
    intro:SetPoint("TOPLEFT", 16, -50)
    intro:SetWidth(SUPPORT_WIDTH - 32)
    intro:SetWordWrap(true)
    intro:SetSpacing(2)
    intro:SetText("Found a bug or have an idea? Open an issue on GitHub. Click the link, press Ctrl+C to copy it, and paste it into your browser.")

    local link = CopyBox(panel, SUPPORT_WIDTH - 32, addon.ISSUES_URL)
    link:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -10)

    local heading = UI.Text(panel, "body", "text")
    heading:SetPoint("TOPLEFT", link, "BOTTOMLEFT", 0, -16)
    heading:SetText("For a bug, it helps to include")
    local details = UI.Text(panel, "small", "muted")
    details:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)
    details:SetWidth(SUPPORT_WIDTH - 32)
    details:SetWordWrap(true)
    details:SetSpacing(2)

    local back = UI.Button(panel, "Back to settings", 130, 24, function()
        panel:Hide()
        settings:Show()
    end)
    back:SetPoint("BOTTOMRIGHT", -16, 12)

    -- The details below, gathered for you (Report.lua)
    local report = addon:CreateReportPanel(parent, panel)
    local reportButton = UI.Button(panel, "Copy bug report", 140, 24, function()
        panel:Hide()
        report:Show()
    end)
    reportButton:SetPoint("BOTTOMLEFT", 16, 12)
    local errorsText = UI.Text(panel, "small", "warning")
    errorsText:SetPoint("LEFT", reportButton, "RIGHT", 10, 0)

    -- Tall enough for the text, however it wrapped: the title, the intro,
    -- the link, the heading and details with the gaps between, the button
    panel:SetScript("OnShow", function()
        details:SetText("What you did and what happened. Copy bug report adds your versions, settings and any saved errors.")
        local errors = #addon:GetErrors()
        errorsText:SetText(errors > 0 and string.format("%d error%s saved", errors, errors == 1 and "" or "s") or "")
        panel:SetHeight(50 + intro:GetStringHeight() + 10 + 26 + 16 + heading:GetStringHeight() + 4
            + details:GetStringHeight() + 52)
    end)
    return panel
end

_G.Goldsmith = addon
