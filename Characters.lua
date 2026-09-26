local addon = _G.Goldsmith or {}

local function Print(msg, ...)
    print("|cFF00FF00[Goldsmith]|r " .. string.format(msg, ...))
end

local function FormatGold(copper)
    return string.format("%.2fg", copper / 10000)
end

-- Characters
--
-- Everything that differs between your characters is kept per character in
-- GoldsmithDB.characters["Name-Realm"]:
--   { name, realm, class, lastSeen,
--     professions   = { [profession] = { icon, skill, maxSkill } },
--     knownRecipes  = { [recipeID] = true },
--     recipeStats   = { [recipeID] = stats }       (see Pricing.lua)
--     tierData      = { [recipeID] = tiers }       (see Quality.lua)
--     calibration   = { [profession] = procs }     (see Pricing.lua)
--     concentration = { [profession] = { currencyID, current, max,
--                                        cycleMS, perCycle, time } },
--     money, gold   = { ["YYYY-MM-DD"] = copper at the end of that day } }
-- addon.char is the logged-in character's table. Prices, recipes' materials,
-- the ledger, milling and vendor prices stay shared across the account.
--
-- Concentration refills over time, so an alt's current amount is worked out
-- from its last saved amount and how long ago that was.

local GOLD_HISTORY_DAYS = 365

function addon:CharKey()
    return (UnitName("player") or "Unknown") .. "-" .. (GetRealmName() or "Unknown")
end

local function NewCharacter(name, realm)
    return {
        name = name, realm = realm,
        professions = {}, knownRecipes = {},
        recipeStats = {}, tierData = {}, calibration = {},
        concentration = {}, gold = {},
    }
end

local function EnsureFields(c)
    for _, key in ipairs({ "professions", "knownRecipes", "recipeStats", "tierData",
                           "calibration", "concentration", "gold" }) do
        c[key] = c[key] or {}
    end
end

-- v1 kept stats, tiers and calibration for the whole account. They belong to
-- the character who made them: the one in the ledger most often (not
-- necessarily whoever logs in first after the update).
local function MigrateAccountData()
    local legacy = GoldsmithDB.recipeStats or GoldsmithDB.tierData or GoldsmithDB.calibration
    if not legacy then return end

    local counts, owner, best = {}, nil, 0
    for _, e in ipairs(GoldsmithDB.entries or {}) do
        if e.character and e.realm then
            local key = e.character .. "-" .. e.realm
            counts[key] = (counts[key] or 0) + 1
            if counts[key] > best then owner, best = key, counts[key] end
        end
    end
    owner = owner or addon:CharKey()

    local c = GoldsmithDB.characters[owner]
    if not c then
        local name, realm = owner:match("^(.-)%-(.+)$")
        c = NewCharacter(name, realm)
        GoldsmithDB.characters[owner] = c
    end
    EnsureFields(c)

    for recipeID, stats in pairs(GoldsmithDB.recipeStats or {}) do
        c.recipeStats[recipeID] = c.recipeStats[recipeID] or stats
        c.knownRecipes[recipeID] = true
    end
    for recipeID, tiers in pairs(GoldsmithDB.tierData or {}) do
        c.tierData[recipeID] = c.tierData[recipeID] or tiers
    end
    for profession, procs in pairs(GoldsmithDB.calibration or {}) do
        c.calibration[profession] = c.calibration[profession] or procs
    end
    -- v1 scanned every recipe on this character, so it knows them all
    for recipeID in pairs(GoldsmithDB.recipes or {}) do
        c.knownRecipes[recipeID] = true
    end

    GoldsmithDB.recipeStats, GoldsmithDB.tierData, GoldsmithDB.calibration = nil, nil, nil
    Print("Moved your crafting stats to %s. Each character now keeps its own.", owner)
end

-- Professions and skill levels of the logged-in character
local function UpdateProfessions()
    local c = addon.char
    for _, index in ipairs({ GetProfessions() }) do
        local name, icon, skill, maxSkill = GetProfessionInfo(index)
        if name then
            c.professions[name] = { icon = icon, skill = skill, maxSkill = maxSkill }
        end
    end
end

-- Current concentration for each of this character's professions whose
-- concentration currency is known (learned when a profession is opened)
local function SnapshotConcentration()
    local c = addon.char
    for profession in pairs(c.professions) do
        local currencyID = GoldsmithDB.concentrationCurrency and GoldsmithDB.concentrationCurrency[profession]
        if currencyID and currencyID > 0 then
            local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
            if ok and info then
                c.concentration[profession] = {
                    currencyID = currencyID,
                    current = info.quantity or 0,
                    max = info.maxQuantity or 0,
                    cycleMS = info.rechargingCycleDurationMS,
                    perCycle = info.rechargingAmountPerCycle,
                    time = time(),
                }
            end
        end
    end
end

local function RecordGold()
    local c = addon.char
    local money = GetMoney()
    c.money = money
    c.gold[date("%Y-%m-%d")] = money
    local cutoff = date("%Y-%m-%d", time() - GOLD_HISTORY_DAYS * 86400)
    for day in pairs(c.gold) do
        if day < cutoff then c.gold[day] = nil end
    end
end

local function UpdateAll()
    local c = addon.char
    c.lastSeen = time()
    c.class = select(2, UnitClass("player"))
    UpdateProfessions()
    SnapshotConcentration()
    RecordGold()
end

-- A character's concentration for a profession, worked out to now from its
-- last saved amount and recharge rate. Returns current, max, minutes until
-- full (nil if full or unknown) and when it was last saved, or nil.
function addon:GetCharacterConcentration(charKey, profession)
    local c = GoldsmithDB.characters[charKey]
    local snap = c and c.concentration[profession]
    if not snap then return nil end

    local current = snap.current
    if charKey ~= addon.charKey and snap.cycleMS and snap.perCycle and snap.cycleMS > 0 then
        local cycles = (time() - snap.time) * 1000 / snap.cycleMS
        current = math.min(snap.max, current + cycles * snap.perCycle)
    end
    local minutesToFull
    if snap.cycleMS and snap.perCycle and snap.perCycle > 0 and current < snap.max then
        minutesToFull = (snap.max - current) / snap.perCycle * snap.cycleMS / 60000
    end
    return math.floor(current), snap.max, minutesToFull, snap.time
end

-- Characters sorted: the logged-in one first, then by name
function addon:GetCharacters()
    local list = {}
    for key, c in pairs(GoldsmithDB.characters) do
        table.insert(list, { key = key, data = c })
    end
    table.sort(list, function(a, b)
        if (a.key == addon.charKey) ~= (b.key == addon.charKey) then return a.key == addon.charKey end
        return a.key < b.key
    end)
    return list
end

-- Mark recipes this character knows (called by the recipe scan)
function addon:MarkRecipeKnown(recipeID)
    addon.char.knownRecipes[recipeID] = true
end

function addon:KnowsRecipe(recipeID, charKey)
    local c = charKey and GoldsmithDB.characters[charKey] or addon.char
    return c and c.knownRecipes[recipeID] == true
end

-- /gsm chars
function addon:ListCharacters()
    UpdateAll()
    Print("Your characters:")
    for _, entry in ipairs(addon:GetCharacters()) do
        local c = entry.data
        local seen = entry.key == addon.charKey and "online now"
            or (c.lastSeen and ("last seen " .. date("%b %d %H:%M", c.lastSeen)) or "never seen")
        print(string.format("  %s%s - %s, %s", entry.key, entry.key == addon.charKey and " (you)" or "",
            c.money and FormatGold(c.money) or "?", seen))
        for profession, p in pairs(c.professions) do
            local line = string.format("    %s %d/%d", profession, p.skill or 0, p.maxSkill or 0)
            local current, max, minutesToFull = addon:GetCharacterConcentration(entry.key, profession)
            if current then
                line = line .. string.format(", concentration %d/%d", current, max)
                if minutesToFull then
                    line = line .. string.format(" (full in %.1fh)", minutesToFull / 60)
                end
            end
            print(line)
        end
    end
end

function addon:InitializeCharacters()
    GoldsmithDB.characters = GoldsmithDB.characters or {}
    local key = addon:CharKey()
    local c = GoldsmithDB.characters[key]
    if not c then
        c = NewCharacter(UnitName("player"), GetRealmName())
        GoldsmithDB.characters[key] = c
    end
    EnsureFields(c)
    addon.char, addon.charKey = c, key

    MigrateAccountData()
    -- The migration may have created or filled this character's table
    addon.char = GoldsmithDB.characters[key]
    EnsureFields(addon.char)

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterEvent("SKILL_LINES_CHANGED")
    frame:RegisterEvent("PLAYER_MONEY")
    frame:RegisterEvent("CURRENCY_DISPLAY_UPDATE")
    frame:RegisterEvent("PLAYER_LOGOUT")
    local pending = false
    frame:SetScript("OnEvent", function(_, event)
        if event == "PLAYER_LOGOUT" then
            UpdateAll()
        elseif event == "PLAYER_MONEY" then
            RecordGold()
        elseif not pending then
            -- Profession and currency data can arrive a moment after these
            -- events, and they can fire in bursts
            pending = true
            C_Timer.After(2, function()
                pending = false
                UpdateAll()
            end)
        end
    end)
end

_G.Goldsmith = addon
