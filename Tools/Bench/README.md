# Goldsmith test bench

Runs Goldsmith outside WoW, with stand-ins for the game's functions, on
your saved data, so the logic can be checked after every change without
logging in: plans, prices, queues, Buy next, the mailbox panel, what each
panel and chat line says.

```
lua Tools\Bench\run.lua            every scenario
lua Tools\Bench\run.lua mail       only scenarios with "mail" in the name
lua Tools\Bench\run.lua -v         every check, passes too
Tools\Bench\run.cmd                the same, from Explorer
```

Lua 5.1 is at `C:\Program Files (x86)\Lua\5.1\lua.exe`. Each scenario runs in
its own process and takes about a second.

## What it does and doesn't do

- **Loads the real addon:** every file in `Goldsmith.toc`, in order, then
  login (`ADDON_LOADED`, `PLAYER_LOGIN`, `PLAYER_ENTERING_WORLD`) and 20
  seconds of login chores.
- **On your saved data, read-only:** `WTF\...\SavedVariables\Goldsmith.lua`
  is read into memory. Nothing is written back. Set `GOLDSMITH_SAVED` to use
  another file.
- **A character's world from what Goldsmith saved:** their bags, bank, gold
  and the warband bank come from their last login. The clock starts at their
  last login too.
- **Draws nothing.** Frames keep their text, shown/hidden state and click
  handlers, so a scenario can read a panel and click its buttons. Layout,
  overlap and colors still need the game.
- **Time is virtual.** `C_Timer` callbacks run only when a scenario calls
  `bench.Advance(seconds)`.
- **Lua errors fail the scenario.** Errors inside Goldsmith's event handlers
  and timers are caught (as the game does) and listed at the end.

## Writing a scenario

A file in `scenarios\`:

```lua
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()                  -- change it before logging in
db.queues["Mysticmead-Sargeras"] = { { recipeID = 1226197, quantity = 8, made = 0, added = os.time() } }
local addon = bench.Login("Maddoxynn", { db = db })
bench.SetBags({ ["Azeroot"] = 18 })
bench.OpenAH()
bench.Has("says to mail them", bench.Screen(), "You have 18 Azeroot: mail")
bench.Click("Buy 8 Azeroot")
bench.Done()
```

Shared code for several scenarios goes in `lib\` (see
`todo-concentration.lua`).

### Setting up

| | |
|---|---|
| `bench.LoadSaved()` | the saved GoldsmithDB, to change before logging in |
| `bench.Login(name, opts)` | log in as a saved character. `opts`: `db`, `fresh = true` (new install), `bags`, `money`, `time`, `settle` |
| `bench.SetBags({ [id or name] = n })` | change the bags (nil removes) |
| `bench.SetMoney(copper)` | |
| `bench.SetListings({ [id] = { {unitPrice, qty}, ... } })` | AH listings for searches |
| `bench.AddItem(id, name, fields)` | an item the saved data doesn't name |
| `bench.ItemID(name)`, `bench.Gold(g)` | |
| `bench.world` | everything else the game knows: `buffs`, `merchant`, `inbox`, `currencies`, `recipeInfo`, `schematics`, `operations`, `modifiers`, `combat` |
| Globals | set `TSM_API`, `Auctionator` and so on before `Login` to have them installed |

### Doing things

| | |
|---|---|
| `bench.OpenProfession("Cooking")` / `CloseProfession()` | the profession window, its recipes answered from the saved ones (quality stats only if `world.operations` has them) |
| `bench.OpenAH()` / `CloseAH()`, `OpenMail()` / `CloseMail()`, `OpenVendor(items)` / `CloseVendor()` | |
| `bench.Click("label", mouseButton, wait)` | click the shown button with that text, then let `wait` seconds pass (default 1) |
| `bench.Slash("/gsm data")` | |
| `bench.QuotePrice(id, unitPrice, qty)` | the AH answers a purchase's price request |
| `bench.PurchaseSucceeds(id, qty, total)` | gold comes off, the items go to the mailbox |
| `bench.TakeMail()` | the mailbox's items into the bags |
| `bench.Fire(event, ...)`, `bench.Advance(seconds)` | |
| `addon:...` | any of Goldsmith's own functions |

### Checking

| | |
|---|---|
| `bench.Check(name, ok, detail)`, `Equal(name, got, want)`, `Near(name, got, want, tolerance)` | |
| `bench.Has(name, where, text)` / `HasNot` | plain text in a string or any line of a list (`false` as a 4th argument for a Lua pattern) |
| `bench.Screen()` | text of every frame showing now |
| `bench.Chat()` | chat lines since the last call (`bench.loginChat`: what login said) |
| `bench.Calls()` | game calls since the last call: `"ConfirmCommoditiesPurchase(236774, 8)"` |
| `bench.Serialize(t)`, `Diff(a, b)`, `Copy(t)` | compare data before and after |
| `bench.Show(lines)`, `bench.Log(...)` | print, to see what to check for |
| `bench.Done()` | last line: prints the result |

## When the game is missing something

`wow.lua` holds the stand-ins. A frame answers any method: setters do nothing,
`Get...` gives 0, `Is/Has/Can...` false, `Create...` a new frame. Missing
global functions show as Lua errors naming them: add them to `wow.lua`.
