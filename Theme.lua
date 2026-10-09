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
        },
        texture = "Interface\\Buttons\\WHITE8x8",
    },
}

addon.theme = addon.themes.clean

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
    if gold < 1000 then
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
