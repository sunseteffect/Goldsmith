local addon = _G.Goldsmith or {}

local function Print(msg, ...)
    print("|cFF00FF00[Goldsmith]|r " .. string.format(msg, ...))
end

-- Craft cooldowns
--
-- Some recipes can only be made once a day, or have charges that come back
-- over time. Each character's are kept in
-- GoldsmithDB.characters[key].cooldowns[recipeID] =
--   { profession, seen (when read),
--     readyAt   - when it can next be made (no charges),
--     charges, maxCharges, nextChargeAt, chargeSeconds - recipes with charges,
--     duration  - seconds one use locks it for, if known }
-- so an alt's are worked out to now, like concentration.
--
-- The game doesn't flag a recipe as having a cooldown while it's ready, so
-- a recipe is found by any sign of one: on cooldown now, charges, or a base
-- cooldown on its spell (the recipe ID is a spell ID). Read for every learned
-- recipe when a profession window opens, and again after you make one.
-- Once found, a recipe stays tracked.
--
-- Only the current expansion's cooldowns are kept (user, 2026-10-06: old
-- transmutes and the like piled up on a long-played character and cluttered
-- every list). Showing older ones could come back as an option later.
local MIN_COOLDOWN = 60 -- seconds; shorter is a cast lock, not a cooldown
local SCAN_DELAY = 1
local SCAN_EVERY = 30   -- at most one full scan this often per profession
local READ_AFTER_CRAFT = 1

-- What the game says about a recipe's cooldown now, or nil without any
-- sign of one: { cd (seconds left), day, charges, maxCharges, chargeSeconds,
-- duration }
local function Read(recipeID)
    local ok, cd, isDay, charges, maxCharges = pcall(C_TradeSkillUI.GetRecipeCooldown, recipeID)
    if not ok then cd, isDay, charges, maxCharges = nil, nil, nil, nil end
    local chargeInfo
    if C_Spell and C_Spell.GetSpellCharges then
        local okCharges, info = pcall(C_Spell.GetSpellCharges, recipeID)
        if okCharges and type(info) == "table" then chargeInfo = info end
    end
    local base
    local GetBase = (C_Spell and C_Spell.GetSpellBaseCooldown) or GetSpellBaseCooldown
    if GetBase then
        local okBase, ms = pcall(GetBase, recipeID)
        if okBase and type(ms) == "number" then base = ms / 1000 end
    end

    maxCharges = (maxCharges and maxCharges > 0 and maxCharges) or (chargeInfo and chargeInfo.maxCharges) or 0
    -- One charge is just a cooldown
    if maxCharges < 2 then maxCharges = 0 end
    cd = cd or 0
    local hasCooldown = cd >= MIN_COOLDOWN or isDay or maxCharges > 0 or (base and base >= MIN_COOLDOWN)
    if not hasCooldown then return nil end
    return {
        cd = cd, day = isDay and true or nil,
        charges = maxCharges > 0 and (charges or (chargeInfo and chargeInfo.currentCharges)) or nil,
        maxCharges = maxCharges > 0 and maxCharges or nil,
        chargeSeconds = chargeInfo and chargeInfo.cooldownDuration and chargeInfo.cooldownDuration > 0
            and chargeInfo.cooldownDuration or nil,
        duration = base and base >= MIN_COOLDOWN and base or nil,
    }
end

-- "Midnight Alchemy", for the expansion (needs the profession's data loaded)
local function SkillLineOf(recipeID)
    if not C_TradeSkillUI.GetTradeSkillLineForRecipe then return nil end
    local ok, _, name = pcall(C_TradeSkillUI.GetTradeSkillLineForRecipe, recipeID)
    return ok and type(name) == "string" and name ~= "" and name or nil
end

-- A cooldown recipe's expansion: from the saved recipe, else the skill
-- line seen when it was read. nil if neither is known yet.
local function ExpansionOf(recipeID, entry)
    local recipe = GoldsmithDB.recipes[recipeID]
    if recipe then
        local expansion = addon:GetRecipeExpansion(recipe)
        if expansion then return expansion end
    end
    if entry.skillLine then
        return addon:GetRecipeExpansion({ skillLine = entry.skillLine,
            outputItemID = recipe and recipe.outputItemID or 0 })
    end
end

-- True only when the expansion is known and isn't the current one; unknown
-- ones are kept (hidden) until a profession scan finds their skill line
local function IsOlder(recipeID, entry)
    local expansion = ExpansionOf(recipeID, entry)
    return expansion ~= nil and expansion ~= addon:GetCurrentExpansion()
end

local function IsCurrent(recipeID, entry)
    return ExpansionOf(recipeID, entry) == addon:GetCurrentExpansion()
end

-- "Midnight cooldowns"
function addon:CooldownsLabel()
    return (_G["EXPANSION_NAME" .. addon:GetCurrentExpansion()] or "Current") .. " cooldowns"
end

local function ProfessionOf(recipeID)
    local recipe = GoldsmithDB.recipes[recipeID]
    if recipe and recipe.profession then return recipe.profession end
    local ok, info = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    return ok and info and info.professionName or nil
end

-- Saves what the game says about one recipe for the logged-in character.
-- Returns true when it's a cooldown recipe.
local function Record(recipeID, info)
    local c = addon.char
    c.cooldowns = c.cooldowns or {}
    local entry = c.cooldowns[recipeID]
    info = info or Read(recipeID)
    if not info then
        -- Known cooldown recipe reading as nothing: it's ready
        if entry then
            entry.seen = time()
            entry.skillLine = entry.skillLine or SkillLineOf(recipeID)
            if IsOlder(recipeID, entry) then
                c.cooldowns[recipeID] = nil
                return false
            end
            if entry.maxCharges then
                entry.charges, entry.nextChargeAt = entry.maxCharges, nil
            else
                entry.readyAt = time()
            end
        end
        return entry ~= nil
    end
    local now = time()
    entry = entry or {}
    entry.profession = entry.profession or ProfessionOf(recipeID)
    entry.skillLine = entry.skillLine or SkillLineOf(recipeID)
    if IsOlder(recipeID, entry) then
        c.cooldowns[recipeID] = nil
        return false
    end
    entry.seen = now
    entry.day = info.day or entry.day
    entry.duration = info.duration or entry.duration
    if info.maxCharges then
        entry.maxCharges, entry.charges = info.maxCharges, math.min(info.charges or 0, info.maxCharges)
        entry.chargeSeconds = info.chargeSeconds or entry.chargeSeconds or info.duration
        entry.nextChargeAt = (entry.charges < entry.maxCharges and info.cd > 0) and (now + info.cd) or nil
        entry.readyAt = nil
    else
        entry.readyAt = now + info.cd
    end
    c.cooldowns[recipeID] = entry
    return true
end

-- A character's cooldown worked out to now: ready, readyAt (nil when
-- ready), charges available (recipes with charges, else 1 or 0)
local function Status(entry)
    local now = time()
    if entry.maxCharges then
        local charges, next = entry.charges or 0, entry.nextChargeAt
        while next and now >= next and charges < entry.maxCharges do
            charges = charges + 1
            next = (entry.chargeSeconds and charges < entry.maxCharges) and (next + entry.chargeSeconds) or nil
        end
        if charges >= entry.maxCharges then next = nil end
        return charges > 0, charges > 0 and nil or next, charges
    end
    local ready = not entry.readyAt or now >= entry.readyAt
    return ready, not ready and entry.readyAt or nil, ready and 1 or 0
end

-- Every tracked current-expansion cooldown on included characters
-- (excluded ones only when includeExcluded), soonest ready first:
-- { { charKey, name, recipeID, recipe (nil if not saved), profession,
--     ready, readyAt, charges, maxCharges } }
-- prof filters to one profession, or "All"/nil. A cooldown whose expansion
-- isn't known yet is left out until a profession scan finds it.
function addon:GetCooldowns(prof, includeExcluded)
    local list = {}
    for key, c in pairs(GoldsmithDB.characters) do
        if includeExcluded or addon:IsCharacterIncluded(key) then
            for recipeID, entry in pairs(c.cooldowns or {}) do
                if (not prof or prof == "All" or entry.profession == prof) and IsCurrent(recipeID, entry) then
                    local ready, readyAt, charges = Status(entry)
                    table.insert(list, {
                        charKey = key, name = c.name or key, recipeID = recipeID,
                        recipe = GoldsmithDB.recipes[recipeID], profession = entry.profession,
                        ready = ready, readyAt = readyAt, charges = charges, maxCharges = entry.maxCharges,
                    })
                end
            end
        end
    end
    table.sort(list, function(a, b)
        if a.ready ~= b.ready then return a.ready end
        if (a.readyAt or 0) ~= (b.readyAt or 0) then return (a.readyAt or 0) < (b.readyAt or 0) end
        return a.charKey .. a.recipeID < b.charKey .. b.recipeID
    end)
    return list
end

-- The recipe's name for lists: what it makes, else its spell name
function addon:CooldownName(cd)
    if cd.recipe and cd.recipe.outputName then return cd.recipe.outputName end
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(cd.recipeID)
    return name or ("recipe " .. cd.recipeID)
end

-- "ready", "2/3 ready", "in 5h", "in 2 days"
function addon:CooldownStatusText(cd)
    if cd.ready then
        if cd.maxCharges then return string.format("%d/%d ready", cd.charges, cd.maxCharges) end
        return "ready"
    end
    if not cd.readyAt then return "unknown" end
    local seconds = cd.readyAt - time()
    if seconds < 3600 then return string.format("in %dm", math.max(math.ceil(seconds / 60), 1)) end
    if seconds < 86400 * 2 then return string.format("in %dh", math.ceil(seconds / 3600)) end
    return string.format("in %d days", math.ceil(seconds / 86400))
end

-- Scanning the open profession

local lastScan = {}
local scanPending = false

local function ScanOpenProfession(force)
    scanPending = false
    local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not ok or not ids then return end
    local profOk, profInfo = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    local profession = profOk and profInfo and profInfo.professionName or "?"
    if not force and lastScan[profession] and GetTime() - lastScan[profession] < SCAN_EVERY then return end
    lastScan[profession] = GetTime()

    local changed = false
    for _, id in ipairs(ids) do
        local info = C_TradeSkillUI.GetRecipeInfo(id)
        if info and info.learned then
            local known = addon.char.cooldowns and addon.char.cooldowns[id]
            local cooldown = Read(id)
            if cooldown or known then
                Record(id, cooldown)
                changed = true
            end
        end
    end
    if changed and addon.Refresh then addon.Refresh() end
end

local function QueueScan()
    if scanPending then return end
    scanPending = true
    C_Timer.After(SCAN_DELAY, function() ScanOpenProfession(false) end)
end

-- After a craft, the recipe's cooldown has started (or a charge is used)
local function OnCast(spellID)
    local tracked = addon.char.cooldowns and addon.char.cooldowns[spellID]
    if not tracked and not GoldsmithDB.recipes[spellID] then return end
    C_Timer.After(READ_AFTER_CRAFT, function()
        local info = Read(spellID)
        if info then
            Record(spellID, info)
        elseif tracked then
            -- The game no longer says; assume one use was spent
            local entry = tracked
            if entry.maxCharges then
                entry.charges = math.max((entry.charges or 1) - 1, 0)
                if not entry.nextChargeAt and entry.chargeSeconds then
                    entry.nextChargeAt = time() + entry.chargeSeconds
                end
            elseif entry.duration then
                entry.readyAt = time() + entry.duration
            end
        else
            return
        end
        if addon.Refresh then addon.Refresh() end
    end)
end

-- At login: what's ready on every character, once the login spam is past
local LOGIN_DELAY = 10
local function AnnounceReady()
    local ready = {}
    for _, cd in ipairs(addon:GetCooldowns("All")) do
        if cd.ready then
            table.insert(ready, string.format("%s (%s)", addon:CooldownName(cd), cd.name))
        end
    end
    if #ready == 0 then return end
    local shown = {}
    for i = 1, math.min(#ready, 4) do shown[i] = ready[i] end
    addon:Notify("info", "%s ready: %s%s.", addon:CooldownsLabel(),
        table.concat(shown, ", "), #ready > 4 and string.format(" and %d more", #ready - 4) or "")
end

-- /gsm cooldowns: what's tracked, and what the game reports for the open
-- profession (to check detection)
function addon:ListCooldowns()
    local list = addon:GetCooldowns("All", true)
    if #list == 0 then
        Print("No %s found yet. Open a profession that has one (or make the craft) on each character.",
            addon:CooldownsLabel():lower())
    else
        Print("%s:", addon:CooldownsLabel())
        for _, cd in ipairs(list) do
            print(string.format("  %s - %s: %s", cd.name, addon:CooldownName(cd), addon:CooldownStatusText(cd)))
        end
    end
    local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if ok and ids and #ids > 0 then
        local found = 0
        for _, id in ipairs(ids) do
            local info = C_TradeSkillUI.GetRecipeInfo(id)
            local cooldown = info and info.learned and not IsOlder(id, { skillLine = SkillLineOf(id) }) and Read(id)
            if cooldown then
                found = found + 1
                if found <= 10 then
                    print(string.format("  game: %s (%d) cd %ds%s%s%s", info.name or "?", id, cooldown.cd,
                        cooldown.day and ", daily" or "",
                        cooldown.maxCharges and string.format(", charges %d/%d", cooldown.charges or 0, cooldown.maxCharges) or "",
                        cooldown.duration and string.format(", base %ds", cooldown.duration) or ""))
                end
            end
        end
        Print("The open profession has %d learned %s recipe%s with a cooldown.", found,
            _G["EXPANSION_NAME" .. addon:GetCurrentExpansion()] or "current", found == 1 and "" or "s")
        if found > 0 then ScanOpenProfession(true) end
    else
        Print("Open a profession to see what the game reports for its recipes.")
    end
end

-- Older expansions' cooldowns saved before they were left out. Run after
-- login, not while the addon loads: on a fresh start the game may not report
-- the current expansion yet, and Midnight's cooldowns were deleted as older
-- (2026-10-06, Mysticmead's Mote of Wild Magic).
local function PruneOlder()
    for _, c in pairs(GoldsmithDB.characters) do
        for recipeID, entry in pairs(c.cooldowns or {}) do
            if IsOlder(recipeID, entry) then c.cooldowns[recipeID] = nil end
        end
    end
end

function addon:InitializeCooldowns()
    for _, c in pairs(GoldsmithDB.characters) do
        c.cooldowns = c.cooldowns or {}
    end
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("TRADE_SKILL_SHOW")
    frame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
    frame:RegisterEvent("PLAYER_ENTERING_WORLD")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    frame:SetScript("OnEvent", function(self, event, ...)
        if event == "UNIT_SPELLCAST_SUCCEEDED" then
            OnCast(select(3, ...))
        elseif event == "PLAYER_ENTERING_WORLD" then
            self:UnregisterEvent("PLAYER_ENTERING_WORLD")
            C_Timer.After(LOGIN_DELAY, function()
                PruneOlder()
                AnnounceReady()
            end)
        else
            QueueScan()
        end
    end)
end

_G.Goldsmith = addon
