# Goldsmith

A World of Warcraft addon that tells you what to craft for gold, on which character, and how to get the materials, then tracks what you actually earned.

Most players don't want to study the auction house. Goldsmith gives you a short list: **Do this next**.

## What it does
- **Do this next:** the best crafts right now, where to spend concentration, cooldowns ready to use, salvage worth doing, and materials selling cheap. How many to make follows how fast your own batches sell: more when they sell out quickly, fewer when they slow down. Suggestions are kept to solid bets: a craft has to make a profit *and* sell.
- **Crafts:** every recipe your characters know, costed with each character's own stats (multicraft, resourcefulness, ingenuity) and the cheapest mix of material qualities for each tier, with and without concentration. Show Recommended, Profitable, All crafts, or Not learned yet (recipes you haven't learned, with what they'd earn and where to learn them). Hide gear, search, or ignore items you never want to see. Each craft shows how well it sells: Sells, Slow or Hardly sells.
- **Planner:** for any craft, whether to buy, craft, mill or prospect each material (right-click one to choose another way, or which item to salvage for it, for that plan only), and a Craft button that walks you through each step. What to craft is picked on today's prices; the plan's profit is on what your materials cost you. Shopping lists cover the unlucky case, so one trip is always enough.
- **Queue:** queue crafts on each character and shop for all of them at once; right-click a craft in Overview or Characters to queue it in one click. Then press Craft next (or its key binding) to work through them: mill, make materials, then craft. A button swaps in the profession tool that suits the next craft.
- **Shopping:** Goldsmith scans the AH itself for every price. **Buy next** buys your queue's materials one item at a time right from the AH, for this character or every character's queue, and warns you when the AH asks more than the plan counted on. The vendor panel buys the exact vendor materials in one click. At the mailbox, a panel sends each character what their queue needs. (Or send the list to Auctionator: turn its button on in Settings.)
- **Before you lose gold:** a raid warning and a popup when a craft you're buying for would lose money (Buy next asks twice). Posting under break-even gets a line in chat.
- **Salvage:** milling, prospecting, crushing and recycling as profit rows, from the yields you actually get. The planner shows whether salvaging beats buying.
- **Characters:** a to-do list for each alt, with their professions, concentration and craft cooldowns. Cooldowns that are ready and worth making show up in Do this next.
- **Items and History:** prices and price history, your stock across bags, banks and the warband bank, every sale, purchase and deposit with real profit after the AH cut, and your total gold over time with where it is. Collecting AH sales from the mailbox lists what each sold for, then the total. Cheap materials suggests stock-ups from what you actually use; right-click one to queue it for Buy next.
- **Stats:** lifetime numbers to compare with friends: a Goldsmith title earned by profit, best sale, best day, profit streaks, biggest mailbox haul, multicraft procs, your most profitable professions and characters, and how often Goldsmith's suggestions held up. Share in chat to brag.
- **Hovers that explain themselves:** hovers stay short, just the numbers. Hold Ctrl over one to see what each number means and how it's worked out.

## Requirements
- English game client (other languages aren't supported yet)
- [Goldsmith Data](https://github.com/sunseteffect/GoldsmithData): region-wide AH prices for US, EU, KR and TW, refreshed daily, and how well each item sells. CurseForge installs it with Goldsmith.

## Using Auctionator?
Not needed: Goldsmith scans the AH itself and Buy next does the shopping. Auctionator is still handy for posting your crafts, and Goldsmith reads its scans. To shop with Auctionator's shopping lists instead, turn on Settings > Send to Auctionator button.

## If you already use TSM
Not needed: Goldsmith Data covers prices and how well each item sells. If TradeSkillMaster and its desktop app are installed anyway, Goldsmith uses TSM's region sales per day and sale rates instead of Goldsmith Data's Sells / Slow / Hardly sells, plus prices between your AH scans and a check on listings far from the usual price.

## Getting started
1. Install Goldsmith (with Goldsmith Data), then log in.
2. Open each of your professions once so Goldsmith can load your recipes.
3. For live prices, open the auction house and press **Scan the AH**. Until then, Goldsmith Data's prices fill in.
4. Type `/gsm` or click the minimap button. The Overview shows a checklist until you're set up.

Repeat step 2 on each alt with professions.

## Commands
- `/gsm`: show or hide the window
- `/gsm help`: list every command
- `/gsm setup`: show the getting started checklist again
- `/gsm report`: copy a bug report to paste into a GitHub issue

You can also set keys for opening Goldsmith and for Craft next in the game's Key Bindings, in their own Goldsmith section.

## Good to know
- Goldsmith never crafts, buys or posts on its own. Every craft and every purchase is one press of a button or key.
- Posting your crafts on the AH is up to you (TSM or Auctionator do that well).
- Characters on more than one realm group: material prices from your AH scan count everywhere in your region (one AH for the whole region), gear prices only on the realms they came from.

## Support and feedback
- Found a bug or have an idea? [Leave a comment on CurseForge](https://www.curseforge.com/wow/addons/goldsmith-crafting-profit-planner/comments), or [open an issue on GitHub](https://github.com/sunseteffect/Goldsmith/issues) if you use it. In game, Settings > Support and feedback has both links and a Copy bug report button that gathers the details for you.
- Goldsmith is free. If it makes you gold and you'd like to say thanks, you can [buy the goldsmith a mana potion on Ko-fi](https://ko-fi.com/the_goldsmith).

## License
All rights reserved. You're welcome to use Goldsmith, read the code, report bugs and suggest changes; copying or republishing it needs permission. See [LICENSE](LICENSE).
