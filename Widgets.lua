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

-- "Loading" with moving dots over part of a screen that's still being
-- worked out (see addon:RunWork). It dims what's under it (the old
-- numbers stay visible until the new ones are in) and takes the mouse, so
-- nothing half-loaded gets clicked. One per frame: UI.Loading(frame)
-- makes it the first time and returns the same one after.
local DOT_SECONDS = 0.35
function UI.Loading(parent)
    if parent.goldsmithLoading then return parent.goldsmithLoading end
    local cover = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    cover:SetAllPoints()
    cover:SetFrameLevel(parent:GetFrameLevel() + 50)
    UI.Style(cover, "window")
    local r, g, b = addon:Color("window")
    cover:SetBackdropColor(r, g, b, 0.8)
    cover:EnableMouse(true)
    local text = UI.Text(cover, "body", "muted", "LEFT")
    -- Anchored left of centre so the dots grow without moving the word
    text:SetPoint("LEFT", cover, "CENTER", -28, 0)
    local dots, elapsed = 1, 0
    local function Draw() text:SetText("Loading" .. string.rep(".", dots)) end
    cover:SetScript("OnShow", function()
        dots, elapsed = 1, 0
        Draw()
    end)
    cover:SetScript("OnUpdate", function(_, delta)
        elapsed = elapsed + delta
        if elapsed >= DOT_SECONDS then
            elapsed = 0
            dots = dots % 3 + 1
            Draw()
        end
    end)
    Draw()
    cover:Hide()
    parent.goldsmithLoading = cover
    return cover
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
-- adds none. Hooked, so a widget's own hover effects (e.g. a gold border)
-- keep working; call it once per frame.
function UI.SetTooltip(frame, fill, anchor)
    frame:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, anchor or "ANCHOR_RIGHT")
        fill(GameTooltip, self)
        if GameTooltip:NumLines() > 0 then
            GameTooltip:Show()
        else
            GameTooltip:Hide()
        end
    end)
    frame:HookScript("OnLeave", GameTooltip_Hide)
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

-- Charts
--
-- chart:SetData(points), points = { { value, color (theme name, optional),
-- tooltip = function(tooltip) } }. Drawn to fit the chart's size and
-- redrawn when it changes. Values below zero go below a zero line.

local function ValueRange(points)
    local maxV, minV = 0, 0
    for _, p in ipairs(points) do
        maxV = math.max(maxV, p.value)
        minV = math.min(minV, p.value)
    end
    local range = maxV - minV
    return minV, range > 0 and range or 1
end

-- An invisible column over each point, for its hover tooltip
local function HoverColumn(chart, i)
    chart.hovers = chart.hovers or {}
    local hover = chart.hovers[i]
    if not hover then
        hover = CreateFrame("Frame", nil, chart)
        hover.highlight = hover:CreateTexture(nil, "BACKGROUND")
        hover.highlight:SetAllPoints()
        hover.highlight:SetColorTexture(addon:Color("hover"))
        hover.highlight:Hide()
        hover:EnableMouse(true)
        hover:SetScript("OnEnter", function(self)
            self.highlight:Show()
            if self.point and self.point.tooltip then
                GameTooltip:SetOwner(self, "ANCHOR_TOP")
                self.point.tooltip(GameTooltip)
                GameTooltip:Show()
            end
        end)
        hover:SetScript("OnLeave", function(self)
            self.highlight:Hide()
            GameTooltip:Hide()
        end)
        chart.hovers[i] = hover
    end
    return hover
end

local function HideFrom(list, first)
    for i = first, #(list or {}) do list[i]:Hide() end
end

function UI.BarChart(parent)
    local chart = CreateFrame("Frame", nil, parent)
    chart.bars = {}
    chart.zero = UI.Line(chart, "borderStrong")
    chart.zero:SetHeight(1)

    function chart:Draw()
        local points = chart.points or {}
        local w, h = chart:GetWidth(), chart:GetHeight()
        local n = #points
        if n == 0 or w <= 0 or h <= 0 then
            HideFrom(chart.bars, 1); HideFrom(chart.hovers, 1)
            chart.zero:Hide()
            return
        end
        local minV, range = ValueRange(points)
        local zeroY = -minV / range * h
        local gap = n > 20 and 2 or 5
        local barWidth = math.max((w - gap * (n - 1)) / n, 1)
        for i, p in ipairs(points) do
            local bar = chart.bars[i]
            if not bar then
                bar = chart:CreateTexture(nil, "ARTWORK")
                chart.bars[i] = bar
            end
            local height = math.abs(p.value) / range * h
            local x = (i - 1) * (barWidth + gap)
            bar:ClearAllPoints()
            if p.value >= 0 then
                bar:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", x, zeroY)
            else
                bar:SetPoint("TOPLEFT", chart, "BOTTOMLEFT", x, zeroY)
            end
            bar:SetSize(barWidth, math.max(height, 2))
            local color = p.color or (p.value > 0 and "bar" or p.value < 0 and "loss" or "barEmpty")
            bar:SetColorTexture(addon:Color(color))
            bar:Show()

            local hover = HoverColumn(chart, i)
            hover.point = p
            hover:ClearAllPoints()
            hover:SetPoint("TOPLEFT", chart, "TOPLEFT", x, 0)
            hover:SetSize(barWidth, h)
            hover:Show()
        end
        HideFrom(chart.bars, n + 1); HideFrom(chart.hovers, n + 1)
        chart.zero:ClearAllPoints()
        chart.zero:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", 0, zeroY)
        chart.zero:SetPoint("BOTTOMRIGHT", chart, "BOTTOMRIGHT", 0, zeroY)
        chart.zero:Show()
    end

    function chart:SetData(points)
        chart.points = points
        chart:Draw()
    end
    chart:SetScript("OnSizeChanged", function() chart:Draw() end)
    return chart
end

-- A line chart. The line is scaled between the lowest and highest values
-- (not from zero), so changes in a large total stay visible.
-- chart:SetData(points, opts): opts.band = { low, high, usual } shades the
-- usual range and marks the usual value (e.g. an item's usual price).
function UI.LineChart(parent)
    local chart = CreateFrame("Frame", nil, parent)
    chart.lines, chart.dots = {}, {}
    chart.bandArea = chart:CreateTexture(nil, "BACKGROUND")
    chart.bandArea:SetColorTexture(addon:Color("band"))
    chart.bandLine = chart:CreateTexture(nil, "BORDER")
    chart.bandLine:SetColorTexture(addon:Color("bandLine"))
    chart.bandLine:SetHeight(1)
    chart.baseline = UI.Line(chart, "borderStrong")
    chart.baseline:SetHeight(1)
    chart.baseline:SetPoint("BOTTOMLEFT")
    chart.baseline:SetPoint("BOTTOMRIGHT")

    function chart:Draw()
        local points = chart.points or {}
        local w, h = chart:GetWidth(), chart:GetHeight()
        local n = #points
        HideFrom(chart.lines, 1); HideFrom(chart.dots, 1); HideFrom(chart.hovers, 1)
        chart.bandArea:Hide(); chart.bandLine:Hide()
        if n == 0 or w <= 0 or h <= 0 then return end

        local minV, maxV = math.huge, -math.huge
        for _, p in ipairs(points) do
            minV, maxV = math.min(minV, p.value), math.max(maxV, p.value)
        end
        local band = chart.band
        if band then
            minV, maxV = math.min(minV, band.low), math.max(maxV, band.high)
        end
        local range = maxV - minV
        -- A flat line sits in the middle
        local function Y(v) return range > 0 and ((v - minV) / range * (h - 8) + 4) or h / 2 end

        if band then
            chart.bandArea:ClearAllPoints()
            chart.bandArea:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", 0, Y(band.low))
            chart.bandArea:SetPoint("BOTTOMRIGHT", chart, "BOTTOMRIGHT", 0, Y(band.low))
            chart.bandArea:SetHeight(math.max(Y(band.high) - Y(band.low), 1))
            chart.bandArea:Show()
            if band.usual then
                chart.bandLine:ClearAllPoints()
                chart.bandLine:SetPoint("BOTTOMLEFT", chart, "BOTTOMLEFT", 0, Y(band.usual))
                chart.bandLine:SetPoint("BOTTOMRIGHT", chart, "BOTTOMRIGHT", 0, Y(band.usual))
                chart.bandLine:Show()
            end
        end
        local step = n > 1 and w / (n - 1) or 0
        local function X(i) return n > 1 and (i - 1) * step or w / 2 end

        for i, p in ipairs(points) do
            if i > 1 then
                local line = chart.lines[i - 1]
                if not line then
                    line = chart:CreateLine(nil, "ARTWORK")
                    line:SetThickness(2)
                    chart.lines[i - 1] = line
                end
                line:SetColorTexture(addon:Color(p.color or "gold"))
                line:SetStartPoint("BOTTOMLEFT", chart, X(i - 1), Y(points[i - 1].value))
                line:SetEndPoint("BOTTOMLEFT", chart, X(i), Y(p.value))
                line:Show()
            end
            local dot = chart.dots[i]
            if not dot then
                dot = chart:CreateTexture(nil, "OVERLAY")
                dot:SetSize(5, 5)
                chart.dots[i] = dot
            end
            dot:SetColorTexture(addon:Color(p.color or "gold"))
            dot:ClearAllPoints()
            dot:SetPoint("CENTER", chart, "BOTTOMLEFT", X(i), Y(p.value))
            dot:Show()

            local hover = HoverColumn(chart, i)
            hover.point = p
            hover:ClearAllPoints()
            -- Half a step either side of the point, kept inside the chart
            local half = n > 1 and step / 2 or w / 2
            local left, right = math.max(X(i) - half, 0), math.min(X(i) + half, w)
            hover:SetPoint("TOPLEFT", chart, "TOPLEFT", left, 0)
            hover:SetSize(math.max(right - left, 1), h)
            hover:Show()
        end
    end

    function chart:SetData(points, opts)
        chart.points = points
        chart.band = opts and opts.band
        chart:Draw()
    end
    chart:SetScript("OnSizeChanged", function() chart:Draw() end)
    return chart
end

-- An on/off switch with a label, for view options that are remembered
-- (e.g. Crafts' Concentration). switch:SetOn(on) shows the state;
-- onToggle(newState) runs when it's clicked.
function UI.Switch(parent, text, onToggle)
    local switch = CreateFrame("Button", nil, parent, "BackdropTemplate")
    switch:SetHeight(26)
    switch.track = CreateFrame("Frame", nil, switch, "BackdropTemplate")
    switch.track:SetSize(28, 14)
    switch.track:SetPoint("LEFT", 8, 0)
    switch.knob = switch.track:CreateTexture(nil, "OVERLAY")
    switch.knob:SetSize(10, 10)
    switch.label = UI.Text(switch, "small", "text")
    switch.label:SetPoint("LEFT", switch.track, "RIGHT", 8, 0)
    switch.label:SetText(text)
    switch:SetWidth(8 + 28 + 8 + switch.label:GetStringWidth() + 12)

    function switch:SetOn(on)
        switch.on = on and true or false
        UI.Style(switch, on and "highlight" or "panelRaised", on and "borderGold" or "borderStrong")
        UI.Style(switch.track, on and "gold" or "barEmpty")
        switch.knob:SetColorTexture(addon:Color("window"))
        switch.knob:ClearAllPoints()
        switch.knob:SetPoint(on and "RIGHT" or "LEFT", switch.track, on and "RIGHT" or "LEFT", on and -2 or 2, 0)
        switch.label:SetTextColor(addon:Color(on and "gold" or "text"))
    end
    switch:SetScript("OnClick", function() onToggle(not switch.on) end)
    switch:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(addon:Color("gold")) end)
    switch:HookScript("OnLeave", function(self)
        self:SetBackdropBorderColor(addon:Color(self.on and "borderGold" or "borderStrong"))
    end)
    switch:SetOn(false)
    return switch
end

-- A checkbox with a label. box:SetChecked(checked); onToggle(newState).
function UI.Checkbox(parent, text, onToggle)
    local check = CreateFrame("Button", nil, parent)
    check:SetHeight(24)
    check.box = UI.Panel(check, "raised")
    check.box:SetSize(14, 14)
    check.box:SetPoint("LEFT", 0, 0)
    check.mark = check.box:CreateTexture(nil, "OVERLAY")
    check.mark:SetSize(8, 8)
    check.mark:SetPoint("CENTER")
    check.mark:SetColorTexture(addon:Color("gold"))
    check.label = UI.Text(check, "small", "text")
    check.label:SetPoint("LEFT", check.box, "RIGHT", 7, 0)
    check.label:SetText(text)
    check:SetWidth(14 + 7 + check.label:GetStringWidth() + 4)

    function check:SetChecked(checked)
        check.checked = checked and true or false
        check.mark:SetShown(check.checked)
    end
    check:SetScript("OnClick", function() onToggle(not check.checked) end)
    check:SetScript("OnEnter", function() check.box:SetBackdropBorderColor(addon:Color("gold")) end)
    check:SetScript("OnLeave", function() check.box:SetBackdropBorderColor(addon:Color("borderStrong")) end)
    check:SetChecked(false)
    return check
end

-- A box for typing a whole number. onChange(number or nil) runs as it's
-- typed; Enter and Escape stop typing.
function UI.NumberBox(parent, width, onChange)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetSize(width, 24)
    UI.Style(box, "panelRaised", "borderStrong")
    box:SetFontObject(addon:Font("body"))
    box:SetTextInsets(8, 8, 0, 0)
    box:SetJustifyH("RIGHT")
    box:SetAutoFocus(false)
    box:SetNumeric(true)
    box:SetMaxLetters(6)
    box:SetScript("OnTextChanged", function(self, userInput)
        if userInput then onChange(tonumber(self:GetText())) end
    end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    -- Clicking in selects the whole number, so typing replaces it (1 then 2
    -- gives 2, not 12). Again next frame: the click that gave focus can
    -- move the cursor after this runs.
    box:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(addon:Color("gold"))
        self:HighlightText()
        C_Timer.After(0, function() if self:HasFocus() then self:HighlightText() end end)
    end)
    box:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(addon:Color("borderStrong"))
        self:HighlightText(0, 0)
    end)
    return box
end

-- A search box with a hint shown while it's empty. onChange(text) runs as
-- it's typed; Escape clears it.
function UI.SearchBox(parent, width, hint, onChange)
    local box = CreateFrame("EditBox", nil, parent, "BackdropTemplate")
    box:SetSize(width, 24)
    UI.Style(box, "panelRaised", "borderStrong")
    box:SetFontObject(addon:Font("body"))
    box:SetTextInsets(10, 24, 0, 0)
    box:SetAutoFocus(false)
    box:SetMaxLetters(60)
    box.hint = UI.Text(box, "small", "dim")
    box.hint:SetPoint("LEFT", 10, 0)
    box.hint:SetText(hint)
    box.clear = UI.IconButton(box, 20, "x", "Clear", function()
        box:SetText("")
        box:ClearFocus()
        onChange("")
    end, { font = "small" })
    box.clear:SetPoint("RIGHT", -2, 0)

    local function Update()
        local empty = box:GetText() == ""
        box.hint:SetShown(empty and not box:HasFocus())
        box.clear:SetShown(not empty)
    end
    box:SetScript("OnTextChanged", function(self, userInput)
        Update()
        if userInput then onChange(self:GetText()) end
    end)
    box:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    box:SetScript("OnEscapePressed", function(self)
        self:SetText("")
        self:ClearFocus()
        onChange("")
    end)
    box:SetScript("OnEditFocusGained", function(self)
        self:SetBackdropBorderColor(addon:Color("gold"))
        Update()
    end)
    box:SetScript("OnEditFocusLost", function(self)
        self:SetBackdropBorderColor(addon:Color("borderStrong"))
        Update()
    end)
    Update()
    return box
end

-- A scrolling list with a header row.
--
-- columns = { { key, label, width (nil: takes the space left), justify } };
-- list:SetColumns changes them (e.g. Crafts' concentration columns).
-- Only the rows that fit on screen exist; scrolling shows other items in
-- them. opts:
--   fill(row, item)            sets row.cells[key] text and colors
--   tooltip(tooltip, item)     hover lines (optional)
--   onClick(item, mouseButton) (optional)
--   onSort(key)                makes headers clickable (optional);
--                              list:SetSort(key, descending) marks one
--   empty                      text shown when there are no items
local LIST_HEADER_HEIGHT = 24
local LIST_PAD = 10
local LIST_GAP = 8
local SCROLLBAR_WIDTH = 6

function UI.List(parent, opts)
    local list = CreateFrame("Frame", nil, parent)
    list.rowHeight = opts.rowHeight or 24
    list.columns, list.items, list.offset = {}, {}, 0
    list.headerCells, list.rows = {}, {}

    local header = CreateFrame("Frame", nil, list)
    header:SetPoint("TOPLEFT")
    header:SetPoint("TOPRIGHT", -(SCROLLBAR_WIDTH + 4), 0)
    header:SetHeight(LIST_HEADER_HEIGHT)
    local headerLine = UI.Line(list, "border")
    headerLine:SetPoint("TOPLEFT", header, "BOTTOMLEFT")
    headerLine:SetPoint("TOPRIGHT", header, "BOTTOMRIGHT")
    headerLine:SetHeight(1)

    local body = CreateFrame("Frame", nil, list)
    body:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -3)
    body:SetPoint("BOTTOMRIGHT", -(SCROLLBAR_WIDTH + 4), 0)
    body:EnableMouseWheel(true)

    local empty = UI.Text(body, "body", "muted", "CENTER")
    empty:SetPoint("TOP", 0, -40)
    empty:SetWidth(460)
    empty:SetWordWrap(true)
    empty:SetText(opts.empty or "")

    local scrollbar = CreateFrame("Slider", nil, list, "BackdropTemplate")
    scrollbar:SetOrientation("VERTICAL")
    scrollbar:SetWidth(SCROLLBAR_WIDTH)
    scrollbar:SetPoint("TOPRIGHT", body, "TOPRIGHT", SCROLLBAR_WIDTH + 4, 0)
    scrollbar:SetPoint("BOTTOMRIGHT", body, "BOTTOMRIGHT", SCROLLBAR_WIDTH + 4, 0)
    UI.Style(scrollbar, "panelRaised")
    local thumb = scrollbar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(addon:Color("borderStrong"))
    thumb:SetSize(SCROLLBAR_WIDTH, 30)
    scrollbar:SetThumbTexture(thumb)
    scrollbar:SetValueStep(1)
    scrollbar:SetObeyStepOnDrag(true)
    scrollbar:EnableMouseWheel(true)

    -- x position and width of each column across the given width
    local function Layout(width)
        local fixed, flexCount = 0, 0
        for _, col in ipairs(list.columns) do
            if col.width then fixed = fixed + col.width else flexCount = flexCount + 1 end
        end
        local gaps = LIST_GAP * math.max(#list.columns - 1, 0)
        local flex = flexCount > 0 and math.max((width - 2 * LIST_PAD - fixed - gaps) / flexCount, 40) or 0
        local x, layout = LIST_PAD, {}
        for _, col in ipairs(list.columns) do
            local w = col.width or flex
            layout[col.key] = { x = x, width = w }
            x = x + w + LIST_GAP
        end
        return layout
    end

    -- Shows a cell per current column (made on first use) and hides the rest
    local function PlaceCells(frame, cells, layout, make)
        for _, cell in pairs(cells) do cell:Hide() end
        for _, col in ipairs(list.columns) do
            local cell = cells[col.key]
            if not cell then
                cell = make(col)
                cells[col.key] = cell
            end
            local l = layout[col.key]
            cell:ClearAllPoints()
            cell:SetPoint("LEFT", frame, "LEFT", l.x, 0)
            cell:SetWidth(l.width)
            local text = cell.text or cell
            text:SetJustifyH(col.justify or "LEFT")
            cell:Show()
        end
    end

    local function HeaderCell(col)
        local cell = CreateFrame("Button", nil, header)
        cell:SetHeight(LIST_HEADER_HEIGHT)
        cell.text = UI.Text(cell, "label", "muted")
        cell.text:SetAllPoints()
        if opts.onSort then
            cell:SetScript("OnClick", function() opts.onSort(col.key) end)
            cell:SetScript("OnEnter", function(self) self.text:SetTextColor(addon:Color("text")) end)
            cell:SetScript("OnLeave", function(self)
                self.text:SetTextColor(addon:Color(self.sorted and "gold" or "muted"))
            end)
        end
        return cell
    end

    local Scroll -- defined below

    local function GetRow(i)
        if list.rows[i] then return list.rows[i] end
        local row = CreateFrame("Button", nil, body)
        row:SetHeight(list.rowHeight)
        row:SetPoint("TOPLEFT", 0, -(i - 1) * list.rowHeight)
        row:SetPoint("RIGHT", body, "RIGHT")
        row:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        row:EnableMouseWheel(true)
        row:SetScript("OnMouseWheel", function(_, delta) Scroll(nil, delta) end)
        if i % 2 == 0 then
            local zebra = row:CreateTexture(nil, "BACKGROUND")
            zebra:SetAllPoints()
            zebra:SetColorTexture(1, 1, 1, 0.025)
        end
        local hover = row:CreateTexture(nil, "HIGHLIGHT")
        hover:SetAllPoints()
        hover:SetColorTexture(addon:Color("hover"))
        row.cells = {}
        row:SetScript("OnClick", function(self, button)
            if self.data and opts.onClick then opts.onClick(self.data, button) end
        end)
        row:SetScript("OnEnter", function(self)
            if not (self.data and opts.tooltip) then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            opts.tooltip(GameTooltip, self.data)
            if GameTooltip:NumLines() > 0 then GameTooltip:Show() else GameTooltip:Hide() end
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        list.rows[i] = row
        return row
    end

    function list:Update()
        local visible = math.max(math.floor((body:GetHeight() or 0) / list.rowHeight), 0)
        local maxOffset = math.max(#list.items - visible, 0)
        list.offset = math.min(math.max(list.offset, 0), maxOffset)
        local layout = Layout(body:GetWidth() or 0)

        PlaceCells(header, list.headerCells, layout, HeaderCell)
        for _, col in ipairs(list.columns) do
            local cell = list.headerCells[col.key]
            local label = col.label:upper()
            cell.sorted = list.sortKey == col.key
            if cell.sorted then
                local arrow = list.sortDescending and "v" or "^"
                label = (col.justify == "RIGHT") and (arrow .. " " .. label) or (label .. " " .. arrow)
            end
            cell.text:SetText(label)
            cell.text:SetTextColor(addon:Color(cell.sorted and "gold" or "muted"))
        end

        for i = 1, visible do
            local row = GetRow(i)
            local item = list.items[list.offset + i]
            if item then
                row.data = item
                PlaceCells(row, row.cells, layout, function() return UI.Text(row, "body") end)
                for _, cell in pairs(row.cells) do
                    cell:SetText("")
                    cell:SetTextColor(addon:Color("text"))
                end
                opts.fill(row, item)
                row:Show()
                -- Scrolled under the mouse: show the new item's hover
                if GameTooltip:IsOwned(row) then row:GetScript("OnEnter")(row) end
            else
                row.data = nil
                row:Hide()
            end
        end
        for i = visible + 1, #list.rows do
            list.rows[i].data = nil
            list.rows[i]:Hide()
        end

        empty:SetShown(#list.items == 0)
        scrollbar:SetShown(maxOffset > 0)
        if maxOffset > 0 then
            thumb:SetHeight(math.max(body:GetHeight() * visible / #list.items, 20))
            scrollbar:SetMinMaxValues(0, maxOffset)
            scrollbar:SetValue(list.offset)
        end
    end

    function list:SetColumns(columns)
        list.columns = columns
        list:Update()
    end

    -- Both at once, for a list that switches between kinds of items (the
    -- old items would otherwise be drawn with the new columns)
    function list:SetColumnsAndItems(columns, items)
        list.columns, list.items = columns, items
        list:Update()
    end

    function list:SetItems(items)
        list.items = items
        list:Update()
    end

    function list:SetSort(key, descending)
        list.sortKey, list.sortDescending = key, descending
    end

    function list:SetEmptyText(text) empty:SetText(text or "") end

    function list:ScrollToTop() list.offset = 0 end

    Scroll = function(_, delta)
        list.offset = list.offset - delta * 3
        list:Update()
    end
    body:SetScript("OnMouseWheel", Scroll)
    scrollbar:SetScript("OnMouseWheel", Scroll)
    scrollbar:SetScript("OnValueChanged", function(_, value)
        value = math.floor(value + 0.5)
        if value ~= list.offset then
            list.offset = value
            list:Update()
        end
    end)
    body:SetScript("OnSizeChanged", function() list:Update() end)
    return list
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
