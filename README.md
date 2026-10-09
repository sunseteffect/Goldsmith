# Goldsmith

A World of Warcraft addon that tells you what to craft for gold, on which character, and how to get the materials, then tracks what you actually earned.

Most players don't want to study the auction house. Goldsmith gives you a short list: **Do this next**.

## What it does
- **Do this next:** the best crafts right now, where to spend concentration, cooldowns ready to use, salvage worth doing, and materials selling cheap. How many to make follows how fast your own batches sell: more when they sell out quickly, fewer when they slow down. Suggestions are kept to solid bets: a craft has to make a profit *and* sell.
- **Crafts:** every recipe your characters know, costed with each character's own stats (multicraft, resourcefulness, ingenuity) and the cheapest mix of material qualities for each tier, with and without concentration. Show Recommended, Profitable, All crafts, or Not learned yet (recipes you haven't learned, with what they'd earn and where to learn them). Hide gear, search, or ignore items you never want to see. Each craft shows how well it sells: Sells, Slow or Hardly sells.
- **Planner:** for any craft, whether to buy, craft, mill or prospect each material, a shopping list sent to Auctionator, and a Craft button that walks you through each step. Shopping lists cover the unlucky case, so one trip is always enough.
- **Queue:** queue crafts on each character and shop for all of them at once. Then press Craft next (or its key binding) to work through them: mill, make materials, then craft.
- **Salvage:** milling, prospecting and crushing as profit rows, from the yields you actually get. The planner shows whether salvaging beats buying.
- **Characters:** a to-do list for each alt, with their professions, concentration and craft cooldowns. Cooldowns that are ready and worth making show up in Do this next.
- **Items and History:** prices and price history, your stock across bags, banks and the warband bank, every sale, purchase and deposit with real profit after the AH cut, and your total gold over time with where it is.
- **Hovers that explain themselves:** hovers stay short, just the numbers. Hold Ctrl over one to see what each number means and how it's worked out.

## Requirements
- English game client (other languages aren't supported yet)
- [Goldsmith Data](https://github.com/sunseteffect/GoldsmithData): region-wide AH prices for US, EU, KR and TW, refreshed daily, and how well each item sells. CurseForge installs it with Goldsmith.

## Recommended
Both are free on CurseForge, and neither is required: Goldsmith works without them.
- Auctionator, for live prices when you buy and sell, and for shopping lists.
- TradeSkillMaster with its desktop app. With TSM, Goldsmith uses its region sales per day and sale rates instead of Goldsmith Data's Sells / Slow / Hardly sells, plus prices between your Auctionator scans and a check on listings far from the usual price. TSM's numbers are probably more accurate, but without it Goldsmith Data's sell levels work well to decide what's worth making.

## Getting started
1. Install Goldsmith (with Goldsmith Data) and Auctionator, then log in.
2. Open each of your professions once so Goldsmith can load your recipes.
3. For live prices, run a full Auctionator scan at the auction house. Until then, Goldsmith Data's prices fill in.
4. Type `/gsm` or click the minimap button. The Overview shows a checklist until you're set up.

Repeat step 2 on each alt with professions.

## Commands
- `/gsm`: show or hide the window
- `/gsm help`: list every command
- `/gsm setup`: show the getting started checklist again
- `/gsm report`: copy a bug report to paste into a GitHub issue

You can also set keys for opening Goldsmith and for Craft next in the game's Key Bindings, under AddOns.

## Good to know
- Goldsmith never crafts, buys or posts on its own. Every craft is one press of a button or key.
- Posting your crafts on the AH is up to you (TSM or Auctionator do that well).

## Support and feedback
- Found a bug or have an idea? [Open an issue on GitHub](https://github.com/sunseteffect/Goldsmith/issues). In game, Settings > Support and feedback has the link and a Copy bug report button that gathers the details for you.
- Goldsmith is free. If it makes you gold and you'd like to say thanks, you can [buy me a coffee on Ko-fi](https://ko-fi.com/sunseteffect).

## License
All rights reserved. You're welcome to use Goldsmith, read the code, report bugs and suggest changes; copying or republishing it needs permission. See [LICENSE](LICENSE).
