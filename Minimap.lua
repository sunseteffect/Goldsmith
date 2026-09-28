local addon = _G.Goldsmith or {}

-- Minimap button
--
-- A round button on the edge of the minimap: click to show or hide the
-- window, right-click for Settings, drag to move it around the edge. Shown
-- unless turned off in Settings ("showMinimap"); where it sits is kept in
-- GoldsmithDB.minimapAngle (degrees). Goldsmith can also be opened from
-- the game's addon compartment by the minimap and a key (Bindings.xml).
-- Built from the game's own minimap button textures, no libraries.

local DEFAULT_ANGLE = 200
local button

local function Place()
    local angle = math.rad(GoldsmithDB.minimapAngle or DEFAULT_ANGLE)
    local radius = Minimap:GetWidth() / 2 + 5
    button:ClearAllPoints()
    button:SetPoint("CENTER", Minimap, "CENTER", math.cos(angle) * radius, math.sin(angle) * radius)
end

-- While dragging: follow the cursor around the minimap's edge
local function FollowCursor()
    local mx, my = Minimap:GetCenter()
    local cx, cy = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    GoldsmithDB.minimapAngle = math.deg(math.atan2(cy / scale - my, cx / scale - mx))
    Place()
end

function addon:CreateMinimapButton()
    button = CreateFrame("Button", "GoldsmithMinimapButton", Minimap)
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFrameLevel(8)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetSize(20, 20)
    background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
    background:SetPoint("TOPLEFT", 7, -5)
    -- Goldsmith's logo: hammer and ingot (Media\Logo.tga)
    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetSize(20, 20)
    icon:SetTexture("Interface\\AddOns\\Goldsmith\\Media\\Logo")
    icon:SetPoint("TOPLEFT", 6, -5)
    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetSize(53, 53)
    border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
    border:SetPoint("TOPLEFT")

    button:SetScript("OnClick", function(_, mouseButton)
        if mouseButton == "RightButton" then
            addon:ShowSettings()
        else
            addon:ToggleWindow()
        end
    end)
    button:SetScript("OnDragStart", function(self)
        self:SetScript("OnUpdate", FollowCursor)
        GameTooltip:Hide()
    end)
    button:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Goldsmith", 1, 0.82, 0)
        GameTooltip:AddLine("Click to show or hide", 1, 1, 1)
        GameTooltip:AddLine("Right-click for settings", 1, 1, 1)
        GameTooltip:AddLine("Drag to move it around the minimap", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", GameTooltip_Hide)

    Place()
    addon:UpdateMinimapButton()
end

-- Shows or hides the button to match the setting
function addon:UpdateMinimapButton()
    if button then button:SetShown(addon:Setting("showMinimap")) end
end

_G.Goldsmith = addon
