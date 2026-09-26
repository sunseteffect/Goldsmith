local addon = _G.Goldsmith or {}

-- Widgets
--
-- The parts every v2 screen is built from, all styled from the theme
-- (Theme.lua). Screens use these instead of Blizzard templates so the look
-- stays consistent and can be swapped in one place.

local UI = {}
addon.UI = UI

-- Flat background and 1px border in theme colors
function UI.Style(frame, bg, border)
    if not frame.SetBackdrop then
        Mixin(frame, BackdropTemplateMixin)
        frame:HookScript("OnSizeChanged", frame.OnBackdropSizeChanged)
    end
    local texture = addon.theme.texture
    frame:SetBackdrop({ bgFile = texture, edgeFile = border and texture or nil, edgeSize = 1 })
    frame:SetBackdropColor(addon:Color(bg or "panel"))
    if border then
        frame:SetBackdropBorderColor(addon:Color(border))
    end
end

-- A box: "panel" (default), "header", "highlight" (gold border, for the
-- thing to look at first) or "raised"
local PANEL_STYLES = {
    panel = { "panel", "border" },
    header = { "header", nil },
    highlight = { "highlight", "borderGold" },
    raised = { "panelRaised", "borderStrong" },
}

function UI.Panel(parent, style)
    local frame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    local s = PANEL_STYLES[style or "panel"]
    UI.Style(frame, s[1], s[2])
    return frame
end

-- A 1px line in a theme color
function UI.Line(parent, colorName)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(addon:Color(colorName or "border"))
    return line
end

-- Text in a theme font; colorName overrides the font's color
function UI.Text(parent, fontName, colorName, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(addon:Font(fontName or "body"))
    if colorName then fs:SetTextColor(addon:Color(colorName)) end
    fs:SetJustifyH(justify or "LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- Hover tooltip. fill(tooltip, frame) adds the lines; nothing shows if it
-- adds none.
function UI.SetTooltip(frame, fill, anchor)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
        fill(GameTooltip, self)
        if GameTooltip:NumLines() > 0 then
            GameTooltip:Show()
        else
            GameTooltip:Hide()
        end
    end)
    frame:SetScript("OnLeave", GameTooltip_Hide)
end

-- A flat button. onClick(self, mouseButton).
function UI.Button(parent, text, width, height, onClick)
    local button = CreateFrame("Button", nil, parent, "BackdropTemplate")
    button:SetSize(width or 100, height or 24)
    UI.Style(button, "panelRaised", "borderStrong")
    button.label = UI.Text(button, "small", "text", "CENTER")
    button.label:SetPoint("LEFT", 8, 0)
    button.label:SetPoint("RIGHT", -8, 0)
    button.label:SetText(text or "")
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnClick", onClick)
    button:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(addon:Color("gold")) end)
    button:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderStrong")) end)

    function button:SetLabel(value) self.label:SetText(value) end
    return button
end

-- A button that opens a menu, for filters. build(root) fills the menu
-- (MenuUtil's description API); the label shows the current choice.
function UI.Dropdown(parent, width, build)
    local button = UI.Button(parent, "", width, 24, function(self)
        if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
        MenuUtil.CreateContextMenu(self, function(_, root) build(root) end)
    end)
    button.label:SetJustifyH("LEFT")
    button.arrow = UI.Text(button, "small", "muted", "RIGHT")
    button.arrow:SetPoint("RIGHT", -8, 0)
    button.arrow:SetText("v")
    button.label:SetPoint("RIGHT", button.arrow, "LEFT", -4, 0)
    return button
end

-- A small square button with a short symbol. opts: font (theme font
-- name), hoverColor (theme color, default gold).
function UI.IconButton(parent, size, symbol, tooltipText, onClick, opts)
    opts = opts or {}
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(size, size)
    button.hover = button:CreateTexture(nil, "BACKGROUND")
    button.hover:SetAllPoints()
    button.hover:SetColorTexture(addon:Color("hover"))
    button.hover:Hide()
    button.label = UI.Text(button, opts.font or "heading", "muted", "CENTER")
    button.label:SetPoint("CENTER", 0, 1)
    button.label:SetText(symbol)
    button:SetScript("OnClick", onClick)
    UI.SetTooltip(button, function(tooltip)
        if tooltipText then tooltip:AddLine(tooltipText, 1, 1, 1) end
    end, "ANCHOR_BOTTOM")
    button:HookScript("OnEnter", function(self)
        self.label:SetTextColor(addon:Color(opts.hoverColor or "gold"))
        self.hover:Show()
    end)
    button:HookScript("OnLeave", function(self)
        self.label:SetTextColor(addon:Color("muted"))
        self.hover:Hide()
    end)
    return button
end

-- Tabs along the top of a screen. tabs = { { key, label } }.
-- onSelect(key) runs when one is clicked; bar:Select(key) marks one.
function UI.TabBar(parent, tabs, onSelect)
    local bar = CreateFrame("Frame", nil, parent)
    bar:SetHeight(32)
    bar.buttons = {}
    local previous
    for _, tab in ipairs(tabs) do
        local button = CreateFrame("Button", nil, bar)
        button.key = tab.key
        button.label = UI.Text(button, "tab", "muted", "CENTER")
        button.label:SetPoint("CENTER", 0, 1)
        button.label:SetText(tab.label)
        button:SetSize(button.label:GetStringWidth() + 32, 32)
        if previous then
            button:SetPoint("LEFT", previous, "RIGHT", 2, 0)
        else
            button:SetPoint("LEFT", bar, "LEFT", 8, 0)
        end
        button.underline = button:CreateTexture(nil, "ARTWORK")
        button.underline:SetColorTexture(addon:Color("gold"))
        button.underline:SetPoint("BOTTOMLEFT", 6, 0)
        button.underline:SetPoint("BOTTOMRIGHT", -6, 0)
        button.underline:SetHeight(2)
        button:SetScript("OnClick", function() onSelect(tab.key) end)
        button:SetScript("OnEnter", function(self)
            if bar.selected ~= self.key then self.label:SetTextColor(addon:Color("text")) end
        end)
        button:SetScript("OnLeave", function(self)
            if bar.selected ~= self.key then self.label:SetTextColor(addon:Color("muted")) end
        end)
        bar.buttons[tab.key] = button
        previous = button
    end

    function bar:Select(key)
        bar.selected = key
        for k, button in pairs(bar.buttons) do
            button.label:SetTextColor(addon:Color(k == key and "gold" or "muted"))
            button.underline:SetShown(k == key)
        end
    end
    return bar
end

-- A big-number tile: a small label, the number, and a note under it.
-- tile:Set(label, value, valueColor, note, noteColor); tile.tooltip =
-- function(tooltip) adds hover lines.
function UI.StatTile(parent, style)
    local tile = UI.Panel(parent, style)
    tile:SetHeight(76)
    tile.label = UI.Text(tile, "label", "muted")
    tile.label:SetPoint("TOPLEFT", 14, -12)
    tile.value = UI.Text(tile, "big")
    tile.value:SetPoint("TOPLEFT", tile.label, "BOTTOMLEFT", 0, -6)
    tile.note = UI.Text(tile, "small", "muted")
    tile.note:SetPoint("TOPLEFT", tile.value, "BOTTOMLEFT", 0, -4)
    tile.note:SetPoint("RIGHT", tile, "RIGHT", -10, 0)

    function tile:Set(label, value, valueColor, note, noteColor)
        tile.label:SetText(label and label:upper() or "")
        tile.value:SetText(value or "")
        tile.value:SetTextColor(addon:Color(valueColor or "text"))
        tile.note:SetText(note or "")
        tile.note:SetTextColor(addon:Color(noteColor or "muted"))
    end

    tile:EnableMouse(true)
    UI.SetTooltip(tile, function(tooltip)
        if tile.tooltip then tile.tooltip(tooltip) end
    end)
    return tile
end

-- A helpful empty screen: a heading and what to do next.
-- box:Set(title, body)
function UI.EmptyState(parent)
    local box = CreateFrame("Frame", nil, parent)
    box:SetSize(460, 120)
    box.title = UI.Text(box, "heading", nil, "CENTER")
    box.title:SetPoint("TOP", 0, 0)
    box.body = UI.Text(box, "body", "muted", "CENTER")
    box.body:SetPoint("TOP", box.title, "BOTTOM", 0, -10)
    box.body:SetWidth(460)
    box.body:SetWordWrap(true)
    box.body:SetSpacing(3)

    function box:Set(title, body)
        box.title:SetText(title or "")
        box.body:SetText(body or "")
    end
    return box
end

_G.Goldsmith = addon
