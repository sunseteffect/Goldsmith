local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Settings
--
-- Few settings, strong defaults. Saved for the account in
-- GoldsmithDB.settings; anything not set uses its default:
--   costMode    - "estimated" (from your stats) or "worst" (no procs)
--   priceSource - "auto" (whichever is newer), "auctionator" or "tsm"
--   minROI      - ROI (%) a craft needs to count as worth crafting
--   showMinimap - the minimap button (Minimap.lua)
-- Concentration in Crafts isn't here: the Crafts tab's switch remembers it.

local DEFAULTS = {
    costMode = "estimated",
    priceSource = "auto",
    minROI = 15,
    showMinimap = true,
}

function addon:Setting(key)
    local settings = GoldsmithDB and GoldsmithDB.settings
    local value = settings and settings[key]
    if value == nil then return DEFAULTS[key] end
    return value
end

function addon:SetSetting(key, value)
    GoldsmithDB.settings = GoldsmithDB.settings or {}
    GoldsmithDB.settings[key] = value
    if addon.Refresh then addon.Refresh() end
end

-- Panel

local WIDTH = 400
local ROW_HEIGHT = 74

local COST_MODES = {
    { value = "estimated", label = "Estimated (recommended)" },
    { value = "worst", label = "Worst case" },
}
local PRICE_SOURCES = {
    { value = "auto", label = "Automatic (recommended)" },
    { value = "auctionator", label = "Prefer Auctionator" },
    { value = "tsm", label = "Prefer TSM" },
}
local ROI_CHOICES = { 0, 5, 10, 15, 20, 30, 50 }

local function ROILabel(value)
    if value == 0 then return "Any profit" end
    return string.format("%d%%%s", value, value == DEFAULTS.minROI and " (recommended)" or "")
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
    showMinimap = {
        "Minimap button",
        "A gold coin on the edge of the minimap: click to show or hide Goldsmith, right-click for these settings, drag to move it.",
        "Other ways to open Goldsmith: /gsm, a key (Options > Keybindings > AddOns > Goldsmith), or the addons button by the minimap.",
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
local function Row(panel, index, key, title, description)
    local row = CreateFrame("Frame", nil, panel)
    row:SetPoint("TOPLEFT", 16, -52 - (index - 1) * ROW_HEIGHT)
    row:SetPoint("RIGHT", panel, "RIGHT", -16, 0)
    row:SetHeight(ROW_HEIGHT - 8)
    row:EnableMouse(true)
    row.title = UI.Text(row, "body", "text")
    row.title:SetPoint("TOPLEFT", 0, -4)
    row.title:SetText(title)
    row.description = UI.Text(row, "small", "muted")
    row.description:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -5)
    row.description:SetWidth(WIDTH - 32 - 180)
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

function addon:CreateSettingsPanel(parent)
    local panel = CreateFrame("Frame", "GoldsmithSettings", parent, "BackdropTemplate")
    panel:SetSize(WIDTH, 52 + 4 * ROW_HEIGHT + 20)
    UI.Style(panel, "window", "borderGold")
    panel:SetFrameStrata("DIALOG")
    panel:EnableMouse(true)
    panel:Hide()

    local title = UI.Text(panel, "heading")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("Settings")
    local close = UI.IconButton(panel, 26, "X", "Close", function() panel:Hide() end, { hoverColor = "loss" })
    close:SetPoint("TOPRIGHT", -8, -8)

    local rows = {}

    rows.costMode = Row(panel, 1, "costMode", "Show cost as", "Estimated uses your stats; worst case assumes no procs.")
    rows.costMode.control = Dropdown(rows.costMode, "costMode", function(root)
        for _, c in ipairs(COST_MODES) do
            root:CreateRadio(c.label, function() return addon:Setting("costMode") == c.value end,
                function() addon:SetSetting("costMode", c.value); panel:Update() end)
        end
    end)

    rows.priceSource = Row(panel, 2, "priceSource", "Price source", "Where AH prices come from when both Auctionator and TSM have one.")
    rows.priceSource.control = Dropdown(rows.priceSource, "priceSource", function(root)
        for _, c in ipairs(PRICE_SOURCES) do
            root:CreateRadio(c.label, function() return addon:Setting("priceSource") == c.value end,
                function() addon:SetSetting("priceSource", c.value); panel:Update() end)
        end
    end)

    rows.minROI = Row(panel, 3, "minROI", "Worth crafting at", "The ROI a craft needs for Profitable only and Best crafts.")
    rows.minROI.control = Dropdown(rows.minROI, "minROI", function(root)
        for _, value in ipairs(ROI_CHOICES) do
            root:CreateRadio(ROILabel(value), function() return addon:Setting("minROI") == value end,
                function() addon:SetSetting("minROI", value); panel:Update() end)
        end
    end)

    rows.showMinimap = Row(panel, 4, "showMinimap", "Minimap button", "A coin by the minimap that opens Goldsmith.")
    rows.showMinimap.control = UI.Checkbox(rows.showMinimap, "Show", function(checked)
        addon:SetSetting("showMinimap", checked)
        addon:UpdateMinimapButton()
        panel:Update()
    end)
    rows.showMinimap.control:SetPoint("TOPRIGHT", 0, 0)
    UI.SetTooltip(rows.showMinimap.control, function(tooltip) AddHelp(tooltip, "showMinimap") end, "ANCHOR_LEFT")

    local footer = UI.Text(panel, "label", "dim")
    footer:SetPoint("BOTTOMLEFT", 16, 12)
    footer:SetText("Saved for all your characters. Hover a setting for details.")

    function panel:Update()
        rows.costMode.control:SetLabel(LabelFor(COST_MODES, addon:Setting("costMode")))
        rows.priceSource.control:SetLabel(LabelFor(PRICE_SOURCES, addon:Setting("priceSource")))
        rows.minROI.control:SetLabel(ROILabel(addon:Setting("minROI")))
        rows.showMinimap.control:SetChecked(addon:Setting("showMinimap"))
    end
    panel:SetScript("OnShow", function() panel:Update() end)
    return panel
end

_G.Goldsmith = addon
