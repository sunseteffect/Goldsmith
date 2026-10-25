-- Stand-ins for the game, enough to load Goldsmith outside WoW (Lua 5.1).
--
-- Everything the game would know lives in `world` (bench.lua sets it up
-- from the saved data; scenarios change it). Frames are permissive: any
-- method works, so UI code runs, but nothing is drawn. Time is virtual:
-- C_Timer callbacks run only when a scenario calls bench.Advance().

local world = {
    clock = 0,           -- seconds since the bench started (GetTime)
    baseTime = os.time(), -- time() at clock 0
    player = { name = "Bench", realm = "Sargeras", class = "MAGE", classID = 8 },
    money = 0,
    bags = {},           -- itemID -> count in bags
    bank = {},           -- itemID -> count in the bank
    warband = {},        -- itemID -> count in the warband bank
    items = {},          -- itemID -> { name, quality, sellPrice, icon, classID, subclassID, stack, link }
    spells = {},         -- spellID -> name
    -- C_TradeSkillUI answers, by recipeID (filled by scenarios when needed)
    recipeInfo = {}, schematics = {}, operations = {},
    -- The AH: itemID -> { { unitPrice, quantity }, ... } cheapest first
    commodities = {},
    auctionHouseOpen = false, mailOpen = false, merchantOpen = false,
    merchant = {},       -- { { itemID, name, price, stack, numAvailable }, ... }
    buffs = {},          -- { { name, spellId }, ... }
    combat = false,
    modifiers = {},      -- shift / ctrl / alt held
    calls = {},          -- every C_AuctionHouse / mail / craft call, in order
    chat = {},           -- every print(), with colors stripped
    errors = {},         -- errors caught from scripts and timers
}
_G.BenchWorld = world

local function Record(name, ...)
    local args = { ... }
    for i = 1, select("#", ...) do args[i] = tostring(args[i]) end
    table.insert(world.calls, name .. "(" .. table.concat(args, ", ") .. ")")
end

local function Strip(s)
    s = tostring(s)
    s = s:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    s = s:gsub("|T.-|t", ""):gsub("|A.-|a", ""):gsub("|H.-|h(.-)|h", "%1")
    -- An icon gone leaves a double space ("Buy 8  Azeroot")
    s = s:gsub("  +", " "):gsub("^ ", ""):gsub(" $", "")
    return s
end

-- Errors inside event handlers and timers are kept, not fatal, like the
-- game (which shows them in BugSack); bench.Check fails a run that has any
local function Protected(where, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        table.insert(world.errors, where .. ": " .. tostring(err))
        if world.echoErrors then io.stderr:write("ERROR " .. where .. ": " .. tostring(err) .. "\n") end
    end
end

---------------------------------------------------------------------------
-- Lua extras the game adds
---------------------------------------------------------------------------
strtrim = function(s, chars)
    if not s then return s end
    if chars then
        local pat = "[" .. chars:gsub("%W", "%%%0") .. "]"
        return (s:gsub("^" .. pat .. "+", ""):gsub(pat .. "+$", ""))
    end
    return (s:match("^%s*(.-)%s*$"))
end
string.trim = strtrim
strsplit = function(sep, s, limit)
    if not s then return nil end
    local out, start = {}, 1
    while true do
        if limit and #out == limit - 1 then table.insert(out, s:sub(start)) break end
        local i, j = s:find(sep, start, true)
        if not i then table.insert(out, s:sub(start)) break end
        table.insert(out, s:sub(start, i - 1))
        start = j + 1
    end
    return unpack(out)
end
string.split = function(s, sep, limit) return strsplit(sep, s, limit) end
strjoin = function(sep, ...) return table.concat({ ... }, sep) end
strsub, strlen, strlower, strupper, strfind, strmatch, strrep, strbyte, strchar =
    string.sub, string.len, string.lower, string.upper, string.find, string.match, string.rep, string.byte, string.char
gsub, format, gmatch, strrev = string.gsub, string.format, string.gmatch, string.reverse
tinsert, tremove, tconcat, sort = table.insert, table.remove, table.concat, table.sort
floor, ceil, abs, max, min, sqrt, random = math.floor, math.ceil, math.abs, math.max, math.min, math.sqrt, math.random
mod = math.fmod
wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
table.wipe = wipe
tContains = function(t, v) for _, x in ipairs(t) do if x == v then return true end end return false end
tInvert = function(t) local o = {} for k, v in pairs(t) do o[v] = k end return o end
CopyTable = function(t, shallow)
    local o = {}
    for k, v in pairs(t) do o[k] = (type(v) == "table" and not shallow) and CopyTable(v) or v end
    return o
end
Mixin = function(o, ...) for _, m in ipairs({ ... }) do for k, v in pairs(m) do o[k] = v end end return o end
CreateFromMixins = function(...) return Mixin({}, ...) end
bit = bit or {
    band = function(a, b) local r, p = 0, 1 while a > 0 and b > 0 do if a % 2 == 1 and b % 2 == 1 then r = r + p end a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2 end return r end,
    bor = function(a, b) local r, p = 0, 1 while a > 0 or b > 0 do if a % 2 == 1 or b % 2 == 1 then r = r + p end a, b, p = math.floor(a / 2), math.floor(b / 2), p * 2 end return r end,
}
debugprofilestop = function() return os.clock() * 1000 end
securecall = function(fn, ...) if type(fn) == "string" then fn = _G[fn] end return fn(...) end
issecurevariable = function() return true end
geterrorhandler = function() return function(err) table.insert(world.errors, "errorhandler: " .. tostring(err)) end end
seterrorhandler = function() end
scrub = function(...) return ... end

local realTime, realDate = os.time, os.date
time = function(t) if t then return realTime(t) end return math.floor(world.baseTime + world.clock) end
date = function(fmt, t) return realDate(fmt, t or time()) end
GetTime = function() return world.clock end
GetServerTime = time

print = function(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    local line = Strip(table.concat(parts, " "))
    table.insert(world.chat, line)
    if world.echoChat then io.write("  chat: ", line, "\n") end
end

---------------------------------------------------------------------------
-- Frames
---------------------------------------------------------------------------
local frames = {}      -- every frame made, for the event bus
local named = {}
local Widget

local function Child(self, kind)
    local w = Widget(kind, nil, self)
    return w
end

local methods = {}
function methods:SetScript(name, fn) self._scripts[name] = fn end
function methods:GetScript(name) return self._scripts[name] end
function methods:HasScript() return true end
function methods:HookScript(name, fn)
    local old = self._scripts[name]
    self._scripts[name] = old and function(...) old(...) fn(...) end or fn
end
function methods:RegisterEvent(e) self._events[e] = true end
function methods:RegisterUnitEvent(e) self._events[e] = true end
function methods:UnregisterEvent(e) self._events[e] = nil end
function methods:UnregisterAllEvents() wipe(self._events) end
function methods:IsEventRegistered(e) return self._events[e] == true end
function methods:Show()
    if self._shown then return end
    self._shown = true
    if self._scripts.OnShow then Protected("OnShow", self._scripts.OnShow, self) end
end
function methods:Hide()
    if not self._shown then return end
    self._shown = false
    if self._scripts.OnHide then Protected("OnHide", self._scripts.OnHide, self) end
end
function methods:SetShown(v) if v then self:Show() else self:Hide() end end
function methods:IsShown() return self._shown end
function methods:IsVisible()
    local f = self
    while f do if not f._shown then return false end f = f._parent end
    return true
end
function methods:SetText(t) self._text = t ~= nil and tostring(t) or nil end
function methods:SetFormattedText(fmt, ...) self._text = string.format(fmt, ...) end
function methods:GetText() return self._text end
function methods:SetLabel(t) self._text = t end
function methods:SetWidth(w) self._w = w end
function methods:SetHeight(h) self._h = h end
function methods:SetSize(w, h) self._w, self._h = w, h end
function methods:GetWidth() return self._w or 100 end
function methods:GetHeight() return self._h or 20 end
function methods:GetSize() return self:GetWidth(), self:GetHeight() end
function methods:GetScale() return 1 end
function methods:GetEffectiveScale() return 1 end
function methods:GetLeft() return self._left or 0 end
function methods:GetRight() return (self._left or 0) + self:GetWidth() end
function methods:GetTop() return self._top or self:GetHeight() end
function methods:GetBottom() return 0 end
function methods:GetCenter() return self:GetWidth() / 2, self:GetHeight() / 2 end
function methods:GetRect() return 0, 0, self:GetWidth(), self:GetHeight() end
-- Anchors are kept (not laid out), so a scenario can see where a frame was put
function methods:SetPoint(point, rel, relPoint, x, y)
    self._points = self._points or {}
    if type(rel) == "number" then rel, relPoint, x, y = nil, point, rel, relPoint end
    table.insert(self._points, { point, rel or self._parent, relPoint or point, x or 0, y or 0 })
end
function methods:SetAllPoints(rel) self._points = { { "TOPLEFT", rel or self._parent, "TOPLEFT", 0, 0 } } end
function methods:ClearAllPoints() self._points = {} end
function methods:GetNumPoints() return #(self._points or {}) end
function methods:GetPoint(i)
    local p = (self._points or {})[i or 1]
    if not p then return nil end
    return p[1], p[2], p[3], p[4], p[5]
end
-- Dragging: a scenario sets where it lets go (world.dropAt = { left, top })
function methods:StartMoving() self._moving = true end
function methods:StopMovingOrSizing()
    self._moving = false
    if world.dropAt then self._left, self._top = world.dropAt[1], world.dropAt[2] end
end
-- Text sizes: 6 px a character, 14 px a line (wrapping by width)
function methods:GetStringWidth() return #(Strip(self._text or "")) * 6 end
function methods:GetUnboundedStringWidth() return self:GetStringWidth() end
function methods:GetStringHeight()
    local w = self._w or 0
    local text = Strip(self._text or "")
    if text == "" then return 0 end
    local lines = 0
    for line in (text .. "\n"):gmatch("(.-)\n") do
        lines = lines + ((w > 0) and math.max(1, math.ceil(#line * 6 / w)) or 1)
    end
    return lines * 14
end
function methods:GetNumLines() return math.max(1, math.floor(self:GetStringHeight() / 14)) end
function methods:IsTruncated() return false end
function methods:GetParent() return self._parent end
function methods:SetParent(p) self._parent = p end
function methods:GetName() return self._name end
function methods:GetDebugName() return self._name or self._kind end
function methods:GetObjectType() return self._kind end
function methods:IsObjectType(k) return self._kind == k end
function methods:IsForbidden() return false end
function methods:GetChildren() return unpack(self._children) end
function methods:GetRegions() return end
function methods:GetNumChildren() return #self._children end
function methods:SetAttribute(k, v) self._attr[k] = v end
function methods:GetAttribute(k) return self._attr[k] end
function methods:SetID(id) self._id = id end
function methods:GetID() return self._id or 0 end
function methods:Click(button)
    if self._enabled == false then return end
    if self._scripts.PreClick then Protected("PreClick", self._scripts.PreClick, self, button or "LeftButton") end
    if self._scripts.OnClick then Protected("OnClick", self._scripts.OnClick, self, button or "LeftButton", false) end
    if self._scripts.PostClick then Protected("PostClick", self._scripts.PostClick, self, button or "LeftButton") end
end
function methods:Enable() self._enabled = true end
function methods:Disable() self._enabled = false end
function methods:SetEnabled(v) self._enabled = v and true or false end
function methods:IsEnabled() return self._enabled ~= false end
function methods:SetChecked(v) self._checked = v and true or false end
function methods:GetChecked() return self._checked end
function methods:SetValue(v) self._value = v end
function methods:GetValue() return self._value or 0 end
function methods:SetMinMaxValues(a, b) self._min, self._max = a, b end
function methods:GetMinMaxValues() return self._min or 0, self._max or 0 end
function methods:SetVerticalScroll(v) self._scroll = v end
function methods:GetVerticalScroll() return self._scroll or 0 end
function methods:GetVerticalScrollRange() return 0 end
function methods:GetHorizontalScroll() return 0 end
function methods:SetAlpha(a) self._alpha = a end
function methods:GetAlpha() return self._alpha or 1 end
function methods:GetEffectiveAlpha() return self._alpha or 1 end
function methods:IsMouseOver() return false end
function methods:IsMouseEnabled() return true end
function methods:GetFrameLevel() return 1 end
function methods:GetFrameStrata() return "MEDIUM" end
function methods:GetFont() return "Fonts\\FRIZQT__.TTF", 12, "" end
function methods:GetTextColor() return 1, 1, 1, 1 end
function methods:GetVertexColor() return 1, 1, 1, 1 end
function methods:GetTexture() return self._texture end
function methods:SetTexture(t) self._texture = t end
function methods:GetCursorPosition() return 0 end
function methods:HasFocus() return false end
function methods:GetNumber() return tonumber(self._text) or 0 end
function methods:GetFontString() self._fs = self._fs or Child(self, "FontString") return self._fs end
function methods:SetFontString(fs) self._fs = fs end
function methods:GetNormalTexture() return Child(self, "Texture") end
function methods:GetHighlightTexture() return Child(self, "Texture") end
function methods:GetPushedTexture() return Child(self, "Texture") end
function methods:GetDisabledTexture() return Child(self, "Texture") end
function methods:GetCheckedTexture() return Child(self, "Texture") end
function methods:GetStatusBarTexture() return Child(self, "Texture") end
function methods:GetScrollChild() return self._scrollChild end
function methods:SetScrollChild(c) self._scrollChild = c end
function methods:CreateFontString(name) return Widget("FontString", name, self) end
function methods:CreateTexture(name) return Widget("Texture", name, self) end
function methods:CreateMaskTexture(name) return Widget("MaskTexture", name, self) end
function methods:CreateLine(name) return Widget("Line", name, self) end
function methods:CreateAnimationGroup(name) return Widget("AnimationGroup", name, self) end
function methods:CreateAnimation(kind, name) return Widget("Animation", name, self) end
function methods:IsPlaying() return false end
function methods:GetItem() return nil end
function methods:GetSpell() return nil end
function methods:NumLines() return 0 end
function methods:GetOwner() return self._owner end
function methods:SetOwner(o) self._owner = o end
function methods:IsOwned(o) return self._owner == o end

-- What an unknown method gives back, by its name: setters nothing,
-- getters 0, Is/Has/Can false, Create a new frame
local function DefaultResult(key, owner)
    if key:find("^Create") or key:find("^Acquire") then return Widget("Frame", nil, owner) end
    if key:find("^Is") or key:find("^Has") or key:find("^Can") then return false end
    if key:find("^Get") then return 0 end
    return nil
end

local widgetMeta, autoMeta
local function Index(self, key)
    local m = methods[key]
    if m then return m end
    if type(key) ~= "string" then return nil end
    -- The bench's own fields (_w, _text...) and the addon's (lowercase:
    -- frame.rows, button.label) are plain fields: nil until set
    if not key:find("^%u") then return nil end
    -- Capitalized: a Blizzard method or child frame (ScrollBox, OrdersPage).
    -- One object works as both: call it and it answers like a method by
    -- its name; index it and it's a frame.
    local member = setmetatable({
        _kind = "Frame", _key = key, _owner = self, _parent = self, _scripts = {}, _events = {},
        _children = {}, _attr = {}, _shown = true,
    }, autoMeta)
    rawset(self, key, member)
    return member
end
widgetMeta = { __index = Index }
autoMeta = {
    __index = Index,
    __call = function(member, ...) return DefaultResult(member._key, member._owner) end,
}

Widget = function(kind, name, parent, template)
    local w = {
        _kind = kind or "Frame", _name = name, _parent = parent, _scripts = {}, _events = {},
        _children = {}, _attr = {}, _shown = true, _template = template,
    }
    setmetatable(w, widgetMeta)
    if parent and type(parent) == "table" and parent._children then table.insert(parent._children, w) end
    if name then
        named[name] = w
        rawset(_G, name, w)
    end
    table.insert(frames, w)
    return w
end
_G.BenchWidget = Widget

CreateFrame = function(kind, name, parent, template)
    local f = Widget(kind, name, parent, template)
    if kind == "GameTooltip" then f._lines = {} end
    if template and template:find("ScrollFrame") then
        f.ScrollBar = Widget("Slider", nil, f)
    end
    return f
end

UIParent = Widget("Frame", "UIParent")
UIParent:SetSize(1920, 1080)
WorldFrame = Widget("Frame", "WorldFrame")
Minimap = Widget("Frame", "Minimap")
GameTooltip = Widget("GameTooltip", "GameTooltip", UIParent)
GameTooltip:Hide()
ItemRefTooltip = Widget("GameTooltip", "ItemRefTooltip", UIParent)
ShoppingTooltip1 = Widget("GameTooltip", "ShoppingTooltip1", UIParent)
DEFAULT_CHAT_FRAME = Widget("Frame", "DEFAULT_CHAT_FRAME")
DEFAULT_CHAT_FRAME.AddMessage = function(_, msg) print(msg) end
ChatFrame1 = DEFAULT_CHAT_FRAME
ChatFrame1EditBox = Widget("EditBox", "ChatFrame1EditBox")
ChatFrame1EditBox:Hide()
UIErrorsFrame = Widget("Frame", "UIErrorsFrame")
UIErrorsFrame.AddMessage = function(_, msg) print("[error frame] " .. tostring(msg)) end
for _, n in ipairs({ "GameFontNormal", "GameFontNormalSmall", "GameFontNormalLarge", "GameFontHighlight",
    "GameFontHighlightSmall", "GameFontHighlightLarge", "GameFontDisable", "GameFontDisableSmall", "GameFontWhite",
    "GameFontNormalHuge", "NumberFontNormal", "SystemFont_Shadow_Med1", "ChatFontNormal", "GameFontRed",
    "GameFontGreen", "GameFontHighlightMedium", "Tooltip_Med", "Tooltip_Small" }) do
    _G[n] = Widget("Font", n)
end
CreateFont = function(name) return Widget("Font", name) end
-- Blizzard windows Goldsmith sits beside; hidden until a scenario opens them
for _, n in ipairs({ "AuctionHouseFrame", "ProfessionsFrame", "MailFrame", "MerchantFrame", "BankFrame",
    "ContainerFrameCombinedBags", "CharacterFrame", "SendMailFrame", "InboxFrame", "OpenMailFrame",
    "ProfessionsCustomerOrdersFrame", "AccountBankPanel", "GameMenuFrame", "SettingsPanel", "PlayerSpellsFrame",
    "SendMailNameEditBox", "SendMailSubjectEditBox", "SendMailBodyEditBox", "SendMailMailButton", "MailFrameTab2",
    "StaticPopup1" }) do
    Widget("Frame", n, UIParent):Hide()
end
ProfessionsFrame.CraftingPage = Widget("Frame", nil, ProfessionsFrame)
ProfessionsFrame.CraftingPage.SchematicForm = Widget("Frame", nil, ProfessionsFrame.CraftingPage)
ProfessionsFrame.OrdersPage = Widget("Frame", nil, ProfessionsFrame)
AuctionHouseFrame.CommoditiesBuyFrame = Widget("Frame", nil, AuctionHouseFrame)
AuctionHouseFrame.ItemBuyFrame = Widget("Frame", nil, AuctionHouseFrame)
SendMailMoneyFrame = Widget("Frame", "SendMailMoneyFrame")

UISpecialFrames, UIPanelWindows = {}, {}
StaticPopupDialogs = {}
StaticPopup_Show = function(which, a, b, data)
    Record("StaticPopup_Show", which, a)
    world.lastPopup = { which = which, text1 = a, text2 = b, data = data }
    return StaticPopup1
end
StaticPopup_Hide = function() end
StaticPopup_Visible = function() return nil end
SlashCmdList = {}
hash_SlashCmdList = {}
Settings = { OpenToCategory = function() end, RegisterCanvasLayoutCategory = function() return { ID = 1 } end,
    RegisterAddOnCategory = function() end }
Menu = { ModifyMenu = function() end }
MenuUtil = { CreateContextMenu = function(owner, gen) world.lastMenu = gen return Widget("Frame") end,
    CreateButtonMenu = function() end }
EasyMenu = function() end
ShowUIPanel = function(f) if f then f:Show() end end
HideUIPanel = function(f) if f then f:Hide() end end
CloseDropDownMenus = function() end
PlaySound = function(id) Record("PlaySound", id) end
PlaySoundFile = function(f) Record("PlaySoundFile", f) end
RaidWarningFrame = {}
RaidNotice_AddMessage = function(_, msg) Record("RaidNotice", msg) end
StopSound = function() end
SOUNDKIT = setmetatable({}, { __index = function(_, k) return k end })
InCombatLockdown = function() return world.combat end
IsShiftKeyDown = function() return world.modifiers.shift end
IsControlKeyDown = function() return world.modifiers.ctrl end
IsAltKeyDown = function() return world.modifiers.alt end
IsModifiedClick = function() return false end
GetCursorPosition = function() return 0, 0 end
GetCursorInfo = function() return nil end
ClearCursor = function() world.cursor = nil end
GetMouseFocus = function() return nil end
GetMouseFoci = function() return {} end
GetScreenWidth = function() return 1920 end
GetScreenHeight = function() return 1080 end
GetBindingKey = function() return nil end
GetBindingText = function(k) return k end
GetLocale = function() return "enUS" end
GetCurrentRegion = function() return 1 end
GetCurrentRegionName = function() return "US" end
GetBuildInfo = function() return "12.0.5", "60000", "Oct 1 2026", 120105 end
GetExpansionLevel = function() return 11 end
GetServerExpansionLevel = function() return 11 end
GetAddOnMemoryUsage = function() return 1000 end
UpdateAddOnMemoryUsage = function() end
WOW_PROJECT_ID, WOW_PROJECT_MAINLINE = 1, 1
BreakUpLargeNumbers = function(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (out:gsub("^,", ""):gsub("^%-,", "-"))
end
SecondsToTime = function(s) return string.format("%d min", math.floor(s / 60)) end
GetCoinTextureString = function(c) return string.format("%dg", math.floor(c / 10000)) end
GetMoneyString = GetCoinTextureString
FormatLargeNumber = BreakUpLargeNumbers
hooksecurefunc = function(a, b, c)
    local t, name, fn = _G, a, b
    if type(a) == "table" then t, name, fn = a, b, c end
    local old = t[name] or function() end
    t[name] = function(...)
        local r = { old(...) }
        fn(...)
        return unpack(r)
    end
end
YES, NO, OKAY, CANCEL, ACCEPT, CLOSE = "Yes", "No", "Okay", "Cancel", "Accept", "Close"
STANDARD_TEXT_FONT = "Fonts\\FRIZQT__.TTF"
RAID_CLASS_COLORS = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1, colorStr = "ffffffff",
    GenerateHexColor = function() return "ffffffff" end, WrapTextInColorCode = function(_, t) return t end } end })
ITEM_QUALITY_COLORS = setmetatable({}, { __index = function() return { r = 1, g = 1, b = 1, hex = "|cffffffff" } end })
NORMAL_FONT_COLOR = { r = 1, g = 0.82, b = 0, GetRGB = function() return 1, 0.82, 0 end }
HIGHLIGHT_FONT_COLOR = { r = 1, g = 1, b = 1, GetRGB = function() return 1, 1, 1 end }
CreateColor = function(r, g, b, a)
    return { r = r, g = g, b = b, a = a, GetRGB = function() return r, g, b end, GetRGBA = function() return r, g, b, a end,
        WrapTextInColorCode = function(_, t) return t end, GenerateHexColor = function() return "ffffffff" end }
end
WrapTextInColorCode = function(t) return t end
CreateAtlasMarkup = function() return "" end
CreateTextureMarkup = function() return "" end
Enum = setmetatable({
    ItemQuality = { Poor = 0, Common = 1, Uncommon = 2, Rare = 3, Epic = 4, Legendary = 5 },
    ItemClass = { Consumable = 0, Container = 1, Weapon = 2, Gem = 3, Armor = 4, Reagent = 5, Projectile = 6,
        Tradegoods = 7, ItemEnhancement = 8, Recipe = 9, Battlepet = 17, Profession = 19 },
    BagIndex = { Backpack = 0, ReagentBag = 5, Bank = -1, AccountBankTab_1 = 12 },
    TradeskillRecipeType = { Item = 1, Salvage = 2, Enchant = 3, Recraft = 4, Gathering = 5 },
    CraftingReagentType = { Modifying = 0, Basic = 1, Finishing = 2, Automatic = 3 },
    AuctionHouseTimeLeftBand = { Short = 0, Medium = 1, Long = 2, VeryLong = 3 },
    BankType = { Character = 0, Guild = 1, Account = 2 },
    PlayerInteractionType = setmetatable({}, { __index = function(_, k) return k end }),
}, { __index = function() return setmetatable({}, { __index = function(_, k) return k end }) end })

---------------------------------------------------------------------------
-- The player
---------------------------------------------------------------------------
UnitName = function(unit) if unit == "player" then return world.player.name end return nil end
UnitFullName = function(unit) return world.player.name, world.player.realm end
UnitClass = function() return world.player.class, world.player.class, world.player.classID end
UnitGUID = function() return "Player-0-00000001" end
UnitLevel = function() return 90 end
UnitRace = function() return "Human", "Human" end
UnitFactionGroup = function() return "Horde" end
UnitExists = function(u) return u == "player" end
UnitIsDeadOrGhost = function() return false end
UnitCastingInfo = function() return nil end
UnitChannelInfo = function() return nil end
GetRealmName = function() return world.player.realm end
GetNormalizedRealmName = function() return (world.player.realm:gsub("[%s%-]", "")) end
GetAutoCompleteRealms = function() return {} end
GetMoney = function() return world.money end
GetProfessions = function() return nil end
GetProfessionInfo = function() return nil end
GetInventoryItemID = function() return nil end
GetInventoryItemLink = function() return nil end
EquipCursorItem = function() end
GetSpellInfo = function(id) return world.spells[id] end
IsSpellKnown = function() return false end
IsPlayerSpell = function() return false end

---------------------------------------------------------------------------
-- Items and bags
---------------------------------------------------------------------------
local function ItemOf(id)
    if type(id) == "string" then
        local n = tonumber(id:match("item:(%d+)")) or tonumber(id)
        if n then return world.items[n], n end
        for iid, it in pairs(world.items) do if it.name == id then return it, iid end end
        return nil
    end
    return world.items[id], id
end
local function ItemLink(id)
    local it = world.items[id]
    return it and string.format("|cffffffff|Hitem:%d::::::::90:::::|h[%s]|h|r", id, it.name) or nil
end
_G.BenchItemLink = ItemLink

local function Count(id, bank, _, _, warband)
    local n = world.bags[id] or 0
    if bank then n = n + (world.bank[id] or 0) end
    if warband then n = n + (world.warband[id] or 0) end
    return n
end

-- Bag slots (all in bag 0) are built from world.bags: one slot per full
-- stack (the item's `stack`, default 1000), or the sizes in
-- world.stacks[itemID] = { 7, 20 } first. A stack split off into an empty
-- slot is kept apart in world.splits[slot] = { itemID, count, lockedUntil }
-- (still counted in world.bags), as the game puts it in its own slot.
world.stacks, world.splits = {}, {}
local function BagSlots()
    local slots = {}
    local ids = {}
    for id, n in pairs(world.bags) do if n > 0 then table.insert(ids, id) end end
    table.sort(ids)
    local apart = {}
    for _, s in pairs(world.splits) do apart[s[1]] = (apart[s[1]] or 0) + s[2] end
    for _, id in ipairs(ids) do
        local left = world.bags[id] - (apart[id] or 0)
        for _, size in ipairs(world.stacks[id] or {}) do
            if left <= 0 then break end
            local n = math.min(size, left)
            table.insert(slots, { itemID = id, stackCount = n })
            left = left - n
        end
        while left > 0 do
            local n = math.min(left, (world.items[id] and world.items[id].stack) or 1000)
            table.insert(slots, { itemID = id, stackCount = n })
            left = left - n
        end
    end
    return slots
end
local function SlotAt(bag, slot)
    if bag ~= 0 then return nil end
    local s = world.splits[slot]
    if s then return { itemID = s[1], stackCount = s[2], locked = (s[3] or 0) > world.clock, split = true } end
    return BagSlots()[slot]
end
local function NumSlots()
    local n = math.max(16, #BagSlots() + 8)
    for slot in pairs(world.splits) do n = math.max(n, slot) end
    return n
end

C_Item = {
    GetItemCount = Count,
    GetItemNameByID = function(id) local it = ItemOf(id) return it and it.name end,
    GetItemName = function(loc) local it = ItemOf(loc and loc.itemID or loc) return it and it.name end,
    GetItemInfo = function(id)
        local it, iid = ItemOf(id)
        if not it then return nil end
        return it.name, ItemLink(iid), it.quality or 1, it.level or 1, 1, "Tradeskill", "Reagent",
            it.stack or 1000, "", it.icon or 134400, it.sellPrice or 0, it.classID or 7, it.subclassID or 0,
            it.bind or 0, it.expansion or 11
    end,
    GetItemInfoInstant = function(id)
        local it, iid = ItemOf(id)
        if not iid then return nil end
        it = it or {}
        return iid, "Tradeskill", "Reagent", "", it.icon or 134400, it.classID or 7, it.subclassID or 0
    end,
    GetItemIconByID = function(id) local it = ItemOf(id) return it and it.icon or 134400 end,
    GetItemQualityByID = function(id) local it = ItemOf(id) return it and it.quality or 1 end,
    GetItemID = function(loc) return loc and loc.itemID end,
    GetItemGUID = function(loc) return loc and ("Item-" .. tostring(loc.itemID)) end,
    GetItemIDByGUID = function(guid) return tonumber(tostring(guid):match("Item%-(%d+)")) end,
    GetItemLink = function(loc) return loc and ItemLink(loc.itemID) end,
    GetCurrentItemLevel = function() return 1 end,
    DoesItemExist = function(loc) return loc and loc.itemID ~= nil end,
    DoesItemExistByID = function(id) return ItemOf(id) ~= nil end,
    IsItemDataCachedByID = function(id) return ItemOf(id) ~= nil end,
    RequestLoadItemDataByID = function() end,
    IsEquippableItem = function() return false end,
    GetItemSpell = function() return nil end,
    GetItemClassInfo = function() return "Tradeskill" end,
    GetItemSubClassInfo = function() return "Other" end,
    GetItemMaxStackSizeByID = function(id) local it = ItemOf(id) return it and it.stack or 1000 end,
    IsBound = function() return false end,
}
GetItemInfo = C_Item.GetItemInfo
GetItemCount = C_Item.GetItemCount
GetItemIcon = C_Item.GetItemIconByID
ItemLocation = {
    CreateFromBagAndSlot = function(_, bag, slot)
        local s = SlotAt(bag, slot)
        return { bag = bag, slot = slot, itemID = s and s.itemID, IsValid = function() return s ~= nil end,
            GetBagAndSlot = function() return bag, slot end }
    end,
    CreateFromEquipmentSlot = function() return { IsValid = function() return false end } end,
}
Item = {
    CreateFromItemID = function(_, id)
        return { ContinueOnItemLoad = function(_, fn) fn() end, GetItemName = function() return C_Item.GetItemNameByID(id) end,
            GetItemID = function() return id end, IsItemEmpty = function() return ItemOf(id) == nil end,
            GetItemLink = function() return ItemLink(id) end }
    end,
}
Item.CreateFromItemLink = function(_, link) return Item.CreateFromItemID(nil, tonumber(link:match("item:(%d+)"))) end

C_Container = {
    GetContainerNumSlots = function(bag) if bag == 0 then return NumSlots() end return 0 end,
    GetContainerItemInfo = function(bag, slot)
        local s = SlotAt(bag, slot)
        if not s then return nil end
        return { itemID = s.itemID, stackCount = s.stackCount, hyperlink = ItemLink(s.itemID), iconFileID = 134400,
            quality = 1, isLocked = s.locked == true, isBound = false }
    end,
    GetContainerItemID = function(bag, slot) local s = SlotAt(bag, slot) return s and s.itemID end,
    GetContainerItemLink = function(bag, slot) local s = SlotAt(bag, slot) return s and ItemLink(s.itemID) end,
    GetContainerNumFreeSlots = function() return 20, 0 end,
    -- With something on the cursor and an empty slot: put it down there (a
    -- split lands as its own stack, locked for a moment). Else pick it up.
    PickupContainerItem = function(bag, slot)
        Record("PickupContainerItem", bag, slot)
        local s = SlotAt(bag, slot)
        if world.cursor and not s and bag == 0 then
            world.splits[slot] = { world.cursor.itemID, world.cursor.count, world.clock + 0.2 }
            world.cursor = nil
            C_Timer.After(0.2, function() _G.BenchFire("BAG_UPDATE_DELAYED") end)
            return
        end
        world.cursor = s and { itemID = s.itemID, count = s.stackCount, slot = s.split and slot or nil } or nil
    end,
    -- On the cursor, but the game still thinks of it as the stack it came
    -- from: attached to a mail straight away, the whole stack goes in
    SplitContainerItem = function(bag, slot, n)
        Record("SplitContainerItem", bag, slot, n)
        local s = SlotAt(bag, slot)
        world.cursor = s and { itemID = s.itemID, count = math.min(n, s.stackCount), wholeStack = s.stackCount } or nil
    end,
    UseContainerItem = function(bag, slot) Record("UseContainerItem", bag, slot) end,
    GetBagName = function() return "Bag" end,
}
C_Bank = { FetchDepositedMoney = function() return world.warbandMoney or 0 end, CanUseBank = function() return false end }
C_PlayerInteractionManager = { IsInteractingWithNpcOfType = function() return false end }
C_TooltipInfo = setmetatable({}, { __index = function() return function() return { lines = {} } end end })
TooltipDataProcessor = { AddTooltipPostCall = function() end }
TooltipUtil = { SurfaceArgs = function() end }

---------------------------------------------------------------------------
-- Spells, buffs, currencies, addons
---------------------------------------------------------------------------
C_Spell = {
    GetSpellName = function(id) return world.spells[id] end,
    GetSpellInfo = function(id) local n = world.spells[id] return n and { name = n, spellID = id } end,
    GetSpellCharges = function() return nil end,
    GetSpellCooldown = function() return { startTime = 0, duration = 0 } end,
    GetSpellBaseCooldown = function() return 0 end,
    GetSpellTexture = function() return 134400 end,
}
C_UnitAuras = {
    GetAuraDataByIndex = function(_, i) local b = world.buffs[i] return b and { name = b.name, spellId = b.spellId } end,
    GetPlayerAuraBySpellID = function(id) for _, b in ipairs(world.buffs) do if b.spellId == id then return b end end end,
}
C_CurrencyInfo = {
    GetCurrencyInfo = function(id)
        local c = world.currencies and world.currencies[id]
        return c and { name = c.name or "Concentration", quantity = c.quantity or 0, maxQuantity = c.max or 1000,
            rechargingAmountPerCycle = 0, rechargingCycleDurationMS = 0 }
    end,
}
C_AddOns = {
    IsAddOnLoaded = function(n) return n == "Goldsmith" end,
    GetNumAddOns = function() return 1 end,
    GetAddOnInfo = function() return "Goldsmith", "Goldsmith", "", true end,
    GetAddOnMetadata = function(_, key)
        if key == "Version" then return world.version or "bench" end
        return nil
    end,
    LoadAddOn = function() return false end,
    GetAddOnEnableState = function() return 2 end,
}
IsAddOnLoaded = C_AddOns.IsAddOnLoaded
C_ChatInfo = { RegisterAddonMessagePrefix = function() return true end, SendAddonMessage = function() end }
C_Map = { GetBestMapForUnit = function() return 0 end, GetMapInfo = function() return { name = "Silvermoon" } end }
GetZoneText = function() return "Silvermoon City" end
GetSubZoneText = function() return "" end
C_DateAndTime = { GetCurrentCalendarTime = function() local d = date("*t") return { year = d.year, month = d.month,
    monthDay = d.day, hour = d.hour, minute = d.min, weekday = d.wday } end,
    GetSecondsUntilWeeklyReset = function() return 3 * 86400 end, GetSecondsUntilDailyReset = function() return 43200 end }
C_EncodingUtil = nil

---------------------------------------------------------------------------
-- Professions (answers come from world.recipeInfo / schematics / operations)
---------------------------------------------------------------------------
C_TradeSkillUI = {
    GetRecipeInfo = function(id) return world.recipeInfo[id] end,
    GetRecipeSchematic = function(id) return world.schematics[id] end,
    GetCraftingOperationInfo = function(id, reagents, guid, conc)
        local op = world.operations[id]
        if type(op) == "function" then return op(reagents, guid, conc) end
        return op
    end,
    GetAllRecipeIDs = function() local t = {} for id in pairs(world.recipeInfo) do table.insert(t, id) end return t end,
    GetBaseProfessionInfo = function() return world.openProfession end,
    GetChildProfessionInfo = function() return world.openProfession end,
    GetProfessionInfoBySkillLineID = function() return world.openProfession end,
    GetTradeSkillLineForRecipe = function() return nil end,
    GetRecipeOutputItemData = function(id) local s = world.schematics[id] return s and { itemID = s.outputItemID } end,
    GetRecipeRequirements = function() return {} end,
    GetRecipeCooldown = function() return nil end,
    GetRecipeSourceText = function() return nil end,
    GetQualitiesForRecipe = function() return nil end,
    GetSalvagableItemIDs = function() return {} end,
    GetItemReagentQualityByItemInfo = function(id) local it = ItemOf(id) return it and it.tier end,
    GetItemCraftedQualityByItemInfo = function(id) local it = ItemOf(id) return it and it.tier end,
    GetReagentSlotStatus = function() return false end,
    IsRecipeRepeating = function() return false end,
    IsTradeSkillReady = function() return world.openProfession ~= nil end,
    IsTradeSkillLinked = function() return false end,
    IsTradeSkillGuild = function() return false end,
    IsNPCCrafting = function() return false end,
    IsRuneforging = function() return false end,
    OpenRecipe = function(id) Record("OpenRecipe", id) end,
    OpenTradeSkill = function(id) Record("OpenTradeSkill", id) return true end,
    CloseTradeSkill = function() end,
    SetRecipeItemNameFilter = function() end,
    CraftRecipe = function(id, n, reagents, level, guid, conc) Record("CraftRecipe", id, n or 1, conc and "conc" or "") end,
    CraftSalvage = function(id, n, loc) Record("CraftSalvage", id, n or 1) end,
    CraftEnchant = function(id, n) Record("CraftEnchant", id, n or 1) end,
    GetProfessionChildSkillLineID = function() return 0 end,
    GetProfessionSkillLineID = function() return 0 end,
}
C_CraftingOrders = { GetClaimedOrder = function() return nil end, GetCrafterOrders = function() return {} end }
C_ProfSpecs = setmetatable({}, { __index = function() return function() return nil end end })
Professions = { GetProfessionInfo = function() return nil end }
ProfessionsUtil = setmetatable({}, { __index = function() return function() return nil end end })

---------------------------------------------------------------------------
-- The auction house
---------------------------------------------------------------------------
C_AuctionHouse = {
    IsThrottledMessageSystemReady = function() return world.ahReady ~= false end,
    StartCommoditiesPurchase = function(id, n) Record("StartCommoditiesPurchase", id, n) end,
    ConfirmCommoditiesPurchase = function(id, n) Record("ConfirmCommoditiesPurchase", id, n) end,
    CancelCommoditiesPurchase = function() Record("CancelCommoditiesPurchase") end,
    PostCommodity = function(loc, dur, n, price) Record("PostCommodity", loc and loc.itemID, n, price) end,
    PostItem = function(loc, dur, n, bid, buyout) Record("PostItem", loc and loc.itemID, n, buyout) end,
    SendSearchQuery = function(key) Record("SendSearchQuery", key and key.itemID) end,
    SendBrowseQuery = function() Record("SendBrowseQuery") end,
    ReplicateItems = function() Record("ReplicateItems") end,
    GetNumReplicateItems = function() return 0 end,
    MakeItemKey = function(id, level, suffix, pet) return { itemID = id, itemLevel = level or 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
    GetItemKeyInfo = function(key) local it = key and world.items[key.itemID] return it and { itemName = it.name, isCommodity = true } end,
    GetNumCommoditySearchResults = function(id) return #(world.commodities[id] or {}) end,
    GetCommoditySearchResultInfo = function(id, i)
        local r = (world.commodities[id] or {})[i]
        return r and { itemID = id, unitPrice = r[1], quantity = r[2], numOwnerItems = 0, auctionID = i }
    end,
    HasFullCommoditySearchResults = function() return true end,
    RequestMoreCommoditySearchResults = function() return false end,
    GetBrowseResults = function() return {} end,
    HasFullBrowseResults = function() return true end,
    RequestMoreBrowseResults = function() end,
    QueryOwnedAuctions = function() Record("QueryOwnedAuctions") end,
    GetOwnedAuctions = function() return world.ownedAuctions or {} end,
    GetNumOwnedAuctions = function() return #(world.ownedAuctions or {}) end,
    CalculateItemDeposit = function() return 0 end,
    CalculateCommodityDeposit = function() return 0 end,
    GetAuctionHouseFee = function() return 0.05 end,
    GetReplicateItemInfo = function() return nil end,
    GetReplicateItemLink = function() return nil end,
    GetItemSearchResultInfo = function() return nil end,
    GetNumItemSearchResults = function() return 0 end,
    CloseAuctionHouse = function() end,
}
C_AuctionHouse.GetAvailablePostCount = function(loc) return loc and world.bags[loc.itemID] or 0 end
AuctionHouseUtil = setmetatable({}, { __index = function() return function() return nil end end })

---------------------------------------------------------------------------
-- Vendors and mail
---------------------------------------------------------------------------
C_MerchantFrame = {
    GetItemInfo = function(i) local m = world.merchant[i] return m and { name = m.name, price = m.price,
        stackCount = m.stack or 1, numAvailable = m.numAvailable or -1, isPurchasable = true, isUsable = true } end,
    GetNumJunkItems = function() return 0 end,
    IsMerchantItemRefundable = function() return false end,
}
GetMerchantNumItems = function() return #world.merchant end
GetMerchantItemInfo = function(i) local m = world.merchant[i] if not m then return nil end
    return m.name, 134400, m.price, m.stack or 1, m.numAvailable or -1, true, true, 0 end
GetMerchantItemID = function(i) local m = world.merchant[i] return m and m.itemID end
GetMerchantItemLink = function(i) local m = world.merchant[i] return m and ItemLink(m.itemID) end
GetMerchantItemMaxStack = function(i) local m = world.merchant[i] return m and (m.maxStack or 1000) or 0 end
GetMerchantItemCostInfo = function() return 0 end
BuyMerchantItem = function(i, n) Record("BuyMerchantItem", i, n or 1) end
CanMerchantRepair = function() return false end

world.inbox = {}       -- { { sender, subject, money, items = { {itemID, count} } }, ... }
world.sendItems = {}   -- attachment index -> { itemID, count }
GetInboxNumItems = function() return #world.inbox, #world.inbox end
GetInboxHeaderInfo = function(i)
    local m = world.inbox[i]
    if not m then return nil end
    return nil, nil, m.sender, m.subject, m.money or 0, 0, 30, m.items and #m.items or 0, true, false, false, false, false, false
end
GetInboxItem = function(i, a) local it = world.inbox[i] and world.inbox[i].items and world.inbox[i].items[a]
    if not it then return nil end return world.items[it[1]] and world.items[it[1]].name, it[1], 134400, it[2] end
GetInboxItemLink = function(i, a) local it = world.inbox[i] and world.inbox[i].items and world.inbox[i].items[a]
    return it and ItemLink(it[1]) end
GetInboxInvoiceInfo = function(i) local m = world.inbox[i] if not m or not m.invoice then return nil end
    return m.invoice.type, m.invoice.item, m.invoice.buyer, m.invoice.bid, 0, m.invoice.deposit or 0, m.invoice.fee or 0, 0, 0, 0, m.invoice.count end
GetInboxText = function() return "" end
TakeInboxMoney = function(i) Record("TakeInboxMoney", i) end
TakeInboxItem = function(i, a) Record("TakeInboxItem", i, a) end
AutoLootMailItem = function(i) Record("AutoLootMailItem", i) end
CheckInbox = function() end
GetSendMailItem = function(i) local s = world.sendItems[i] if not s then return nil end
    return world.items[s[1]] and world.items[s[1]].name, s[1], 134400, s[2] end
GetSendMailItemLink = function(i) local s = world.sendItems[i] return s and ItemLink(s[1]) end
GetSendMailMoney = function() return 0 end
GetSendMailPrice = function() return 30 end
-- Attaching puts the item on the cursor into the slot; sending takes the
-- attachments out of the bags a moment later, as the game does
ClickSendMailItemButton = function(i, clear)
    Record("ClickSendMailItemButton", i, clear and "clear" or nil)
    if clear then
        world.sendItems[i] = nil
        C_Timer.After(0, function() _G.BenchFire("MAIL_SEND_INFO_UPDATE") end)
    elseif world.cursor then
        -- A split straight from its stack: the game attaches the whole stack
        -- (7 Azeroot went for 3 in game, 2026-10-24)
        local c = world.cursor
        world.sendItems[i] = { c.itemID, c.wholeStack or c.count, c.slot }
        world.cursor = nil
        C_Timer.After(0, function() _G.BenchFire("MAIL_SEND_INFO_UPDATE") end)
    end
end
SendMail = function(to, subject, body)
    Record("SendMail", to, subject)
    local sent = world.sendItems
    world.sentMail = world.sentMail or {}
    table.insert(world.sentMail, { to = to, subject = subject, items = sent })
    C_Timer.After(0.5, function()
        world.sendItems = {}
        for _, it in pairs(sent) do
            world.bags[it[1]] = (world.bags[it[1]] or 0) - it[2]
            if world.bags[it[1]] <= 0 then world.bags[it[1]] = nil end
            if it[3] then world.splits[it[3]] = nil end
        end
        _G.BenchFire("MAIL_SEND_SUCCESS")
        _G.BenchFire("BAG_UPDATE_DELAYED")
    end)
end
SetSendMailMoney = function() end
ATTACHMENTS_MAX_SEND = 12
ATTACHMENTS_MAX_RECEIVE = 16
MailFrameTab_OnClick = function() end
CanSendAuctionQuery = function() return true end

---------------------------------------------------------------------------
-- Loot
---------------------------------------------------------------------------
GetNumLootItems = function() return 0 end
GetLootSourceInfo = function() return nil end
GetLootSlotInfo = function() return nil end
GetLootSlotLink = function() return nil end

---------------------------------------------------------------------------
-- Timers and events
---------------------------------------------------------------------------
local timers = {}
local seq = 0
local function AddTimer(delay, fn, repeats, handle)
    seq = seq + 1
    local t = { at = world.clock + math.max(delay or 0, 0), fn = fn, every = repeats and math.max(delay, 0.01),
        seq = seq, handle = handle }
    table.insert(timers, t)
    return t
end
local function TimerHandle()
    local h = {}
    h.Cancel = function() h._cancelled = true end
    h.IsCancelled = function() return h._cancelled == true end
    return h
end
C_Timer = {
    After = function(d, fn) AddTimer(d, fn) end,
    NewTimer = function(d, fn) local h = TimerHandle() AddTimer(d, function() fn(h) end, false, h) return h end,
    NewTicker = function(d, fn, n)
        local h = TimerHandle()
        local left = n
        local t = AddTimer(d, nil, true, h)
        t.fn = function()
            fn(h)
            if left then left = left - 1 if left <= 0 then h:Cancel() end end
        end
        return h
    end,
}

-- Runs the timers due by now + seconds, in time order. OnUpdate scripts
-- run once per step (steps of 0.1 s, at most 50 per call, so a long
-- Advance doesn't spin through every frame)
local function Advance(seconds)
    local target = world.clock + (seconds or 0)
    local steps = 0
    while true do
        table.sort(timers, function(a, b) if a.at ~= b.at then return a.at < b.at end return a.seq < b.seq end)
        local t = timers[1]
        if not t or t.at > target then break end
        table.remove(timers, 1)
        if t.at > world.clock then world.clock = t.at end
        if not (t.handle and t.handle._cancelled) then
            Protected("timer", t.fn)
            if t.every and not (t.handle and t.handle._cancelled) then
                t.at = world.clock + t.every
                seq = seq + 1
                t.seq = seq
                table.insert(timers, t)
            end
        end
        steps = steps + 1
        if steps > 100000 then error("timers never settle (a ticker every frame?)") end
    end
    world.clock = target
    local updates = math.min(50, math.max(1, math.floor((seconds or 0) / 0.1)))
    for _ = 1, updates do
        for _, f in ipairs(frames) do
            local fn = f._scripts.OnUpdate
            if fn and f:IsVisible() then Protected("OnUpdate", fn, f, 0.1) end
        end
    end
end

local function Fire(event, ...)
    for _, f in ipairs(frames) do
        if f._events[event] and f._scripts.OnEvent then
            Protected(event, f._scripts.OnEvent, f, event, ...)
        end
    end
end

_G.BenchFire = Fire

-- The mail window's tabs
MailFrameTab2:SetScript("OnClick", function() InboxFrame:Hide() SendMailFrame:Show() end)

return { world = world, Fire = Fire, Advance = Advance, Widget = Widget, frames = frames, named = named,
    Strip = Strip, Protected = Protected, ItemLink = ItemLink, Record = Record }
