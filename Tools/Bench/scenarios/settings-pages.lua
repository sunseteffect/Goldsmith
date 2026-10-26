-- The settings panel: categories down the left, a dashboard first, a
-- toggle per on/off setting, search across pages, and a reset to
-- recommended that leaves excluded characters and ignored crafts alone
-- (user, 2026-10-25)
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
GoldsmithDB.settings = { excluded = { ["Maddoxynn-Sargeras"] = true } }
addon:SetIgnored(12345, "Test Craft", true)
addon:ToggleWindow()
bench.Advance(2)
addon:ShowSettings()
bench.Advance(1)
local panel = GoldsmithSettings

-- Dashboard first
local screen = bench.Screen()
bench.Has("opens on the dashboard", screen, "Goldsmith settings")
for _, label in ipairs({ "Help", "Support and feedback", "Take the tour", "Getting started",
        "VERSION", "LAST AH SCAN", "KEY TO OPEN", "0 of 16", "Everything is on its recommended setting." }) do
    bench.Has("dashboard shows " .. label, screen, label)
end
for _, label in ipairs({ "Suggestions", "Ignored crafts", "Characters", "Prices and scan", "Buy next",
        "Display", "Chat and sounds", "Keys", "History" }) do
    bench.Has("nav lists " .. label, screen, label)
end

-- A page shows only its own settings
bench.Click("Display")
screen = bench.Screen()
bench.Has("Display page", screen, "Item tooltips")
bench.Has("Display page: minimap", screen, "Minimap button")
bench.HasNot("other pages hidden", screen, "Worth crafting at")

-- A toggle saves the setting; the dashboard lists it as changed
panel:Open("alerts")
local function ToggleOf(title)
    for _, f in ipairs(bench.wow.frames) do
        if f.titleText == title and f.control then return f.control end
    end
end
ToggleOf("Sounds"):Click()
bench.Equal("toggle saves", addon:Setting("sounds"), false)
addon:SetSetting("tooltips", "short")
panel:Open("dashboard")
screen = bench.Screen()
bench.Has("changed count", screen, "2 of 16")
bench.Has("changed list names it", screen, "Item tooltips: Short")
bench.Has("changed list: sounds", screen, "Sounds: Off")

-- Auto scan greys out with the scan off
addon:SetSetting("ahScan", false)
panel:Open("prices")
bench.Has("auto scan says why", bench.Screen(), "Needs Auction House scan on.")
bench.Equal("auto scan not usable", ToggleOf("Auto scan").usable, false)
addon:SetSetting("ahScan", nil)

-- Search finds settings on any page, and pages by a character's name
panel:Search("minimap")
screen = bench.Screen()
bench.Has("search: heading", screen, "Display")
bench.Has("search: the row", screen, "Minimap button")
bench.HasNot("search: not others", screen, "Worth crafting at")
panel:Search("maddox")
bench.Has("search finds a character's page", bench.Screen(), "Characters")
panel:Search("zzzz")
bench.Has("search: nothing", bench.Screen(), "No setting matches")

-- Characters and ignored crafts: a toggle each
panel:Open("characters")
bench.Equal("excluded character is off", ToggleOf("Maddoxynn").on, false)
panel:Open("ignored")
bench.Has("ignored craft listed", bench.Screen(), "Test Craft")
ToggleOf("Test Craft"):Click()
bench.Check("turned off: not ignored", not addon:IsIgnored(12345))
bench.Has("stays listed to turn back on", bench.Screen(), "Test Craft")
ToggleOf("Test Craft"):Click()
bench.Check("turned back on", addon:IsIgnored(12345))

-- Reset to recommended: asks, then resets settings only
panel:Open("dashboard")
bench.Click("Reset to recommended")
bench.Equal("asks first", bench.world.lastPopup and bench.world.lastPopup.which, "GOLDSMITH_RESET_SETTINGS")
StaticPopupDialogs.GOLDSMITH_RESET_SETTINGS.OnAccept(nil, bench.world.lastPopup.data)
bench.Equal("tooltips back", addon:Setting("tooltips"), "full")
bench.Equal("sounds back", addon:Setting("sounds"), true)
bench.Check("excluded character kept", not addon:IsCharacterIncluded("Maddoxynn-Sargeras"))
bench.Check("ignored craft kept", addon:IsIgnored(12345))
bench.Has("dashboard: nothing changed", bench.Screen(), "0 of 16")
-- Help, Support and the bug report open in the panel, not windows of
-- their own (user, 2026-10-25)
panel:Open("dashboard")
bench.Click("Help")
bench.Check("settings stay open for Help", panel:IsShown())
bench.Has("Help page", bench.Screen(), "Show getting started")
bench.Click("Support and feedback")
bench.Check("settings stay open for Support", panel:IsShown())
bench.Has("Support page", bench.Screen(), "Use GitHub? Issues work too:")
bench.Click("Copy bug report")
bench.Has("bug report page", bench.Screen(), "Select all")
bench.Click("Back")
bench.Has("back to Support", bench.Screen(), "Use GitHub? Issues work too:")
panel:Hide()
addon:ShowBugReport()
bench.Check("/gsm report opens the panel", panel:IsShown())
bench.Has("on the bug report", bench.Screen(), "Select all")
panel:Search("interact key")
bench.HasNot("search finds Help's text", bench.Screen(), "No setting matches")

-- A dropdown's button shows the choice without "(recommended)", which
-- ran off the end; the menu still marks it (user, 2026-10-25)
panel:Open("buying")
screen = bench.Screen()
bench.Has("button shows the choice", screen, "Up to 2% more")
bench.HasNot("no (recommended) on the button", screen, "(recommended)")

bench.Done()
