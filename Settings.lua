local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Settings
--
-- Few settings, strong defaults. Saved for the account in
-- GoldsmithDB.settings; anything not set uses its default:
--   priceSource - "auto" (whichever is newer), "auctionator" or "tsm"
--   minROI      - ROI (%) a craft needs to count as worth crafting
--   minLine     - gold a suggested batch must make in all to be a to-do
--                 (user, 2026-10-12: Cooking filled the list with
--                 +0.36g Quick Sandwiches)
--   dealPercent - how far below its usual price a material counts as cheap
--   heldDays    - days unsold before a crafted item is held too long
--   keepDays    - days of transactions and daily gold kept; 0 = forever
--                 (addon:TrimHistory, Data.lua)
--   tooltips   - Goldsmith lines in item tooltips: "full", "short" or "off"
--   chat        - chat messages: "all" or "off" (an old "money" counts
--                 as "all")
--   excluded    - { [charKey] = true } for characters left out of stock,
--                 concentration and the Overview
--   showMinimap - the minimap button (Minimap.lua)
--   craftCost   - "Your materials / Profit" in the game's profession and
--                 crafting orders windows (OrderCost.lua), like
--                 Auctionator's own switch (user, 2026-10-16)
--   ahScan      - Goldsmith's own AH scan at all: off hides the panel by
--                 the AH (and Buy next with it), no scans, Auctionator's
--                 scans aren't read (user, 2026-10-19: just in case)
--   autoScan    - Goldsmith's own AH scan when you open the AH and the last
--                 is over an hour old (Scan.lua)
--   buyOver     - Buy next buys without asking when the AH asks up to this
--                 % more than the plan, of the item's cost or the queue's
--                 profit (Shop.lua; user, 2026-10-19: a second click for
--                 1.75g over 820g was friction). 0 always asks
--   peekKey     - the modifier held to see through the window (Window.lua):
--                 "alt" or "off" (the key binding only). Not Shift or Ctrl:
--                 shift-clicks and Ctrl-to-explain would peek (user, 2026-10-17)
-- Concentration in Crafts isn't here: the Crafts tab's switch remembers it.
-- "Show cost as" (estimated or worst case) was removed 2026-10-10: costs
-- are always the estimate; the worst case is in each craft's hover.

local DEFAULTS = {
    priceSource = "auto",
    minROI = 15,
    minLine = 10,
    dealPercent = 10,
    heldDays = 7,
    keepDays = 0,
    tooltips = "full",
    chat = "all",
    showMinimap = true,
    craftCost = true,
    ahScan = true,
    autoScan = true,
    buyOver = 2,
    peekKey = "alt",
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
-- DataChanged, as does excluding a character. Switching tabs and
-- scrolling only redraw. As a safety net a cache also empties after CACHE_SECONDS.
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
--     other code never sees an alt's stats; the same for the plan choices
--     in use (addon.planChoices, see WithChoices)
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
    if not work.keep and work ~= current then coroutine.yield() end
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
function addon:RunWork(fn, onSlow, onDone, label, keep)
    local work = { co = coroutine.create(fn), statsChar = addon.statsChar, planChoices = addon.planChoices,
        totalMs = 0, longestMs = 0, frames = 0, keep = keep }
    works[work.co] = work
    -- keep: runs beside other work, not stopped by newer work (the perf
    -- check's own steps)
    if not keep then current = work end
    local slow = false
    local function Step()
        if not work.keep and current ~= work then return end
        work.sliceStart = debugprofilestop()
        -- The work's own stats while it runs (see the rules above)
        local outside, outsideChoices = addon.statsChar, addon.planChoices
        addon.statsChar, addon.planChoices = work.statsChar, work.planChoices
        local ok, err = coroutine.resume(work.co)
        work.statsChar, work.planChoices = addon.statsChar, addon.planChoices
        addon.statsChar, addon.planChoices = outside, outsideChoices
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
        if not work.keep and current ~= work then return end
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

-- Also on the Characters tab. Most cached results are kept for every
-- character, but not all (Items' Held board kept an excluded alt's items,
-- 2026-10-14), so cached results go: excluding is rare.
function addon:SetCharacterIncluded(charKey, included)
    GoldsmithDB.settings = GoldsmithDB.settings or {}
    GoldsmithDB.settings.excluded = GoldsmithDB.settings.excluded or {}
    GoldsmithDB.settings.excluded[charKey] = (not included) or nil
    addon:DataChanged()
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

-- "Not this" on a Do this next suggestion: hidden from every suggestion
-- (Do this next, to-dos, concentration plans) for a day, then it can come
-- back if it's still a good bet (user, 2026-10-10: hide until tomorrow;
-- Ignore stays the permanent way). GoldsmithDB.snoozed[itemID] =
-- { name, untilTime }, keyed by the craft's output (or what's salvaged).
local SNOOZE_SECONDS = 24 * 3600

function addon:IsSnoozed(itemID)
    local entry = itemID and GoldsmithDB.snoozed and GoldsmithDB.snoozed[itemID]
    if not entry then return false end
    if entry.untilTime <= time() then
        GoldsmithDB.snoozed[itemID] = nil
        return false
    end
    return true, entry.untilTime
end

function addon:SetSnoozed(itemID, name, snoozed)
    if not itemID then return end
    GoldsmithDB.snoozed = GoldsmithDB.snoozed or {}
    GoldsmithDB.snoozed[itemID] = snoozed and { name = name, untilTime = time() + SNOOZE_SECONDS } or nil
    addon:DataChanged()
    if addon.RefreshWindow then addon.RefreshWindow() end
end

-- { { itemID, name, untilTime } } still hidden, soonest back first
function addon:GetSnoozedItems()
    local list = {}
    for itemID in pairs(GoldsmithDB.snoozed or {}) do
        local on, untilTime = addon:IsSnoozed(itemID)
        if on then
            local entry = GoldsmithDB.snoozed[itemID]
            table.insert(list, { itemID = itemID, name = entry.name or ("item " .. itemID), untilTime = untilTime })
        end
    end
    table.sort(list, function(a, b) return a.untilTime < b.untilTime end)
    return list
end

function addon:ClearSnoozed()
    GoldsmithDB.snoozed = {}
    addon:DataChanged()
    if addon.RefreshWindow then addon.RefreshWindow() end
end

-- "N hidden" (Overview and Characters): a button listing what's hidden,
-- when each comes back, to bring one or all back now. Hidden while
-- nothing is. Call button:Update() on refresh.
function addon:HiddenSuggestionsButton(parent)
    local button = UI.Button(parent, "", 80, 22, function(self)
        if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
        GameTooltip:Hide()
        MenuUtil.CreateContextMenu(self, function(_, root)
            root:CreateTitle("Hidden for a day (Not this)")
            for _, item in ipairs(addon:GetSnoozedItems()) do
                root:CreateButton(string.format("%s  (back %s)", item.name, date("%a %H:%M", item.untilTime)),
                    function() addon:SetSnoozed(item.itemID, item.name, false) end)
            end
            root:CreateDivider()
            root:CreateButton("Bring them all back", function() addon:ClearSnoozed() end)
        end)
    end)
    UI.SetTooltip(button, function(tooltip)
        tooltip:AddLine("Hidden suggestions", 1, 1, 1)
        tooltip:AddLine("Ones you hid with Not this. Click to bring one back now.", 0.8, 0.8, 0.8, true)
    end, "ANCHOR_BOTTOM")
    function button:Update(hide)
        local count = #addon:GetSnoozedItems()
        self:SetShown(not hide and count > 0)
        self:SetLabel(string.format("%d hidden", count))
    end
    button:Hide()
    return button
end

-- "followed: +320g" (Overview and Characters): how the last 7 days'
-- suggestions turned out (GetFollowedSummary), beside a title. Both tabs'
-- suggestions count (MarkSuggested), so it's the same number on each.
-- Call label:Update(hide) on refresh.
local FOLLOWED_ON_TARGET = "|TInterface\\RaidFrame\\ReadyCheck-Ready:0|t"
local FOLLOWED_SHORT = "|TInterface\\RaidFrame\\ReadyCheck-NotReady:0|t"

function addon:FollowedLabel(parent)
    local Signed = function(c) return addon:FormatSignedMoney(c) end
    local label = CreateFrame("Frame", nil, parent)
    label:SetSize(150, 18)
    label:EnableMouse(true)
    label.text = UI.Text(label, "small", "muted")
    label.text:SetPoint("LEFT")
    UI.SetTooltip(label, function(tooltip)
        local f = label.data
        if not f then return end
        tooltip:AddLine("Suggestions you followed, last 7 days", 1, 1, 1)
        -- With Ctrl, like the other explanations (user, 2026-10-11)
        addon:Explain(tooltip, "Crafts of what Goldsmith suggested, made within a day and up to the number suggested (from Goldsmith or the game's window), and what they sold for.")
        -- Compact: one line per item, a mark for how it did, and a second
        -- line only when it fell short. Two or three lines each, with the
        -- totals repeated, was "an eye sore" (user, 2026-10-16).
        local r, g, b = addon:Color(addon:MoneyColor(f.profit))
        tooltip:AddDoubleLine("Profit on what sold", Signed(f.profit), 0.8, 0.8, 0.8, r, g, b)
        tooltip:AddDoubleLine("Sold", string.format("%d of %d crafted", f.sold, f.crafted), 0.8, 0.8, 0.8, 1, 1, 1)
        -- How the suggestions did: what sold against what was expected when
        -- it was crafted (user, 2026-10-11). "On target" (2026-10-13, was
        -- "paid off") also reads right for a craft expected to lose a little
        -- that lost less or made a little
        if f.checked > 0 then
            tooltip:AddDoubleLine("On target", string.format("%d of %d items", f.heldUp, f.checked),
                0.8, 0.8, 0.8, 1, 1, 1)
        end
        tooltip:AddLine(" ")
        local muted = addon:Colorize("%d/%d %s", "muted")
        for i = 1, math.min(#f.items, 8) do
            local s = f.items[i]
            local mark = ""
            if s.expected and s.sold > 0 then mark = (s.heldUp and FOLLOWED_ON_TARGET or FOLLOWED_SHORT) .. " " end
            local right, ir, ig, ib
            if s.sold > 0 then
                -- White unless a loss: green on every line was too much
                -- (user, 2026-10-16); the mark says how it did, and the
                -- total at the top stays green
                right = mark .. Signed(s.profit)
                ir, ig, ib = addon:Color(s.profit < 0 and addon:MoneyColor(s.profit) or "text")
            else
                right = "-"
                ir, ig, ib = addon:Color("dim")
            end
            tooltip:AddDoubleLine(s.name .. "  " .. string.format(muted, s.sold, s.made, s.opened and "opened" or "sold"),
                right, 0.9, 0.9, 0.9, ir, ig, ib)
            if s.expected and s.sold > 0 and not s.heldUp then
                local er, eg, eb = addon:Color("warning")
                tooltip:AddLine("    fell short: expected " .. Signed(s.expected), er, eg, eb)
            end
        end
        -- One label to a line, easier to read (user, 2026-10-11)
        addon:Explain(tooltip, "21/37 sold: of the 37 you made, 21 have sold. Profit is on those.")
        addon:Explain(tooltip, FOLLOWED_ON_TARGET .. " On target: its sales made at least 80% of the expected profit (or, when a loss was expected, lost no more than that).")
        addon:Explain(tooltip, FOLLOWED_SHORT .. " Fell short: its sales made less than that.")
        addon:Explain(tooltip, "Expected: the AH price when you crafted it, after the AH cut, minus the craft cost.")
        addon:Explain(tooltip, "Counted for crafts from Oct 11, 2026 on.")
    end, "ANCHOR_BOTTOM")
    function label:Update(hide)
        local f = addon:GetFollowedSummary(7)
        self.data = f
        self:SetShown(not hide and f.crafted > 0)
        -- Nothing sold yet: say so, rather than "+0.00g" (user, 2026-10-10)
        if f.sold == 0 then
            self.text:SetText(string.format("followed: %d made, 0 sold", math.floor(f.crafted + 0.5)))
        else
            self.text:SetText("followed: " .. addon:Colorize(Signed(f.profit), addon:MoneyColor(f.profit)))
        end
        self:SetWidth(math.max(self.text:GetStringWidth(), 1))
    end
    label:Hide()
    return label
end

-- Chat messages Goldsmith prints by itself (not answers to /gsm commands).
-- kind is "money" (a sale, purchase or deposit) or "info" (anything else).
-- Everything or off: the "Sales and purchases" level was dropped (user,
-- 2026-10-10: History shows all of that; chat is for troubleshooting), so
-- a saved "money" counts as everything.
function addon:Notify(kind, msg, ...)
    if addon:Setting("chat") == "off" then return end
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
-- A binding's key as the game writes it ("CTRL-G"), or nil if unbound
function addon:BindingKeyText(name)
    local key = GetBindingKey and GetBindingKey(name)
    return key and (GetBindingText and GetBindingText(key) or key) or nil
end

-- The Goldsmith section of the Keybindings page: opened and scrolled to
-- the top, so nobody scrolls past every other section to find it (user,
-- 2026-10-17). Reads the game's own list, so it's all in pcalls; false if
-- the page isn't built the way it was when written.
local function ShowGoldsmithSection()
    local list = SettingsPanel and SettingsPanel.Container and SettingsPanel.Container.SettingsList
    local box = list and list.ScrollBox
    local provider = box and box.GetDataProvider and box:GetDataProvider()
    if not (provider and provider.FindElementDataByPredicate) then return false end
    local section = provider:FindElementDataByPredicate(function(e)
        local data = e and e.data
        return type(data) == "table" and (data.name == "Goldsmith" or data.name == BINDING_HEADER_GOLDSMITH)
    end)
    if not section then return false end
    local top = ScrollBoxConstants and ScrollBoxConstants.AlignBegin
    box:ScrollToElementData(section, top)
    if not section.data.expanded then
        local frame = box:FindFrame(section)
        local button = frame and (frame.Button or frame)
        if not (button and button.Click) then return false end
        button:Click()
        box:ScrollToElementData(section, top)
    end
    return true
end

function addon:OpenKeybindings()
    local ok = Settings and Settings.OpenToCategory and Settings.KEYBINDINGS_CATEGORY_ID
        and pcall(Settings.OpenToCategory, Settings.KEYBINDINGS_CATEGORY_ID)
    if not ok then
        print("|cFF00FF00[Goldsmith]|r Set a key in Options > Keybindings > Goldsmith.")
        return
    end
    if addon.window then addon.window:Hide() end
    -- The page fills its list once shown
    C_Timer.After(0.1, function()
        local done, shown = pcall(ShowGoldsmithSection)
        if not (done and shown) then
            print("|cFF00FF00[Goldsmith]|r Scroll down to Goldsmith, near the bottom, and pick your keys.")
        end
    end)
end

-- Panel

local COLUMN_WIDTH = 400
local WIDTH = 2 * COLUMN_WIDTH + 16
local ROW_HEIGHT = 74
local ROWS_TOP = -78

local CHOICES = {
    priceSource = {
        { value = "auto", label = "Automatic (recommended)" },
        { value = "auctionator", label = "Prefer Auctionator" },
        { value = "tsm", label = "Prefer TSM" },
    },
    minROI = {},
    minLine = {},
    dealPercent = {},
    heldDays = {},
    buyOver = {},
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
    chat = {
        { value = "all", label = "On (recommended)" },
        { value = "off", label = "Off" },
    },
    peekKey = {
        { value = "alt", label = "Hold Alt" },
        { value = "off", label = "Key binding only" },
    },
}
for _, value in ipairs({ 0, 5, 10, 15, 20, 30, 50 }) do
    table.insert(CHOICES.minROI, { value = value,
        label = value == 0 and "Any profit" or string.format("%d%%", value) })
end
-- Forever's gold is scarce: silver amounts (in gold, as the setting is)
local isForever = WOW_PROJECT_ID == (WOW_PROJECT_CAMELOT or 18)
if isForever then DEFAULTS.minLine = 0.5 end
for _, value in ipairs(isForever and { 0, 0.1, 0.25, 0.5, 1, 5 } or { 0, 5, 10, 25, 50, 100 }) do
    table.insert(CHOICES.minLine, { value = value,
        label = value == 0 and "Any profit"
            or isForever and addon:FormatMoney(value * 10000) .. " a batch"
            or string.format("%dg a batch", value) })
end
for _, value in ipairs({ 5, 10, 15, 20, 25 }) do
    table.insert(CHOICES.dealPercent, { value = value, label = string.format("%d%% below usual", value) })
end
for _, value in ipairs({ 0, 2, 5, 10 }) do
    table.insert(CHOICES.buyOver, { value = value,
        label = value == 0 and "Always ask" or string.format("Up to %d%% more", value) })
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
    priceSource = {
        "Price source",
        "Automatic: the newest scan wins, Goldsmith's own or Auctionator's (one made since you logged in); otherwise TSM's price, which its app updates about hourly. Live prices from AH searches you've just made are used first.",
        "Prefer Auctionator: Auctionator's last scan even if it's days old, TSM only for items it hasn't seen.",
        "Prefer TSM: TSM's price, Auctionator only for items TSM has no price for. Live AH searches are ignored.",
        "Either way, a listing far below or above the usual price is replaced by TSM's market value when TSM is installed.",
    },
    minROI = {
        "Worth crafting at",
        "The ROI (profit as a share of what the craft costs) a craft needs to count as worth doing.",
        "Used by Recommended on the Crafts tab and by Best crafts right now on the Overview.",
        "Higher leaves room for undercuts and slow sales; 15% is a good start.",
    },
    minLine = {
        "Worth a to-do at",
        "The gold a suggested batch must make in all to be a to-do (the profit each times how many to make).",
        "Used by Do this next and the to-do lists on the Overview and Characters tabs. Cheap, quick crafts like Cooking's earn a few silver a batch and filled the list.",
    },
    dealPercent = {
        "Cheap materials",
        "How far below its usual price a material has to be for the Overview's Cheap materials today.",
        "The usual price is the middle of the prices saved each day. Until you have 5 days of them, it's Goldsmith Data's price for your region over the last 7 days.",
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
        "Full: everything Goldsmith knows about the item, such as what you paid, how today's price compares, what yours cost you, break-even, and the cost and profit of crafting it now with your stats.",
        "Short: cost and profit of crafting it now for things you craft, otherwise what you paid and today's price against usual.",
        "Off: no Goldsmith lines. Everything is still on the item's page in /gsm.",
    },
    chat = {
        "Chat messages",
        "On: each sale, purchase and AH deposit, saved recipes and milling results. Handy for checking what Goldsmith records.",
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
        "Other ways to open Goldsmith: /gsm, a key (Options > Keybindings > Goldsmith), or the addons button by the minimap.",
    },
    -- The row's hover: each box's name in gold, then what it does
    ahScanRow = {
        "Auction House scan",
        "|cffe8c25aOn:|r a panel beside the AH window with Scan the AH and Buy next. Off: no scans.",
        "|cffe8c25aAuto scan:|r scans when you open the AH and the last scan is over an hour old.",
    },
    ahScan = {
        "On",
        "A panel beside the AH window with Scan the AH and Buy next.",
        "Off: no panel and no scans. Prices come from Auctionator, TSM and Goldsmith Data.",
    },
    autoScan = {
        "Auto scan",
        "Scans when you open the AH and the last scan is over an hour old. About a minute; you can keep using the AH.",
        "If Auctionator scans too, Goldsmith reads its scan instead.",
    },
    buyOver = {
        "Buy without asking",
        "How much more than the plan Buy next pays without a second click. Up to 2% more: buys when the extra is under 2% of the item's cost or under 2% of the queue's profit.",
        "Over that, the panel says how much more and what the queue earns then, and waits for a second click. It always asks when the queue would lose gold.",
        "Always ask: a second click for anything over the plan. Under the plan always buys at once.",
    },
    craftCost = {
        "Cost in the profession window",
        "Goldsmith's Your materials and Profit lines in the game's profession and crafting orders windows, under the materials. Hover them for the breakdown.",
        "Auctionator shows its own To Craft and Profit there; Goldsmith's go below it. Auctionator's can be turned off in its settings, under Crafting Info.",
    },
    peekKey = {
        "See through Goldsmith",
        "While you hold this key, Goldsmith fades almost away and clicks go through it, so you can click the auctioneer or a mailbox behind it without moving the window. Let go and it's back.",
        "Alt is the only choice here: Shift and Ctrl already do things in Goldsmith (shift-click an item, Ctrl to explain a hover). For any other key, pick Key binding only and set it in Options > Keybindings > Goldsmith: Hold to see through. The game can't bind Alt, Shift or Ctrl alone there.",
    },
    keybind = {
        "Key to open Goldsmith",
        "Set key opens the game's Keybindings at Goldsmith's section: click the box next to Show or hide the window and press the key you want.",
        "Goldsmith closes while you do it; press your new key to bring it back.",
        "More keys are there: Craft next in the queue, Buy next for the queue at the AH, and Open hovered item (hover an item in your bags, the AH or a chat link and press it for the item's page).",
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
    { title = "Crafting and prices", rows = { "priceSource", "autoScan", "buyOver", "minROI", "minLine", "dealPercent", "heldDays", "keepDays" } },
    { title = "Display", rows = { "ignored", "tooltips", "chat", "characters", "showMinimap", "craftCost", "peekKey", "keybind" } },
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

    rows.priceSource = ChoiceRow(panel, "priceSource", "Price source", "Where AH prices come from when both Auctionator and TSM have one.")
    rows.minROI = ChoiceRow(panel, "minROI", "Worth crafting at", "The ROI a craft needs for Recommended and Best crafts.")
    rows.minLine = ChoiceRow(panel, "minLine", "Worth a to-do at", "The gold a suggested batch must make in all.")
    rows.dealPercent = ChoiceRow(panel, "dealPercent", "Cheap materials", "How far below usual a material's price counts as cheap.")
    rows.heldDays = ChoiceRow(panel, "heldDays", "Held too long", "Days unsold before a crafted item is flagged.")
    rows.buyOver = ChoiceRow(panel, "buyOver", "Buy without asking", "How much over the plan Buy next pays without a second click.")
    rows.keepDays = Row(panel, "keepDays", "Keep history for", "How long purchases, sales and deposits are kept.")
    rows.keepDays.control = Dropdown(rows.keepDays, "keepDays", function(root)
        for _, c in ipairs(CHOICES.keepDays) do
            root:CreateRadio(c.label, function() return addon:Setting("keepDays") == c.value end,
                function() SetKeepDays(c.value, panel) end)
        end
    end)
    function rows.keepDays:Update() self.control:SetLabel(LabelFor(CHOICES.keepDays, addon:Setting("keepDays"))) end
    rows.tooltips = ChoiceRow(panel, "tooltips", "Item tooltips", "Goldsmith's lines in the game's item tooltips.")
    rows.chat = ChoiceRow(panel, "chat", "Chat messages", "What Goldsmith says in chat as things happen.")
    rows.peekKey = ChoiceRow(panel, "peekKey", "See through Goldsmith", "Hold it to click the auctioneer or a mailbox behind the window.")

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

    -- Two boxes: the scan at all, and scanning when you open the AH
    rows.autoScan = Row(panel, "ahScanRow", "Auction House scan", "Goldsmith's own scan and Buy next, in a panel beside the AH.")
    rows.autoScan.on = UI.Checkbox(rows.autoScan, "On", function(checked)
        addon:SetSetting("ahScan", checked)
        if addon.UpdateScanPanel then addon.UpdateScanPanel() end
        panel:Update()
    end)
    rows.autoScan.on:SetPoint("TOPLEFT", rows.autoScan, "TOPRIGHT", -170, 0)
    UI.SetTooltip(rows.autoScan.on, function(tooltip) AddHelp(tooltip, "ahScan") end, "ANCHOR_LEFT")
    rows.autoScan.control = UI.Checkbox(rows.autoScan, "Auto scan", function(checked)
        if not addon:Setting("ahScan") then return end
        addon:SetSetting("autoScan", checked)
        panel:Update()
    end)
    rows.autoScan.control:SetPoint("TOPLEFT", rows.autoScan.on, "BOTTOMLEFT", 0, 0)
    UI.SetTooltip(rows.autoScan.control, function(tooltip) AddHelp(tooltip, "autoScan") end, "ANCHOR_LEFT")
    function rows.autoScan:Update()
        local on = addon:Setting("ahScan")
        self.on:SetChecked(on)
        self.control:SetChecked(on and addon:Setting("autoScan"))
        self.control:SetAlpha(on and 1 or 0.4)
    end

    rows.craftCost = Row(panel, "craftCost", "Cost in the profession window", "Your materials and Profit under a recipe's materials.")
    rows.craftCost.control = UI.Checkbox(rows.craftCost, "Show", function(checked)
        addon:SetSetting("craftCost", checked)
        if addon.UpdateCraftCostLines then addon:UpdateCraftCostLines() end
        panel:Update()
    end)
    rows.craftCost.control:SetPoint("TOPRIGHT", 0, 0)
    UI.SetTooltip(rows.craftCost.control, function(tooltip) AddHelp(tooltip, "craftCost") end, "ANCHOR_LEFT")
    function rows.craftCost:Update() self.control:SetChecked(addon:Setting("craftCost")) end

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
        tooltip:AddLine("Report a bug or suggest an idea on Goldsmith's CurseForge page.", 0.8, 0.8, 0.8, true)
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
        rows.priceSource:SetShown(addon:HasAuctionator() and addon:HasTSM() and true or false)
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
        addon:Colorize("Overview", "text") .. ": what to do next on the character you're on, which of your other characters has the most waiting, and how you're doing across all of them. \"followed\" by Do this next adds up what the suggestions you crafted have made; Set a goal on the Total gold chart gives you a gold goal.",
        addon:Colorize("Characters", "text") .. ": a to-do list for each character, its craft cooldowns, and which characters count.",
        addon:Colorize("Crafts", "text") .. ": what you can make, with its cost, profit and how well it sells. Show picks Recommended, All crafts or Not learned yet (recipes worth going to learn), and can hide gear. Click a craft to plan it: type how many crafts, and it shows what they make and what to buy. With concentration it plans only what yours covers now; Why this mix shows the material qualities compared, and clicking one uses it instead.",
        addon:Colorize("Queue", "text") .. ": crafts lined up to make, with one shopping list and a button that does the next step.",
        addon:Colorize("Items", "text") .. ": any item's page, and In my bags for everything you hold.",
        addon:Colorize("History", "text") .. ": every purchase, sale, craft and deposit; right-click an entry to fix it.",
        addon:Colorize("Stats", "text") .. ": lifetime stats and your Goldsmith title; Share in chat to brag.",
      }, "\n") },
    { "Getting to the AH and the mailbox",
      "Hold Alt and Goldsmith fades almost away: clicks go through it, so you can click the auctioneer or the mailbox behind it without moving the window. Let go and it's back. Pick another key in Settings > See through Goldsmith. The game's Interact key works too: turn on Options > Gameplay > Controls > Enable Interact Key, bind Interact with Target in Keybindings, and press it beside the auctioneer or a mailbox." },
    { "In the game's windows",
      "Under the reagents in a profession window, Goldsmith shows what your materials cost and the profit, the same as on Crafts; hover it for the breakdown. On a crafting order, only the materials you supply count, with the commission and rewards (a payout bag at what's usually inside). Above Goldsmith's Craft button, a note reminds you when a crafting buff such as Everburning Ignition or Shattered Essence is off." },
    { "Hovers and clicks",
      "Click ? at the top right, then any part of the window, to see what it's for. Hovers show the numbers. Hold Ctrl over one to see what each number means, how it's worked out and what clicking does; let go and they're gone. The line along the bottom of the window says what clicking, right-clicking and shift-clicking do on the screen you're on. A gold Filtered button by Settings means something is hiding part of the list: click it to see everything." },
    { "When a suggestion isn't for you",
      "The x on a Do this next card, or right-clicking a to-do on Characters, hides a suggestion for a day; it comes back after that if it's still a good bet, and the \"hidden\" button brings it back sooner. To hide something for good, right-click it on Crafts and pick Ignore; to undo that, untick it in Settings > Ignored items, or tick Show ignored in the Crafts Show menu and right-click it. Deleted something in History by mistake? It stays greyed in the list until you leave History: click it to undo. Too many small suggestions? Settings > Worth a to-do at sets the least gold a batch must make." },
    { "Item tooltips",
      "Show your cost, profit and break-even price. Hold Shift for each material's cost. Settings > Item tooltips makes them shorter or turns them off." },
    { "Recommended: Auctionator",
      "Goldsmith works without it: Goldsmith Data brings the region's AH prices, refreshed with each daily update, and how well each item sells. Auctionator adds two things. Its scans give live prices for the moment you buy and sell. And its Shopping tab is where Goldsmith's shopping lists go: Send to Auctionator in a plan or the Queue makes a list there, and Auctionator searches the AH for every item on it. The game's own AH has no shopping lists." },
    { "If you already use TSM",
      "Not needed: Goldsmith Data covers prices and how well each item sells (Sells / Slow / Hardly sells). If TSM and its desktop app are installed anyway, Goldsmith uses TSM's region sales per day and sale rates instead, a check on listings far from the usual price, and prices between AH scans." },
    { "Commands",
      "Everything is in the window; commands are for checking what Goldsmith recorded. /gsm help lists them all, for example /gsm cooldowns (every craft cooldown it's found, and what the game reports), /gsm recipes and /gsm milling. The buttons below bring back the getting started checklist and the tour." },
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

    -- The sections scroll (mouse wheel or the bar) between the title and
    -- the buttons: at 1920x1080 the page ran off the bottom of the screen
    -- (user, 2026-10-12)
    local SCROLL_BAR = 8
    local scroll = CreateFrame("ScrollFrame", nil, panel)
    scroll:SetPoint("TOPLEFT", 16, -46)
    scroll:SetPoint("BOTTOMRIGHT", -(16 + SCROLL_BAR + 6), 46)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(HELP_WIDTH - 32 - SCROLL_BAR - 6, 1)
    scroll:SetScrollChild(content)
    local bar = CreateFrame("Slider", nil, panel, "BackdropTemplate")
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(SCROLL_BAR)
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 6, 0)
    UI.Style(bar, "panelRaised")
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(addon:Color("borderStrong"))
    thumb:SetSize(SCROLL_BAR, 40)
    bar:SetThumbTexture(thumb)
    bar:SetMinMaxValues(0, 0)
    bar:SetValue(0)
    bar:SetScript("OnValueChanged", function(_, value) scroll:SetVerticalScroll(value) end)
    local function Wheel(_, delta)
        local low, high = bar:GetMinMaxValues()
        bar:SetValue(math.max(low, math.min(high, bar:GetValue() - delta * 40)))
    end
    for _, f in ipairs({ scroll, bar }) do
        f:EnableMouseWheel(true)
        f:SetScript("OnMouseWheel", Wheel)
    end

    local above
    local texts = {}
    for _, section in ipairs(HELP_SECTIONS) do
        local heading = UI.Text(content, "body", "text")
        if above then
            heading:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -14)
        else
            heading:SetPoint("TOPLEFT", 0, 0)
        end
        heading:SetText(section[1])
        local text = UI.Text(content, "small", "muted")
        text:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)
        text:SetWidth(HELP_WIDTH - 32 - SCROLL_BAR - 6)
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

    -- Tall enough for the text, however it wrapped, but no taller than
    -- the Goldsmith window below the settings panel's top; the rest
    -- scrolls (the bar only shows when there's something to scroll)
    panel:SetScript("OnShow", function()
        local textHeight = (#HELP_SECTIONS - 1) * 14 + #HELP_SECTIONS * 4
        for _, fs in ipairs(texts) do textHeight = textHeight + fs:GetStringHeight() end
        content:SetHeight(textHeight)
        local top = panel:GetTop() or settings:GetTop()
        local room = (top and parent:GetBottom()) and (top - parent:GetBottom() - 8) or 600
        local height = math.min(46 + textHeight + 46 + 4, room)
        panel:SetHeight(height)
        local overflow = math.max(textHeight - (height - 92), 0)
        bar:SetMinMaxValues(0, overflow)
        bar:SetValue(0)
        scroll:SetVerticalScroll(0)
        bar:SetShown(overflow > 0)
    end)
    return panel
end

-- Support and feedback
--
-- Where to report bugs and ideas: CurseForge comments first (players have
-- an account from the app), GitHub issues for those who use it. Addons
-- can't open a web page, so the links are in boxes to copy. No donation link here: Blizzard's
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
    intro:SetText("Found a bug or have an idea? Leave a comment on Goldsmith's CurseForge page. Click the link, press Ctrl+C to copy it, and paste it into your browser.")

    local link = CopyBox(panel, SUPPORT_WIDTH - 32, addon.COMMENTS_URL)
    link:SetPoint("TOPLEFT", intro, "BOTTOMLEFT", 0, -10)

    local githubText = UI.Text(panel, "small", "muted")
    githubText:SetPoint("TOPLEFT", link, "BOTTOMLEFT", 0, -10)
    githubText:SetText("Use GitHub? Issues work too:")
    local github = CopyBox(panel, SUPPORT_WIDTH - 32, addon.ISSUES_URL)
    github:SetPoint("TOPLEFT", githubText, "BOTTOMLEFT", 0, -6)

    local heading = UI.Text(panel, "body", "text")
    heading:SetPoint("TOPLEFT", github, "BOTTOMLEFT", 0, -16)
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
    -- the two links with the GitHub line, the heading and details with the
    -- gaps between, the button
    panel:SetScript("OnShow", function()
        details:SetText("What you did and what happened. Copy bug report adds your versions, settings and any saved errors.")
        local errors = #addon:GetErrors()
        errorsText:SetText(errors > 0 and string.format("%d error%s saved", errors, errors == 1 and "" or "s") or "")
        panel:SetHeight(50 + intro:GetStringHeight() + 10 + 26 + 10 + githubText:GetStringHeight() + 6 + 26
            + 16 + heading:GetStringHeight() + 4
            + details:GetStringHeight() + 52)
    end)
    return panel
end

_G.Goldsmith = addon
