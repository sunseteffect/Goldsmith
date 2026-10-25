-- Goldsmith's offline test bench: loads the addon outside WoW (Lua 5.1)
-- with stand-ins for the game (wow.lua), on a copy of your saved data held
-- in memory. Nothing is ever written back to the WTF folder.
--
-- A scenario is a Lua file in scenarios\ that starts with
--     local bench = dofile(BENCH_DIR .. "bench.lua")
-- then sets up a situation, runs Goldsmith's own functions and checks the
-- results. See README.md. run.lua runs them all, each in its own process.

local B = {}
local dir = BENCH_DIR or (arg and arg[0] and arg[0]:match("^(.*[/\\])") or "./")
B.dir = dir
B.addonDir = dir .. "../../"
B.savedPath = os.getenv("GOLDSMITH_SAVED")
    or "C:/Program Files (x86)/World of Warcraft/_retail_/WTF/Account/SUNSETEFFECT/SavedVariables/Goldsmith.lua"

local wow = dofile(dir .. "wow.lua")
-- The game's print goes to the chat log; the bench reports to the console
local function print(s) io.write(s, "\n") end
B.world, B.wow = wow.world, wow
local world = wow.world

---------------------------------------------------------------------------
-- Results
---------------------------------------------------------------------------
local passed, failed = 0, 0
local scenarioName = (arg and arg[0] or "scenario"):match("([^/\\]+)%.lua$") or "scenario"

local function Show(v)
    if type(v) == "string" then return string.format("%q", v) end
    return tostring(v)
end

function B.Check(name, ok, detail)
    if ok then
        passed = passed + 1
        print("  PASS " .. name)
    else
        failed = failed + 1
        print("  FAIL " .. name .. (detail and ("\n       " .. tostring(detail)) or ""))
    end
    return ok
end

function B.Equal(name, got, want)
    return B.Check(name, got == want, "got " .. Show(got) .. ", want " .. Show(want))
end

-- Money is checked to the copper by default; give a tolerance in gold
function B.Near(name, got, want, tolerance)
    tolerance = tolerance or 0
    local ok = type(got) == "number" and math.abs(got - want) <= tolerance
    return B.Check(name, ok, "got " .. Show(got) .. ", want " .. Show(want) .. " (±" .. tolerance .. ")")
end

-- A pattern (plain text unless it has Lua pattern characters) found in a
-- string or in any line of a list
function B.Has(name, where, pattern, plain)
    if plain == nil then plain = not pattern:find("[%%%[%]%^%$%*%+%-%?]") end
    local lines = type(where) == "table" and where or { tostring(where) }
    for _, line in ipairs(lines) do
        if tostring(line):find(pattern, 1, plain) then return B.Check(name, true) end
    end
    return B.Check(name, false, "no " .. Show(pattern) .. " in:\n         " .. table.concat(lines, "\n         "))
end

function B.HasNot(name, where, pattern, plain)
    if plain == nil then plain = not pattern:find("[%%%[%]%^%$%*%+%-%?]") end
    local lines = type(where) == "table" and where or { tostring(where) }
    for _, line in ipairs(lines) do
        if tostring(line):find(pattern, 1, plain) then
            return B.Check(name, false, "found " .. Show(pattern) .. " in " .. Show(line))
        end
    end
    return B.Check(name, true)
end

-- Every scenario ends with this. Errors caught inside Goldsmith's event
-- handlers and timers fail the scenario too (the game would show them).
function B.Done()
    if #world.errors > 0 then
        failed = failed + 1
        print("  FAIL Lua errors inside Goldsmith (" .. #world.errors .. "):")
        local seen = {}
        for _, e in ipairs(world.errors) do
            if not seen[e] then seen[e] = true print("       " .. e) end
        end
    end
    print(string.format("RESULT %s %s: %d passed, %d failed", failed == 0 and "PASS" or "FAIL", scenarioName, passed, failed))
    os.exit(failed == 0 and 0 or 1)
end

-- Errors so far, cleared (for a scenario that expects one)
function B.TakeErrors()
    local e = world.errors
    world.errors = {}
    return e
end

---------------------------------------------------------------------------
-- Chat and calls
---------------------------------------------------------------------------
-- Chat lines printed since the last B.Chat() (or since login)
local chatMark = 0
function B.Chat()
    local out = {}
    for i = chatMark + 1, #world.chat do table.insert(out, world.chat[i]) end
    chatMark = #world.chat
    return out
end
local callMark = 0
-- Game calls made since the last B.Calls(): "ConfirmCommoditiesPurchase(1234, 20)"
function B.Calls()
    local out = {}
    for i = callMark + 1, #world.calls do table.insert(out, world.calls[i]) end
    callMark = #world.calls
    return out
end
B.Strip = wow.Strip

---------------------------------------------------------------------------
-- Saved data and items
---------------------------------------------------------------------------
local saved
local function LoadSaved()
    if saved ~= nil then return saved end
    local fn, err = loadfile(B.savedPath)
    if not fn then error("can't read the saved data at " .. B.savedPath .. ": " .. tostring(err)) end
    local env = {}
    setfenv(fn, env)
    fn()
    saved = env.GoldsmithDB or false
    return saved
end
B.LoadSaved = LoadSaved

-- Item names from everything the saved data names: recipes, their
-- materials, and the ledger's entries. Scenarios can add more with B.AddItem.
local function LearnItems(db)
    local items = world.items
    local function Add(id, name)
        id = tonumber(id)
        if id and name and not items[id] then items[id] = { name = name } end
    end
    for _, r in pairs(db.recipes or {}) do
        Add(r.outputItemID, r.outputName or r.name)
        for _, slot in ipairs(r.reagents or {}) do
            for i, id in ipairs(slot.itemIDs or {}) do Add(id, slot.names and slot.names[i]) end
        end
    end
    for _, e in pairs(db.entries or {}) do
        if type(e) == "table" then Add(e.itemID, e.item or e.name) end
    end
    for id, facts in pairs(db.itemFacts or {}) do
        local it = items[id]
        if it and type(facts) == "table" then
            it.bind, it.expansion = facts.bind, facts.expansion
        end
    end
end

-- Find an item's ID by its exact name (case-insensitive)
function B.ItemID(name)
    local lower = name:lower()
    for id, it in pairs(world.items) do
        if it.name and it.name:lower() == lower then return id end
    end
    error("no item named " .. name .. " in the saved data (add it with bench.AddItem)")
end

function B.AddItem(id, name, fields)
    local it = fields or {}
    it.name = name
    world.items[id] = it
    return id
end

function B.Gold(g) return math.floor(g * 10000 + 0.5) end

---------------------------------------------------------------------------
-- Logging in
---------------------------------------------------------------------------
local function LoadAddon()
    local toc = assert(io.open(B.addonDir .. "Goldsmith.toc"), "no Goldsmith.toc")
    local files = {}
    for line in toc:lines() do
        line = line:gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if line ~= "" and not line:find("^#") then table.insert(files, line) end
    end
    toc:close()
    local private = {}
    for _, file in ipairs(files) do
        local path = B.addonDir .. file:gsub("\\", "/")
        if file:find("%.lua$") then
            local fn, err = loadfile(path)
            if not fn then error("syntax error: " .. tostring(err)) end
            local ok, runErr = pcall(fn, "Goldsmith", private)
            if not ok then error("loading " .. file .. ": " .. tostring(runErr)) end
        end
    end
    B.files = files
end

-- Log in as one of the saved characters ("Mysticmead-Sargeras", or just
-- "Mysticmead"). Their bags, bank and gold come from what Goldsmith saved
-- at their last login. Options:
--   fresh = true      no saved data (a new install)
--   db = table        use this GoldsmithDB instead of the saved one
--   bags = { [itemID] = n }   replace the bags (bank and warband stay)
--   money = copper
--   settle = seconds  how long to let login chores run (default 20)
function B.Login(who, opts)
    opts = opts or {}
    local db
    if opts.fresh then
        db = nil
    elseif opts.db then
        db = opts.db
    else
        db = LoadSaved()
        if not db then error("the saved data has no GoldsmithDB") end
    end
    if db then LearnItems(db) end

    local key, c = nil, nil
    if db and who then
        for k, ch in pairs(db.characters or {}) do
            if k == who or k:match("^([^-]+)") == who then key, c = k, ch end
        end
        if not c then error("no saved character " .. who) end
    end
    if c then
        world.player.name = c.name or key:match("^([^-]+)")
        world.player.realm = c.realm or key:match("%-(.+)$")
        world.player.class = c.class or "MAGE"
        world.money = c.money or c.gold or 0
        local bank = c.stockBank or {}
        for id, n in pairs(c.stock or {}) do
            local inBank = math.min(bank[id] or 0, n)
            if n - inBank > 0 then world.bags[id] = n - inBank end
            if inBank > 0 then world.bank[id] = inBank end
        end
        for id, n in pairs(db.warbandStock or {}) do world.warband[id] = n end
        -- The game's clock starts where the saved data ends
        if c.lastSeen and c.lastSeen > world.baseTime then world.baseTime = c.lastSeen end
    elseif who then
        world.player.name = who
    end
    if opts.bags then world.bags = opts.bags end
    if opts.money then world.money = opts.money end
    if opts.time then world.baseTime = opts.time end

    GoldsmithDB = db
    LoadAddon()
    B.addon = _G.Goldsmith
    B.Fire("ADDON_LOADED", "Goldsmith")
    B.Fire("PLAYER_LOGIN")
    B.Fire("PLAYER_ENTERING_WORLD", true, false)
    B.Fire("BAG_UPDATE_DELAYED")
    B.Advance(opts.settle or 20)
    -- What login said, kept apart so scenarios start with a clean chat
    B.loginChat = B.Chat()
    B.Calls()
    B.key = B.addon.charKey
    return B.addon
end

B.Fire = wow.Fire
B.Advance = wow.Advance

-- Run a slash command as if typed: B.Slash("/gsm data")
function B.Slash(text)
    local cmd, rest = text:match("^(/%S+)%s*(.-)$")
    for name, fn in pairs(SlashCmdList) do
        for i = 1, 9 do
            local alias = _G["SLASH_" .. name .. i]
            if not alias then break end
            if alias:lower() == cmd:lower() then
                wow.Protected(text, fn, rest)
                B.Advance(0)
                return
            end
        end
    end
    error("no slash command " .. cmd)
end

---------------------------------------------------------------------------
-- Changing the world
---------------------------------------------------------------------------
-- Bags change: give { [itemID or name] = count } (nil count removes)
function B.SetBags(changes)
    for k, n in pairs(changes) do
        local id = type(k) == "string" and B.ItemID(k) or k
        world.bags[id] = (n and n > 0) and n or nil
    end
    B.Fire("BAG_UPDATE", 0)
    B.Fire("BAG_UPDATE_DELAYED")
    B.Advance(1)
end

function B.SetMoney(copper)
    world.money = copper
    B.Fire("PLAYER_MONEY")
    B.Advance(0)
end

-- AH listings: { [itemID or name] = { {unitPrice, quantity}, ... } }
function B.SetListings(listings)
    for k, rows in pairs(listings) do
        local id = type(k) == "string" and B.ItemID(k) or k
        world.commodities[id] = rows
    end
end

local function Open(frame, event, ...)
    frame:Show()
    B.Fire(event, ...)
    B.Fire("PLAYER_INTERACTION_MANAGER_FRAME_SHOW", ...)
    B.Advance(1)
end
local function Close(frame, event, ...)
    frame:Hide()
    B.Fire(event, ...)
    B.Advance(1)
end
function B.OpenAH() world.auctionHouseOpen = true Open(AuctionHouseFrame, "AUCTION_HOUSE_SHOW") end
function B.CloseAH() world.auctionHouseOpen = false Close(AuctionHouseFrame, "AUCTION_HOUSE_CLOSED") end
function B.OpenMail()
    world.mailOpen = true
    InboxFrame:Show()
    SendMailFrame:Hide()
    Open(MailFrame, "MAIL_SHOW")
    B.Fire("MAIL_INBOX_UPDATE")
    B.Advance(1)
end
function B.CloseMail() world.mailOpen = false Close(MailFrame, "MAIL_CLOSED") end

-- Click the shown button whose label matches (plain text, or a pattern).
-- Fails the check when no such button shows.
function B.Click(label, mouseButton)
    local plain = not label:find("[%%%[%]%^%$%*%+%-%?]")
    for _, f in ipairs(wow.frames) do
        if f._text and f:IsVisible() and wow.Strip(f._text):find(label, 1, plain) then
            local b = f
            while b and not b._scripts.OnClick do b = b._parent end
            if b then
                b:Click(mouseButton)
                B.Advance(1)
                return B.Check("click " .. label, true)
            end
        end
    end
    return B.Check("click " .. label, false, "no button labeled " .. label .. " on screen")
end
function B.OpenVendor(items)
    world.merchant = items or world.merchant
    world.merchantOpen = true
    Open(MerchantFrame, "MERCHANT_SHOW")
end
function B.CloseVendor() world.merchantOpen = false Close(MerchantFrame, "MERCHANT_CLOSED") end

-- The AH answers a commodity purchase started with StartCommoditiesPurchase
function B.QuotePrice(itemID, unitPrice, quantity)
    B.Fire("COMMODITY_PRICE_UPDATED", unitPrice, unitPrice * quantity)
    B.Advance(0)
end
-- The purchase goes through: gold comes off, and the items go to the
-- mailbox ("You won an auction"), as AH purchases do. B.TakeMail() moves
-- them into the bags.
function B.PurchaseSucceeds(itemID, quantity, total)
    world.money = world.money - total
    B.Fire("COMMODITY_PURCHASE_SUCCEEDED")
    B.Fire("PLAYER_MONEY")
    table.insert(world.inbox, { sender = "Auction House", subject = "Auction won", items = { { itemID, quantity } } })
    B.Advance(3)
end

-- Take every item from the mailbox into the bags
function B.TakeMail()
    for _, m in ipairs(world.inbox) do
        for _, it in ipairs(m.items or {}) do
            world.bags[it[1]] = (world.bags[it[1]] or 0) + it[2]
        end
    end
    world.inbox = {}
    B.Fire("MAIL_INBOX_UPDATE")
    B.Fire("BAG_UPDATE")
    B.Fire("BAG_UPDATE_DELAYED")
    B.Advance(1)
end

-- Plain text of a frame and everything under it, for checking what a panel
-- says (layout isn't checked: the bench draws nothing)
function B.TextOf(frame)
    local out = {}
    local function Walk(f)
        if not f:IsShown() then return end
        if f._text and f._text ~= "" then table.insert(out, wow.Strip(f._text)) end
        for _, child in ipairs(f._children) do Walk(child) end
    end
    Walk(frame)
    return out
end

-- A table's whole contents as one string, keys sorted, to compare before
-- and after ("the tour left your data exactly as it was")
function B.Serialize(v, seen)
    seen = seen or {}
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) ~= "table" then return tostring(v) end
    if seen[v] then return "<cycle>" end
    seen[v] = true
    local keys = {}
    for k in pairs(v) do table.insert(keys, k) end
    table.sort(keys, function(a, b)
        if type(a) == type(b) and (type(a) == "number" or type(a) == "string") then return a < b end
        return type(a) < type(b)
    end)
    local parts = {}
    for _, k in ipairs(keys) do
        if type(v[k]) ~= "function" then
            table.insert(parts, "[" .. B.Serialize(k, seen) .. "]=" .. B.Serialize(v[k], seen))
        end
    end
    seen[v] = nil
    return "{" .. table.concat(parts, ",") .. "}"
end

-- Where two tables differ: a list of "path: before -> after" (at most `limit`)
function B.Diff(a, b, limit, path, out)
    out = out or {}
    limit = limit or 20
    path = path or ""
    if #out >= limit then return out end
    if type(a) ~= "table" or type(b) ~= "table" then
        if a ~= b and not (type(a) == "function" and type(b) == "function") then
            table.insert(out, path .. ": " .. B.Serialize(a):sub(1, 80) .. " -> " .. B.Serialize(b):sub(1, 80))
        end
        return out
    end
    for k, v in pairs(a) do B.Diff(v, b[k], limit, path .. "." .. tostring(k), out) end
    for k, v in pairs(b) do
        if a[k] == nil then B.Diff(nil, v, limit, path .. "." .. tostring(k), out) end
    end
    return out
end

function B.Copy(t)
    if type(t) ~= "table" then return t end
    local o = {}
    for k, v in pairs(t) do o[k] = B.Copy(v) end
    return o
end

-- Text of every frame on screen now (shown, with all its parents shown)
function B.Screen()
    local out = {}
    for _, f in ipairs(wow.frames) do
        if f._text and f._text ~= "" and f:IsVisible() then table.insert(out, wow.Strip(f._text)) end
    end
    return out
end

-- A note in the bench's output (print() is the game's chat)
function B.Log(fmt, ...)
    print("  " .. (select("#", ...) > 0 and string.format(fmt, ...) or tostring(fmt)))
end

-- Print what's on screen (or a list of lines), to see what a check should look for
function B.Show(lines, title)
    print("  --- " .. (title or "on screen"))
    for _, l in ipairs(lines or B.Screen()) do print("  | " .. l) end
end

-- Run a function of Goldsmith's, failing the check (not the bench) on an error
function B.Try(name, fn, ...)
    local r = { pcall(fn, ...) }
    if not r[1] then
        B.Check(name, false, r[2])
        return nil
    end
    return unpack(r, 2)
end

return B
