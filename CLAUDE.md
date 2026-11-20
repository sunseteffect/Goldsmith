# Goldsmith: working notes for Claude

Goldsmith is a World of Warcraft crafting-profit addon (Lua 5.1, WoW API) for retail (Midnight) and WoW Forever (client 1.60.x, one addon with an `addon.isForever` check). Published on CurseForge as "Goldsmith - Crafting Profit Planner", with the companion data addon Goldsmith Data (its own repo).

The developer plays and tests mostly on **Forever**. Assume Forever for questions and bug reports unless told otherwise.

## What the addon is for

- Core workflow, taught first everywhere: **pick what to craft → queue it → buy it (Buy next at the AH, vendor panel) → craft it (Craft next)**. Stats, history and charts are bonus.
- It's about making gold, not only crafting: vendor flips and other gold sources count in the totals with their own label.
- Design for the middle player (less into numbers than the developer). People learn by doing: explain a feature where it's used, not in long tours.
- Recommendations are solid bets only. When in doubt, leave a craft out of suggestions; the Crafts tab still lists it with the reason (`WhyNotRecommended` in Insights.lua).

## Rules the code follows

- **Two price bases:** decide (Crafts list, Do this next) on today's prices only; show (plan, queue, craft done) what the materials cost you.
- **A price needs quantity behind it.** Lowest-only sources (search list, Auctionator, page scan) can't move a price far from usual on their own. Full scans and live order books are trusted.
- **Shopping lists cover the unlucky case:** full materials per craft, guaranteed output only, concentration at the full cost to start (ingenuity is only shown as a chance). Leftovers are fine; shopping twice is not.
- **Never freeze the game.** Slow work runs in frame-budgeted pieces (`addon:Yield()`) with a visible "Loading..." state, even if slower overall.
- **Short UI text.** Shortest clear wording, lists one item per line, show the number the player acts on.
- Buy next is the shopping path; don't promote Auctionator (Send to Auctionator is a hidden opt-in).
- Tooltips: decide what Goldsmith shows by whether another addon *actually* shows that line, not by whether it's installed.
- Never wrap or replace Blizzard chat functions (`ChatFrame.AddMessage`): chat carries secret values and it taints chat. Check `issecretvalue` before indexing any game string.
- Don't parse localized game text by English word order (German clients broke on that).
- Debug commands (`/gsm sound`, `/gsm buylist`) only run with `GoldsmithDB.devTools = true` and stay out of help and docs.
- Comments explain *why* a rule exists, usually with the case that caused it and the date. Keep that style.

## Testing

- **Test bench:** `Tools/Bench` runs the addon under plain Lua 5.1 with game stand-ins on a copy of real saved data. After any logic change, add or update a scenario and run the whole bench:
  `lua Tools/Bench/run.lua` (no argument; about 2 minutes). An argument is a **name filter**, so `run.lua all` runs only scenarios with "all" in the name. How-to: `Tools/Bench/README.md`.
- Syntax check: `luac -p File.lua` (delete the stray `luac.out`).
- The bench can't see layout. Anything it can't reach gets an in-game check on the developer's numbered test checklist (numbers never change; ticked items are dated).
- **Forever loads a separate copy** of the addon from `_forever_\Interface\AddOns\Goldsmith` (plain files). After every change, copy `*.lua`, `Goldsmith.toc` and `README.md` there and confirm with `diff -rq` before asking for a `/reload`. For Forever bugs, read the Forever saved data, not retail's.

## Git and releases

- Commit only when the developer says so; push only on a separate go.
- **Never** bump the `.toc` version, tag or build a release zip without the developer's explicit go. Fixes stay on `main` with the version unchanged while testing goes on.
- Release flow: check the docs for what changed (README, CurseForge description, in-game help, help mode text, tour, What's new: read in full, not grepped) → full bench → set `## Version:` → commit → tag `vX.Y.Z-beta` → `Tools/Package.ps1` builds the zip from git → changelog as a plain code block → push `main` and the tag (`refs/heads/...`, `refs/tags/...`: a branch and a tag share the name `v2`).
- CurseForge uploads are tagged with every supported game version (current retail versions and Forever 1.60.1).
- Player reports come through CurseForge comments first, GitHub issues second.

## Talking with the developer

- Give real verdicts and push back when something is weak; don't agree by default.
- Ideas come up mid-play: build agreed ones right away, test them later in one batch.
