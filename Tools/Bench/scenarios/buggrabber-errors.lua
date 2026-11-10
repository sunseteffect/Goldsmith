-- With BugSack installed, Goldsmith still records its own errors (2026-11-10:
-- today's BugGrabber announces them through EventRegistry, and Goldsmith
-- only listened the old way, so a What's new error showed in BugSack only)
local bench = dofile(BENCH_DIR .. "bench.lua")
-- BugGrabber owns the error handler and announces each error by ID
local callbacks = {}
EventRegistry = { RegisterCallback = function(_, event, fn, owner) callbacks[event] = fn end,
                  TriggerEvent = function(_, event, ...) if callbacks[event] then callbacks[event](nil, ...) end end }
local errors = {}
BugGrabber = { GetErrorByID = function(_, id) return errors[id] end }
local grabberHandler = function() end
geterrorhandler = function() return grabberHandler end
seterrorhandler = function() end
local addon = bench.Login("Mysticmead")
bench.Fire("PLAYER_LOGIN")
bench.Advance(1)
bench.Check("listening to BugGrabber.BugGrabbed", callbacks["BugGrabber.BugGrabbed"] ~= nil)
local before = #(GoldsmithDB.errorLog or {})
errors.e1 = { message = "Goldsmith/WhatsNew.lua:90: attempt to index local 's' (a nil value)",
              stack = "[Goldsmith/WhatsNew.lua]:90: in function <Goldsmith/WhatsNew.lua:77>" }
EventRegistry:TriggerEvent("BugGrabber.BugGrabbed", "e1")
bench.Equal("Goldsmith's error recorded", #(GoldsmithDB.errorLog or {}), before + 1)
-- Another addon's error isn't Goldsmith's
errors.e2 = { message = "OtherAddon/Core.lua:5: oops", stack = "[OtherAddon/Core.lua]:5" }
EventRegistry:TriggerEvent("BugGrabber.BugGrabbed", "e2")
bench.Equal("another addon's error left out", #(GoldsmithDB.errorLog or {}), before + 1)
bench.Done()
