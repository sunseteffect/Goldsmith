-- Send to Auctionator is hidden unless turned on (Settings > Buy next):
-- Buy next does the shopping, and Goldsmith no longer pushes Auctionator
-- (user, 2026-10-26). On, it's back on the queue and plans; off, Craft
-- next takes its place.
local bench = dofile(BENCH_DIR .. "bench.lua")
local KEY = "Mysticmead-Sargeras"
local db = bench.LoadSaved()
db.queues[KEY] = { { recipeID = 1226197, quantity = 8, made = 0, added = os.time() } } -- Azeroot Tea
Auctionator = { API = { v1 = {} } }
local addon = bench.Login("Mysticmead", { db = db })

bench.Equal("off by default", addon:Setting("auctionatorButton"), false)
addon:ToggleWindow()
addon:ShowTab("queue")
bench.Advance(3)
bench.HasNot("queue: no Send to Auctionator", bench.Screen(), "Send to Auctionator")
addon:OpenCraftPlan(GoldsmithDB.recipes[1226197], {}, KEY, 8, "queue")
bench.Advance(2)
bench.HasNot("plan: no Send to Auctionator", bench.Screen(), "Send to Auctionator")

addon:SetSetting("auctionatorButton", true)
addon:ShowTab("queue")
bench.Advance(3)
bench.Has("queue: Send to Auctionator when on", bench.Screen(), "Send to Auctionator")

-- Getting started no longer recommends Auctionator
addon:ShowSetup()
bench.Advance(2)
local setup = bench.Screen()
bench.Has("setup: Goldsmith Data step", setup, "Goldsmith Data")
bench.HasNot("setup: no Recommended: Auctionator", setup, "Recommended: Auctionator")
bench.Done()
