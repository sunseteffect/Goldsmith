-- The mailbox panel and the Craft complete notice move where they're
-- dragged and stay there (user, 2026-10-24); right-click puts them back.
-- A drag of the notice doesn't count as the click that closes it.
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT = 236774
local db = bench.LoadSaved()
db.ui2.mailPanel, db.ui2.craftDonePos = nil, nil
db.queues["Mysticmead-Sargeras"] = { { recipeID = 1226197, quantity = 8, made = 0, added = os.time() } }
db.boughtFor["Mysticmead-Sargeras"] = { [AZEROOT] = { quantity = 8, holder = "Maddoxynn-Sargeras", time = os.time() } }
local tsmMail = false
TSM_API = { IsUIVisible = function(ui) return ui == "MAILING" and tsmMail end }
local addon = bench.Login("Maddoxynn", { db = db })
bench.SetBags({ [AZEROOT] = 8 })

local function Point(f)
    local point, rel, relPoint, x, y = f:GetPoint(1)
    return string.format("%s %s %s %d %d", tostring(point), rel == UIParent and "UIParent" or rel == MailFrame and "MailFrame"
        or tostring(rel), tostring(relPoint), x or 0, y or 0)
end
local function Drag(f, left, top)
    bench.world.dropAt = { left, top }
    f:GetScript("OnDragStart")(f)
    f:GetScript("OnDragStop")(f)
    bench.world.dropAt = nil
end
-- The right-click menu's button with this text
local function MenuButton(text)
    local found
    local root = { CreateTitle = function() end, CreateDivider = function() end,
        CreateButton = function(_, label, fn) if label == text then found = fn end end }
    bench.world.lastMenu(nil, root)
    return found
end

-- The mailbox panel
bench.OpenMail()
local panel
for _, f in ipairs(bench.wow.frames) do
    if f._text == "GOLDSMITH: MAIL" then panel = f._parent end
end
bench.Check("mail panel shows", panel and panel:IsVisible())
bench.Equal("beside the mailbox at first", Point(panel), "TOPLEFT MailFrame TOPRIGHT 4 0")
Drag(panel, 300, 700)
bench.Equal("spot saved", db.ui2.mailPanel and (db.ui2.mailPanel.x .. "," .. db.ui2.mailPanel.y), "300,-380")
bench.Equal("stays where dropped", Point(panel), "TOPLEFT UIParent TOPLEFT 300 -380")
bench.CloseMail()
bench.OpenMail()
bench.Equal("same spot next time", Point(panel), "TOPLEFT UIParent TOPLEFT 300 -380")
bench.CloseMail()
bench.OpenMail()
tsmMail = true
MailFrame:Hide()
bench.Advance(2)
bench.Check("shows with TSM's mailbox", panel:IsVisible())
bench.Equal("same spot with TSM's mailbox", Point(panel), "TOPLEFT UIParent TOPLEFT 300 -380")
tsmMail = false
MailFrame:Show()
bench.Fire("MAIL_INBOX_UPDATE")
bench.Advance(1)
panel:GetScript("OnMouseUp")(panel, "RightButton")
local back = MenuButton("Put it back by the mailbox")
bench.Check("right-click offers to put it back", back ~= nil)
if back then back() end
bench.Equal("spot forgotten", db.ui2.mailPanel, nil)
bench.Equal("back beside the mailbox", Point(panel), "TOPLEFT MailFrame TOPRIGHT 4 0")
bench.CloseMail()

-- The Craft complete notice
addon:ShowSalvageDone(AZEROOT, { made = 5, got = {} })
local toast = GoldsmithCraftDone
bench.Check("notice shows", toast and toast:IsShown())
bench.Has("says click to close", bench.TextOf(toast), "click to close")
bench.Equal("upper middle at first", Point(toast), "TOP UIParent TOP 0 -260")
Drag(toast, 800, 900)
toast:Click("LeftButton")
bench.Check("letting go of a drag doesn't close it", toast:IsShown())
bench.Equal("spot saved", db.ui2.craftDonePos and (db.ui2.craftDonePos.x .. "," .. db.ui2.craftDonePos.y), "800,-180")
bench.Advance(0)
toast:Click("LeftButton")
bench.Check("a click closes it", not toast:IsShown())
addon:ShowSalvageDone(AZEROOT, { made = 5, got = {} })
bench.Equal("next notice at the saved spot", Point(toast), "TOPLEFT UIParent TOPLEFT 800 -180")
toast:Click("RightButton")
bench.Check("right-click doesn't close it", toast:IsShown())
bench.Equal("right-click forgets the spot", db.ui2.craftDonePos, nil)
bench.Equal("back in the upper middle", Point(toast), "TOP UIParent TOP 0 -260")
bench.Done()
