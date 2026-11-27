# FS25 Dynamic Market Events — Design

A standalone **global economy mod** for Farming Simulator 25 that makes market
prices fluctuate over time through random events. Works on **any map** (not tied
to a specific map's `fillTypes.xml`). Packaged as a `.zip` with
`modDesc.xml` (`descVersion="96"`).

Status: **design in progress** — event roster being built collaboratively.

---

## Core concept

On every in-game day the mod rolls a chance to trigger a market event. If it
fires, one event is chosen from a weighted pool, then a **severity** is rolled.
The event applies a temporary, **time-varying** price impact to a set of
products, then expires. Multiple events can be active at once and **stack**.

Players see only the **live daily modifier** at sell points (e.g.
`Wheat 2003  ^15.7%`) — never the underlying curve, peak, or remaining
duration. The event message gives qualitative flavor only. Surprise + judgment
are the gameplay.

**The in-game price graph does reflect events, for elapsed months.** Verified in
testing: with a +27% drought running, wheat's graph peaked in **November** at
1,405 instead of its vanilla **January** peak, a +24.7% residual over the vanilla
Nov/Aug ratio — matching the modifier reported by `mswPrice`. The graph plots
recorded history for past and current months and an un-evented projection for
future ones, so the shape visibly distorts while an event runs and the forecast
beyond it stays flat. This corrects an earlier assumption that the graph was
purely static seasonal data: no UI work is needed for players to get a visual
signal.

**The commodity-name marker works.** Writing to `fillType.title` (see
`PriceDisplayAdapter`) shows up in the prices list as e.g. `Wheat  [+60%]`, and
because each product carries its own figure the damping and ripple lag are
visible directly in the UI — a single drought reads `Wheat [+60%]`,
`Straw [+57%]`, `Bread [+16%]` at once.

An earlier test appeared to show it failing. The list evidently builds its rows
when the menu opens, so the marker only appears if the menu is opened *after* a
refresh has applied it; a menu already open when the event fired showed stale
names.

---

## Trigger mechanics

- **One roll per in-game day**, always — independent of what is already active
  (because events stack).
- **Per-day probability (per event, seasonal):**

  ```
  p_e(month)         = K × baseWeight_e × monthShare_e[month] / D
  monthShare_e[month] = monthWeight_e[month] / Σ_month monthWeight_e   (sums to 1)
  K                  = E / Σ_e baseWeight_e
  ```

  - `E` = the **"Events per year (average)"** user setting — total events/year
    across all events. Default **2.0**; `0` disables all events.
  - `D` = the player's **days-per-month** setting. The `/D` keeps the **annual**
    rate independent of month length (verified: ~1.70/yr at D = 1, 3, 10).
  - `monthWeight_e[month]` = a per-event 12-month profile; **0 = cannot trigger**
    that month. It's **normalized** (`monthShare`), so the season sets *when* an
    event fires, **not how often**.
  - Each event's annual rate = `K × baseWeight_e`. **Equal base weight → equal
    frequency** (e.g. drought vs bumper each ~0.85/yr → win/lose parity). The
    ~E/yr is a **fixed budget split across all events** by weight; raise `E` as
    the roster grows for more total activity.
- **Seasonal, not flat** — each event fires only in its allowed months, weighted
  within them. Editable by calendar-month name; the mod maps names → game
  periods (**period 1 = March**).

### Pile-up guards

Two rails stop the player being swamped with announcements:

1. **One event may start per day.** Even absent a cooldown, two dialogs in one day
   is exactly the pile-up worth preventing, so extra rolls that day are discarded.
2. **A minimum gap between event starts** — `minMonthsBetweenEvents`, default
   **2 game months**, which leaves one whole month silent:

   | | |
   |---|---|
   | April | event fires |
   | May | nothing can fire |
   | June | events may fire again |

   The gap is converted to days, so it behaves identically at any days-per-month
   (at 3 days/month it blocks the rest of April and all of May, freeing up on the
   first day of June). Applies to the random roll only; `mswTrigger` bypasses it
   deliberately, as it does the season check. Any event starting resets the clock,
   whether from the scheduler or the console.

Measured effect (`tools/cooldown_sim.py`):

| daysPerMonth | no cooldown | 1 month | 2 months | 3 months |
|---|---|---|---|---|
| 1  | 1.80 | 1.80 | 1.56 | 1.38 |
| 3  | 1.88 | 1.71 | 1.49 | 1.33 |
| 10 | 1.92 | 1.68 | 1.47 | 1.31 |

The default of **2** costs about 0.2 events/year (the table above was measured
at a target of 1.7, giving ≈1.5–1.6/yr) and buys a guaranteed silent month
between every pair of events. The shipped default target has since been raised
to **2.0** as the roster grew to 19 events, so that each event stays about as
frequent as it was; a full simulation of the scheduler, including mirrored
events blocking each other, puts the realised rate at about 1.6/yr.

Note that **1 would be a no-op**: a one-month gap means events may fire in
consecutive months, which is already possible — and at `daysPerMonth = 1` it
reduces to a single day, i.e. no restriction at all. 2 is the smallest value that
actually enforces silence. 3 is available for a quieter game but pulls the rate to
~1.3/yr.

### When an event fires

1. **Pick an event type** from the pool, weighted by
   `baseWeight × monthWeight[current month]` (only events active this month are
   eligible).
2. **Roll severity** — default distribution Low **60%** / Medium **30%** /
   High **10%** (per-event overridable).
3. **Roll a unique price curve** within the severity's parameter ranges (below).

---

## Price curve model

Each event instance is a smooth, time-varying curve — **not** a flat modifier.
Shape: **rise to an early peak → hold high on a slowly-decaying plateau → sharp
correction at the end** of the period (the new harvest). Over normalized time
`u = day / duration` (0→1):

```
rise    (u < peakPos):  intensity = (u / peakPos) ^ riseExp   # up to 1.0 at the early peak
plateau (post-peak):    intensity decays slowly 1.0 → hold    # base stays high

factor(day) = 1 + (peakMag - 1) × intensity × (1 ± dailyJitter)
```

**Harvest stabilization (market-wide correction).** Near the period end a smooth
envelope `S(month)` eases from 1 → 0 over the last `corr` months (~1 month), using
a smoothstep so it's fast but not instant. It multiplies the *deviation* of
**every product at once**:

```
finalFactor(product, day) = 1 + (factor(product, day) − 1) × S(month)
```

Because `S` is synchronized (not lagged), the whole chain corrects **together** —
new-harvest estimates stabilize wheat, flour, bread and cake at the same time,
quickly but smoothly. No downstream product lingers high after the base
normalizes.

- `peakMag` — maximum price factor (e.g. 1.67 = +67% at the peak).
- `peakPos` — where the peak lands (fraction of duration). Strong events peak
  **early** so the ripple has time to travel the chain.
- `riseExp` — onset steepness.
- `hold` — plateau level as a fraction of the peak swing (e.g. 0.72 = base stays
  at 72% of peak). **This keeps the base product elevated while the ripple works
  up the chain**, so it's never inconsistent (e.g. wheat still high when cake
  peaks). Bigger for stronger events.
- `corr` — length (months) of the harvest-stabilization correction at the end;
  everything eases back to baseline together over this window.
- `dailyJitter` — small day-to-day wiggle so the modifier is never static.

**Every parameter is rolled per instance** within the severity's ranges, so no
two events share a curve — players can't memorize the pattern (replayability).

---

## Stacking

When multiple active events affect the same product, their factors combine
**multiplicatively, with diminishing returns**. Per product, the effects pushing
the same way are ranked by today's size: the largest counts in full, the second
at **60%**, the third and any later one at **30%**.

`effective = (1 + d1) × (1 + 0.6·d2) × (1 + 0.3·d3) ...`

| Overlap on one product | Plain multiplication | With 100 / 60 / 30 |
|---|---|---|
| two medium rises (+25%, +25%) | +56% | +44% |
| two high rises (+70%, +70%) | +189% | +141% |
| three high rises (+70%, +70%, +50%) | +334% | +178% |
| two high falls (−32.5%, −32.5%) | −54% | −46% |
| a rise against a fall (+70%, −32.5%) | +15% | +15% |

Three rules make this behave:

- **Ranked by size, not by arrival.** If the first event to start always counted
  in full, the price would jump on the day it ended and the next was promoted.
  Ranking by today's size has no jump: where two effects cross they are equal,
  so swapping their weights changes nothing.
- **Rises and falls are ranked separately.** A drought against a glut is two real
  forces and still nets out in full; only effects pushing the *same* way dampen
  one another.
- **Per product.** A second event is only dampened on the products it shares; the
  rest of its reach moves at full strength.

The weights were chosen by simulation (30,000 years, 19 events, 1 day per
month). Every candidate made a product at +100% or more a once-in-thousands-of-
years sight; 100/60/30 kept the second event visibly meaningful (it adds 3 or
more points in about three overlaps out of four) while cutting the largest rise
seen from +183% to +137%. They live in `MSWPriceModel.STACK_WEIGHTS`. Stacking
still can never drive a price to zero or negative.

### Mutual exclusion — what must never stack

Two events sharing a **`subtype`** can never run at the same time. This exists for
the **mirrored pairs**: an ethanol boom on top of an ethanol glut is not a
compounding shock, it is the same market telling two opposite stories, and the
ripple maths would have them fighting over the same products. Eight pairs are
grouped:

| Subtype | Members |
|---|---|
| `grain` | grainDrought · grainBumper |
| `root` | rootDrought · rootBumper |
| `dairyTrade` | dairyEmbargo · dairyExportBoom |
| `medTrade` | mediterraneanEmbargo · mediterraneanExportBoom |
| `asiaTrade` | asianTradeDisruption · monsoonBounty |
| `ethanol` | ethanolGlut · ethanolBoom |
| `greenhouse` | greenhousePest · greenhouseBounty |
| `consumerShift` | pandemicCrisis · trendyLifestyle |

**Alternating is fine** — the moment one expires the other is eligible again
(subject to the normal cooldown). Only overlap is forbidden.

`subtype` **defaults to the event's own id**, so an event without one blocks only
itself. That is exactly the self-overlap rule that always applied, now expressed
as one mechanism instead of two. The three unpaired events — harsh winter, natural
disaster, input shock — carry no subtype.

The rule is enforced in `PriceModel:findActiveBySubtype`, which returns the
*offending event* rather than a boolean so log lines can name it, and it is
checked on **every** start path: the daily roll, `fireEvent`, and `mswTrigger`.
The console bypasses the season window and the cooldown deliberately, but not
this — forcing it would produce a state the scheduler can never reach.

### What still stacks, deliberately

Events with **different** subtypes stack freely even where they share products,
and that is not an oversight:

- `ethanolGlut` pushes `MAIZE` down while `grainDrought` pushes it up. Two real
  forces pulling against each other — a drought tightening supply while biofuel
  demand collapses is an ordinary year in a real commodity market.
- `TOMATO` sits in four events (both Mediterranean, both greenhouse). A pest
  outbreak and an export embargo are unrelated causes that happen to touch the
  same crop.

The distinction is **narrative**, not arithmetic: mirrors are one story told
twice, and are excluded. Everything else is two stories at once, and compounds.

---

## Supply-chain propagation

Price shocks ripple **downstream** through the production chain, delayed and
dampened. When an upstream product's factor moves, each downstream product
echoes it after a lag, at a fraction of the swing:

```
downstreamFactor(t) = 1 + (upstreamFactor(t − lag) − 1) × passThrough
```

Example — one drought on `WHEAT` cascades with a **~1 month lag per layer**:
`WHEAT` peaks first → `FLOUR` ~1mo later → `BREAD` ~1mo after that → `CAKE` ~1mo
later still, each hop at a diminishing fraction of the previous swing. The ripple
**outlasts** the source (downstream products stay elevated after wheat returns to
baseline). These echoes stack multiplicatively with any *direct* events on the
downstream product.

### Lag is capped relative to the event

A hop's lag is written in months, which suits a drought that runs most of a year
and not a cold snap that runs a month or two: there a one-month lag is most of
the event, and at 1–2 days per month — where a short event is a handful of whole
days — the downstream product never moved at all. So one month of lag is never
allowed to take up more than **12 % of the event's duration**
(`MSWActiveEvent.MAX_HOP_LAG_SHARE`):

```
lagMonthDays = min(daysPerMonth, 0.12 × durationDays)
lagDays(hop) = lagDays(parent) + hop.lagMonths × lagMonthDays
```

The cap is on the length of a lag-month, not on each hop's total, so hops keep
their relative order (cake's two-month hop is still twice bread's one-month hop).
Long events are untouched — a high grain drought at 12 days per month has a cap
of ~16 days against a 12-day month — while every configured chain in a short
event now has room to play out. Because the capped lag depends only on the
event's saved duration, a reload reproduces it even if the player changed
days-per-month in between.

### A day's price is read at mid-day

A game day covers the interval `[d, d+1)` and its price is the curve at
`d + 0.5` (`MSWActiveEvent.DAY_SAMPLE_OFFSET`), not at `d`. Reading at the first
instant meant the firing day always sat at exactly 1.0: the news arrived and
nothing moved until the next day, which at 1 day per month wasted up to half of a
short event. With the mid-day sample the first prices move on the day of the
news, and an event traces the same month-by-month profile at 1 day per month as
at 12 (within ~2 points for a high grain drought).

The dependency graph and base prices come from `reference/product-catalog.md`
(extracted from the game's real fill types). Livestock/meat are excluded — a
different game system (see catalog).

**Deduplication rule.** When an event hits several raw crops that share a
downstream product (e.g. both wheat and barley are milled to flour), the raw
crops each move directly, but the shared processed product is driven by a
**single primary source** only. Every processed product appears exactly once in
the propagation graph — no double impact.

**Co-products.** Not every linked product is *downstream*. A co-product leaves
the same field in the same pass (straw from grain), so it tracks the source's
**volume**: it moves in the **same direction**, at **near-zero lag**, with high
pass-through — unlike a processed good, which arrives later and damped. Same
math, different lag/pass-through.

**Correlated products (forage).** Grass and hay are not derived from any crop —
the same weather hits them independently. A drought dries out pasture whichever
crop it targets, so `GRASS_WINDROW` and `DRYGRASS_WINDROW` appear in **every**
drought at tier 1 (so all severities reach them). Because both droughts can run
at once, they also **compound**. They are therefore deliberately **damped
(0.45**, against straw's 0.80): each event alone is a modest nudge and the overlap
is what adds up — verified at one HI drought ≈ **+38%** on grass, two overlapping
≈ **+84%**. They are expressed as chains purely to obtain that damping, since
anything in `affects` always moves at full magnitude. Fresh grass reacts first
(0.25mo — pasture visibly browns); hay follows (0.5mo) as cuts come in short.
`GRASS`, `MEADOW` and `DRYGRASS` are field states rather than tradeable goods, so
only the windrow forms are used.

**Direction.** Ripple normally flows *downstream* (raw → processed). Some events
instead ripple *input-ward*: e.g. a winter energy-price spike lifts biogas
feedstock (silage, manure) because expensive energy makes biogas output more
valuable. Mechanically it's identical math — only which products a driver pulls
differs.

**Ripple scales with severity** — depth (how far up the chain) and strength
(pass-through multiplier) both grow:

| Severity | Ripple depth | Pass-through scale | Effect |
|---|---|---|---|
| LOW | 1 hop (e.g. wheat→flour) | ~0.55× | shallow, barely reaches first product |
| MED | 2 hops (→bread) | 1.0× | moderate, the reference example |
| HI  | 3+ hops (→cake…) | ~1.3× | deep, the whole chain moves |

**HI peak is early, base held high.** A HI drought's *source* (wheat) peaks early
(~month 4 of 12) then **holds high on a plateau** through ~month 10, giving the
cascade runway to travel the full chain (flour→bread→cake, each ~1mo later) while
the base stays elevated — so no layer is ever inconsistent (wheat is still ~+58%
when cake peaks ~+29% at month 7). A **market-wide harvest
correction** near the period end (month ~11–12) eases the entire chain back to
baseline together — fast but smooth (~1 month) — so nothing lingers high after the
base normalizes.

## Balance philosophy

- **Frequency:** player-win (↑ price) and player-lose (↓ price) events roll
  about **equally often**.
- **Severity:** adverse (lose) events are **downtuned** — smaller magnitudes
  and/or shorter durations — so the economy stays challenging but fun.

---

## User settings (in-game menu)

Fifteen settings, on the **Settings** tab of the mod's own ESC-menu page (see
*The hub page* below). Each has a description in the right-hand panel. If that
page cannot be added on some game version, the same rows fall back to **ESC →
Settings → GAME SETTINGS**, under a `MARKET SHOCKWAVES` section header, which is
where they lived up to build b19. Everything is also reachable from the console (`mswSettings`, `mswSet`,
`mswReset`), and the two routes share one code path.

| Setting | Type | Effect |
|---|---|---|
| **Enable Market Shockwaves** | on/off, default on | master switch. Events already running are allowed to **expire naturally** rather than being cut off, so the market winds down instead of snapping back. |
| **Events per year (average)** | steps 0…10, default **2** | sets `E` directly — the average total events/year across all events. **0 disables** new events. |
| **Minimum time between events** | steps 0…12 months, default **2** | cooldown on event *starts*. 2 leaves one whole month silent; 1 would be a no-op, since consecutive months are already allowed. |
| **Maximum events at once** | steps 1…8, default **3** | ceiling on simultaneous events. Events are designed to stack, so this is the rail that stops an unlucky run compounding indefinitely. |
| **Event Intensity** | 0–200%, default 100% | scales price-swing magnitude + daily jitter |
| **Event Duration** | 25–200%, default 100% | scales how long events last |
| **Supply chain effects** | raw only / first stage / most / full, default full | caps how far a ripple may climb the chain. A **cap only reduces** reach — it never extends what a severity would have reached on its own. |
| **Show price markers** | on/off, default on | the `[+60%]` suffix on commodity names. It also shows in the shop and HUD, hence the opt-out. |
| **Event categories** (7 toggles) | on/off, default on | crops, greenhouse, trade, biofuel, winter, supplies, consumer — matching the `category` attribute in `config/events.xml` |

### The hub page

From build b20 the mod has its own page in the ESC menu: a hub rather than a
settings page, because the mod now has more to show than switches. Sub-tabs
run across the top, the way the game's own statistics page does it:

| Tab | Shows |
|---|---|
| **Market** | *In the news*: every running event, newest first, under the title it was announced with. *Prices on the move*: every product whose price has moved 1% or more today, largest first. Selecting a news item shows its full message again; selecting a product shows which events are behind it. |
| **Forecasts** | every forecast that has been announced and is still undecided, with its opening message. The status reads *Open*, or *Verdict close* once its pre-move has begun. Nothing about the outcome. |
| **History** | every message the mod has shown, newest first: date, kind (event, forecast, verdict, info), title and a one-word status. Selecting a row shows the message again. Kept with the savegame, the last 200. A forecast's row gains its outcome only once the verdict has happened. |
| **Settings** | the seventeen settings. |

The first three tabs share one layout and one piece of code (`LISTS` in
`HubFrame.lua`): a list on the left, the selected row's text on the right.

**No spoilers.** The Market tab shows only what the player was already told (the
news item) and what a selling point already shows (today's change). No remaining
duration, no peak, and a ripple that has not arrived yet is not listed until it
does. The change shown is exactly the modifier the price hook applies, combined
across events with the stacking rule.

**Split in two for testing.** `model/MarketView.lua` turns the price model into
plain tables and is covered offline; `game/HubFrame.lua` only draws them.

**How it gets into the menu.** The page is a `TabbedMenuFrameElement` with its
own layout (`gui/MSWHubFrame.xml`), added to the ESC menu's paging element,
registered, given a tab icon, and the tab list rebuilt. Every call it needs is
checked for first; if one is missing, or the layout loads without its controls,
the menu is left untouched and the settings fall back to GAME SETTINGS. All
drawing runs under `pcall`, so a mistake costs this page and never the ESC menu.

**The tab icon** is a white glyph on transparent (`gui/menuIcon.dds`, drawn by
`tools/make_menu_icon.py`). The menu tints its tab icons, so the full-colour
store icon cannot be reused there: b20 tried, and it came out as a muddy grid.

**The settings rows need their own colours.** The base game's row profile sets
a size and nothing else, and a Bitmap with no colour draws solid white; the base
settings page paints its rows from code. The hub's row profile states the
colours instead (transparent, with every second row banded).

**Reference for base-game profiles:** `sdk/xmlDoku/guiProfiles.xml` in the game
install lists every `fs25_*` profile and colour preset. Check it before using
one; do not guess what a profile sets.

### How the rows are built

Cloned from the game's own rows rather than constructed. `MSWSettingsAdapter`
holds an ordered `MENU_SPEC`, and `MSWSettingsMenu` turns each entry into a row
by cloning an existing `fs25_multiTextOptionContainer` out of
`gameSettingsLayout`, so the rows inherit this build's look, spacing and focus
behaviour for free.

Verified by probe rather than assumed (`MSWDiag.dumpSettingsGui`):

- the frame is `InGameMenuSettingsFrame`, reached as
  `g_gui.guis.InGameMenu.target.pageSettings`
- `gameSettingsLayout` is the GAME SETTINGS tab — the right home, since these
  are savegame-scoped economy settings sitting next to SEASONS and CROPS AND
  GROWTH, not client preferences like units or volume
- section headers are `Text` elements named `sectionHeader`
- frame classes are **not enumerable** from a mod's environment: `pairs` over it
  sees only the mod's own globals, so class names have to be resolved by direct
  lookup

Three decisions worth recording:

1. **`onFrameOpen` is wrapped on the page instance, not on the class.** The
   instance method shadows the class one, so no other mod patching
   `InGameMenuSettingsFrame` can collide with us.
2. **Every row is a `MultiTextOption`, booleans included** (Off/On). One code
   path covers all seventeen settings, and it matches how most of the game's own
   rows are built.
3. **A clone carries the template's `onClickCallback` and `target`**, which point
   at a real base-game handler. Both are overwritten — otherwise changing a mod
   setting would change the growth mode.

The whole build is `pcall`-guarded. If the layout ever changes shape, the rows
are simply absent and the reason is in the log: a settings page missing our rows
is an acceptable failure, a broken settings page is not.

"Events per year" replaces an abstract frequency multiplier — the player just
types how often they want events, and `K = E / Σ baseWeight` distributes that
budget across the roster (per event = `E × baseWeight / Σ baseWeight`).

---

## What the player pays (purchase prices)

Until b24 the mod only moved what a selling point PAYS. Farm inputs are mostly
bought, not sold, so an input shock showed in the Market tab and changed nothing
the player was charged (seen in game on b22, savegame3). The game charges for
goods by three routes, each seen in its own scripts:

| Route | Game function | Hooked |
|---|---|---|
| Fuel pump, filling points (`FillTrigger`) | `economyManager:getPricePerLiter(fillType)` | since the start |
| A helper refilling a seeder, sprayer or tank on the go | `economyManager:getCostPerLiter(fillType)` | b24 |
| Big bags, pallets and tanks in the shop | `economyManager:getBuyPrice(storeItem, configurations, saleItem)` | b24 |

The shop charges by ITEM, so the item is matched to what it holds: a shop item
in a consumable category (`bigbags`, `bigbagPallets`, `ibc`, `pallets`) whose
fill unit lists exactly one fill type, read from the same data the shop uses for
its fill-type icons (`StoreItemUtil.loadSpecsFromXML`, `specs.fillTypes`). A bag
of fertiliser costs more during an input shock; a spreader, a fuel trailer or a
used-market item does not. Items holding several products are left alone.

NOT YET CONFIRMED IN GAME: that the shop's list shows the changed price and not
only the purchase dialog, and that the fuel pump really charges more.

---

## Forecasts (speculation)

Added in build b22. Code: `scripts/model/Forecast.lua`, `CropCalendar.lua`,
`History.lua`; config: `config/forecasts.xml`.

**An event and a forecast do opposite jobs.** An event is a surprise: it rewards
a quick reaction and leaves the player's plans alone. A forecast arrives early
enough to change what gets planted, felled or stored, and it is never certain.

### The life of a forecast

1. **Opening message.** Who expects what, and how sure they are.
2. **Uncertainty.** Months with no price movement at all.
3. **Pre-move.** Just before the verdict, the lead products edge the way the
   analysts called it, by a quarter of the expected move. It says the verdict is
   close, not which way it goes.
4. **Verdict message.** What actually happened, and why.
5. **A real event.** The verdict starts an ordinary event. From here the
   forecast is over: curve, chains, markers and news are the event engine's.

### Rules the owner set

- **Every forecast must be actionable.** There has to be a real way, and enough
  time, to change a plan. `resolveTiming()` refuses a forecast with fewer than
  `minLeadMonths` between message and verdict, or for crops the map does not
  have; `tools/validate_forecasts.py` fails the build on the same rule.
- **Not niche.** A forecast must not hinge on one crop that needs its own
  expensive machinery. Hence wheat with oats, canola with sunflower, potatoes
  with the sugar crops.
- **The confidence is honest and never below 70.** Rolled per forecast as 70, 80
  or 90, it is exactly the chance the analysts are right. The player is told in
  words ("the majority seems to agree", "largely agree", "unanimous"), never as
  a number.
- **There is always an effect.** No "nothing happened" outcome.
- **A crop forecast's effect lasts until that crop's next harvest.** A shortage
  cannot clear before a new crop comes in; it only fades as stocks are sold.
- **No numbers in the messages.** No sizes, no exact lengths. Enforced by the
  validator and the tests.
- **No console command is needed for anything a player does.** The forecast
  console commands are for testing only.

### Outcomes

| Outcome | Share (of "right") | What the verdict starts |
|---|---|---|
| As forecast | 40 | the forecast's event, medium |
| Stronger | 12 | the forecast's event, high |
| Milder | 8 | the forecast's event, low |
| Right price, wrong reason | 10 | the forecast's event, medium, without any companion event |
| Backfire | the remaining 100 - confidence | the mirror event, low (60%) or medium (40%) |

The backfire is always the same story: everyone acted on the forecast, so the
market went the other way.

### Dates come from the map

Maps change the crop calendar, so no months are written for crop forecasts.
`CropCalendarAdapter` reads each crop's own data file (the crop keeps the path
it was loaded from), and `MSWCropCalendar.fromGrowthTable` walks its twelve-period
growth table from sowing to the harvest-ready stage. A growth step applies at
the END of its period, which is what makes the walk agree with the in-game
calendar for the base game. The game's own "plantable in this period" function,
the one its seeders use, has the last word on sowing months. With seasonal growth
off, or a file that cannot be read, the base-game months are used.

A crop forecast's message arrives in the two months before its anchor crop's
sowing opens; the verdict falls when that crop's harvest starts; the effect lasts
twelve months.

### The six forecasts

Months are for the base-game calendar.

| Forecast | Variants | Leads | Follows | Message | Verdict | Effect ends |
|---|---|---|---|---|---|---|
| millingGrains | up, down | wheat, oat | flour, bread, cake, cereal, straw, hay | Jul-Aug | Jul | next Jul |
| vegetableOil | up, down | canola, sunflower | canola oil, sunflower oil | Jun-Jul | Jul | next Jul |
| biofuel | up, down | corn, soybean | silage | Feb-Mar | Oct | next Oct |
| foodProcessors | up, down | potato, sugar beet, sugarcane | potato chips, potato soup, sugar, chocolate | Jan-Feb | Aug | next Aug |
| sawmill | open, close | timber | boards, planks, beams, prefab walls, wood chips move the OTHER way, and recover sooner | any month | a year later | a year after that |
| winterFeed | severe, long | silage, hay, grass, straw, mixed ration | corn; a severe winter that happens also starts Harsh Winter (energy) | Feb-Apr | Nov / Oct | Apr |

### Outcome events are ordinary events

They use the schema of `events.xml` but live in `forecasts.xml` under
`<outcomeEvents>`, loaded into `config.forecastEvents`. The random scheduler
never sees them, and neither do the tools that document the random roster.

- **Their own families.** Both sides of one forecast share a subtype
  (`fcGrains`, `fcOil`, ...), so they can never run together. They deliberately
  do NOT share a family with the related random events: an effect runs for a
  year, and sharing would switch off every grain drought and bumper for that
  whole year. Overlap with random events is left to the stacking rule.
- **They do not count against the concurrent-event ceiling** and do not start
  the quiet period between random events.
- **A forecast cannot be announced while its own family's event is running.**
- **Exact length.** `MSWActiveEvent.new` takes `durationMonths`, which replaces
  the rolled length and ignores the player's duration setting: the effect ends
  at a point on the calendar.
- **Early recovery for the opposite side.** `<opposite durationShare="0.65">`
  plays the opposite group's whole curve in that share of the event. A new
  sawmill keeps timber dear for a year; its price war on sawn wood ends sooner.

### Rate

`forecastsPerYear` 4.0 is the roll rate before a nine-month cooldown; together
they give about 0.94 forecasts a year at any season length. At most two are
open at once, never two of one kind.

The player's **Forecasts per year** setting (0.5, 1, 1.5 or 2; added in b23)
scales this: the roll rate is multiplied by it and the cooldown divided by it,
and up to twice the setting may be open at once. Measured over 3,000 simulated
years with the random events running: 0.51, 0.94, 1.42 and 1.75 a year. The top
value falls short of 2 because a forecast cannot open while its own event is
still running. The spike figures below were measured before this change, at
0.87 a year.

### Do forecasts cause spikes? (30,000 simulated years)

`lua tools/sim_forecast_spikes.lua` runs the real model with and without
forecasts.

| Some product at or above | Events only | With forecasts |
|---|---|---|
| +50% | 11.2% of years | 14.3% of years |
| +75% | 0.23% of years | 2.32% of years |
| +100% | 0.03% of years | 0.28% of years |
| +150% | never | never |

Nothing fell below -50% in either run. Of the product-days at +100% or more with
forecasts, most came from ONE combination: a severe winter that comes in
"stronger" starts both the feed event and Harsh Winter at high severity, and
both push silage (Harsh Winter through its biogas link). That is a designed
double hit, not an unlucky overlap. Capping the companion Harsh Winter at medium
severity would bring +100% years down to 0.07% and +75% years to 0.95%. The
owner decided against the cap: an extreme winter together with a feed shortage
may produce a short period of extreme pricing, and that is accepted.

### Not yet confirmed in game

Everything above is tested offline against the real config. In game, as of b22,
none of it has run: the crop-file reading, the Forecasts and History tabs, and
the messages. The log prints one `crop calendar:` line per crop and a
`forecasts:` block listing what the map offers and when.

---

## Event roster

### 1. Grain Drought  *(player win — prices up)*

Supply shock: grain becomes scarce, prices rise.

**Raw crops hit directly** (each rises on its own — no dedup):
`WHEAT BARLEY OAT CANOLA MAIZE SORGHUM SUNFLOWER SOYBEAN`
*(RICE excluded — paddy/flood-irrigated, a drought wouldn't spike it.)*

**Impacted production chains** (x → Y → Z). Each processed product is driven by a
**single primary source** so shared goods are never impacted twice:

```
WHEAT     → FLOUR → BREAD
          → FLOUR → CAKE
          → STRAW                (CO-PRODUCT: same direction, ~no lag)
OAT       → CEREAL
CANOLA    → CANOLA_OIL
SUNFLOWER → SUNFLOWER_OIL

BARLEY    → (flour)  shares FLOUR → dropped (wheat is the driver)
MAIZE / SORGHUM / SOYBEAN → no sellable processed good (feed/raw only)
```

**Straw** is a co-product of the grain harvest, so it follows grain *volume*:
a drought leaves less straw behind (price **up**), a bumper harvest heaps it up
(price **down**). It moves with grain rather than after it — `lagMonths="0.25"`,
`passThrough="0.80"` — and is reached at every severity, since it is a direct
by-product rather than a processing step. `WHEAT` is its single driver.

Deduplicated downstream targets: FLOUR→BREAD/CAKE, CEREAL, CANOLA_OIL,
SUNFLOWER_OIL. **Engine rule:** every processed product appears exactly once in
the propagation graph, driven by its primary input.

**Seasonal trigger profile** — active FEB–SEP, weighted to spring/early summer
(makes no sense in winter, and by October it's too late to move grain prices; a
strong drought's harvest-correction lines up with the next season):

| Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| 0 | 0.4 | 0.8 | 1.3 | 1.5 | 1.5 | 1.3 | 1.0 | 0.6 | 0 | 0 | 0 |

Per-severity parameter ranges (each event rolls uniformly within these):

| Param | Light | Medium | Strong |
|---|---|---|---|
| Peak magnitude    | +15–20%   | +20–30%   | +60–70%   |
| Duration (months) | 3–6       | 6–8       | 10–12     |
| Peak position     | 10–40%    | 35–60%    | 30–45% (early — gives the ripple room to travel the chain) |
| Onset (riseExp)   | 0.5–0.9 (fast spike) | 1.0–1.5 | 1.5–2.0 (accel.) |
| Plateau hold      | ~0.55     | ~0.62     | ~0.72 (stays highest) |
| Harvest correction| ~0.8mo    | ~1.1mo    | ~1.2mo (fast, market-wide) |
| Daily jitter      | ±1.5%     | ±2.0%     | ±2.5%     |

Signature: **strong droughts peak early** and hold high on a plateau, letting the
ripple travel the full chain, then correct fast at the next harvest.

Event messages name the impacted crops and hide all numbers/mechanics; the
production-chain hint escalates with severity:
- *LOW:* "A brief dry spell has lightly stressed the region's field crops —
  wheat, barley, oats, maize, sorghum, canola, sunflower and soybean. Prices
  should tick up modestly before easing back. Millers and processors may feel a
  faint knock-on."
- *MED:* "A moderate drought is tightening supplies of the region's field crops —
  wheat, barley, oats, maize, sorghum, canola, sunflower and soybean. Prices will
  climb over the coming months before gradually easing, and as stocks draw down
  the squeeze is likely to work its way into processed goods further down the
  chain."
- *HI:* "A severe, prolonged drought has struck the region's field crops — wheat,
  barley, oats, maize, sorghum, canola, sunflower and soybean — and prices are
  spiking fast. The shortage will hold high for an extended spell, likely up to
  the next harvest, and ripple deep through the production chain as processed
  goods grow scarce in turn."

### 2. Grain Bumper Harvest  *(player lose — prices down)*

The downside **mirror** of the Grain Drought: an unexpectedly large harvest floods
the market and prices fall. Same engine, **inverted** (factor < 1), and
**downtuned ~50%** per the adverse-event rule.

Chains are the same graph as the Grain Drought, including **straw** — a bumper
harvest means excess straw on the market, so it dips alongside grain.

Raw crops hit directly (same 8, all fall):
`WHEAT BARLEY OAT CANOLA MAIZE SORGHUM SUNFLOWER SOYBEAN`

**Impacted chains**: the *same deduplicated graph* as the drought — processed
goods get **cheaper**, about half as much as a drought moves them:

```
WHEAT     → FLOUR → BREAD / CAKE
OAT       → CEREAL
CANOLA    → CANOLA_OIL
SUNFLOWER → SUNFLOWER_OIL
```

**Seasonal trigger profile** — active JUN–NOV, peak Aug–Sep. June–July are
**projection months** (a promising standing crop softens prices before harvest);
small grains (wheat/barley/oat/canola) glut in Jul–Aug; row crops (maize/soybean/
sunflower/sorghum) glut in Sep–Oct; Nov is the tail as silos fill:

| Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| 0 | 0 | 0 | 0 | 0 | 0.5 | 1.0 | 1.4 | 1.5 | 1.1 | 0.5 | 0 |

**Trough magnitude** (≈ half the drought's swing). All other curve params
(duration, trough position, plateau, harvest recovery, jitter, ripple
depth/strength) mirror the drought:

| Param | Light | Medium | Strong |
|---|---|---|---|
| Trough magnitude | −8 to −10% (×0.90–0.925) | −10 to −15% (×0.85–0.90) | −30 to −35% (×0.65–0.70) |

Curve mirrors the drought, inverted: early **trough** → low **plateau** (glut
lingers) → **fast recovery** at the end as the market absorbs the surplus /
next planting.

Messages name the crops; the production-chain hint escalates:
- *LOW (Strong Yields):* "Favourable weather has delivered better-than-expected
  yields across the region's field crops — wheat, barley, oats, maize, sorghum,
  canola, sunflower and soybean. With a little extra grain on the market, prices
  should dip modestly before recovering. Processors may see a slight easing too."
- *MED (Bumper Harvest):* "An unexpectedly strong harvest has flooded the region's
  silos — [same crops]. Prices will slide over the coming months as the surplus
  works through the market, and the drop will filter into processed goods as cheap
  raw stock spreads down the chain."
- *HI (Record Glut):* "A record-breaking harvest has overwhelmed the region's
  field crops — [same crops] — and prices are tumbling fast. Expect a prolonged
  slump as the oversupply lingers, likely until the next planting season, with the
  glut rippling deep through the production chain as cheap goods pile up."

---

### 3. Root & Vegetable Drought  *(player win — prices up)*

The same drought, applied to the drought-sensitive root and vegetable crops.
**Same numbers as the Grain Drought** — severity ranges, curve shape, ripple
depth/strength, harvest correction, jitter, and base weight — **except the
season**, shifted later for realism. Full magnitude (a price-up drought is a
player win, not downtuned).

Raw crops hit directly:
`POTATO SUGARBEET BEETROOT CARROT PARSNIP GREENBEAN PEA SPINACH`

**Seasonal trigger profile** — active MAR–OCT, peak Jun–Jul. Roots/veg bulk and
are harvested ~1 month later than grain (potato Aug–Oct, sugarbeet Oct–Nov), so
the stress window sits later than the Grain Drought and early spring is dropped:

| Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| 0 | 0 | 0.5 | 0.9 | 1.2 | 1.5 | 1.5 | 1.3 | 0.8 | 0.3 | 0 | 0 |

**Impacted production chains** (deduplicated — each processed good driven once):

```
POTATO    → POTATOCHIPS
          → SOUPCANSPOTATO
SUGARBEET → SUGAR → CHOCOLATE       (SUGAR's single driver = sugarbeet)
BEETROOT  → PRESERVEDBEETROOT
          → SOUPCANSBEETROOT
CARROT    → PRESERVEDCARROTS
          → SOUPCANSCARROTS
PARSNIP   → PRESERVEDPARSNIP
          → SOUPCANSPARSNIP
GREENBEAN → JARRED_GREENBEAN
PEA       → CANNED_PEAS
SPINACH   → SPINACH_BAGS
```

Cross-event dedup: **CAKE** stays with the Grain Drought (flour-driven), so here
sugar drives **CHOCOLATE** only. Mixed blends (`SOUPCANSMIXED`, `NOODLESOUP`) are
omitted to keep the one-driver rule clean.

Messages name the crops; the chain hint escalates (same format as Grain Drought):
- *LOW (Dry Spell):* "A brief dry spell has lightly stressed the region's root and
  vegetable crops — potatoes, sugar beet, beetroot, carrots, parsnips, green
  beans, peas and spinach. Prices should tick up modestly before easing back.
  Canneries and processors may feel a faint knock-on."
- *MED (Drought):* "A moderate drought is tightening supplies of the region's root
  and vegetable crops — [same list]. Prices will climb over the coming months
  before gradually easing, and the squeeze will work its way into canned and
  preserved goods as stocks draw down."
- *HI (Severe Drought):* "A severe, prolonged drought has struck the region's root
  and vegetable crops — [same list] — and prices are spiking fast. The shortage
  will hold high for an extended spell, likely up to the next harvest, and ripple
  deep through the chain as canned, preserved and processed goods grow scarce in
  turn."

---

### 4. Root & Vegetable Bumper Harvest  *(player lose — prices down)*

The downside **mirror** of the Root & Vegetable Drought: a bumper root/veg harvest
floods the market and prices fall. Same engine, **inverted**, **downtuned ~50%**.
Same crops and deduplicated chains as event 3 — processed goods get cheaper.

Raw crops hit directly:
`POTATO SUGARBEET BEETROOT CARROT PARSNIP GREENBEAN PEA SPINACH`

Chains: identical graph to the Root & Vegetable Drought (POTATO→POTATOCHIPS/
SOUPCANSPOTATO, SUGARBEET→SUGAR→CHOCOLATE, BEETROOT/CARROT/PARSNIP→preserves &
soupcans, GREENBEAN→JARRED_GREENBEAN, PEA→CANNED_PEAS, SPINACH→SPINACH_BAGS), all
falling.

**Seasonal trigger profile** — active JUL–NOV, peak Oct (~1 month later than the
grain bumper). Jul–Aug are projection months as summer bulking looks strong;
potatoes/veg glut Aug–Sep; main root harvest and late sugarbeet peak Oct–Nov:

| Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| 0 | 0 | 0 | 0 | 0 | 0 | 0.5 | 0.9 | 1.3 | 1.5 | 1.2 | 0 |

Trough magnitude: same downtuned ~50% as the grain bumper (LOW −8 to −10%, MED
−10 to −15%, HI −30 to −35%). All other params mirror event 3.

Messages name the crops; the chain hint escalates:
- *LOW (Strong Yields):* "Favourable conditions have delivered bumper root and
  vegetable yields — potatoes, sugar beet, beetroot, carrots, parsnips, green
  beans, peas and spinach. With extra produce reaching market, prices should dip
  modestly before recovering. Canneries may see a slight easing too."
- *MED (Bumper Harvest):* "An unexpectedly strong root and vegetable harvest is
  flooding the region's stores — [same list]. Prices will slide over the coming
  months as the surplus works through the market, and the drop will filter into
  canned and preserved goods as cheap stock spreads down the chain."
- *HI (Record Glut):* "A record-breaking root and vegetable harvest has overwhelmed
  the market — [same list] — and prices are tumbling fast. Expect a prolonged slump
  as the oversupply lingers, likely until the next planting season, with the glut
  rippling deep through the chain as cheap canned and preserved goods pile up."

> **Balance note:** the roster is now 2 win droughts (grain, root & veg) + 2 lose
> bumpers (grain, root & veg) → **win/lose parity** at equal base weight.

---

### 5. Harsh Winter  *(neutral — mixed: energy sellers gain, fuel buyers pay)*

A new event **type**: a cold winter drives up energy prices. **Neutral**, not
adverse — higher energy prices *help* players who sell electricity (solar/wind/
biogas) or biogas feedstock, while diesel costs *hurt*. So it takes **full
magnitude** (no adverse downtune) and doesn't count toward win/lose balance.
Fills the winter gap in the yearly distribution, and is our first **input-ward**
ripple.

**Directly raised** (energy prices ↑): `DIESEL ELECTRICCHARGE METHANE`

**Input-ward ripple** (↑, lagged & dampened) — biogas feedstock follows the
energy value (expensive energy → biogas output worth more → demand for what the
plant consumes rises):

```
ELECTRICCHARGE / METHANE ──▶ SILAGE, MANURE, LIQUIDMANURE
DIESEL                       (standalone fuel cost, no ripple)
```

This is the **reverse** of the drought's downstream ripple — it flows toward
*inputs*, not out to processed goods.

**Seasonal trigger profile** — active NOV–MAR, peak Dec–Jan (the empty winter
slot):

| Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| 1.5 | 1.2 | 0.5 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0.6 | 1.4 |

**Magnitude** (full — neutral event; prices **UP**):

| Param | Light | Medium | Strong |
|---|---|---|---|
| Peak magnitude | +15 to +20% | +20 to +30% | +60 to +70% |
| Duration (months) | 1–2 | 2–3 | 3–4 |

**Duration is winter-scaled** — much shorter than droughts (a cold snap is weeks,
a brutal winter a season; it must not run 12 months). Curve: rise as the cold
sets in → plateau through the freeze → ease as spring warms (the **thaw** is the
stabilization, not a harvest).

Messages name the affected items and, being neutral, give **both sides** — cost
at the pump vs. opportunity for energy/feedstock sellers:
- *LOW (Cold Snap):* "A brief cold snap has nudged energy demand higher across the
  region. Diesel, electricity and gas prices should tick up before easing as the
  weather turns — a minor pinch at the pump, but a small boon for anyone selling
  power. Biogas feedstock like silage and manure may firm up slightly too."
- *MED (Harsh Winter):* "A harsh winter has settled over the region, lifting demand
  for fuel and power. Diesel, electricity and gas prices will climb through the
  cold months before easing with the thaw. Costly at the pump — but a good stretch
  for biogas and energy producers, and feedstock like silage and manure will firm
  up as energy grows dear."
- *HI (Deep Freeze):* "A brutal, prolonged freeze grips the region, sending energy
  prices soaring. Diesel, electricity and gas will stay high well into the season.
  A heavy hit for fuel buyers — but a windfall for anyone selling power, and with
  energy at a premium, biogas feedstock like silage and manure is dragged up
  sharply in turn."

> **Balance note:** roster is 2 win (droughts) + 2 lose (bumpers) + 1 **neutral**
> (harsh winter) → win/lose parity holds; the neutral event sits outside the count.

---

### 6. Natural Disaster  *(player win — building materials up)*

A **demand** shock, and the structural mirror of a crop event. Crop events start
at a raw product and push **downstream** (wheat → flour → bread). This starts at
the **finished** goods being shipped in for relief and pulls **backward toward
raw materials**: relief orders prefab walls, cement and clothing, mills ramp up,
and that demand works back to logs and cotton.

**Directly hit** (full magnitude, every severity):
`PREFABWALL ROOFPLATES CEMENT CEMENTBRICKS CLOTHES`

**Backward ripple:**

```
PREFABWALL ─┬─▶ WOODBEAM   (t1, +0.5mo, 0.75)   mills respond fast
            ├─▶ PLANKS     (t1, +0.5mo, 0.75)
            ├─▶ BOARDS     (t1, +0.5mo, 0.75)
            └─▶ BATHTUB    (t3, +2.0mo, 0.50)   fittings, once homes are up
BOARDS      ─┬─▶ WOOD      (t2, +0.5mo, 0.70)   raw log demand follows
             └─▶ WOODCHIPS (t2, +0.5mo, 0.70)
PLANKS       ──▶ FURNITURE (t3, +1.5mo, 0.50)   rebuild, then furnish
CLOTHES      ──▶ FABRIC    (t1, +0.5mo, 0.75)   weavers respond as fast as mills
FABRIC       ──▶ COTTON    (t2, +0.5mo, 0.70)   raw fibre follows the weavers
```

**Relief is not only construction.** Blankets and warm clothing are shipped in
for the displaced, so `CLOTHES` is a direct order and the demand pulls back
through `FABRIC` to `COTTON` on exactly the same shape as the timber chain —
finished good direct, mill at t1, raw material at t2. No new mechanism.

**This is also why cotton needs no event of its own.** It is far too niche a crop
to carry one, and a relief effort is a more honest reason for its price to move
than any weather story we could have invented. Coverage went 93 → 96 for the cost
of two chain lines.

Pass-through is deliberately **higher than a processing chain** (0.70–0.75 vs
0.60): this is a direct demand pull, not a diluted processing step.

**Reach is identical at every severity** — unlike the crop events, a relief effort
hits the whole construction market at once. `rippleDepth=3` and `rippleScale=1.0`
throughout, so **severity changes only magnitude and duration**, never breadth.
Tiers still shape the *timing*.

**Magnitude** (full — a win event): LOW +15–20%, MED +20–30%, HI +60–70%
**Duration** (reconstruction timescales): LOW 2–4mo, MED 4–7mo, HI 8–12mo

**Distinct curve signature — the fastest onset in the roster.** Relief orders go
out at once, so `peakPos` is 0.10–0.20 (vs a drought's gradual build), then a
**long high plateau** (`hold` 0.75–0.85, the highest) through reconstruction. The
end correction represents *rebuilding finishing*, not a harvest.

Verified HI cascade: `walls +65% (m1.1) → boards +49% (m1.6) → wood +34% (m2.1)
→ furniture +24% (m3.1)`.

**Seasonal trigger profile** — **available all year** (a disaster can strike any
time; no month is zero), but heavily weighted to the **OCT–APR** storm/flood
season, peaking Dec–Jan. Summer stays live but light (wildfire season):

| Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| 1.5 | 1.4 | 1.2 | 1.0 | 0.5 | 0.4 | 0.4 | 0.5 | 0.8 | 1.2 | 1.4 | 1.5 |

That puts **~78% of firings in Oct–Apr** and ~22% in May–Sep — filling the
deep-winter gap in the roster (previously only Harsh Winter covered Dec–Jan)
while keeping the event possible year-round. It is the only event with no
closed season.

Messages escalate storm → disaster → catastrophe, naming the materials and the
timber pull-through:
- *LOW (Severe Storm):* local repairs funded; walls/roofing/cement firm up,
  sawmills busy.
- *MED (Natural Disaster):* relief shipping materials in by the truckload; timber
  pulled up as mills scramble for logs; furniture to follow.
- *HI (Regional Catastrophe):* major reconstruction, every material at a premium,
  timber bought at almost any price, running the best part of a year.

> **Balance note:** roster is now **3 win** (2 droughts + disaster) + **2 lose**
> (bumpers) + 1 neutral → slightly win-leaning. A construction-slump counterpart,
> or a base-weight tweak, would restore parity.

---

### 7. Input Price Shock  *(player lose — farm input costs up)*

A cost shock on the **buy side**: a global supply squeeze (fertiliser plants
throttling output on expensive gas, mineral freight disruption, tight seed
stocks) hits exactly when players restock for spreading and drilling season.
This is the first lose event that can fire in winter/spring — it fills the
Dec–May gap where the lose column was previously zero, and restored exact
win/lose parity at that stage of the roster.

**Directly hit** (prices **up** = costs up; downtuned ~50% as adverse):
`FERTILIZER LIQUIDFERTILIZER LIME SEEDS`

**Ripple (t1 only — a cost shock, not a production chain):**

```
FERTILIZER ──▶ HERBICIDE     (t1, +0.5mo,  0.65)  same agrochemical industry/logistics
FERTILIZER ──▶ MANURE        (t1, +0.75mo, 0.35)  SUBSTITUTION: organic muck bid up
FERTILIZER ──▶ LIQUIDMANURE  (t1, +0.75mo, 0.35)
FERTILIZER ──▶ DIGESTATE     (t1, +0.75mo, 0.35)  biogas output, spread like slurry
```

**Substitution effect.** Dear synthetic fertiliser pushes growers toward organic
alternatives, bidding `MANURE`, `LIQUIDMANURE` and `DIGESTATE` up (digestate is
the biogas equivalent, spread on fields exactly like slurry). Pass-through is
deliberately weak (0.35, vs 0.65 for herbicide) and the lag slower (0.75mo):
substitution demand takes time to build, and this is a **silver lining inside a
negative event** — it should reward players holding muck without offsetting the
pain. At HI that's about +11% on muck against +30–35% on fertiliser.

This also gives biogas operators a second way to benefit from a market event
(Harsh Winter lifts their feedstock; this lifts their digestate output).

Out of reach (not on the price table): `MINERAL_FEED`, `PIGFOOD`,
`SILAGE_ADDITIVE`, `LIQUIDSEEDTREATMENT`, `TREESAPLINGS`.

**Magnitude** (downtuned ~50%): LOW +8–10%, MED +10–15%, HI +30–35%
**Duration:** LOW 1–3mo, MED 3–5mo, HI 6–10mo (supply contracts renegotiate slowly)

**Curve:** news-driven fast onset (`peakPos` 0.15–0.35), stubborn plateau
(`hold` 0.65–0.75); the correction is new import capacity coming online.

**Seasonal trigger profile** — DEC–MAY, peak Feb–Mar (the restocking window
right before spreading/drilling); gone by summer:

| Jan | Feb | Mar | Apr | May | Jun–Nov | Dec |
|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| 1.0 | 1.4 | 1.5 | 1.1 | 0.5 | 0 | 0.6 |

**Gameplay counters (deliberate):** manure/slurry spreading substitutes for
bought fertiliser *and* rises in value via the substitution chain, and a
stone-crusher lime production turns the shock into a small win — all called out in
the flavour text so players discover the counterplay. Messages escalate: *Input Costs Rising* (restock early hint) →
*Supply Squeeze* (budget warning, lean on manure) → *Global Input Crisis*
("every pass over the field now costs real money").

> **Balance note** _(roster at this point)_: **3 win : 3 lose : 1 neutral** —
> parity restored, and the lose side now has winter/spring coverage.

---

### 8. Dairy Export Embargo  *(player lose — dairy prices down)*

Geopolitical sanctions close export markets. Mechanically this is a **backward
ripple** — the same direction as the Natural Disaster, but with the opposite sign
and a different cause. It is the **finished export goods** that get blocked, so
cheese, butter and bottled milk pile up unsold at home and their prices fall; the
processors then bid **less for raw milk** at the farm gate. That is how real dairy
counter-sanctions have actually played out.

**Directly hit** (the blocked export goods; downtuned ~50% as adverse):
`CHEESE BUTTER GOATCHEESE BUFFALOMOZZARELLA MILK_BOTTLED GOATMILK_BOTTLED
BUFFALOMILK_BOTTLED`

**Backward ripple — processors cut the farm gate price:**

```
CHEESE            ──▶ MILK        (t1, +0.5mo, 0.80)
GOATCHEESE        ──▶ GOATMILK    (t1, +0.5mo, 0.80)
BUFFALOMOZZARELLA ──▶ BUFFALOMILK (t1, +0.5mo, 0.80)
```

Pass-through is **high (0.80)** — dairy farmers absorb most of an export ban. One
driver per raw milk type keeps the single-driver rule intact.

**Season is FLAT** — all twelve months weighted equally. This holds for **all four
trade events** (both embargoes and both booms): they are driven by politics, not
by weather or yields, so they land whenever they land and hit whatever inventory
is still unsold. Being seasonless, they are a steady background presence that
keeps every month active.

`CHOCOLATE` is excluded: it is `SUGAR`-driven in the root events and isn't really
a dairy product.

**Magnitude:** LOW −8 to −10%, MED −10 to −15%, HI −30 to −35%
**Duration:** LOW 2–4mo, MED 4–8mo, HI 8–12mo

**Curve:** sanctions land overnight (fast onset, `peakPos` 0.10–0.25), then grind
on (`hold` 0.75–0.85 — the highest sustained pressure in the roster); the
correction is new buyers being found.

Messages escalate *Dairy Trade Friction* → *Dairy Export Sanctions* → *Dairy Trade
War*, each naming the goods and the farm-gate consequence ("milk cheques will look
a little thinner" → "cutting farm gate prices" → "slashed what they pay for raw
milk").

---

### 9. Mediterranean Export Embargo  *(player lose — prices down)*

The same backward embargo mechanic applied to Mediterranean goods: blocked exports
of olive oil, juice and raisins back up into what growers are paid for olives and
grapes.

**Directly hit:** `OLIVE_OIL GRAPEJUICE RAISINS`

**Backward ripple — pressers and bottlers pay growers less:**

```
OLIVE_OIL  ──▶ OLIVE  (t1, +0.5mo, 0.80)
GRAPEJUICE ──▶ GRAPE  (t1, +0.5mo, 0.80)
```

`RAISINS` is grape-derived too, but `GRAPE` already has a single driver, so no
second link.

**Season is FLAT**, as for dairy. An embargo is a *political* event, not a weather
or yield one: it lands when it lands and devalues whatever stock is still unsold,
so the month carries no special weight.

Magnitude, duration and curve match the dairy embargo. This event finally brings
**grape and olive** into the roster — they were deliberately left out of the
droughts as too drought-tolerant.

Messages escalate *Export Red Tape* → *Mediterranean Export Sanctions* →
*Mediterranean Trade Blockade*.

---

### 10–11. Export Booms — Dairy & Mediterranean  *(player win — prices up)*

The **mirrors** of the two embargoes: a new export market opens instead of closing.
Same backward ripple, opposite sign — demand for finished export goods surges,
they are bid up, and processors chasing volume then pay **more** at the farm gate.

| | Embargo (8–9) | Export Boom (10–11) |
|---|---|---|
| Cause | sanctions close a market | trade deal opens one |
| Direction | prices **down** | prices **up** |
| Magnitude | downtuned ~50% (adverse) | **full** (win) |
| Onset | **slams shut** (`peakPos` 0.10–0.25, `riseExp` 0.5–0.8) | **ramps up** (`peakPos` 0.20–0.40, `riseExp` 0.8–1.3) |
| Plateau / duration | identical (`hold` 0.75–0.85; 2–4 / 4–8 / 8–12mo) | identical |
| Products & chains | identical | identical |
| Season | flat (political, not seasonal) | same |

**The onset difference is the interesting part:** a sanction lands overnight, but a
trade deal *ramps* as contracts are signed and shipments scale. Same plateau, but
the boom takes visibly longer to arrive — so the player has time to build stock
into a rising market, whereas an embargo catches them holding it.

**Magnitude:** LOW +15–20%, MED +20–30%, HI +60–70% (full, per the win/lose rule —
adverse events are downtuned, wins are not)

**Products & ripple** — identical to their embargo counterparts:

```
Dairy:         CHEESE/BUTTER/GOATCHEESE/BUFFALOMOZZARELLA/*_BOTTLED (direct)
               CHEESE            ──▶ MILK        (t1, +0.5mo, 0.80)
               GOATCHEESE        ──▶ GOATMILK    (t1, +0.5mo, 0.80)
               BUFFALOMOZZARELLA ──▶ BUFFALOMILK (t1, +0.5mo, 0.80)

Mediterranean: OLIVE_OIL/GRAPEJUICE/RAISINS (direct)
               OLIVE_OIL  ──▶ OLIVE (t1, +0.5mo, 0.80)
               GRAPEJUICE ──▶ GRAPE (t1, +0.5mo, 0.80)
```

Messages escalate *Demand Firming* → *Export Deal* → *Export Boom*, with the HI
dairy message nudging the player to act ("if your parlour can run at capacity, now
is the time — a window like this may not come again for years").

Because the self-overlap guard is per event **id**, an embargo and its boom are
separate ids and *can* in principle overlap. They would partially cancel
multiplicatively (e.g. 0.85 × 1.25 ≈ 1.06), which reads acceptably as
"sanctions offset by a new market" — but it is a candidate for a future
mutual-exclusion rule if it feels odd in play.

> **Balance note** _(roster at this point)_: **5 win : 5 lose : 1 neutral** —
> parity restored at equal base weight, with each mirror pair sharing products,
> chains and season.

---

### 12–13. Southeast Asia — Trade Disruption & Favourable Monsoon  *(win / lose)*

The events that finally reach **rice**, which was deliberately excluded from the
grain drought (paddy rice is flood-irrigated — a dry European summer would not
spike it) and had been left with its entire chain untouched ever since.

**Directly hit** (both events): `RICE RICELONGGRAIN ENOKI`

`RICELONGGRAIN` sits in `affects` rather than behind a chain: it is a separate
crop, not a product of `RICE`.

**Ripple** (both events, same structure, opposite sign):

```
RICE ──▶ RICEFLOUR ──▶ RICEROLLS
                  ──▶ NOODLESOUP        (t3, +2.0mo, 0.45)
     ──▶ RICE_BAGS    (t1, +0.5mo, 0.70)
     ──▶ RICE_OIL     (t1, +1.0mo, 0.55)
     ──▶ RICE_BOXES   (t2, +1.0mo, 0.50)
ENOKI ──▶ OYSTER      (t1, +0.5mo, 0.35)   ← substitution, not processing
```

**`RICESAPLINGS` deliberately excluded — from the whole roster.** It was in an
earlier draft here, on the reasoning that planting stock should follow the grain
it is grown from, which would have made this the one double-edged event in the
roster. Cut, because the volumes do not support it: a player buys saplings in
quantities that are noise against the rice they sell, so the "cost" would never
register as a real decision and the event would just read as inconsistent — sold
rice moving one way, a rounding error moving the other.

The same argument then applied to its other appearance, as a ripple off `SEEDS`
in the input price shock, so that went too. An unfelt price change still costs a
line in every message explaining it. `SEEDS` itself still moves there; only the
rice-specific sapling product is left alone, and it is the one deliberately
uncovered product in `docs/filltype-coverage.txt` rather than an oversight.

**Oyster mushrooms move by substitution, not processing.** Enoki is overwhelmingly
a Chinese/Japanese/Korean crop and arrives on the affected ships; oyster mushrooms
are grown locally. When enoki gets dear, buyers priced out of it reach for the
local alternative and bid it up — but only partway (`passThrough` 0.35). Same
mechanism as manure standing in for fertiliser in event 7, and it runs in reverse
for the monsoon: cheap imports undercut the local grower.

| | Disruption (12) | Monsoon (13) |
|---|---|---|
| Direction | prices **up** (routes closed) | prices **down** (glut) |
| Magnitude | full: +15–20, +20–30, +60–70% | downtuned ~50%: −8/−10, −10/−15, −30/−35% |
| Onset | **fast** (`peakPos` 0.15–0.35, `riseExp` 0.5–0.9) — the market prices in news, not a harvest | glut curve, later peak, accelerating rise — the surplus builds as it is cut and shipped |
| Duration | 2–4 / 4–8 / 8–12 mo | 3–6 / 6–8 / 10–12 mo |
| Season | **flat** | **Sep–Jan**, peak Oct–Nov |

**The seasonal asymmetry is the point.** Its mirror is flat because a disruption
is political and lands whenever, exactly like the two embargoes. A monsoon is
weather on a schedule: the southwest monsoon runs through summer, the main harvest
lands in autumn, and the price effect arrives Sep–Jan with the market anticipating
it from late August. Month weights are normalised internally, so the narrower
window changes **when** the event fires and never **how often** — the pair stays
balanced against each other.

| Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| 0.8 | 0.3 | 0 | 0 | 0 | 0 | 0 | 0.3 | 0.9 | 1.5 | 1.5 | 1.2 |

**Both sit in `trade`, not `crops`.** Nothing has happened to the player's field
in either case — it is shipping and foreign harvests. Keeping the pair in one
category also means switching *Trade events* off removes both halves rather than
leaving a one-way ratchet on rice prices.

**One assumption, flagged in the config.** `NOODLESOUP` is treated as rice-noodle
based, so `RICEFLOUR` drives it. It is a blended product and was left out of the
greenhouse events for that reason; here rice is the plausible primary input rather
than one of several vegetables. It is the only claim in these events not read off
the game's own chain data, and it is a single line to delete if wrong.

---

### 14–15. Biofuel Mandate — Cut & Boost  *(lose / win)*

A **policy** pair. Ethanol stocks build up, so the government cuts its biofuel
intake and feedstock demand collapses (**cut**, prices down); or it raises the
blending target and refineries compete for every tonne (**boost**, prices up).

**Directly hit** (both events): `MAIZE SUGARBEET SUGARCANE SOYBEAN`

*On the crop list:* maize, sugarbeet and sugarcane are **ethanol** feedstock
(starch/sugar); soybean is really **biodiesel** feedstock. Framing both events as a
single *biofuel mandate* keeps the four coherent together, and the flavour text
uses that wording.

**Ripple — diversion between fuel and food/feed:**

```
SUGARBEET ──▶ SUGAR   (t1, +0.5mo, 0.60)
MAIZE     ──▶ SILAGE  (t1, +0.5mo, 0.50)
```

The direction is the interesting part. On a **cut**, crops that would have gone to
the refineries are diverted *into* food and feed, oversupplying those markets so
sugar and silage fall too — meaning cheaper feed is a small silver lining inside a
negative event, much like the muck bump in the Input Price Shock. On a **boost**,
the same crops are pulled *away* from food and feed, so sugar and silage tighten
instead — good for growers, expensive if you buy feed.

| | Cut (12) | Boost (13) |
|---|---|---|
| Direction | prices **down** | prices **up** |
| Magnitude | downtuned ~50%: −8/−10, −10/−15, −30/−35% | full: +15–20, +20–30, +60–70% |
| Onset | lands fast (`peakPos` 0.15–0.30) | ramps (`peakPos` 0.20–0.40) |
| Duration | 2–4 / 4–8 / 8–12 mo | same |
| Ripple side-effect | sugar & silage **cheaper** | sugar & silage **dearer** |

The onset asymmetry follows the embargo/boom precedent: a mandate cut is announced
and bites, while a boost takes effect only as refineries scale up and contract.

**Season FLAT** for both — a policy decision runs on a political timeline, not an
agricultural one. Same reasoning as the trade events.

Messages escalate *Ethanol Stocks Building* → *Biofuel Mandate Cut* → *Biofuel
Mandate Slashed*, and *Biofuel Demand Firming* → *Mandate Raised* → *Biofuel Boom*,
each naming the winners and losers of the diversion.

> **Balance note** _(roster at this point)_: **6 win : 6 lose : 1 neutral** —
> parity holds.

---

### 16–17. Greenhouse Beetles — Plague & Pest-Free Season  *(win / lose)*

The first events to touch the **greenhouse crops**, which nothing else reached.

**Directly hit** (both events):
`LETTUCE TOMATO STRAWBERRY SPRING_ONION NAPACABBAGE CHILLI GARLIC`

**Ripple:** `NAPACABBAGE ──▶ FERMENTEDNAPACABBAGE` (t1, +0.5mo, 0.60)

**Mind the direction.** A beetle plague *hurts production*, so supply drops and
prices **rise** — a win for anyone with clean crop to sell. Same logic as a
drought, not a disaster. The mirror is a collapse in beetle numbers: glasshouses
run clean, yields are outstanding, and abundance pushes prices **down**.

| | Plague (16) | Pest-Free (17) |
|---|---|---|
| Direction | prices **up** (supply destroyed) | prices **down** (abundance) |
| Magnitude | full: +15–20, +20–30, +60–70% | downtuned ~50%: −8/−10, −10/−15, −30/−35% |
| Onset | **exponential** (`riseExp` 1.3–1.8) — beetles breed | gentler (0.8–1.2) — clean crops reveal themselves gradually |
| Duration | 1–3 / 3–5 / 5–8 mo | same |

**Short durations by design.** Greenhouse crops cycle fast, so an outbreak
resolves far quicker than a field drought — these are the shortest crop events in
the roster after Harsh Winter. The end correction represents pest control
succeeding.

**Mushrooms excluded.** `ENOKI` and `OYSTER` grow in dark, humid mushroom houses,
not glasshouses, and beetles are not their pest. They are covered instead by the
Southeast Asian pair (12–13), where enoki moves as an import and oyster follows it
as a substitute.

**Season — climate-controlled, so only partly seasonal.** Greenhouses are heated,
so this can fire in **any** month, unlike a field drought. But pest pressure still
tracks outdoor temperature (insects enter from outside and breed far faster in
warmth), so it is strongly summer-weighted:

| Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|:-:|
| 0.2 | 0.3 | 0.5 | 0.9 | 1.3 | 1.5 | 1.5 | 1.3 | 0.9 | 0.5 | 0.3 | 0.2 |

Messages escalate *Beetle Sightings* → *Beetle Infestation* → *Beetle Plague*, and
*Clean Glasshouses* → *Pest-Free Season* → *Greenhouse Glut*.

**Tomatoes also join the Mediterranean pair.** `TOMATO` is a Mediterranean export
staple, shipped **fresh** (there is no processed tomato product in the base game),
so it sits in `affects` directly rather than behind a chain — meaning it takes the
full swing where olives and grapes are cushioned by their processors. That is the
right asymmetry: a fresh-produce grower is directly exposed to a closed border. It
also broadens those events beyond the fairly niche olive/grape crops. Tomato is
consequently in **four** events (both Mediterranean, both greenhouse), which is
legitimate stacking across different event ids.

> **Balance note** _(roster at this point)_: **8 win : 8 lose : 1 neutral** — parity
> holds.

---

### 18–19. Pandemic and Trendy Lifestyle  *(neutral — mixed: one group up, one down)*

The first **demand-side** pair, in a new category, **consumer**. Nothing happens
to supply; shoppers simply change what they buy, so there is a winner and a
loser in the same event.

| | Pandemic (18) | Trendy Lifestyle (19) |
|---|---|---|
| Rises (full) | soups, cans, jars, preserves | greenhouse produce, cheeses, olive oil, grape juice |
| Falls (half strength) | greenhouse produce, cheeses, olive oil, grape juice | soups, cans, jars, preserves |
| Magnitude of the rise | +15–20, +20–30, +60–70% | +15–20, +20–30, **+40–50%** |
| Onset | near-instant (`peakPos` 0.10–0.25, `riseExp` 0.5–0.8), low hold | slow build (`peakPos` 0.45–0.65, `riseExp` 1.2–1.6), high hold |
| Duration | 1–2 / 3–5 / 6–9 mo | 2–4 / 4–7 / 8–12 mo |

**Shelf-stable group:** `SOUPCANSCARROTS` `SOUPCANSPARSNIP` `SOUPCANSBEETROOT`
`SOUPCANSPOTATO` `SOUPCANSMIXED` `NOODLESOUP` `PRESERVEDCARROTS` `PRESERVEDPARSNIP`
`PRESERVEDBEETROOT` `CANNED_PEAS` `JARRED_GREENBEAN`

**Fresh and premium group:** `LETTUCE` `TOMATO` `STRAWBERRY` `SPRING_ONION`
`NAPACABBAGE` `CHILLI` `GARLIC` `CHEESE` `GOATCHEESE` `BUFFALOMOZZARELLA`
`OLIVE_OIL` `GRAPEJUICE`

**The opposite group is a new config element.** Until now an event moved
everything it touched one way. `<opposite scale="0.50">` lists products moved
*against* the event's direction at half the swing — which is exactly the adverse
downtune the roster already uses, so the losing side of a high pandemic falls
30–35% like any other high adverse event. Opposite products are direct: no lag,
no chain may start from them, and neither the severity's ripple depth nor the
player's supply-chain setting removes them. In the reach map they are simply a
negative pass-through.

**Backward ripples**, as in the trade events — the processor running flat out
pays more for what goes in:

```
Pandemic:  PRESERVEDCARROTS ──▶ CARROT     PRESERVEDPARSNIP ──▶ PARSNIP
           PRESERVEDBEETROOT ──▶ BEETROOT  SOUPCANSPOTATO ──▶ POTATO
           CANNED_PEAS ──▶ PEA             JARRED_GREENBEAN ──▶ GREENBEAN
Trendy:    CHEESE ──▶ MILK   GOATCHEESE ──▶ GOATMILK   BUFFALOMOZZARELLA ──▶ BUFFALOMILK
           OLIVE_OIL ──▶ OLIVE   GRAPEJUICE ──▶ GRAPE
```

All tier 1 with a half-month lag; pass-through 0.50 for the vegetables and 0.80
for milk, olives and grapes (the trade events' value). The vegetable ripple is
what makes the pandemic matter to a player with no cannery.

**Why neutral, both of them.** Each has a clear winner and a clear loser, like
the harsh winter, so the rising side takes full magnitude and the pair sits
outside the win/lose count.

**Why the trend's high tier is softer.** It is the broadest event in the roster:
twelve direct products that the greenhouse, dairy and Mediterranean pairs also
move, so it overlaps more than any other. A fashion is also a gentler force than
a failed harvest.

**`SOUPCANSMIXED` and `NOODLESOUP` finally move.** They are multi-input blends,
so no crop event drives them. A demand shock acts on the finished product and
has no such problem.

**No wine.** The base game has no wine product; `GRAPEJUICE` stands in, as it
does in the Mediterranean pair.

**Season — flat for both.** Neither an outbreak nor a fashion keeps a farmer's
calendar.

Messages escalate *Stockpiling Scare* → *Regional Lockdown* → *Pandemic*, and
*Fresh Food Fad* → *Clean Eating Trend* → *Gourmet Craze*. Being mixed, each
names both sides.

> **Balance note (current roster):** **8 win : 8 lose : 3 neutral** — parity
> holds. Earlier notes in this file are marked _(roster at this point)_ and record
> parity as the roster grew; this is the one that describes the shipped mod.

---

*(More events to be added together. Broad-market events — small effects across
many products — are planned.)*

---

## Confirmed from game files

Verified against `reference/fillTypes_basegame.xml`:

- **Economy schema** — `<economy pricePerLiter="X"><factors><factor period="N"
  value="Y"/></factors></economy>`. Every product has a built-in 12-period
  (monthly) price curve; **period 1 = March**. Our events multiply on top.
- **Product list** — full catalog in `reference/product-catalog.md` (real names
  + base prices).
- **Adjustable set** — sellable products (`showOnPriceTable="true"`). Livestock
  (`COW_*`/`PIG_*`/`SHEEP_*`) are `false` → animal-dealer system, not reachable
  via the price table. Confirmed out of scope.

## Verified in-game

All confirmed against a live FS25 install (see the test logs):

| Item | Status |
|---|---|
| Price hook | ✅ `SellingStation.getEffectiveFillTypePrice`, wrapped and multiplying |
| Calendar | ✅ `environment.currentPeriod` / `.daysPerPeriod` / `.currentDay` |
| Product resolution | ✅ 86/86 configured products resolve |
| Curve / ripple / damping | ✅ visible per product: `Wheat [+60%]`, `Straw [+57%]`, `Bread [+16%]` |
| Event messages | ✅ modal dialog via `InfoDialog.show` (the `g_gui:showInfoDialog` variants fail) |
| Commodity markers | ✅ via `fillType.title` |
| Persistence | ✅ own XML in the savegame folder; `restore: 1 event(s) restored, 0 dropped` |
| Cooldown / one-per-day | ✅ |
| Savegame path | ⚠️ `missionInfo.savegameDirectory` does **not** exist; the
  `getUserProfileAppPath()` + `savegameIndex` fallback is what works |

## Deliberately not doing

- **Custom drawing in the prices screen** (recoloured arrows, a second baseline
  line on the graph). The list element is `InGameMenu.target.priceList`, but
  plotting into the chart would mean hooking a draw call and replicating its
  internal coordinate mapping — fragile, version-specific, and liable to conflict
  with other UI mods or break on a patch. The per-commodity markers already carry
  more information than a single extra line could, since they are per product.

## Still open

1. **Multiplayer** — `update` is gated on `g_server`, so the structure is ready,
   but nothing is synced to clients yet. The settings rows sit in GAME SETTINGS,
   which the base game already hides from clients without master rights.
2. **Diagnostics** — `MSWDiag.enabled` now defaults to **false**; verbose logging
   produced ~1,600 lines per session. `mswDump` still works on demand and
   `mswDebug` re-enables it.

---

## Compatibility with other price mods

Two implementation choices decide this, and both were made deliberately:

1. we **wrap** the price getter with `Utils.overwrittenFunction` rather than
   replacing it;
2. we **multiply** the original result rather than returning an absolute price,
   and never mutate stored economy data.

Together they mean we *compose* with other mods instead of competing:

| Other mod's approach | Example | Result |
|---|---|---|
| Ships its own `fillTypes.xml` (base prices / monthly factors) via modDesc | Guaranteed Crop Prices, Seasonal Prices — most ModHub price mods | ✅ **Compatible.** They set the baseline, we add volatility on top |
| Also *wraps* the same getter | well-behaved economy mods | ✅ **Compatible.** Wrappers chain; both multiply, so load order is irrelevant |
| Mutates stored economy data at runtime | some overhaul mods | ✅ **Compatible.** We never touch the data |
| Returns an **absolute** price, discarding the original | hard "fixed price" script mods | ⚠️ **Load-order dependent** — if it runs after us, our modifier is thrown away |
| **Replaces** the getter by plain assignment | rare; but it is what RealisticLivestock does to `Animal:getSellPrice` | ❌ **Breaks us silently** if it loads after us |

*Worked example:* Guaranteed Crop Prices only ships `gcp_fillTypes.xml` with every
monthly factor flattened to `1.21` and no Lua at all — so it is fully compatible,
and arguably a good pairing: it removes vanilla seasonality while we supply
event-driven movement instead.

Note for users: two *data-override* mods conflict with **each other** (last loaded
wins on `fillTypes.xml`). That is pre-existing between them, not caused by us.

**Silent failure is the real danger**, so `EconomyAdapter:verifyHooks()` stores the
wrapper it installed and compares it against the live function at mission start
(and on demand via `mswHooks`). If another mod replaced it, we log a clear warning
and reinstall on top. `logPriceModNeighbours()` additionally lists any loaded mod
whose name suggests price/economy work, so a user's `log.txt` names the likely
culprit without guesswork.

---

## Livestock prices — findings

Selling **animals** is a separate system from the fill-type price table, so the
current `EconomyAdapter` hook does not touch it. Confirmed from the game data:
every animal fill type (`COW_*`, `PIG_*`, `SHEEP_*`, `HORSE_*`, `CHICKEN`, `GOAT`)
has `showOnPriceTable="false"` and **no `<factors>` block at all**, and several are
priced `0` — those entries are transport/physics stand-ins (`massPerLiter="600"`),
not sale prices.

It **is** reachable through the animal system. Price flow, traced through
[FS25_RealisticLivestockRM](https://github.com/rittermod/FS25_RealisticLivestockRM):

```
Animal:getSellPrice()              per-animal value: subType.sellPrice:get(age),
    |                              then weight / genetics / health / castration /
    |                              disease / lactating / pregnant modifiers
    v
AnimalItemStock.cachedSellPrice    cached at construction
    v
AnimalItemStock:getPrice()
    v
AnimalScreenDealer:getTargetPrice()   what the dealer screen shows and pays
```

Two candidate hooks:

| Hook | Status | Coverage |
|---|---|---|
| `Animal.getSellPrice` | very likely vanilla — reads `subType.sellPrice`, a vanilla `AnimalSubType` curve | **all** sale paths (dealer, trailer, AI sell) |
| `AnimalScreenDealer.getSourcePrice` / `getTargetPrice` | **proven** vanilla — RL wraps them with `Utils.overwrittenFunction`, which requires the original to exist | dealer screen only |

`getSellPrice` returns a single number, so our modifier applies exactly as it does
for crops (`price * modifier`).

Three consequences if we implement it:

1. **Separate modifier channel.** `PriceModel` is keyed by `fillTypeIndex`; animals
   are not fill types and need a parallel lookup keyed by animal subtype. The
   subtype names appear to match the fill-type names we already have
   (`COW_HOLSTEIN`, `PIG_LANDRACE`, …), so `events.xml` can reference them with no
   new syntax — the adapter routes animal names to the animal hook instead.
2. **Load-order conflict with RealisticLivestock.** RL *replaces*
   `Animal:getSellPrice` outright rather than wrapping it, so if RL loads after us
   our wrapper is lost. Mitigation: install the hook at mission-start rather than
   script-load time, and/or hook the (proven) dealer functions as a fallback.
3. **Animal products are already reachable** — `MILK`, `GOATMILK`, `BUFFALOMILK`,
   `WOOL`, `EGG`, `HONEY` are all on the price table with monthly factors and are
   already moved by the four dairy trade events. Only the sale of the animals
   themselves is currently out of scope.

Candidate events once wired: a **herd sell-off** (feed costs force liquidation →
animal prices crash) or a **breeding stock shortage** (prices spike) — and a
livestock **disease** event would finally have somewhere to live.

---

## Dev tools

- `tools/drought_sim.py` — rolls randomized curve instances per severity, applies
  the intensity setting, prints price evolution + sparklines.
- `tools/propagation_sim.py` — supply-chain price propagation on real prices.
- `tools/severity_ripple_sim.py` — severity-scaled ripple depth/strength.
- `tools/event_tables.py` — full LOW/MED/HI price tables with the harvest
  stabilization correction.
- `tools/trigger_timing_sim.py` — validates seasonal trigger weighting (monthly
  distribution + days-per-month-independent annual rate).

All are standalone Python; no game required.
