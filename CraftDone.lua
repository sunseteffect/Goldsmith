local addon = _G.Goldsmith or {}
local UI = addon.UI

-- "Craft complete"
--
-- When the planner's (or queue's) Craft button starts the plan's own item,
-- the crafts are followed as the game reports them: items made, extras
-- from multicraft, materials resourcefulness gave back, and what the
-- materials cost (the craft lots, Pricing.lua). When the last one is in, a
-- notice pops up near the top of the screen and fades away by itself, so
-- a finished plan is clearly finished (the Craft button going back to the
-- start had left the user wondering whether it had crafted at all). If the
-- crafts stop early, it says how many were made.

local AH_CUT = 0.05
-- How long the notice stays before fading, and how long the fade takes
local HOLD_SECONDS = 5
local FADE_SECONDS = 1.5
-- No new craft for this long, and not casting: the batch stopped early
local STOP_WAIT = 6
-- A batch nothing came of is forgotten after this
local START_WAIT = 30
local WIDTH = 330
-- Materials named in the "saved" line before "and N more"
local SAVED_NAMED = 3

local batch -- the crafts being followed, see StartCraftBatch
local stopTimer
local toast

local Money = function(c) return addon:FormatMoney(c) end

-- The notice

local function CreateToast()
    local f = CreateFrame("Button", "GoldsmithCraftDone", UIParent)
    f:SetSize(WIDTH, 100)
    f:SetFrameStrata("HIGH")
    f:SetClampedToScreen(true)
    UI.Style(f, "dialog", "borderGold")
    f:Hide()

    -- A pulsing gold border, as the tour uses, so it's noticed (its own
    -- layer, so the pulse and the fade-out don't fight over the alpha)
    f.glow = CreateFrame("Frame", nil, f, "BackdropTemplate")
    f.glow:SetPoint("TOPLEFT", -1, 1)
    f.glow:SetPoint("BOTTOMRIGHT", 1, -1)
    f.glow:SetBackdrop({ edgeFile = addon.theme.texture, edgeSize = 2 })
    f.glow:SetBackdropBorderColor(addon:Color("gold"))
    f.glow:EnableMouse(false)
    local pulse = f.glow:CreateAnimationGroup()
    pulse:SetLooping("BOUNCE")
    local fade = pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(1)
    fade:SetToAlpha(0.2)
    fade:SetDuration(0.6)
    f.pulse = pulse

    f.icon = f:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(40, 40)
    f.icon:SetPoint("TOPLEFT", 12, -12)

    f.title = UI.Text(f, "heading", "gold")
    f.title:SetPoint("TOPLEFT", f.icon, "TOPRIGHT", 10, 0)
    f.title:SetPoint("RIGHT", -12, 0)

    f.item = UI.Text(f, "body", "text")
    f.item:SetPoint("TOPLEFT", f.title, "BOTTOMLEFT", 0, -4)
    f.item:SetPoint("RIGHT", -12, 0)

    f.details = UI.Text(f, "small", "text")
    f.details:SetPoint("TOPLEFT", f.item, "BOTTOMLEFT", 0, -6)
    f.details:SetPoint("RIGHT", -12, 0)
    f.details:SetWordWrap(true)
    f.details:SetSpacing(2)

    f.profit = UI.Text(f, "body", "text")
    f.profit:SetPoint("TOPLEFT", f.details, "BOTTOMLEFT", 0, -6)
    f.profit:SetPoint("RIGHT", -12, 0)

    f.hint = UI.Text(f, "label", "dim", "RIGHT")
    f.hint:SetPoint("BOTTOMRIGHT", -8, 6)
    f.hint:SetText("click to close")

    -- Stays while the mouse is over it, then fades
    f:SetScript("OnUpdate", function(self, elapsed)
        if self:IsMouseOver() then
            self.elapsed = 0
            self:SetAlpha(1)
            return
        end
        self.elapsed = (self.elapsed or 0) + elapsed
        if self.elapsed > HOLD_SECONDS then
            local alpha = 1 - (self.elapsed - HOLD_SECONDS) / FADE_SECONDS
            if alpha <= 0 then
                self.pulse:Stop()
                self:Hide()
            else
                self:SetAlpha(alpha)
            end
        end
    end)
    f:SetScript("OnClick", function(self)
        self.pulse:Stop()
        self:Hide()
    end)
    return f
end

-- To the right of the game's Crafting Results window when it's showing,
-- tops lined up (it sits near the top, where the notice used to cover
-- it), else in the upper middle. Clamped, so it stays on screen.
-- The craft result arrives just before the game shows that window, so the
-- notice is placed again a moment later, and whenever the window appears
-- while it's up.
local logHooked = false
local function Place(f)
    f:ClearAllPoints()
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    local log = page and page.CraftingOutputLog
    if log and not logHooked then
        logHooked = true
        log:HookScript("OnShow", function() if f:IsShown() then Place(f) end end)
    end
    if log and log:IsShown() then
        f:SetPoint("TOPLEFT", log, "TOPRIGHT", 12, 0)
    else
        f:SetPoint("TOP", UIParent, "TOP", 0, -260)
    end
end

local function Colored(text, color)
    return addon:Colorize(text, color)
end

-- The batch's lines: { title, item, details, profit (text or nil) }
local function Describe(b)
    local finished = b.done >= b.crafts
    local title
    if not finished then
        title = string.format("Crafting stopped: %d of %d done", b.done, b.crafts)
    elseif b.planCrafts and b.planCrafts > b.crafts then
        title = "Batch complete"
    else
        title = "Craft complete"
    end

    local tier, tierCount = addon:GetItemTier(b.itemID)
    local item = (tier and (addon:TierIconText(tier, tierCount) .. " ") or "") .. b.name
        .. Colored("  x" .. b.made, "gold")

    local details = {}
    table.insert(details, string.format("%d craft%s", b.done, b.done == 1 and "" or "s")
        .. (b.concentrate and " with concentration" or ""))
    if b.extra > 0 then
        table.insert(details, string.format("Multicraft: %s extra (%d proc%s)",
            Colored("+" .. b.extra, "profit"), b.procs, b.procs == 1 and "" or "s"))
    end
    local saved = {}
    for id, qty in pairs(b.saved) do
        table.insert(saved, { name = C_Item.GetItemNameByID(id) or ("item " .. id), qty = qty,
            value = (addon:GetMarketPrice(id) or 0) * qty })
    end
    if #saved > 0 then
        table.sort(saved, function(a, c) return a.value > c.value end)
        local names = {}
        for i, s in ipairs(saved) do
            if i > SAVED_NAMED then
                table.insert(names, string.format("and %d more", #saved - SAVED_NAMED))
                break
            end
            table.insert(names, string.format("%d %s", s.qty, s.name))
        end
        local value = 0
        for _, s in ipairs(saved) do value = value + s.value end
        table.insert(details, "Resourcefulness saved: " .. table.concat(names, ", ")
            .. (value > 0 and Colored(" (" .. Money(value) .. ")", "profit") or ""))
    end
    if finished and b.planCrafts and b.planCrafts > b.crafts then
        table.insert(details, Colored(string.format("The plan has %d more craft%s to go.",
            b.planCrafts - b.crafts, b.planCrafts - b.crafts == 1 and "" or "s"), "warning"))
    end

    local profit
    local price = addon:GetMarketPrice(b.itemID)
    if price and b.made > 0 then
        local amount = b.made * price * (1 - AH_CUT) - b.cost
        profit = string.format("%s %s", b.partial and "Estimated profit (at most):" or "Estimated profit:",
            Colored(addon:FormatSignedMoney(amount), addon:MoneyColor(amount)))
    end
    return title, item, table.concat(details, "\n"), profit, price
end

local function ShowToast(b)
    toast = toast or CreateToast()
    local title, item, details, profit = Describe(b)
    toast.icon:SetTexture(C_Item.GetItemIconByID(b.itemID) or 134400)
    toast.title:SetText(title)
    toast.title:SetTextColor(addon:Color(b.done >= b.crafts and "gold" or "warning"))
    toast.item:SetText(item)
    toast.details:SetText(details)
    toast.profit:SetText(profit or "")
    toast.profit:SetShown(profit ~= nil)

    local height = 12 + toast.title:GetStringHeight() + 4 + toast.item:GetStringHeight()
        + 6 + toast.details:GetStringHeight() + (profit and (6 + toast.profit:GetStringHeight()) or 0) + 24
    toast:SetHeight(math.max(height, 64))
    toast.elapsed = 0
    toast:SetAlpha(1)
    Place(toast)
    toast:Show()
    toast.pulse:Play()
    C_Timer.After(0.2, function() if toast:IsShown() then Place(toast) end end)
end

-- Following a batch

local function Finish()
    if stopTimer then stopTimer:Cancel() end
    stopTimer = nil
    local b = batch
    batch = nil
    if not b or b.done == 0 then return end
    ShowToast(b)
    -- The planner takes what was made off its Make box (the queue counts
    -- its own)
    if b.fromPlan and addon.PlanCraftsDone then addon.PlanCraftsDone(b.recipeID, b.made) end
    local _, _, _, profit = Describe(b)
    addon:Notify("info", "%s: %d %s%s.", b.done >= b.crafts and "Craft complete" or "Crafting stopped",
        b.made, b.name, profit and (", " .. profit:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):lower()) or "")
end

-- Still crafting (a cast underway or the game repeating the recipe)?
local function StillCrafting()
    local ok, casting = pcall(UnitCastingInfo, "player")
    if ok and casting ~= nil and not (issecretvalue and issecretvalue(casting)) then return true end
    if C_TradeSkillUI.IsRecipeRepeating then
        local ok, repeating = pcall(C_TradeSkillUI.IsRecipeRepeating)
        if ok and repeating == true then return true end
    end
    return false
end

-- Checks back after a pause in crafts: still going, or stopped early
local function WaitForStop(seconds)
    if stopTimer then stopTimer:Cancel() end
    stopTimer = C_Timer.NewTimer(seconds, function()
        stopTimer = nil
        if not batch then return end
        if StillCrafting() then
            WaitForStop(STOP_WAIT)
        else
            Finish()
        end
    end)
end

-- The Craft button is starting the plan's own crafts (Crafts.lua's
-- PerformCraftState). state: crafts, planCrafts, concentrate.
function addon:StartCraftBatch(recipe, state)
    -- One still open stopped early (a new batch means it isn't going on)
    if batch then Finish() end
    batch = {
        recipeID = recipe.recipeID, name = recipe.outputName, itemID = nil,
        crafts = state.crafts or 1, planCrafts = state.planCrafts, concentrate = state.concentrate,
        fromPlan = state.fromPlan,
        done = 0, made = 0, extra = 0, procs = 0, saved = {}, cost = 0, partial = false,
    }
    WaitForStop(START_WAIT)
end

-- One craft finished (Pricing.lua's craft result, after its lot is saved)
function addon:CraftBatchResult(recipeID, recipe, resultData, lot)
    local b = batch
    if not (b and recipeID == b.recipeID and resultData) then return end
    b.itemID = b.itemID or resultData.itemID
    b.done = b.done + 1
    local made = lot and lot.qty or resultData.quantity or 0
    b.made = b.made + made
    local extra = resultData.multicraft
    if type(extra) == "number" and extra > 0 then
        b.extra = b.extra + extra
        b.procs = b.procs + 1
    end
    for _, ret in ipairs(resultData.resourcesReturned or {}) do
        local id = ret.itemID or (type(ret.reagent) == "table" and ret.reagent.itemID)
        if id and ret.quantity then b.saved[id] = (b.saved[id] or 0) + ret.quantity end
    end
    if lot then
        b.cost = b.cost + (lot.unitCost or 0) * (lot.qty or 0)
        b.partial = b.partial or lot.partial
    else
        b.partial = true
    end
    if b.done >= b.crafts then
        Finish()
    else
        WaitForStop(STOP_WAIT)
    end
end

_G.Goldsmith = addon
