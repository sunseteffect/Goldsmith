local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Help mode
--
-- The ? in the header. Click it and every part of the window that has an
-- explanation gets a gold outline; click one and a box says what it's for.
-- The tabs stay clickable, so any tab can be explored the same way. ? again,
-- Esc or closing the window ends it.
--
-- Why (user, 2026-10-15): people learn a feature best right when they're
-- about to use it, not in a long tour (the tour was 20 steps and a friend
-- couldn't take it in; now it's 7, and its last step points here). One
-- button rather than a question mark on every part, so the window doesn't
-- get any busier. The texts are the old tour's, one idea each.
--
-- While it's on, a dark layer over the window (all but the tabs) takes
-- the clicks, so nothing underneath does anything by accident; the
-- outlines sit above it. Stand-ins for ? and X sit on top so both still
-- work.

local EDGE = 2
local BOX_WIDTH = 320
local DIM_ALPHA = 0.55
local DIM_LEVEL = 20
local OUTLINE_LEVEL = 30
local BOX_LEVEL = 200
local INTRO = "Click any outlined part to see what it's for. The tabs still work. Esc or ? to stop."

local active, ticker, selected
local dims, outlines, box, helpProxy, closeProxy = {}, {}, nil, nil, nil
local entries = {}

function addon:HelpModeActive()
    return active == true
end

local function Screen(key)
    local screen = addon:GetTabScreen(key)
    return screen and screen.view
end

local function Part(name)
    return addon.tourParts and addon.tourParts[name]
end

local function Shown(f)
    return f and f:IsVisible() and (f:GetWidth() or 0) > 1 and (f:GetHeight() or 0) > 1
end

-- What can be explained right now: { title, text, first, last }
local function Add(list, title, text, first, last)
    if Shown(first) and (not last or Shown(last)) then
        table.insert(list, { title = title, text = text, first = first, last = last })
    end
end

local function HeaderParts(list)
    local filters = Part("filters")
    Add(list, "Filters",
        "Pick one profession or all of them, the dates for profits and charts, and which expansions' items to show. They apply on every tab.",
        filters[1], filters[2])
    Add(list, "Prices",
        "Where prices come from right now: Goldsmith Data's daily prices for your region, an Auctionator scan, or TSM. It turns orange when they're old.",
        Part("price"))
    Add(list, "Settings",
        "Prices, when a craft is worth suggesting, item tooltips, chat messages and which characters count. Help, support and bug reports are in there too.",
        Part("settings"))
    Add(list, "Filtered",
        "Something is narrowing what this tab shows. Click it (after help) to clear it.",
        Part("filterChip"))
    Add(list, "What clicks do",
        "What clicking does on the screen you're on: click, right-click, Shift-click. Hold Ctrl over any hover to see what its numbers mean.",
        Part("legend"))
end

local TAB_PARTS = {}

TAB_PARTS.overview = function(list)
    local view = Screen("overview")
    if not view then return end
    Add(list, "Profit on sales",
        "Profit on what you sold in the dates picked at the top, after what the items cost you and AH deposits. All your characters.",
        view.tiles[1])
    Add(list, "Sales", "Gold from your sales after the AH cut. All your characters.", view.tiles[2])
    Add(list, "Gold in stock",
        "What the crafted items and materials you hold are worth, on every character. Click it to see them.",
        view.tiles[3])
    Add(list, "Concentration",
        "Concentration on the character you're on, and what it's worth spent now. Hover for every character.",
        view.tiles[4])
    if view.setup:IsShown() then
        Add(list, "Getting started",
            "The steps that get Goldsmith ready. Each one ticks itself off. Close it with X when they're done.",
            view.actionsPanel)
    else
        Add(list, "Do this next",
            "What to do now on the character you're on, best first. Only solid bets show here: things that sell. Click one to open its plan.",
            view.actionsPanel)
        Add(list, "Followed",
            "How the suggestions you crafted turned out: what they made compared to what Goldsmith expected. Hover it for each one.",
            view.followed)
        Add(list, "Your other characters",
            "Who has the most gold waiting. Click it for every character's to-do list on the Characters tab.",
            view.others)
    end
    Add(list, "Charts",
        "Profit by day, total gold, and gold per hour of goldmaking. The arrows switch between them.",
        view.chartPanel)
    Add(list, "Gold goal",
        "A gold goal to work toward, counted from when you set it. Click it to set or change one.",
        view.goal)
    Add(list, "Profit by profession",
        "Which professions make you the most gold in the dates picked at the top, best first. Hover one for its numbers.",
        view.professionsPanel)
end

TAB_PARTS.crafts = function(list)
    local view = Screen("crafts")
    if not view then return end
    local plan = view.plan
    if plan:IsShown() then
        Add(list, "How many", "How many crafts to make. The line beside it says what they'll make.",
            plan.qty, Shown(plan.crafts) and plan.crafts or nil)
        Add(list, "Use concentration",
            "Plans this quality with concentration, using the mix of material qualities that earns the most.",
            plan.useConc)
        Add(list, "Materials",
            "Each material and where it comes from: your bags, a vendor, the AH, or crafting it first. Right-click one to change that.",
            plan.list)
        Add(list, "Material qualities",
            "The mix of material qualities. Goldsmith picks the best one for this quality and lists the top three to compare. Click one to use it instead, or click the bar to hide or show them.",
            plan.mixes)
        Add(list, "Cost and profit",
            "What it all costs, what it sells for and the profit, worked out from your own crafting stats. Hover a number for how.",
            plan.shop:GetParent())
        Add(list, "Shopping list",
            "With Auctionator, sends everything you need to buy to its Shopping tab at the AH. Items come off it as you buy them.",
            plan.shop)
        Add(list, "Craft", "Crafts it from here: one click per craft.", plan.craft)
        Add(list, "Add to queue",
            "Puts this plan in the character's queue, so you can shop for everything at once and craft it all from the Queue tab.",
            plan.queue)
    elseif view.salvage and view.salvage:IsShown() then
        Add(list, "Salvage plan",
            "Milling, prospecting or crushing: how many to do, what it costs, and what comes out, from your own results.",
            view.salvage)
    else
        Add(list, "Show",
            "Recommended (solid bets), All crafts, or Not learned yet: recipes worth going to learn. It can hide gear too.",
            view.show)
        Add(list, "Only this character",
            "Only what the character you're on can make, with their own stats.", view.onlyMine)
        Add(list, "Find a craft", "Search every craft and salvage by name.", view.searchBox)
        Add(list, "Concentration",
            "Shows the better quality concentration reaches, and how much gold each point earns (g/conc).",
            view.concSwitch)
        Add(list, "Crafts",
            "Every craft with its cost from your own crafting stats, AH price, profit and how well it sells. Click one for its plan.",
            view.list)
        Add(list, "Concentration to spend",
            "Your concentration and the best way to spend it right now. Hover it for the details.",
            view.budget)
    end
end

TAB_PARTS.queue = function(list)
    local view = Screen("queue")
    if not view then return end
    Add(list, "Whose queue", "Each character has their own queue. Switch between them here.", view.who)
    Add(list, "Queue", "Crafts lined up to make, added from a plan or by right-clicking a craft.", view.list)
    Add(list, "Shopping list",
        "With Auctionator, one shopping list for everything in this character's queue (the one picked in Whose queue). Items come off it as you buy them.",
        view.shop)
    Add(list, "Craft next", "Does the next step of the queue: one click per craft.", view.craft)
end

TAB_PARTS.items = function(list)
    local view = Screen("items")
    if not view then return end
    local page = view.page
    if page:IsShown() then
        -- A part for each piece (user, 2026-10-15: one box for the whole
        -- page said too little, and switching tiers wasn't obvious)
        local t = page.tiles or {}
        Add(list, "AH price", "What it sells for on the AH right now, and where that price comes from.", t[1])
        Add(list, "Usual price", "Its usual price, and how today's price compares. Hover it for the range.", t[2])
        Add(list, "Sells", "How well it sells in your region, and how many you sell a day.", t[3])
        Add(list, "You have", "How many you hold on every character: bags, banks and AH listings.", t[4])
        Add(list, "Break-even",
            "The lowest price that doesn't lose money on what yours cost you, after the AH cut. List above this.",
            t[5])
        Add(list, "What it costs", "What yours cost you, crafted or bought, next to the AH price now.",
            page.concNote:GetParent())
        local firstTier, lastTier
        for _, row in ipairs(page.tierRows or {}) do
            if Shown(row) then
                firstTier = firstTier or row
                lastTier = row
            end
        end
        Add(list, "Tiers",
            "Each quality of this item, with its price and how many you have. Click one to switch this page to it.",
            firstTier, lastTier ~= firstTier and lastTier or nil)
        Add(list, "Price history",
            "What it has sold for over the dates picked at the top. The band is its usual range. Hover a point for that day.",
            page.chartNote:GetParent())
        Add(list, "Your activity",
            "Everything you've done with it, newest first: crafted, bought, posted and sold, with the gold each time. The link at the bottom opens it all in History.",
            page.earned:GetParent())
        Add(list, "Craft this", "Opens its plan on the Crafts tab.", page.craft)
        return
    end
    Add(list, "Find an item", "Search any item: its page has prices, costs and everything you've done with it.",
        view.searchBox)
    Add(list, "In my bags", "Lists what you hold, on every character.", view.inBags)
    Add(list, "Cheap materials", "Materials well below their usual price right now.", view.cheap)
    local boards = view.boards or {}
    if Shown(boards[1]) then
        Add(list, "Leaderboards",
            "Most profit, best margin, fastest sellers, and things held too long. Click an item for its page.",
            boards[1], boards[#boards])
    else
        Add(list, "Items", "Click an item for its page.", view.list)
    end
end

TAB_PARTS.history = function(list)
    local view = Screen("history")
    if not view then return end
    local chips = view.chips or {}
    Add(list, "Kinds", "Show one kind: purchases, sales, crafts, orders, deposits or gathering.",
        chips[1], chips[#chips])
    Add(list, "Character", "Show one character's entries.", view.character)
    Add(list, "History",
        "Everything Goldsmith recorded by itself. Right-click an entry to fix it, for example to mark a craft as a crafting order.",
        view.list)
end

TAB_PARTS.characters = function(list)
    local view = Screen("characters")
    if not view then return end
    local card = view.cards and view.cards[1]
    if Shown(card) then
        Add(list, "Exclude",
            "Leave out a character you don't play: their gold, stock and recipes stay out of everything.",
            card.exclude)
        Add(list, "A character",
            "Professions, concentration, craft cooldowns and a to-do list for each character, most gold first. Click a to-do to open its plan.",
            card)
    end
    Add(list, "Followed",
        "How the suggestions you crafted turned out: what they made compared to what Goldsmith expected. Hover it for each one.",
        view.followed)
end

TAB_PARTS.stats = function(list)
    local view = Screen("stats")
    if not view then return end
    Add(list, "Goldsmith title",
        "Earned by lifetime profit, from Apprentice up. Hover it for every title and what it takes.",
        view.tiles[1])
    Add(list, "Share in chat",
        "Writes your title and best numbers in the chat box. Press Enter to send it to friends or your guild.",
        view.share)
    Add(list, "Lifetime stats",
        "Everything Goldsmith has recorded, on every character and profession, for all time. The filters at the top don't change it. Hover any line for details.",
        view.left[1], view.right[1])
end

local function Collect()
    local list = {}
    HeaderParts(list)
    local fill = TAB_PARTS[addon:CurrentTab()]
    if fill then fill(list) end
    return list
end

-- Frames

-- A frame's edges in UIParent's coordinates
local function Edges(frame)
    local left, bottom, width, height = frame:GetRect()
    if not left then return nil end
    -- Text has no scale of its own: it's the window's
    local owner = frame.GetEffectiveScale and frame or addon.window
    local s = owner:GetEffectiveScale() / UIParent:GetEffectiveScale()
    return left * s, bottom * s, (left + width) * s, (bottom + height) * s
end

local function Place(frame, left, bottom, right, top)
    frame:ClearAllPoints()
    if right - left < 1 or top - bottom < 1 then frame:Hide() return end
    frame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", left, bottom)
    frame:SetSize(right - left, top - bottom)
    frame:Show()
end

local function Gold(alpha)
    local r, g, b = addon:Color("gold")
    return r, g, b, alpha
end

local Select -- below

local function StyleOutline(outline, strong)
    outline:SetBackdropBorderColor(Gold(strong and 1 or 0.55))
    outline:SetBackdropColor(Gold(strong and 0.16 or 0.04))
end

local function GetOutline(i)
    if outlines[i] then return outlines[i] end
    local texture = addon.theme.texture
    local outline = CreateFrame("Button", nil, UIParent, "BackdropTemplate")
    outline:SetFrameStrata("FULLSCREEN_DIALOG")
    outline:SetBackdrop({ bgFile = texture, edgeFile = texture, edgeSize = EDGE })
    outline:RegisterForClicks("AnyUp")
    outline:SetScript("OnClick", function(self) if self.entry then Select(self.entry) end end)
    outline:SetScript("OnEnter", function(self)
        StyleOutline(self, true)
        if self.entry then
            GameTooltip:SetOwner(self, "ANCHOR_CURSOR")
            GameTooltip:AddLine(self.entry.title, 1, 1, 1)
            GameTooltip:Show()
        end
    end)
    outline:SetScript("OnLeave", function(self)
        StyleOutline(self, selected and self.entry and selected.title == self.entry.title)
        GameTooltip:Hide()
    end)
    outlines[i] = outline
    return outline
end

local function CreateBox()
    local texture = addon.theme.texture
    box = CreateFrame("Frame", "GoldsmithHelpMode", UIParent, "BackdropTemplate")
    box:SetFrameStrata("FULLSCREEN_DIALOG")
    box:SetFrameLevel(BOX_LEVEL)
    box:SetWidth(BOX_WIDTH)
    box:SetClampedToScreen(true)
    box:EnableMouse(true)
    box:SetBackdrop({ bgFile = texture, edgeFile = texture, edgeSize = EDGE })
    box:SetBackdropColor(addon:Color("dialog"))
    box:SetBackdropBorderColor(Gold(1))
    box.title = UI.Text(box, "heading", "gold")
    box.title:SetPoint("TOPLEFT", 14, -12)
    box.title:SetPoint("RIGHT", box, "RIGHT", -36, 0)
    box.close = UI.IconButton(box, 22, "X", "Stop help (Esc)", function() addon:ExitHelpMode() end,
        { font = "body", hoverColor = "loss" })
    box.close:SetPoint("TOPRIGHT", -8, -8)
    box.text = UI.Text(box, "body", "text")
    box.text:SetPoint("TOPLEFT", box.title, "BOTTOMLEFT", 0, -10)
    box.text:SetWidth(BOX_WIDTH - 28)
    box.text:SetWordWrap(true)
    box.note = UI.Text(box, "label", "muted")
    box.note:SetPoint("TOPLEFT", box.text, "BOTTOMLEFT", 0, -10)
    box.note:SetWidth(BOX_WIDTH - 28)
    box.note:SetWordWrap(true)
end

local function FitBox()
    box:SetHeight(12 + box.title:GetStringHeight() + 10 + box.text:GetStringHeight()
        + (box.note:IsShown() and (10 + box.note:GetStringHeight()) or 0) + 14)
end

-- Beside the window when there's room, level with the part (or the top of
-- the window for the intro), so it never covers a part you may want to ask
-- about next (user, 2026-10-15: the intro sat on Show and Settings). Below
-- the window next, and only then by the part itself.
local SIDE_GAP = 12
local function PlaceBox(entry)
    box:ClearAllPoints()
    local wl, wb, wr, wt = Edges(addon.window)
    local top = wt
    if entry then
        local _, _, _, partTop = Edges(entry.first)
        top = partTop or wt
    end
    local width, height = box:GetWidth(), box:GetHeight()
    local screenWidth = UIParent:GetWidth()
    if wr and wr + SIDE_GAP + width <= screenWidth then
        box:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", wr + SIDE_GAP, top)
    elseif wl and wl - SIDE_GAP - width >= 0 then
        box:SetPoint("TOPRIGHT", UIParent, "BOTTOMLEFT", wl - SIDE_GAP, top)
    elseif wb and wb - SIDE_GAP - height >= 0 then
        box:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", wl, wb - SIDE_GAP)
    elseif not entry then
        box:SetPoint("TOPRIGHT", Part("help"), "BOTTOMRIGHT", 0, -10)
    else
        local _, y = entry.first:GetCenter()
        if y and y > UIParent:GetHeight() / 2 then
            box:SetPoint("TOPLEFT", entry.first, "BOTTOMLEFT", 0, -10)
        else
            box:SetPoint("BOTTOMLEFT", entry.first, "TOPLEFT", 0, 10)
        end
    end
end

local function ShowBox(entry)
    if not box then CreateBox() end
    box.title:SetText(entry and entry.title or "What's this?")
    box.text:SetText(entry and entry.text or INTRO)
    box.note:SetText("Click another outlined part, or ? to stop.")
    box.note:SetShown(entry ~= nil)
    -- Sized first: where it goes depends on its height
    FitBox()
    PlaceBox(entry)
    box:Show()
    C_Timer.After(0, function() if box:IsShown() then FitBox() PlaceBox(selected) end end)
end

Select = function(entry)
    selected = entry
    for _, outline in ipairs(outlines) do
        StyleOutline(outline, entry and outline.entry and outline.entry.title == entry.title
            and outline.entry.first == entry.first)
    end
    ShowBox(entry)
end

-- A stand-in above the dark layer for a header button
local function Proxy(symbol, tooltip, onClick)
    local proxy = UI.IconButton(UIParent, 34, symbol, tooltip, onClick, { font = "close" })
    proxy:SetFrameStrata("FULLSCREEN_DIALOG")
    proxy:SetFrameLevel(BOX_LEVEL - 10)
    proxy:Hide()
    return proxy
end

local function CreateDims()
    for i = 1, 2 do
        local f = CreateFrame("Frame", nil, UIParent)
        f:SetFrameStrata("FULLSCREEN_DIALOG")
        f:SetFrameLevel(DIM_LEVEL)
        f:EnableMouse(true)
        f:EnableMouseWheel(true)
        f:SetScript("OnMouseWheel", function() end)
        -- A click on nothing in particular puts the intro back
        f:SetScript("OnMouseDown", function() if selected then Select(nil) end end)
        local t = f:CreateTexture(nil, "BACKGROUND")
        t:SetAllPoints()
        t:SetColorTexture(0, 0, 0, DIM_ALPHA)
        dims[i] = f
    end
    helpProxy = Proxy("?", "Stop help (Esc)", function() addon:ExitHelpMode() end)
    helpProxy.label:SetTextColor(Gold(1))
    helpProxy:HookScript("OnLeave", function(self) self.label:SetTextColor(Gold(1)) end)
    closeProxy = Proxy("X", "Close", function() if addon.window then addon.window:Hide() end end)
end

local POPUPS = { "GoldsmithSettings", "GoldsmithHelp", "GoldsmithSupport", "GoldsmithReport" }
local function AnyPopup()
    for _, name in ipairs(POPUPS) do
        if _G[name] and _G[name]:IsShown() then return true end
    end
    return false
end

local function SameEntry(a, b)
    return a and b and a.title == b.title and a.first == b.first
end

-- Lays everything out again: the tab, its lists and the window can change
-- while help is on
local function Update()
    if not active then return end
    local window = addon.window
    if not (window and window:IsShown()) or AnyPopup() or (addon.TourRunning and addon:TourRunning()) then
        addon:ExitHelpMode()
        return
    end
    local wl, wb, wr, wt = Edges(window)
    local tabArea = Part("tabArea")
    local _, tb, _, tt = Edges(tabArea)
    if not (wl and tb) then return end
    Place(dims[1], wl, tt, wr, wt) -- the header
    Place(dims[2], wl, wb, wr, tb) -- below the tabs
    local help, close = Part("help"), Part("close")
    helpProxy:ClearAllPoints()
    helpProxy:SetAllPoints(help)
    helpProxy:Show()
    closeProxy:ClearAllPoints()
    closeProxy:SetAllPoints(close)
    closeProxy:Show()

    entries = Collect()
    -- Smaller parts above bigger ones, so a part inside another (Followed
    -- in Do this next) can still be clicked
    local function Area(e)
        local l, b, r, t = Edges(e.first)
        if e.last then
            local l2, b2, r2, t2 = Edges(e.last)
            if l2 then l, b, r, t = math.min(l, l2), math.min(b, b2), math.max(r, r2), math.max(t, t2) end
        end
        return l and (r - l) * (t - b) or 0
    end
    for _, e in ipairs(entries) do e.area = Area(e) end
    table.sort(entries, function(a, b) return a.area > b.area end)
    local stillThere = false
    for i, e in ipairs(entries) do
        local outline = GetOutline(i)
        outline.entry = e
        outline:SetFrameLevel(OUTLINE_LEVEL + i * 2)
        outline:ClearAllPoints()
        outline:SetPoint("TOPLEFT", e.first, "TOPLEFT", -3, 3)
        outline:SetPoint("BOTTOMRIGHT", e.last or e.first, "BOTTOMRIGHT", 3, -3)
        local strong = SameEntry(e, selected) or outline:IsMouseOver()
        StyleOutline(outline, strong)
        outline:Show()
        if SameEntry(e, selected) then
            stillThere = true
            selected = e
        end
    end
    for i = #entries + 1, #outlines do
        outlines[i].entry = nil
        outlines[i]:Hide()
    end
    -- Its part is gone (another tab): back to the intro
    if selected and not stillThere then Select(nil) end
end

function addon:EnterHelpMode()
    if active or not addon.window or (addon.TourRunning and addon:TourRunning()) then return end
    if not addon.window:IsShown() then addon.window:Show() end
    for _, name in ipairs(POPUPS) do
        if _G[name] then _G[name]:Hide() end
    end
    if not dims[1] then CreateDims() end
    active = true
    selected = nil
    Update()
    Select(nil)
    ticker = C_Timer.NewTicker(0.2, Update)
end

function addon:ExitHelpMode()
    if not active then return end
    active = false
    selected = nil
    if ticker then ticker:Cancel() end
    ticker = nil
    for _, f in ipairs(dims) do f:Hide() end
    for _, outline in ipairs(outlines) do
        outline.entry = nil
        outline:Hide()
    end
    if helpProxy then helpProxy:Hide() end
    if closeProxy then closeProxy:Hide() end
    if box then box:Hide() end
    GameTooltip:Hide()
end

function addon:ToggleHelpMode()
    if active then addon:ExitHelpMode() else addon:EnterHelpMode() end
end

_G.Goldsmith = addon
