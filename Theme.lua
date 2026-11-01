local addon = _G.Goldsmith or {}

-- Theme
--
-- Every color and font the window uses. A different look (a WoW-style
-- theme, say) is another table in addon.themes, not changes all over the
-- UI code. Colors are named by what they mean, not what they look like:
--   profit  = profit or a good deal      loss    = a loss
--   conc    = concentration              warning = stale price, slow seller,
--   muted   = secondary information                held too long

local function Hex(hex, alpha)
    return {
        tonumber(hex:sub(1, 2), 16) / 255,
        tonumber(hex:sub(3, 4), 16) / 255,
        tonumber(hex:sub(5, 6), 16) / 255,
        alpha or 1,
    }
end

addon.themes = {
    clean = {
        colors = {
            window      = Hex("17181d", 0.97),
            -- Pop-ups over the window (Settings, Help, Support, Bug report):
            -- solid, so their text never sits over the list behind
            dialog      = Hex("17181d"),
            header      = Hex("24252c"),
            panel       = Hex("1f2027"),
            -- Panels on their own by the game's windows (queue, AH,
            -- mailbox, vendor)
            floating    = Hex("1f2027"),
            panelRaised = Hex("26272e"),
            highlight   = Hex("26221a"),
            border      = Hex("2c2d34"),
            borderStrong = Hex("3a3b44"),
            borderGold  = Hex("4a3f1f"),
            hover       = Hex("ffffff", 0.06),

            text        = Hex("ece7da"),
            muted       = Hex("9a9ca6"),
            dim         = Hex("7c7e88"),
            gold        = Hex("e8c25a"),
            -- The expansion after a craft's name (Crafts): its own
            -- color, so it still reads on a greyed-out row
            expansion   = Hex("7fa7d9"),
            -- What clicking does, at the end of hovers, one color per kind
            -- everywhere: click blue, right-click lavender, shift-click
            -- peach. Not green, so they never run into an item's green
            -- Use/Equip text or a profit.
            hint        = Hex("9cc3ef"),
            hintRight   = Hex("c4adef"),
            hintShift   = Hex("efb79c"),

            profit      = Hex("5fcf7b"),
            loss        = Hex("e5645a"),
            conc        = Hex("e8c25a"),
            warning     = Hex("e59a3a"),
            bar         = Hex("3f9e5a"),
            band        = Hex("e8c25a", 0.10),
            bandLine    = Hex("e8c25a", 0.35),
            line        = Hex("b48be0"),
            barEmpty    = Hex("3a3b44"),
            -- Quality stripes on Crafts rows (TierColor), so silver and gold
            -- rows differ at a glance and not only by the small icon
            tierTop     = Hex("e8c25a"),
            tierMid     = Hex("b08d57"),
            tierLow     = Hex("aeb3bc"),
        },
        -- { file, size, flags, color }
        fonts = {
            title   = { "Fonts\\FRIZQT__.TTF", 17, "", "gold" },
            heading = { "Fonts\\FRIZQT__.TTF", 13, "", "gold" },
            tab     = { "Fonts\\FRIZQT__.TTF", 12, "", "muted" },
            body    = { "Fonts\\ARIALN.TTF", 14, "", "text" },
            small   = { "Fonts\\ARIALN.TTF", 12, "", "muted" },
            label   = { "Fonts\\ARIALN.TTF", 11, "", "muted" },
            value   = { "Fonts\\ARIALN.TTF", 18, "", "text" },
            big     = { "Fonts\\ARIALN.TTF", 24, "", "text" },
            close   = { "Fonts\\ARIALN.TTF", 22, "", "muted" },
            button  = { "Fonts\\ARIALN.TTF", 12, "", "text" },
        },
        texture = "Interface\\Buttons\\WHITE8x8",
    },

    -- World of Warcraft: made to look like the game's own windows, so
    -- Goldsmith doesn't read as an addon (user, 2026-10-31; experiment).
    -- game = true swaps in Blizzard's art where the widgets allow it: the
    -- window frame, red buttons, tabs under the window (Window.lua,
    -- Widgets.lua). Colors are the game's font colors.
    game = {
        game = true,
        colors = {
            -- The game's frame art is behind the window
            window      = Hex("000000", 0),
            dialog      = Hex("0b0b0d", 0.96),
            header      = Hex("000000", 0),
            panel       = Hex("000000", 0.35),
            -- Nothing behind them but the world: near solid, like the
            -- game's tooltips (user, 2026-10-31: too see-through)
            floating    = Hex("0b0b0d", 0.95),
            panelRaised = Hex("000000", 0.5),
            highlight   = Hex("2a2208", 0.6),
            -- The thin grey line of the Collections tiles
            border      = Hex("5e5e5e"),
            borderStrong = Hex("7a7a7a"),
            borderGold  = Hex("ffd100"),
            hover       = Hex("ffffff", 0.08),

            text        = Hex("ffffff"),
            muted       = Hex("a5a5a5"),
            dim         = Hex("808080"),
            gold        = Hex("ffd100"),
            expansion   = Hex("71d5ff"),
            hint        = Hex("71d5ff"),
            hintRight   = Hex("c4adef"),
            hintShift   = Hex("efb79c"),

            profit      = Hex("1eff00"),
            loss        = Hex("ff2020"),
            conc        = Hex("ffd100"),
            warning     = Hex("ff8000"),
            bar         = Hex("1eaa00"),
            band        = Hex("ffd100", 0.10),
            bandLine    = Hex("ffd100", 0.35),
            line        = Hex("a335ee"),
            barEmpty    = Hex("404040"),
            tierTop     = Hex("ffd100"),
            tierMid     = Hex("b08d57"),
            tierLow     = Hex("aeb3bc"),
        },
        -- Friz Quadrata everywhere, at the sizes of GameFontNormal and
        -- friends
        fonts = {
            title   = { "Fonts\\FRIZQT__.TTF", 14, "", "gold" },
            heading = { "Fonts\\FRIZQT__.TTF", 13, "", "gold" },
            tab     = { "Fonts\\FRIZQT__.TTF", 12, "", "muted" },
            body    = { "Fonts\\FRIZQT__.TTF", 12, "", "text" },
            small   = { "Fonts\\FRIZQT__.TTF", 11, "", "muted" },
            label   = { "Fonts\\FRIZQT__.TTF", 10, "", "muted" },
            value   = { "Fonts\\FRIZQT__.TTF", 16, "", "text" },
            big     = { "Fonts\\FRIZQT__.TTF", 20, "", "text" },
            close   = { "Fonts\\FRIZQT__.TTF", 18, "", "muted" },
            button  = { "Fonts\\FRIZQT__.TTF", 12, "", "gold" },
        },
        texture = "Interface\\Buttons\\WHITE8x8",
        -- Bordered boxes get the game's tooltip edge instead of a 1px line
        edge = "Interface\\Tooltips\\UI-Tooltip-Border",
        edgeSize = 12,
        inset = 3,
    },
}

-- Alliance and Horde (user, 2026-10-31): the World of Warcraft look in the
-- faction's colors: the window's frame tinted (frameTint), its crest faint
-- behind the screens (emblem; Window.lua), highlights, panels and the
-- price band in its colors. Text keeps the game's gold, as the game's own
-- faction windows do.
local function Faction(colors, extra)
    local theme = {}
    for k, v in pairs(addon.themes.game) do theme[k] = v end
    theme.colors = {}
    for k, v in pairs(addon.themes.game.colors) do theme.colors[k] = v end
    for k, v in pairs(colors) do theme.colors[k] = v end
    for k, v in pairs(extra) do theme[k] = v end
    return theme
end
--
-- Round 2 (user, 2026-10-31: "MORE alliance themed", needn't stay looking
-- like Blizzard): frameLayout swaps the window's frame for the faction's
-- ornate one from the BfA mission table (with our own ring round the
-- portrait, Media\Ring); buttonTint recolors the red buttons (Alliance
-- royal blue); tabs take the frame's tint; insetWash is the faction's
-- color washed down from the top of the screens' panel; the crest is
-- bigger and stronger (emblemSize, emblemAlpha); chart bars in its color.
addon.themes.alliance = Faction({
    panel       = Hex("000a1a", 0.4),
    floating    = Hex("060d1c", 0.95),
    highlight   = Hex("0b1f45", 0.65),
    band        = Hex("4a90e2", 0.12),
    bandLine    = Hex("4a90e2", 0.45),
    bar         = Hex("3d7be0"),
}, {
    faction = "Alliance", frameTint = { 0.62, 0.76, 1 }, emblem = "Interface\\Timer\\Alliance-Logo",
    frameLayout = "BFAMissionAlliance", ringColor = { 1, 0.82, 0.3 },
    buttonTint = { 0.35, 0.55, 1 }, insetWash = { 0.12, 0.3, 0.75, 0.45 },
    emblemSize = 400, emblemAlpha = 0.14,
})
addon.themes.horde = Faction({
    panel       = Hex("1a0402", 0.4),
    floating    = Hex("140504", 0.95),
    highlight   = Hex("3d0c06", 0.65),
    borderGold  = Hex("d23a22"),
    band        = Hex("d23a22", 0.12),
    bandLine    = Hex("d23a22", 0.45),
    -- Bronze, not red: red is a loss (user, 2026-11-01)
    bar         = Hex("b8862f"),
}, {
    faction = "Horde", frameTint = { 1, 0.62, 0.55 }, emblem = "Interface\\Timer\\Horde-Logo",
    frameLayout = "BFAMissionHorde", ringColor = { 0.75, 0.55, 0.4 },
    insetWash = { 0.6, 0.1, 0.05, 0.45 },
    emblemSize = 400, emblemAlpha = 0.14,
})

addon.theme = addon.themes.clean

-- The look is picked once, when Goldsmith loads, before the window is made
-- (Core.lua, Initialize; Settings > Display > Theme): every frame takes its
-- colors when it's made, so a change shows after a reload. Match my
-- faction: the character's (a Pandaren yet to choose gets the game's).
function addon:PickTheme()
    local choice = addon:Setting("theme")
    if choice == "faction" then
        local faction = UnitFactionGroup("player")
        choice = faction == "Alliance" and "alliance" or faction == "Horde" and "horde" or "game"
    end
    addon.theme = addon.themes[choice] or addon.themes.clean
end

-- The game's frame art (a NineSlice, a tab) in the faction's tint, if the
-- look has one. Textures only: a tab's name keeps its color.
function addon:TintFrameArt(nineSlice, tint)
    tint = tint or addon.theme.frameTint
    if not (tint and nineSlice) then return end
    for _, region in ipairs({ nineSlice:GetRegions() }) do
        if region:GetObjectType() == "Texture" then
            if tint.desaturate then region:SetDesaturated(true) end
            region:SetVertexColor(tint[1], tint[2], tint[3])
        end
    end
end

-- The faction's own frame instead of the game's plain one (frameLayout).
-- True when it took; the plain frame stays (tinted) if the game hasn't got
-- the layout.
function addon:ApplyFactionFrame(nineSlice)
    local layout = addon.theme.frameLayout
    if not (layout and nineSlice and NineSliceUtil and NineSliceUtil.ApplyLayoutByName) then return false end
    local ok = pcall(NineSliceUtil.ApplyLayoutByName, nineSlice, layout)
    return ok
end

-- r, g, b, a of a theme color
function addon:Color(name)
    local c = addon.theme.colors[name] or addon.theme.colors.text
    return c[1], c[2], c[3], c[4]
end

-- Text wrapped in a theme color's escape code
function addon:Colorize(text, name)
    local r, g, b = addon:Color(name)
    return string.format("|cff%02x%02x%02x%s|r", r * 255, g * 255, b * 255, text)
end

-- Font object for a theme font, created on first use
local fontObjects = {}
function addon:Font(name)
    if fontObjects[name] then return fontObjects[name] end
    local spec = addon.theme.fonts[name] or addon.theme.fonts.body
    local font = CreateFont("GoldsmithFont_" .. name)
    font:SetFont(spec[1], spec[2], spec[3])
    font:SetTextColor(addon:Color(spec[4]))
    fontObjects[name] = font
    return font
end

-- Money, formatted the same everywhere:
--   under 1,000g: 321.24g    under 1M g: 12,345g    above: 1.23M g
local function Thousands(n)
    local s = tostring(n)
    local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (result:gsub("^,", ""))
end

function addon:FormatMoney(copper)
    local gold = math.abs(copper) / 10000
    local text
    -- Forever: most prices are silver and copper, which 0.00g hid (a
    -- 10c Linen Cloth; stress test, 2026-10-21). 12s 40c, 3g 25s.
    local c = math.floor(math.abs(copper) + 0.5)
    if addon.isForever and c < 10000 then
        local s, cc = math.floor(c / 100), c % 100
        text = (s > 0 and (s .. "s") or "") .. ((cc > 0 or s == 0) and ((s > 0 and " " or "") .. cc .. "c") or "")
    elseif addon.isForever and gold < 100 then
        local g, s = math.floor(c / 10000), math.floor((c % 10000) / 100)
        text = g .. "g" .. (s > 0 and (" " .. s .. "s") or "")
    elseif gold < 1000 then
        text = string.format("%.2fg", gold)
    elseif gold < 1000000 then
        text = Thousands(math.floor(gold + 0.5)) .. "g"
    else
        text = string.format("%.2fM g", gold / 1000000)
    end
    return copper < 0 and ("-" .. text) or text
end

-- With a sign in front: +12.40g, -3.00g
function addon:FormatSignedMoney(copper)
    return (copper >= 0 and "+" or "-") .. addon:FormatMoney(math.abs(copper))
end

-- Theme color for an amount: profit green, loss red, plain for zero
function addon:MoneyColor(copper)
    if copper > 0 then return "profit" end
    if copper < 0 then return "loss" end
    return "text"
end

_G.Goldsmith = addon
