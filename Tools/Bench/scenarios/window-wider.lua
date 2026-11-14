-- The window can be dragged wider (user, 2026-11-13: more columns at
-- once), never narrower than it was laid out for, never past the screen.
-- Lists stretch; the tabs laid out to a fixed width stay that width.
local bench = dofile(BENCH_DIR .. "bench.lua")
UIParent:SetWidth(1920)
-- Saved wider: opens that wide
local db = bench.LoadSaved()
db.ui2 = db.ui2 or {}
db.ui2.width = 1300
local addon = bench.Login("Mysticmead", { db = db })
local ui = GoldsmithDB.ui2
addon:ToggleWindow()
bench.Advance(1)
local frame = addon.window or GoldsmithWindow
bench.Equal("opens as wide as saved", frame and math.floor(frame:GetWidth()), 1300)
addon:ShowTab("crafts")
bench.Advance(3)
addon:ShowTab("overview")
bench.Advance(3)
local crafts = addon:GetTabScreen("crafts").frame
local overview = addon:GetTabScreen("overview").frame
bench.Equal("the Overview keeps its width", overview:GetWidth(), 860)
local point = overview:GetPoint(1)
bench.Equal("centered", point, "TOP")
local cPoint = crafts:GetPoint(1)
bench.Check("Crafts stretches with the window", cPoint ~= "TOP")
bench.Check("grip there", frame.resizeGrip ~= nil)
-- Items stretches too (its list said "no room" beside empty space)
addon:ShowTab("items")
bench.Advance(3)
bench.Check("Items stretches", addon:GetTabScreen("items").frame:GetPoint(1) ~= "TOP")

-- Dragged narrow with columns laid out wide: the list's own size can land
-- after the grip is let go, with no size change after (user, 2026-11-13:
-- every column stayed out past the window's edge). A frame later it's
-- laid out again for the width it has.
addon:ShowTab("crafts")
bench.Advance(3)
local list = addon:GetTabScreen("crafts").view.list
list:Update()
local wide = list.layoutWidth
addon.UI.BeginSizing()
bench.Check("cut off at its edge while dragged", list._clips == true)
-- The new width, without a size change event (as in game)
for _, child in ipairs({ list:GetChildren() }) do
    if child:GetWidth() == wide then child._w = wide - 300 end
end
addon.UI.EndSizing()
bench.Check("not once let go", not list._clips)
bench.Advance(0.3)
bench.Check("laid out again for the narrower width", list.layoutWidth and list.layoutWidth < wide,
    tostring(wide) .. " -> " .. tostring(list.layoutWidth))

-- The grip's double-click: back to normal, nothing saved
if frame.resizeGrip then
    frame.resizeGrip:GetScript("OnDoubleClick")(frame.resizeGrip)
    bench.Equal("double-click: normal width", math.floor(frame:GetWidth()), 900)
    bench.Equal("nothing saved", ui.width, nil)
end
bench.Equal("no errors", #bench.TakeErrors(), 0)
bench.Done()
