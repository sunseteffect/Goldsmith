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
--   buyFor      - whose queues Buy next shops for: "me" (the character
--                 you're on) or "all" (every character's, for buying on a
--                 bank alt; Shop.lua; user, 2026-10-24)
--   auctionatorButton - Send to Auctionator on the queue and plans. Off by
--                 default: Buy next does the shopping, with its price
--                 warnings, and one way to shop is clearer (user,
--                 2026-10-26: "we don't need auctionator and shouldn't
--                 encourage using it"). Kept as a fallback if a patch
--                 breaks buying, and for players who shop that way
--   sounds     - a sound when Goldsmith stops you (addon:Alert)
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
    buyFor = "me",
    auctionatorButton = false,
    sounds = true,
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
        local noYield = addon.noYield
        local ok, err = coroutine.resume(work.co)
        work.statsChar, work.planChoices = addon.statsChar, addon.planChoices
        addon.statsChar, addon.planChoices = outside, outsideChoices
        -- An error inside a no-pausing part (Planner.lua's costing helpers)
        -- would leave it counted, and no work would pause again
        if not ok then addon.noYield = noYield end
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
-- crafts. Keyed by the recipe's item ID, so every quality tier goes:
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
            .. ". To undo: right-click it on Crafts (tick Show ignored in the Show menu), or Settings > Ignored crafts.")
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

-- A sound, only where Goldsmith stops you: refuses a click or waits for a
-- second one. Never for news (a scan done, a deal found): sounds are kept
-- rare so they still mean something (user, 2026-10-23: "used thoughtfully
-- and sparingly because they can get annoying"). The game's own sounds.
--   "loss" - going on would lose gold: the raid warning too (the
--            quest-failed sound was too quiet for the worst case; user,
--            2026-10-25), plus `popup` in the middle of the screen, as
--            the game shows a raid warning, so it's clear where to look
--   "stop" - look before you go on (the raid warning: the beep was too
--            soft, user's pick from /gsm sound, 2026-10-24)
-- One at a time: a key held down or pressed again doesn't stack them.
-- The popup shows with sounds off too: it's text, not noise.
local ALERT_SOUNDS = { loss = "RAID_WARNING", stop = "RAID_WARNING" }
local ALERT_GAP = 1.5
local lastAlert = 0
-- The sound for a kind: one picked with /gsm sound use, else the default
local function AlertSound(kind)
    kind = ALERT_SOUNDS[kind] and kind or "stop"
    local picked = GoldsmithDB and GoldsmithDB.alertSounds and GoldsmithDB.alertSounds[kind]
    return SOUNDKIT and (picked and SOUNDKIT[picked] or SOUNDKIT[ALERT_SOUNDS[kind]])
end
function addon:Alert(kind, popup)
    if popup and RaidNotice_AddMessage and RaidWarningFrame then
        RaidNotice_AddMessage(RaidWarningFrame, "Goldsmith: " .. popup,
            ChatTypeInfo and ChatTypeInfo.RAID_WARNING or { r = 1, g = 0.28, b = 0 })
    end
    if not addon:Setting("sounds") then return end
    local now = GetTime()
    if now - lastAlert < ALERT_GAP then return end
    local sound = AlertSound(kind)
    if not sound then return end
    lastAlert = now
    PlaySound(sound)
end

-- /gsm sound: the game's sounds to try for the alerts, one per use (user,
-- 2026-10-23: "are there other sounds i can sample?"). "/gsm sound <word>"
-- tries the game's sounds with that word in their name; "/gsm sound use"
-- makes the last one heard the "stop" sound ("use loss": the loss sound);
-- "/gsm sound reset" goes back to the defaults. Names missing from this
-- version of the game are skipped.
local SAMPLE_SOUNDS = {
    "ALARM_CLOCK_WARNING_3", "ALARM_CLOCK_WARNING_2", "ALARM_CLOCK_WARNING_1", "IG_QUEST_FAILED",
    "RAID_WARNING", "READY_CHECK", "IG_PLAYER_INVITE_DECLINE", "IG_QUEST_LOG_ABANDON_QUEST",
    "UI_RAID_BOSS_WHISPER_WARNING", "LFG_ROLE_CHECK", "PVP_THROUGH_QUEUE", "TELL_MESSAGE",
    "UI_GARRISON_TOAST_INVASION_ALERT", "IG_MAINMENU_QUIT", "IG_SPELLBOOK_CLOSE", "UI_BNET_TOAST",
}
local sample = { list = nil, word = nil, i = 0, last = nil }
local function SampleList(word)
    local list = {}
    if word == "" then
        for _, name in ipairs(SAMPLE_SOUNDS) do
            if SOUNDKIT and SOUNDKIT[name] then table.insert(list, name) end
        end
    else
        word = word:upper()
        for name in pairs(SOUNDKIT or {}) do
            if type(name) == "string" and name:find(word, 1, true) then table.insert(list, name) end
        end
        table.sort(list)
    end
    return list
end
function addon:SampleSound(arg)
    arg = strtrim(arg or "")
    local Print = function(msg, ...) print("|cFF00FF00[Goldsmith]|r " .. string.format(msg, ...)) end
    local use = arg:lower():match("^use%s*(%a*)$")
    if use then
        local kind = use == "loss" and "loss" or "stop"
        if not sample.last then Print("Try a sound first: /gsm sound") return end
        GoldsmithDB.alertSounds = GoldsmithDB.alertSounds or {}
        GoldsmithDB.alertSounds[kind] = sample.last
        Print("%s is now the %s sound.", sample.last, kind == "loss" and "\"queue would lose gold\"" or "warning")
        return
    end
    if arg:lower() == "reset" then
        GoldsmithDB.alertSounds = nil
        Print("Back to the default sounds (%s, and %s when the queue would lose gold).",
            ALERT_SOUNDS.stop, ALERT_SOUNDS.loss)
        return
    end
    if not sample.list or sample.word ~= arg:lower() then
        sample.list, sample.word, sample.i = SampleList(arg), arg:lower(), 0
    end
    if #sample.list == 0 then Print("No game sounds named with \"%s\".", arg) return end
    sample.i = sample.i % #sample.list + 1
    local name = sample.list[sample.i]
    sample.last = name
    PlaySound(SOUNDKIT[name])
    Print("%d of %d: %s. Again for the next; /gsm sound use to pick it, /gsm sound use loss for the losing-gold one.",
        sample.i, #sample.list, name)
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
--
-- Categories down the left and the page on the right, Dashboard first
-- (user, 2026-10-25, after EnhanceQoL's settings): help, support, the
-- tour, the version, and what's changed from recommended with a reset.
-- Window.lua anchors the top under the tabs and the bottom to the
-- window's, so it never runs below Goldsmith on a small screen; the page
-- scrolls when it's taller.

local WIDTH = 816
local NAV_WIDTH = 188
local PAD = 16
local SCROLL_BAR = 8
-- The scroll area: right of the list and its 1px edge, left of the bar
local PAGE_WIDTH = WIDTH - NAV_WIDTH - 1 - 2 * PAD - SCROLL_BAR - 10
local ROW_HEIGHT = 62
local ROW_GAP = 6
local CONTROL_WIDTH = 190

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
    buyFor = {
        { value = "me", label = "This character's queue" },
        { value = "all", label = "Every character's queue" },
    },
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

-- The choice on a dropdown's button: without "(recommended)", which only
-- the menu shows (user, 2026-10-25: "Up to 2% more (recommend..." was cut
-- off)
local function ButtonLabel(choices, value)
    return (LabelFor(choices, value):gsub(" %(recommended%)", ""))
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
    sounds = {
        "Sounds",
        "A sound only when Goldsmith stops you, so you look before going on. Never for news like a finished scan or a deal.",
        "The raid warning when Buy next waits because the AH asks more than the plan, or when a purchase fails. When buying would lose gold (a queued craft or the queue at a loss), a warning in the middle of the screen too, even with sounds off.",
        "The game's own sounds, at your Sound effects volume.",
    },
    characters = {
        "Characters",
        "Off leaves a character out of Gold in stock, concentration, total gold, the Crafts tab and Do this next: a bank alt, or one you've stopped playing.",
        "Its sales and purchases still count, and Goldsmith keeps recording it while you play it.",
        "The Characters tab has the same switch, and can remove a character you've deleted.",
    },
    ignored = {
        "Ignored crafts",
        "Crafts you've told Goldsmith to ignore: they're never suggested in Do this next and are hidden on the Crafts tab.",
        "Turn one off to stop ignoring it. To ignore a craft, right-click it on the Crafts tab. Tick Show ignored in the Crafts tab's Show menu to see ignored crafts there.",
    },
    showMinimap = {
        "Minimap button",
        "The Goldsmith button on the edge of the minimap: click to show or hide Goldsmith, right-click for these settings, drag to move it.",
        "Other ways to open Goldsmith: /gsm, a key (Settings > Keys), or the addons button by the minimap.",
    },
    ahScan = {
        "Auction House scan",
        "On: a panel by the AH window with Scan the AH and Buy next.",
        "Off: no panel and no scans. Prices come from Auctionator, TSM and Goldsmith Data.",
    },
    autoScan = {
        "Auto scan",
        "Scans when you open the AH and the last scan is over an hour old. About a minute; you can keep using the AH.",
        "If Auctionator scans too, Goldsmith reads its scan instead. Needs Auction House scan on.",
    },
    buyOver = {
        "Buy without asking",
        "How much more than the plan Buy next pays without a second click. Up to 2% more: buys when the extra is under 2% of the item's cost or under 2% of the queue's profit.",
        "Over that, the panel says how much more and what the queue earns then, and waits for a second click. It always asks when the queue would lose gold.",
        "Always ask: a second click for anything over the plan. Under the plan always buys at once.",
    },
    buyFor = {
        "Buy next for",
        "This character's queue: Buy next shops for the character you're logged in on.",
        "Every character's queue: it also shops for your other characters' queues, so you can buy on a bank alt for your crafters. Each item says whose queue it's for. What's bought for another character is kept for them (neither queue buys it again) until you mail it; the mailbox reminds you what to send.",
        "Either way, Buy next's All queues box flips it for one shopping trip, then goes back to this.",
    },
    auctionatorButton = {
        "Send to Auctionator button",
        "On: the queue and plans get a Send to Auctionator button, which makes a shopping list in Auctionator's Shopping tab. Needs Auctionator.",
        "Buy next does the same shopping without it, and warns you when the AH asks more than the plan.",
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
    if not help then return end
    tooltip:AddLine(help[1], 1, 1, 1)
    for i = 2, #help do
        tooltip:AddLine(help[i], 0.8, 0.8, 0.8, true)
    end
end

-- The categories, in order. group: a heading in the list. rows: the
-- settings on the page (made in CreateSettingsPanel). list: a page made
-- from your data, one toggle each (characters, ignored crafts).
local PAGES = {
    { key = "dashboard", label = "Dashboard", title = "Goldsmith settings",
      intro = "Saved for all your characters. Hover any setting for what it does." },
    { group = "Goldmaking" },
    { key = "suggestions", label = "Suggestions",
      intro = "What counts as worth crafting, a cheap material, or held too long.",
      rows = { "minROI", "minLine", "dealPercent", "heldDays" } },
    { key = "ignored", label = "Ignored crafts", list = "ignored",
      intro = "Never suggested, and hidden on the Crafts tab. Turn one off to stop ignoring it. To ignore a craft, right-click it on the Crafts tab." },
    { key = "characters", label = "Characters", list = "characters",
      intro = "Turn a character off to leave it out of Gold in stock, concentration, total gold, the Crafts tab and Do this next: a bank alt, or one you've stopped playing. Its sales and purchases still count." },
    { group = "Auction House" },
    { key = "prices", label = "Prices and scan",
      intro = "Where Goldsmith's AH prices come from.",
      rows = { "priceSource", "ahScan", "autoScan" } },
    { key = "buying", label = "Buy next",
      intro = "How Buy next shops at the AH.",
      rows = { "buyFor", "buyOver", "auctionatorButton" } },
    { group = "Interface" },
    { key = "display", label = "Display",
      intro = "Goldsmith's lines in the game's own windows, and its minimap button.",
      rows = { "tooltips", "craftCost", "showMinimap" } },
    { key = "alerts", label = "Chat and sounds",
      intro = "What Goldsmith tells you as things happen.",
      rows = { "chat", "sounds" } },
    { key = "keys", label = "Keys",
      intro = "Keys to open Goldsmith and to see through it.",
      rows = { "keybind", "peekKey" } },
    { group = "Data" },
    { key = "history", label = "History",
      intro = "How long Goldsmith keeps what it records.",
      rows = { "keepDays" } },
    -- In the panel, not windows of their own (user, 2026-10-25). page:
    -- built by Help and Support below. hidden: not in the list; nav: the
    -- entry it's under.
    { group = "About" },
    { key = "help", label = "Help", page = "help",
      intro = "Getting started, what each tab is for, and the /gsm commands." },
    { key = "support", label = "Support and feedback", page = "support",
      intro = "Found a bug or have an idea? Leave a comment on Goldsmith's CurseForge page. Click a link, press Ctrl+C to copy it, and paste it into your browser." },
    { key = "report", label = "Bug report", page = "report", hidden = true, nav = "support",
      intro = "It's selected: press Ctrl+C to copy it, then paste it into your comment (or GitHub issue) under what happened. Character and realm names are left out, and nothing about your gold or items is included." },
}
local PAGE_BY_KEY, PAGE_OF_ROW = {}, {}
for _, page in ipairs(PAGES) do
    if page.key then PAGE_BY_KEY[page.key] = page end
    for _, key in ipairs(page.rows or {}) do PAGE_OF_ROW[key] = page end
end

-- Settings that differ from recommended, in page order
local function ChangedKeys()
    local list = {}
    for _, page in ipairs(PAGES) do
        for _, key in ipairs(page.rows or {}) do
            if DEFAULTS[key] ~= nil and addon:Setting(key) ~= DEFAULTS[key] then table.insert(list, key) end
        end
    end
    return list
end

local SETTING_COUNT = 0
for _ in pairs(DEFAULTS) do SETTING_COUNT = SETTING_COUNT + 1 end

-- A setting's value as its control shows it ("Short", "On")
local function ValueText(key)
    local value = addon:Setting(key)
    if CHOICES[key] then return ButtonLabel(CHOICES[key], value) end
    return value and "On" or "Off"
end

-- Every setting back to recommended. Excluded characters and ignored
-- crafts are your data, not settings, so they stay.
function addon:ResetSettings()
    GoldsmithDB.settings = GoldsmithDB.settings or {}
    for key in pairs(DEFAULTS) do GoldsmithDB.settings[key] = nil end
    if addon.UpdateMinimapButton then addon:UpdateMinimapButton() end
    if addon.UpdateScanPanel then addon.UpdateScanPanel() end
    if addon.UpdateCraftCostLines then addon:UpdateCraftCostLines() end
    if addon.Refresh then addon.Refresh() end
end

StaticPopupDialogs["GOLDSMITH_RESET_SETTINGS"] = {
    text = "Put every setting back to recommended?\n\nExcluded characters and ignored crafts stay as they are.",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, data) addon:ResetSettings(); if data and data.Update then data:Update() end end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- A setting row: a box with the name and a short description on the
-- left and the control on the right. Hovering it explains it in full.
local function Row(parent, key, title, description)
    local row = UI.Panel(parent, "panel")
    row:SetSize(PAGE_WIDTH, ROW_HEIGHT)
    row:EnableMouse(true)
    row.key, row.titleText = key, title
    row.title = UI.Text(row, "body", "text")
    row.title:SetText(title)
    row.description = UI.Text(row, "small", "muted")
    row.description:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -4)
    row.description:SetWidth(PAGE_WIDTH - CONTROL_WIDTH - 44)
    row.description:SetWordWrap(true)
    row.description:SetMaxLines(2)
    -- No description: the name sits in the middle
    function row:SetDescription(text)
        self.descriptionText = text or ""
        self.description:SetText(self.descriptionText)
        self.title:ClearAllPoints()
        if self.descriptionText ~= "" then
            self.title:SetPoint("TOPLEFT", 14, -11)
        else
            self.title:SetPoint("LEFT", 14, 0)
        end
    end
    row:SetDescription(description)
    UI.SetTooltip(row, function(tooltip) AddHelp(tooltip, key) end, "ANCHOR_LEFT")
    row:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(addon:Color("borderStrong")) end)
    row:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("border")) end)
    return row
end

-- The control at the row's right, explained on hover like the row
local function PlaceControl(row, control, key)
    control:SetPoint("RIGHT", row, "RIGHT", -14, 0)
    UI.SetTooltip(control, function(tooltip) AddHelp(tooltip, key) end, "ANCHOR_LEFT")
    row.control = control
end

local function Dropdown(row, key, build)
    local dropdown = UI.Dropdown(row, CONTROL_WIDTH, build)
    PlaceControl(row, dropdown, key)
    return dropdown
end

-- A row whose dropdown picks one of CHOICES[key]
local function ChoiceRow(parent, panel, key, title, description)
    local row = Row(parent, key, title, description)
    Dropdown(row, key, function(root)
        for _, c in ipairs(CHOICES[key]) do
            root:CreateRadio(c.label, function() return addon:Setting(key) == c.value end,
                function() addon:SetSetting(key, c.value); panel:Update() end)
        end
    end)
    function row:Update() row.control:SetLabel(ButtonLabel(CHOICES[key], addon:Setting(key))) end
    return row
end

-- A row with an on/off toggle; clicking anywhere on the row flips it.
-- onChange(on) runs after it's saved, for what has to follow (the
-- minimap button showing, say). nil key: the toggle saves nothing itself.
local function ToggleRow(parent, panel, key, title, description, onChange)
    local row = Row(parent, key, title, description)
    PlaceControl(row, UI.Toggle(row, function(on)
        if DEFAULTS[key] ~= nil then addon:SetSetting(key, on) end
        if onChange then onChange(on, row) end
        panel:Update()
    end), key)
    row:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" then self.control:Click() end
    end)
    function row:Update() row.control:SetOn(addon:Setting(key)) end
    return row
end

local function CharacterLabel(entry)
    local c = entry.data
    local realm = c.realm ~= GetRealmName() and (" (" .. (c.realm or "?") .. ")") or ""
    return (c.name or entry.key) .. realm .. (entry.key == addon.charKey and ", you" or "")
end

-- Its professions, for the line under a character's name
local function ProfessionList(c)
    local names = {}
    for name in pairs(c.professions or {}) do table.insert(names, name) end
    table.sort(names)
    return #names > 0 and table.concat(names, ", ") or "No crafting professions seen yet"
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

-- A scrolling area: the mouse wheel or the bar moves it, and the bar only
-- shows when there's something to scroll. area:SetContentHeight(h) after
-- laying out; keepPlace leaves it where it was (a redraw after a click)
local function ScrollArea(panel)
    local scroll = CreateFrame("ScrollFrame", nil, panel)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(PAGE_WIDTH, 1)
    scroll:SetScrollChild(content)
    local bar = CreateFrame("Slider", nil, panel, "BackdropTemplate")
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(SCROLL_BAR)
    -- Starts below the close button
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 10, -26)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 10, 0)
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

    local area = { scroll = scroll, content = content }
    function area:SetContentHeight(height, keepPlace)
        content:SetHeight(math.max(height, 1))
        local overflow = math.max(height - (scroll:GetHeight() or 0), 0)
        local place = keepPlace and math.min(bar:GetValue(), overflow) or 0
        bar:SetMinMaxValues(0, overflow)
        bar:SetValue(place)
        scroll:SetVerticalScroll(place)
        bar:SetShown(overflow > 0)
    end
    -- The visible height changes with the window
    scroll:SetScript("OnSizeChanged", function() if area.onResize then area.onResize() end end)
    return area
end

function addon:CreateSettingsPanel(parent)
    local panel = CreateFrame("Frame", "GoldsmithSettings", parent, "BackdropTemplate")
    panel:SetWidth(WIDTH)
    UI.Style(panel, "dialog", "borderGold")
    panel:SetFrameStrata("DIALOG")
    panel:EnableMouse(true)
    panel:Hide()

    local current = "dashboard"
    local query = ""
    local Open, Layout -- below

    local close = UI.IconButton(panel, 26, "X", "Close", function() panel:Hide() end, { hoverColor = "loss" })
    close:SetPoint("TOPRIGHT", -8, -8)

    -- The category list
    local nav = CreateFrame("Frame", nil, panel, "BackdropTemplate")
    nav:SetPoint("TOPLEFT", 1, -1)
    nav:SetPoint("BOTTOMLEFT", 1, 1)
    nav:SetWidth(NAV_WIDTH)
    UI.Style(nav, "header")
    if nav.SetClipsChildren then nav:SetClipsChildren(true) end
    local edge = UI.Line(panel, "borderGold")
    edge:SetWidth(1)
    edge:SetPoint("TOPLEFT", nav, "TOPRIGHT", 0, 0)
    edge:SetPoint("BOTTOMLEFT", nav, "BOTTOMRIGHT", 0, 0)

    local logo = nav:CreateTexture(nil, "ARTWORK")
    logo:SetTexture("Interface\\AddOns\\Goldsmith\\Media\\Logo")
    logo:SetSize(30, 30)
    logo:SetPoint("TOPLEFT", 14, -14)
    local brand = UI.Text(nav, "title")
    brand:SetPoint("TOPLEFT", logo, "TOPRIGHT", 8, -1)
    brand:SetText("Goldsmith")
    local brandNote = UI.Text(nav, "label", "muted")
    brandNote:SetPoint("TOPLEFT", brand, "BOTTOMLEFT", 0, -2)
    brandNote:SetText("SETTINGS")

    local search = UI.SearchBox(nav, NAV_WIDTH - 24, "Search settings", function(text)
        query = text or ""
        Layout()
    end)
    search:SetPoint("TOPLEFT", 12, -56)

    local navButtons = {}
    local function MarkNav()
        local under = PAGE_BY_KEY[current].nav or current
        for key, b in pairs(navButtons) do
            local on = query == "" and key == under
            b.bg:SetColorTexture(addon:Color(on and "highlight" or "hover"))
            b.bg:SetShown(on or b:IsMouseOver())
            b.bar:SetShown(on)
            b.label:SetTextColor(addon:Color(on and "gold" or "text"))
        end
    end
    local y = -92
    for _, page in ipairs(PAGES) do
        if page.group then
            y = y - 8
            local heading = UI.Text(nav, "label", "gold")
            heading:SetPoint("TOPLEFT", PAD, y)
            heading:SetText(page.group:upper())
            y = y - 18
        elseif not page.hidden then
            local b = CreateFrame("Button", nil, nav)
            b:SetSize(NAV_WIDTH - 16, 24)
            b:SetPoint("TOPLEFT", 8, y)
            b.bg = b:CreateTexture(nil, "BACKGROUND")
            b.bg:SetAllPoints()
            b.bar = b:CreateTexture(nil, "ARTWORK")
            b.bar:SetPoint("TOPLEFT")
            b.bar:SetPoint("BOTTOMLEFT")
            b.bar:SetWidth(3)
            b.bar:SetColorTexture(addon:Color("gold"))
            b.label = UI.Text(b, "body", "text")
            b.label:SetPoint("LEFT", 14, 0)
            b.label:SetText(page.label)
            b:SetScript("OnClick", function() Open(page.key) end)
            b:SetScript("OnEnter", MarkNav)
            b:SetScript("OnLeave", function() C_Timer.After(0, MarkNav) end)
            navButtons[page.key] = b
            y = y - 26
        end
    end

    -- The page
    local area = ScrollArea(panel)
    area.scroll:SetPoint("TOPLEFT", NAV_WIDTH + 1 + PAD, -PAD)
    area.scroll:SetPoint("BOTTOMRIGHT", -(PAD + SCROLL_BAR + 10), PAD)
    local content = area.content

    local pageTitle = UI.Text(content, "title")
    pageTitle:SetPoint("TOPLEFT", 0, -2)
    local pageIntro = UI.Text(content, "small", "muted")
    pageIntro:SetPoint("TOPLEFT", pageTitle, "BOTTOMLEFT", 0, -8)
    pageIntro:SetWidth(PAGE_WIDTH - 30)
    pageIntro:SetWordWrap(true)
    pageIntro:SetSpacing(2)
    local emptyText = UI.Text(content, "body", "muted")
    emptyText:SetWidth(PAGE_WIDTH)
    emptyText:SetWordWrap(true)

    -- The settings
    local rows = {}

    rows.minROI = ChoiceRow(content, panel, "minROI", "Worth crafting at", "The ROI a craft needs for Recommended and Best crafts.")
    rows.minLine = ChoiceRow(content, panel, "minLine", "Worth a to-do at", "The gold a suggested batch must make in all.")
    rows.dealPercent = ChoiceRow(content, panel, "dealPercent", "Cheap materials", "How far below usual a material's price counts as cheap.")
    rows.heldDays = ChoiceRow(content, panel, "heldDays", "Held too long", "Days unsold before a crafted item is flagged.")

    rows.priceSource = ChoiceRow(content, panel, "priceSource", "Price source", "Where AH prices come from when both Auctionator and TSM have one.")
    rows.ahScan = ToggleRow(content, panel, "ahScan", "Auction House scan", "Goldsmith's own scan and Buy next, in a panel by the AH.",
        function() if addon.UpdateScanPanel then addon.UpdateScanPanel() end end)
    rows.autoScan = ToggleRow(content, panel, "autoScan", "Auto scan", "Scans when you open the AH and the last scan is over an hour old.")
    function rows.autoScan:Update()
        local on = addon:Setting("ahScan")
        self.control:SetOn(on and addon:Setting("autoScan"))
        self.control:SetUsable(on)
        self:SetDescription(on and "Scans when you open the AH and the last scan is over an hour old."
            or "Needs Auction House scan on.")
    end

    rows.buyFor = ChoiceRow(content, panel, "buyFor", "Buy next for", "Whose queues Buy next shops for at the AH.")
    rows.buyOver = ChoiceRow(content, panel, "buyOver", "Buy without asking", "How much over the plan Buy next pays without a second click.")
    rows.auctionatorButton = ToggleRow(content, panel, "auctionatorButton", "Send to Auctionator button",
        "A shopping list in Auctionator, on the queue and plans.",
        function() if addon.RefreshWindow then addon.RefreshWindow() end end)

    rows.tooltips = ChoiceRow(content, panel, "tooltips", "Item tooltips", "Goldsmith's lines in the game's item tooltips.")
    rows.craftCost = ToggleRow(content, panel, "craftCost", "Cost in the profession window", "Your materials and Profit under a recipe's materials.",
        function() if addon.UpdateCraftCostLines then addon:UpdateCraftCostLines() end end)
    rows.showMinimap = ToggleRow(content, panel, "showMinimap", "Minimap button", "A button by the minimap that opens Goldsmith.",
        function() addon:UpdateMinimapButton() end)

    rows.chat = ChoiceRow(content, panel, "chat", "Chat messages", "What Goldsmith says in chat as things happen.")
    rows.sounds = ToggleRow(content, panel, "sounds", "Sounds", "A sound when Goldsmith stops you, so you look first.",
        -- What it sounds like
        function(on) if on then addon:Alert("stop") end end)

    rows.keybind = Row(content, "keybind", "Key to open Goldsmith", "")
    PlaceControl(rows.keybind, UI.Button(rows.keybind, "Set key", CONTROL_WIDTH, 24, function() addon:OpenKeybindings() end), "keybind")
    function rows.keybind:Update()
        local key = addon:ToggleKeyText()
        self:SetDescription(key and ("Opens with " .. key .. ".") or "No key set yet.")
        self.control:SetLabel(key and "Change key" or "Set key")
    end
    rows.peekKey = ChoiceRow(content, panel, "peekKey", "See through Goldsmith", "Hold it to click the auctioneer or a mailbox behind the window.")

    rows.keepDays = Row(content, "keepDays", "Keep history for", "How long purchases, sales and deposits are kept.")
    Dropdown(rows.keepDays, "keepDays", function(root)
        for _, c in ipairs(CHOICES.keepDays) do
            root:CreateRadio(c.label, function() return addon:Setting("keepDays") == c.value end,
                function() SetKeepDays(c.value, panel) end)
        end
    end)
    function rows.keepDays:Update() self.control:SetLabel(ButtonLabel(CHOICES.keepDays, addon:Setting("keepDays"))) end

    -- Price source only matters with both price addons installed. Asked
    -- each time: TSM can finish loading after Goldsmith.
    local function Applies(key)
        if key == "priceSource" then return addon:HasAuctionator() and addon:HasTSM() and true or false end
        return true
    end

    -- Characters and ignored crafts: a toggle each, made as needed
    local listRows = { characters = {}, ignored = {} }
    local function ListRow(kind, i)
        local pool = listRows[kind]
        if pool[i] then return pool[i] end
        local row = Row(content, kind, "", "")
        PlaceControl(row, UI.Toggle(row, function(on)
            if kind == "characters" then
                addon:SetCharacterIncluded(row.charKey, on)
            else
                addon:SetIgnored(row.itemID, row.titleText, on)
            end
            panel:Update()
        end), kind)
        row:SetScript("OnMouseUp", function(self, button)
            if button == "LeftButton" then self.control:Click() end
        end)
        pool[i] = row
        return row
    end
    -- Ignored crafts are listed as they were when the page opened, so one
    -- turned off stays there to turn back on
    local ignoredShown = {}

    -- The dashboard
    local dash = CreateFrame("Frame", nil, content)
    dash:SetWidth(PAGE_WIDTH)
    local CARD_WIDTH = (PAGE_WIDTH - 10) / 2
    local function Card(icon, title, onClick)
        local card = CreateFrame("Button", nil, dash, "BackdropTemplate")
        card:SetSize(CARD_WIDTH, 66)
        UI.Style(card, "panel", "border")
        card.icon = card:CreateTexture(nil, "ARTWORK")
        card.icon:SetSize(38, 38)
        card.icon:SetPoint("LEFT", 14, 0)
        card.icon:SetTexture(icon)
        card.icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        card.title = UI.Text(card, "heading")
        card.title:SetPoint("TOPLEFT", card.icon, "TOPRIGHT", 12, -1)
        card.title:SetText(title)
        card.text = UI.Text(card, "small", "muted")
        card.text:SetPoint("TOPLEFT", card.title, "BOTTOMLEFT", 0, -5)
        card.text:SetWidth(CARD_WIDTH - 38 - 14 - 12 - 12)
        card.text:SetWordWrap(true)
        card.text:SetMaxLines(2)
        card:SetScript("OnClick", onClick)
        card:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(addon:Color("gold")) end)
        card:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("border")) end)
        return card
    end

    local cards = {
        Card("Interface\\Icons\\INV_Misc_Book_09", "Help", function() Open("help") end),
        Card("Interface\\Icons\\INV_Letter_15", "Support and feedback", function() Open("support") end),
        Card("Interface\\Icons\\INV_Misc_Map_01", "Take the tour", function() panel:Hide(); addon:StartTour() end),
        Card("Interface\\Icons\\INV_Misc_Note_01", "Getting started", function() panel:Hide(); addon:ShowSetup() end),
    }
    -- Help, Support and the bug report, as pages (Help and Support below,
    -- the report in Report.lua)
    local pages = {
        help = addon:BuildHelpPage(content, PAGE_WIDTH, panel),
        support = addon:BuildSupportPage(content, PAGE_WIDTH, function() Open("report") end),
        report = addon:BuildReportPage(content, PAGE_WIDTH, function() Open("support") end),
    }
    for _, p in pairs(pages) do p:Hide() end

    cards[1].text:SetText("Getting started, what each tab is for, and the /gsm commands.")
    cards[3].text:SetText("A guided walk through the window, a step at a time.")
    cards[4].text:SetText("The setup checklist: professions, prices and your first craft.")

    local statusHeading = UI.Text(dash, "label", "dim")
    statusHeading:SetText("STATUS")
    local TILE_WIDTH = (PAGE_WIDTH - 3 * 8) / 4
    local tiles = {}
    for i = 1, 4 do
        local tile = UI.StatTile(dash, "raised")
        tile:SetWidth(TILE_WIDTH)
        tile.value:SetFontObject(addon:Font("value"))
        tile.value:SetPoint("RIGHT", tile, "RIGHT", -10, 0)
        tile.note:SetWordWrap(false)
        tiles[i] = tile
    end
    -- A tile that opens a page
    local function TileOpens(tile, key, what)
        tile:SetScript("OnMouseUp", function() Open(key) end)
        tile.tooltip = function(tooltip) addon:ClickHint(tooltip, "Click for " .. what, true) end
    end
    TileOpens(tiles[2], "prices", "Prices and scan")
    TileOpens(tiles[3], "keys", "Keys")
    tiles[1].tooltip = function(tooltip)
        tooltip:AddLine("Goldsmith " .. addon:GetVersion(), 1, 1, 1)
        tooltip:AddLine("/gsm news shows what's new in this version.", 0.8, 0.8, 0.8, true)
    end
    tiles[4].tooltip = function(tooltip)
        tooltip:AddLine("Settings changed from recommended", 1, 1, 1)
        tooltip:AddLine("Listed below, with a button to put them all back.", 0.8, 0.8, 0.8, true)
    end

    local changedHeading = UI.Text(dash, "label", "dim")
    changedHeading:SetText("CHANGED FROM RECOMMENDED")
    local reset = UI.Button(dash, "Reset to recommended", CONTROL_WIDTH, 24, function()
        StaticPopup_Show("GOLDSMITH_RESET_SETTINGS", nil, nil, panel)
    end)
    UI.SetTooltip(reset, function(tooltip)
        tooltip:AddLine("Reset to recommended", 1, 1, 1)
        tooltip:AddLine("Every setting back to what most players want. Excluded characters and ignored crafts stay as they are.", 0.8, 0.8, 0.8, true)
    end, "ANCHOR_LEFT")
    local changedNone = UI.Text(dash, "small", "muted")
    changedNone:SetText("Everything is on its recommended setting.")
    local changedLines = {}
    local function ChangedLine(i)
        if changedLines[i] then return changedLines[i] end
        local line = CreateFrame("Button", nil, dash)
        line:SetSize(PAGE_WIDTH, 20)
        line.label = UI.Text(line, "body", "text")
        line.label:SetPoint("LEFT", 0, 0)
        line:SetScript("OnClick", function(self) Open(self.page) end)
        line:SetScript("OnEnter", function(self) self.label:SetTextColor(addon:Color("gold")) end)
        line:SetScript("OnLeave", function(self) self.label:SetTextColor(addon:Color("text")) end)
        changedLines[i] = line
        return line
    end

    -- Fills the dashboard and lays it out; returns its height
    local function LayoutDashboard()
        local errors = #addon:GetErrors()
        cards[2].text:SetText(errors > 0
            and string.format("%d error%s saved: a bug report includes them.", errors, errors == 1 and "" or "s")
            or "Report a bug or suggest an idea.")
        cards[2].text:SetTextColor(addon:Color(errors > 0 and "warning" or "muted"))
        for i, card in ipairs(cards) do
            card:ClearAllPoints()
            card:SetPoint("TOPLEFT", dash, "TOPLEFT", ((i - 1) % 2) * (CARD_WIDTH + 10), -math.floor((i - 1) / 2) * 76)
        end
        local dy = -2 * 76 - 10

        statusHeading:ClearAllPoints()
        statusHeading:SetPoint("TOPLEFT", dash, "TOPLEFT", 0, dy)
        dy = dy - 18
        local scan = GoldsmithDB.ownScan
        local key = addon:ToggleKeyText()
        local changed = ChangedKeys()
        tiles[1]:Set("Version", addon:GetVersion(), "text", "/gsm news: what's new")
        if not addon:Setting("ahScan") then
            tiles[2]:Set("Last AH scan", "Off", "muted", "Scan turned off")
        elseif scan and scan.time then
            -- The day on top, its time underneath: "Yesterday 22:52" was cut
            -- off in the tile (user, 2026-10-26)
            local when = addon:WhenText(scan.time, "today ")
            local day, clock = when:match("^(%a+) (%d+:%d+)$")
            tiles[2]:Set("Last AH scan", ((day or when):gsub("^%l", string.upper)), "text",
                (clock and (clock .. " · ") or "") .. BreakUpLargeNumbers(scan.items or 0) .. " items")
        else
            tiles[2]:Set("Last AH scan", "None yet", "muted", "Scan at the auctioneer")
        end
        tiles[3]:Set("Key to open", key or "Not set", key and "text" or "warning", key and "Change in Keys" or "Set one in Keys")
        tiles[4]:Set("Changed", string.format("%d of %d", #changed, SETTING_COUNT), #changed > 0 and "gold" or "text",
            "from recommended")
        for i, tile in ipairs(tiles) do
            tile:ClearAllPoints()
            tile:SetPoint("TOPLEFT", dash, "TOPLEFT", (i - 1) * (TILE_WIDTH + 8), dy)
        end
        dy = dy - 76 - 18

        changedHeading:ClearAllPoints()
        changedHeading:SetPoint("TOPLEFT", dash, "TOPLEFT", 0, dy - 6)
        reset:ClearAllPoints()
        reset:SetPoint("TOPRIGHT", dash, "TOPRIGHT", 0, dy)
        reset:SetEnabled(#changed > 0)
        reset:SetAlpha(#changed > 0 and 1 or 0.5)
        dy = dy - 30
        for _, line in ipairs(changedLines) do line:Hide() end
        changedNone:SetShown(#changed == 0)
        if #changed == 0 then
            changedNone:ClearAllPoints()
            changedNone:SetPoint("TOPLEFT", dash, "TOPLEFT", 0, dy)
            dy = dy - 20
        end
        for i, settingKey in ipairs(changed) do
            local line = ChangedLine(i)
            line.page = PAGE_OF_ROW[settingKey].key
            line.label:SetText(rows[settingKey].titleText .. ": " .. addon:Colorize(ValueText(settingKey), "gold")
                .. addon:Colorize("   " .. PAGE_OF_ROW[settingKey].label, "dim"))
            line:ClearAllPoints()
            line:SetPoint("TOPLEFT", dash, "TOPLEFT", 0, dy)
            line:Show()
            dy = dy - 22
        end
        dash:SetHeight(-dy)
        return -dy
    end

    -- Search results: a heading for each page with a match (click to open
    -- it), then its matching settings
    local headings = {}
    local function Heading(i)
        if headings[i] then return headings[i] end
        local h = CreateFrame("Button", nil, content)
        h:SetSize(PAGE_WIDTH, 22)
        h.label = UI.Text(h, "heading")
        h.label:SetPoint("LEFT", 0, 0)
        h:SetScript("OnClick", function(self) Open(self.page) end)
        h:SetScript("OnEnter", function(self) self.label:SetTextColor(addon:Color("text")) end)
        h:SetScript("OnLeave", function(self) self.label:SetTextColor(addon:Color("gold")) end)
        headings[i] = h
        return h
    end
    local function Matches(text, words)
        text = (text or ""):lower()
        return text:find(words, 1, true) ~= nil
    end
    local function RowMatches(key, words)
        local row = rows[key]
        if Matches(row.titleText, words) or Matches(row.descriptionText, words) then return true end
        for _, line in ipairs(HELP[key] or {}) do
            if Matches(line, words) then return true end
        end
        return false
    end
    local function ListNames(page)
        local names = {}
        if page.list == "characters" then
            for _, entry in ipairs(addon:GetCharacters()) do table.insert(names, CharacterLabel(entry)) end
        elseif page.list == "ignored" then
            for _, entry in ipairs(addon:GetIgnoredItems()) do table.insert(names, entry.name) end
        end
        return names
    end
    local function PageMatches(page, words)
        if Matches(page.label, words) or Matches(page.intro, words) then return true end
        if page.key == "help" and Matches(addon:HelpText(), words) then return true end
        for _, name in ipairs(ListNames(page)) do
            if Matches(name, words) then return true end
        end
        return false
    end

    -- Lays out the page (or the search results) from the top
    local pageY
    local function Place(frame, height, gap)
        frame:ClearAllPoints()
        frame:SetPoint("TOPLEFT", content, "TOPLEFT", 0, pageY)
        frame:Show()
        pageY = pageY - height - (gap or ROW_GAP)
    end

    function Layout(keepPlace)
        for _, row in pairs(rows) do row:Hide() end
        for _, pool in pairs(listRows) do for _, row in ipairs(pool) do row:Hide() end end
        for _, h in ipairs(headings) do h:Hide() end
        dash:Hide()
        for _, p in pairs(pages) do p:Hide() end
        emptyText:Hide()
        MarkNav()

        local page = PAGE_BY_KEY[current]
        local searching = query:gsub("^%s+", ""):gsub("%s+$", "") ~= ""
        if searching then
            pageTitle:SetText("Search")
            pageIntro:SetText(string.format("Settings that mention \"%s\". Click a heading for its page.", query))
        else
            pageTitle:SetText(page.title or page.label)
            pageIntro:SetText(page.intro or "")
        end
        pageY = -2 - 20 - 8 - pageIntro:GetStringHeight() - 16

        if searching then
            local words = query:lower():gsub("^%s+", ""):gsub("%s+$", "")
            local n = 0
            for _, p in ipairs(PAGES) do
                if p.key and p.key ~= "dashboard" and not p.hidden then
                    local found = {}
                    for _, key in ipairs(p.rows or {}) do
                        if Applies(key) and RowMatches(key, words) then table.insert(found, key) end
                    end
                    if #found > 0 or PageMatches(p, words) then
                        n = n + 1
                        local h = Heading(n)
                        h.page = p.key
                        h.label:SetText(p.label)
                        h.label:SetTextColor(addon:Color("gold"))
                        Place(h, 22, 4)
                        for _, key in ipairs(found) do Place(rows[key], ROW_HEIGHT) end
                        pageY = pageY - 10
                    end
                end
            end
            if n == 0 then
                emptyText:SetText("No setting matches. Try another word.")
                Place(emptyText, 20)
            end
        elseif current == "dashboard" then
            Place(dash, LayoutDashboard())
        elseif page.page then
            Place(pages[page.page], pages[page.page]:Measure())
        elseif page.list == "characters" then
            for i, entry in ipairs(addon:GetCharacters()) do
                local row = ListRow("characters", i)
                row.charKey = entry.key
                row.titleText = CharacterLabel(entry)
                row.title:SetText(row.titleText)
                local color = RAID_CLASS_COLORS and entry.data.class and RAID_CLASS_COLORS[entry.data.class]
                if color then row.title:SetTextColor(color.r, color.g, color.b) else row.title:SetTextColor(addon:Color("text")) end
                row:SetDescription(ProfessionList(entry.data))
                row.control:SetOn(addon:IsCharacterIncluded(entry.key))
                Place(row, ROW_HEIGHT)
            end
        elseif page.list == "ignored" then
            for i, entry in ipairs(ignoredShown) do
                local row = ListRow("ignored", i)
                row.itemID = entry.itemID
                row.titleText = entry.name
                row.title:SetText(entry.name)
                row:SetDescription("")
                row.control:SetOn(addon:IsIgnored(entry.itemID))
                Place(row, ROW_HEIGHT)
            end
            if #ignoredShown == 0 then
                emptyText:SetText("Nothing ignored.")
                Place(emptyText, 20)
            end
        else
            for _, key in ipairs(page.rows) do
                if Applies(key) then Place(rows[key], ROW_HEIGHT) end
            end
        end
        area:SetContentHeight(-pageY, keepPlace)
    end
    area.onResize = function() if panel:IsShown() then Layout(true) end end

    local function UpdateRows()
        for _, row in pairs(rows) do row:Update() end
    end

    -- A page from the top, with its values as they are now (a key set in
    -- the game's Keybindings, say)
    function Open(key)
        current = PAGE_BY_KEY[key] and key or "dashboard"
        if current == "ignored" then ignoredShown = addon:GetIgnoredItems() end
        query = ""
        search:SetText("")
        search:ClearFocus()
        UpdateRows()
        Layout()
        -- A new report each time, selected to copy
        if current == "report" then pages.report:Fill() end
    end
    panel.Open = function(_, key) Open(key) end
    panel.Search = function(_, text) query = text or ""; UpdateRows(); Layout() end

    -- Values changed (a click here, or data elsewhere): redraw in place
    function panel:Update()
        UpdateRows()
        Layout(true)
    end
    panel:SetScript("OnShow", function() panel:Update() end)
    return panel
end

-- Help
--
-- What a new player needs, inside the game: WoW can't open a web page, so
-- a link to the README would only be text to copy.

local HELP_SECTIONS = {
    { "Getting started",
      "Open each profession once on every crafter (press K) so Goldsmith loads its recipes and crafting stats. Prices come with Goldsmith Data from the start; press Scan the AH at the auction house for live ones. From then on, purchases, sales, crafts and AH deposits are recorded by themselves." },
    { "Opening Goldsmith",
      "/gsm, the Goldsmith button on the minimap, the addons button by the minimap, or a key of your own (Settings > Keys)." },
    -- One line per tab, its name in the text color (Theme.lua loads first)
    { "The tabs", table.concat({
        addon:Colorize("Overview", "text") .. ": what to do next on the character you're on, which of your other characters has the most waiting, and how you're doing across all of them. \"followed\" by Do this next adds up what the suggestions you crafted have made; Set a goal on the Total gold chart gives you a gold goal.",
        addon:Colorize("Characters", "text") .. ": a to-do list for each character, its craft cooldowns, and which characters count.",
        addon:Colorize("Crafts", "text") .. ": what you can make, with its cost, profit and how well it sells. Show picks Recommended, All crafts or Not learned yet (recipes worth going to learn), and can hide gear. Click a craft to plan it: type how many crafts, and it shows what they make and what to buy. With concentration it plans only what yours covers now; Why this mix shows the material qualities compared, and clicking one uses it instead.",
        addon:Colorize("Queue", "text") .. ": crafts lined up to make, with one shopping list and a button that does the next step.",
        addon:Colorize("Items", "text") .. ": any item's page, In my bags for everything you hold, and Cheap materials (right-click one to stock up).",
        addon:Colorize("History", "text") .. ": every purchase, sale, craft and deposit; right-click an entry to fix it.",
        addon:Colorize("Stats", "text") .. ": lifetime stats and your Goldsmith title; Share in chat to brag.",
      }, "\n") },
    { "Getting to the AH and the mailbox",
      "Hold Alt and Goldsmith fades almost away: clicks go through it, so you can click the auctioneer or the mailbox behind it without moving the window. Let go and it's back. Pick another key in Settings > Keys. The game's Interact key works too: turn on Options > Gameplay > Controls > Enable Interact Key, bind Interact with Target in Keybindings, and press it beside the auctioneer or a mailbox." },
    { "At the AH, vendors and the mailbox",
      "At the AH, Goldsmith's panel scans prices and Buy next buys what the queue needs, one click per item; tick All queues to shop for every character. It asks twice when a craft would lose money. At a vendor, its panel buys the vendor materials. At the mailbox, a panel lists what to send each character: click once to fill in the mail, again to send it. Drag a panel or notice by its move icon; right-click the icon to put it back." },
    { "In the game's windows",
      "Under the reagents in a profession window, Goldsmith shows what your materials cost and the profit, the same as on Crafts; hover it for the breakdown. On a crafting order, only the materials you supply count, with the commission and rewards (a payout bag at what's usually inside). Above Goldsmith's Craft button, a note reminds you when a crafting buff such as Everburning Ignition or Shattered Essence is off, and a button offers to swap in the profession tool that suits the craft best." },
    { "Hovers and clicks",
      "Click ? at the top right, then any part of the window, to see what it's for. Hovers show the numbers. Hold Ctrl over one to see what each number means, how it's worked out and what clicking does; let go and they're gone. The line along the bottom of the window says what clicking, right-clicking and shift-clicking do on the screen you're on. A gold Filtered button by Settings means something is hiding part of the list: click it to see everything." },
    { "When a suggestion isn't for you",
      "The x on a Do this next card, or right-clicking a to-do on Characters, hides a suggestion for a day; it comes back after that if it's still a good bet, and the \"hidden\" button brings it back sooner. To hide something for good, right-click it on Crafts and pick Ignore; to undo that, turn it off in Settings > Ignored crafts, or tick Show ignored in the Crafts Show menu and right-click it. Deleted something in History by mistake? It stays greyed in the list until you leave History: click it to undo. Too many small suggestions? Settings > Worth a to-do at sets the least gold a batch must make." },
    { "Item tooltips",
      "Show your cost, profit and break-even price. Hold Shift for each material's cost. Settings > Item tooltips makes them shorter or turns them off." },
    { "Using Auctionator?",
      "Not needed: Goldsmith scans the AH itself and Buy next does the shopping. Auctionator is still handy for posting your crafts, and Goldsmith reads its scans. If you'd rather shop with Auctionator's shopping lists, turn on Settings > Send to Auctionator button." },
    { "If you already use TSM",
      "Not needed: Goldsmith Data covers prices and how well each item sells (Sells / Slow / Hardly sells). If TSM and its desktop app are installed anyway, Goldsmith uses TSM's region sales per day and sale rates instead, a check on listings far from the usual price, and prices between AH scans." },
    { "Commands",
      "Everything is in the window; commands are for checking what Goldsmith recorded. /gsm help lists them all, for example /gsm cooldowns (every craft cooldown it's found, and what the game reports), /gsm recipes and /gsm milling. The buttons below bring back the getting started checklist and the tour." },
}

-- The Help page in Settings: each section's heading and text, then the
-- getting started checklist and the tour (user, 2026-10-25: in the panel,
-- not a window of its own). page:Measure() sets and returns its height,
-- once the text has wrapped to the page's width.
function addon:BuildHelpPage(parent, width, settings)
    local page = CreateFrame("Frame", nil, parent)
    page:SetWidth(width)
    local above
    local texts = {}
    for _, section in ipairs(HELP_SECTIONS) do
        local heading = UI.Text(page, "body", "text")
        if above then
            heading:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -14)
        else
            heading:SetPoint("TOPLEFT", 0, 0)
        end
        heading:SetText(section[1])
        local text = UI.Text(page, "small", "muted")
        text:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)
        text:SetWidth(width)
        text:SetWordWrap(true)
        text:SetSpacing(2)
        text:SetText(section[2])
        table.insert(texts, heading)
        table.insert(texts, text)
        above = text
    end

    local setupButton = UI.Button(page, "Show getting started", 160, 24, function()
        settings:Hide()
        addon:ShowSetup()
    end)
    setupButton:SetPoint("TOPLEFT", above, "BOTTOMLEFT", 0, -18)
    local tourButton = UI.Button(page, "Take the tour", 120, 24, function()
        settings:Hide()
        addon:StartTour()
    end)
    tourButton:SetPoint("LEFT", setupButton, "RIGHT", 8, 0)

    function page:Measure()
        local height = (#HELP_SECTIONS - 1) * 14 + #HELP_SECTIONS * 4 + 18 + 24
        for _, fs in ipairs(texts) do height = height + fs:GetStringHeight() end
        page:SetHeight(height)
        return height
    end
    return page
end

-- All of Help's text, for the settings search
function addon:HelpText()
    local parts = {}
    for _, section in ipairs(HELP_SECTIONS) do table.insert(parts, section[1] .. " " .. section[2]) end
    return table.concat(parts, " ")
end

-- Support and feedback
--
-- Where to report bugs and ideas: CurseForge comments first (players have
-- an account from the app), GitHub issues for those who use it. Addons
-- can't open a web page, so the links are in boxes to copy. No donation link here: Blizzard's
-- add-on policy doesn't allow asking for donations in game, so that lives
-- on the CurseForge page (2026-10-06).

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

-- The Support and feedback page in Settings (the "Found a bug" line is
-- the page's intro): the two links to copy, what helps in a bug report,
-- and the button for the report. page:Measure() sets and returns its
-- height.
function addon:BuildSupportPage(parent, width, openReport)
    local page = CreateFrame("Frame", nil, parent)
    page:SetWidth(width)

    local link = CopyBox(page, width, addon.COMMENTS_URL)
    link:SetPoint("TOPLEFT", 0, 0)
    local githubText = UI.Text(page, "small", "muted")
    githubText:SetPoint("TOPLEFT", link, "BOTTOMLEFT", 0, -10)
    githubText:SetText("Use GitHub? Issues work too:")
    local github = CopyBox(page, width, addon.ISSUES_URL)
    github:SetPoint("TOPLEFT", githubText, "BOTTOMLEFT", 0, -6)

    local heading = UI.Text(page, "body", "text")
    heading:SetPoint("TOPLEFT", github, "BOTTOMLEFT", 0, -16)
    heading:SetText("For a bug, it helps to include")
    local details = UI.Text(page, "small", "muted")
    details:SetPoint("TOPLEFT", heading, "BOTTOMLEFT", 0, -4)
    details:SetWidth(width)
    details:SetWordWrap(true)
    details:SetSpacing(2)
    details:SetText("What you did and what happened. Copy bug report adds your versions, settings and any saved errors.")

    local reportButton = UI.Button(page, "Copy bug report", 140, 24, openReport)
    reportButton:SetPoint("TOPLEFT", details, "BOTTOMLEFT", 0, -14)
    local errorsText = UI.Text(page, "small", "warning")
    errorsText:SetPoint("LEFT", reportButton, "RIGHT", 10, 0)

    function page:Measure()
        local errors = #addon:GetErrors()
        errorsText:SetText(errors > 0 and string.format("%d error%s saved", errors, errors == 1 and "" or "s") or "")
        local height = 26 + 10 + githubText:GetStringHeight() + 6 + 26 + 16 + heading:GetStringHeight() + 4
            + details:GetStringHeight() + 14 + 24
        page:SetHeight(height)
        return height
    end
    return page
end

_G.Goldsmith = addon
