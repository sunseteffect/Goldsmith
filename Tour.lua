local addon = _G.Goldsmith or {}
local UI = addon.UI

-- The tour
--
-- A short walk through the window for new players: a box with an arrow
-- points at one part at a time and says what it's for. When the next stop
-- is on another tab, the box asks you to click that tab (it lights up) and
-- the tour carries on once you do, so you learn where things are by using
-- them. Back, Next and X to end it at any time.
--
-- Offered once, the first time Goldsmith opens (GoldsmithDB.tourOffered);
-- started again from Getting started, Help, or /gsm tour. Closing the
-- window ends it.
--
-- Each step: tab (the tab it's on), title, text, and target = function()
-- returning the frame to point at, or two frames for an area spanning
-- both. Parts come from Window.lua (addon.tourParts, addon:GetTabScreen).

local function Screen(key)
    local screen = addon:GetTabScreen(key)
    return screen and screen.view, screen and screen.frame
end

local function Part(name)
    return addon.tourParts and addon.tourParts[name]
end

local STEPS = {
    { tab = "overview", title = "Filters",
      text = "Pick one profession or all of them, the dates for profits and charts, and which expansions' items to show. They apply on every tab.",
      target = function() return Part("filters")[1], Part("filters")[2] end },
    { tab = "overview", title = "Prices",
      text = "Where prices come from right now: Goldsmith Data's daily prices for your region, an Auctionator scan, or TSM. It turns orange when prices are old.",
      target = function() return Part("price") end },
    { tab = "overview", title = "How you're doing",
      text = "Profit on what you've sold, your sales, the gold tied up in stock, and concentration across every character. Hover any number to see how it's worked out.",
      target = function()
          local view = Screen("overview")
          return view and view.tiles[1], view and view.tiles[#view.tiles]
      end },
    { tab = "overview", title = "Do this next",
      text = "The best things to do right now (Getting started while you set up): what to craft, with concentration and without. Only solid bets show here, things that sell. Click one to open its plan.",
      target = function()
          local view = Screen("overview")
          return view and view.actionsTitle:GetParent()
      end },
    { tab = "overview", title = "Charts",
      text = "Profit by day, total gold, and gold per hour of goldmaking. The arrows switch between them.",
      target = function()
          local view = Screen("overview")
          return view and view.chartTitle:GetParent()
      end },
    { tab = "overview", title = "By profession",
      text = "Each profession's profit and concentration. Click one to filter everything to it.",
      target = function()
          local view = Screen("overview")
          return view and view.professionsNote:GetParent()
      end },
    { tab = "crafts", title = "Crafts",
      text = "Everything you can craft: cost from your own crafting stats, AH price, profit, and how well it sells. Click a craft for a shopping plan: what to buy, craft or mill, in what order.",
      target = function()
          local view = Screen("crafts")
          return view and view.list
      end },
    { tab = "crafts", title = "Show",
      text = "Recommended (solid bets), Profitable, All crafts, or Not learned yet: recipes worth going to learn. It can hide gear too.",
      target = function()
          local view = Screen("crafts")
          return view and view.show
      end },
    { tab = "crafts", title = "Concentration",
      text = "Turn it on to see the better quality concentration reaches, and how much gold each point earns (g/conc).",
      target = function()
          local view = Screen("crafts")
          return view and view.concSwitch
      end },
    { tab = "queue", title = "Queue",
      text = "Crafts lined up to make, added from any plan or by right-clicking a craft. Each character has their own queue; once another character has crafts queued, a menu appears at the top right to see theirs. One shopping list for all of it, and Craft next does the next step: one click per craft.",
      target = function() return select(2, Screen("queue")) end },
    { tab = "items", title = "Items",
      text = "Leaderboards: most profit, best margin, fastest sellers, and things held too long. Search any item, or tick In my bags or Cheap materials. Click an item for its page: break-even price, costs, price chart.",
      target = function() return select(2, Screen("items")) end },
    { tab = "history", title = "History",
      text = "Every purchase, sale, craft and AH deposit, recorded by itself. Right-click an entry to fix it, for example to mark a craft as a crafting order.",
      target = function() return select(2, Screen("history")) end },
    { tab = "characters", title = "Characters",
      text = "A card per character: professions, concentration, craft cooldowns and a to-do list. Click a to-do to open its plan. Exclude a bank alt so it doesn't count.",
      target = function() return select(2, Screen("characters")) end },
    { title = "Settings",
      text = "Costs, prices, item tooltips, chat messages and characters, plus Help. Hold Ctrl over any hover to see what its numbers mean.\n\nThat's the tour. /gsm tour starts it again.",
      target = function() return Part("settings") end },
}

local TAB_NAMES = {
    overview = "Overview", crafts = "Crafts", queue = "Queue",
    items = "Items", history = "History", characters = "Characters",
}

local BOX_WIDTH = 340
local box, highlight
local current -- step number, or nil when no tour is running
local waiting -- the tab the current step waits for, if any

local function CreateFrames()
    highlight = CreateFrame("Frame", nil, UIParent, "BackdropTemplate")
    highlight:SetFrameStrata("FULLSCREEN_DIALOG")
    highlight:SetBackdrop({ edgeFile = addon.theme.texture, edgeSize = 2 })
    highlight:SetBackdropBorderColor(addon:Color("gold"))
    highlight:EnableMouse(false)
    local pulse = highlight:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.35)
    fade:SetDuration(0.7)
    highlight.pulse = pulse

    box = CreateFrame("Frame", "GoldsmithTour", UIParent, "BackdropTemplate")
    box:SetFrameStrata("FULLSCREEN_DIALOG")
    box:SetFrameLevel(highlight:GetFrameLevel() + 5)
    box:SetWidth(BOX_WIDTH)
    box:SetClampedToScreen(true)
    box:EnableMouse(true)
    UI.Style(box, "dialog", "gold")

    box.title = UI.Text(box, "heading")
    box.title:SetPoint("TOPLEFT", 14, -12)
    box.count = UI.Text(box, "label", "dim", "RIGHT")
    box.count:SetPoint("TOPRIGHT", -36, -14)
    box.close = UI.IconButton(box, 22, "X", "End the tour (/gsm tour starts it again)", function() addon:EndTour() end,
        { font = "body", hoverColor = "loss" })
    box.close:SetPoint("TOPRIGHT", -8, -8)

    box.text = UI.Text(box, "body", "text")
    box.text:SetPoint("TOPLEFT", box.title, "BOTTOMLEFT", 0, -10)
    -- A fixed width, so the wrapped height is known at once (FitBox)
    box.text:SetWidth(BOX_WIDTH - 28)
    box.text:SetWordWrap(true)

    box.ask = UI.Text(box, "body", "gold")
    box.ask:SetPoint("TOPLEFT", box.text, "BOTTOMLEFT", 0, -10)
    box.ask:SetWidth(BOX_WIDTH - 28)
    box.ask:SetWordWrap(true)

    box.back = UI.Button(box, "Back", 80, 24, function() addon:TourStep(current - 1) end)
    box.back:SetPoint("BOTTOMLEFT", 14, 12)
    box.next = UI.Button(box, "Next", 80, 24, function()
        if current == #STEPS then addon:EndTour() else addon:TourStep(current + 1) end
    end)
    box.next:SetPoint("BOTTOMRIGHT", -14, 12)
end

-- Height to fit the wrapped text and the buttons
local function FitBox()
    local height = 12 + box.title:GetStringHeight() + 10 + box.text:GetStringHeight()
    if box.ask:IsShown() then height = height + 10 + box.ask:GetStringHeight() end
    box:SetHeight(height + 12 + 24 + 12)
end

-- Below the target when it's in the top half of the screen, else above
local function PlaceBox(first)
    box:ClearAllPoints()
    local _, top = first:GetCenter()
    if top and top > UIParent:GetHeight() / 2 then
        box:SetPoint("TOPLEFT", first, "BOTTOMLEFT", 0, -12)
    else
        box:SetPoint("BOTTOMLEFT", first, "TOPLEFT", 0, 12)
    end
end

local function Show(first, last)
    highlight:ClearAllPoints()
    highlight:SetPoint("TOPLEFT", first, "TOPLEFT", -4, 4)
    highlight:SetPoint("BOTTOMRIGHT", last or first, "BOTTOMRIGHT", 4, -4)
    highlight:Show()
    highlight.pulse:Play()
    FitBox()
    PlaceBox(first)
    box:Show()
    -- Again once drawn, in case the font measured differently before
    C_Timer.After(0, function() if box:IsShown() then FitBox() end end)
end

-- Shows step n. On another tab: point at that tab and wait for the click
-- (addon.OnTourTab), unless going back, which switches tabs itself.
function addon:TourStep(n)
    if not addon.window then return end
    if not box then CreateFrames() end
    n = math.max(1, math.min(n, #STEPS))
    local goingBackward = current and n < current
    current = n
    local step = STEPS[n]
    if not addon.window:IsShown() then addon.window:Show() end

    box.count:SetText(string.format("%d / %d", n, #STEPS))
    box.back:SetShown(n > 1)
    box.next:SetLabel(n == #STEPS and "Done" or "Next")

    local onTab = not step.tab or addon:CurrentTab() == step.tab
    waiting = not onTab and step.tab or nil
    if waiting and goingBackward then
        addon:ShowTab(step.tab) -- calls OnTourTab, which shows the step
        return
    end
    if waiting then
        box.title:SetText(step.title)
        box.text:SetText(step.text)
        box.ask:SetText("Click the " .. TAB_NAMES[step.tab] .. " tab to carry on.")
        box.ask:Show()
        box.next:Hide()
        local tabButton = Part("tabs")[step.tab]
        Show(tabButton)
        return
    end

    box.title:SetText(step.title)
    box.text:SetText(step.text)
    box.ask:Hide()
    box.next:Show()
    -- The tab's screen may only just have been made; point once it's laid out
    local first, last = step.target()
    if first then
        Show(first, last)
    else
        Show(addon.window)
    end
end

-- The window's tab changed (Window.lua Refresh): a step waiting for that
-- tab carries on
function addon.OnTourTab(key)
    if not current then return end
    if waiting and waiting == key then
        waiting = nil
        local step = current
        C_Timer.After(0, function()
            if current == step then addon:TourStep(current) end
        end)
    end
end

function addon:StartTour()
    GoldsmithDB.tourOffered = true
    current = nil
    if addon.window and not addon.window:IsShown() then addon.window:Show() end
    addon:ShowTab("overview")
    C_Timer.After(0, function() addon:TourStep(1) end)
end

function addon:EndTour()
    current, waiting = nil, nil
    if box then box:Hide() end
    if highlight then
        highlight.pulse:Stop()
        highlight:Hide()
    end
end

function addon:TourRunning()
    return current ~= nil
end

StaticPopupDialogs["GOLDSMITH_TOUR"] = {
    text = "Welcome to Goldsmith!\n\nTake a 2-minute tour of the window?",
    button1 = "Take the tour",
    button2 = "Not now",
    OnAccept = function() addon:StartTour() end,
    OnCancel = function()
        print("|cFF00FF00[Goldsmith]|r No problem. Start the tour any time with /gsm tour, or from Getting started on the Overview.")
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- The first time the window opens: ask once
function addon:OfferTour()
    if GoldsmithDB.tourOffered or current then return end
    GoldsmithDB.tourOffered = true
    StaticPopup_Show("GOLDSMITH_TOUR")
end

_G.Goldsmith = addon
