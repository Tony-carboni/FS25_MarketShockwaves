# Market Shockwaves: guide for content creators

Everything you need to show the mod in a video: what it does, how to set up a
recording, the console commands that make things happen on demand, and a set of
ready-made demonstrations.

Current for version 0.9.2.0. Singleplayer only.

---

## The mod in one paragraph

Farming Simulator's prices drift inside a predictable seasonal band. Market
Shockwaves adds market events on top: droughts, bumper harvests, embargoes,
export booms, hard winters, a pandemic. Each one moves prices for months along
its own curve, and the shock travels down the production chain. It also adds
forecasts: announcements, months ahead, of what analysts expect for next year,
which may or may not come true. The player is always told what happened and
never told how big it gets or how long it lasts.

## What makes it worth showing

- **Selling becomes a decision.** With an event running, the wheat in the silo
  is worth more every week, and nobody says when it stops.
- **The economy is joined up.** A grain shortage reaches flour, then bread, then
  cake, each a little later and a little softer.
- **Forecasts are a gamble.** They arrive while you can still choose what to
  plant, state how sure the experts are, and sometimes backfire.
- **Nothing repeats.** Every event rolls its own size, length and shape.

---

## How it works, in more detail

### Events

- **19 events in 7 categories:** crops, greenhouse, trade, biofuel, winter,
  supplies and consumer trends.
- **Three severities:** low, medium and high. They open with the same kind of
  market report, so the player cannot tell them apart at the start.
- **A curve, not a switch.** Prices build to a peak, hold on a slow plateau and
  correct at the end. A little daily noise rides on top.
- **Ripple down the chain.** Each processed product follows its raw material
  after a delay and moves less. The worse the event, the further it travels.
- **Mirror pairs.** Most events come as a pair, one up and one down (drought and
  bumper harvest, embargo and export boom). The two halves of a pair can never
  run at the same time.
- **Stacking.** Different events can overlap. When two push the same product the
  same way, the second adds less than it would alone, and a third less again.
- **Seasons.** Weather events fire in the months where they make sense. Trade
  and consumer events can land in any month.

### Forecasts

A forecast has five stages:

1. **The opening message.** Who expects what, and how sure they are.
2. **Uncertainty.** Months in which prices do not move at all.
3. **The pre-move.** Shortly before the verdict, prices edge the way the analysts
   called it. It signals that the answer is close, not what it is.
4. **The verdict message.** What actually happened, and why.
5. **A real event.** From the verdict on it behaves like any other event, and
   for crops it lasts until the next harvest.

Things worth pointing out on camera:

- **Timed by the map's crop calendar.** The message arrives before sowing opens
  and the verdict falls when the harvest starts. On a map with its own seasons
  the forecasts move with them.
- **The stated confidence is real.** There are three levels of wording: the
  majority seems to agree, experts largely agree, experts are unanimous. The
  stronger the wording, the more often it comes true.
- **Five possible outcomes:** as forecast, stronger, milder, right about the
  price for the wrong reason, and a backfire where the market goes the other way
  because everyone acted on the forecast.
- **There is always an outcome.** A forecast never just fizzles out.

### The Market Shockwaves page

In the ESC menu, with four tabs:

| Tab | Shows |
|---|---|
| Market | What is in the news, and every product whose price is moving today |
| Forecasts | What has been announced and is still undecided |
| History | Every message the mod has shown, with its date |
| Settings | Frequency, intensity, duration, chain depth, markers, forecasts, categories |

With **price markers** on, affected goods also carry their current change in
their name, for example `Wheat [+14%]`, in the price list, the shop and storage
displays.

---

## Setting up a recording

### 1. Turn on the developer console

In `Documents\My Games\FarmingSimulator2025\game.xml`, set:

```xml
<development>
    <controls>true</controls>
</development>
```

Restart the game. The console opens with `~` (or `^` / `ù`, depending on the
keyboard layout). Press it twice to get the input line.

### 2. Settings that make filming easier

- **One day per month** in the game's own settings, so a month of market
  movement is one sleep.
- **Price markers on** (the default), so the effect is visible in the price
  list without comparing numbers.
- Optional: `mswSet eventsPerYear 0` stops random events from interrupting a
  staged demonstration. `mswReset` restores the defaults afterwards.

### 3. Good to know before you start

- **The commands are for showcasing and testing.** In normal play nothing needs
  the console: events and forecasts arrive on their own.
- **Messages wait for a free screen.** A report opens once no menu is open and
  the player is not asleep, so close the console to see it.
- **Prices update once per in-game day.** After a command, `mswPrice` shows the
  new value at once; the price list follows on the next refresh.
- **`mswClear` wipes the slate** between demonstrations.

---

## Commands

### Events

| Command | What it does |
|---|---|
| `mswStatus` | Settings, calendar, running events and all event ids |
| `mswTrigger <eventId> [low\|medium\|high]` | Starts an event now, ignoring season and cooldown. Medium if no severity is given |
| `mswPrice <PRODUCT>` | Current change for one product, e.g. `mswPrice WHEAT` |
| `mswNotify <eventId> [severity]` | Shows an event's message without starting it |
| `mswClear` | Removes all running events and open forecasts |

### Forecasts

| Command | What it does |
|---|---|
| `mswForecasts` | Open forecasts, and which forecasts this map offers |
| `mswForecast [id] [variant] [70\|80\|90]` | Announces a forecast now, optionally with a chosen confidence |
| `mswForecastSkip` | Jumps every open forecast to its pre-move; the verdict follows after it |
| `mswVerdict [outcome]` | Decides the oldest open forecast now, optionally with a chosen outcome |

Outcomes for `mswVerdict`: `asForecast`, `stronger`, `milder`, `wrongReason`,
`backfire`.

### Settings and display

| Command | What it does |
|---|---|
| `mswSettings` | Every setting with its value |
| `mswSet <setting> <value>` | Changes a setting, e.g. `mswSet intensity 2` |
| `mswReset` | Restores all defaults |
| `mswMarkers on\|off` | The `[+14%]` markers on commodity names |
| `mswWelcome` | Shows the welcome message again |

---

## Reference: ids

### Events, for `mswTrigger`

| Category | Up | Down |
|---|---|---|
| Crops | `grainDrought`, `rootDrought` | `grainBumper`, `rootBumper` |
| Greenhouse | `greenhousePest` | `greenhouseBounty` |
| Trade | `dairyExportBoom`, `mediterraneanExportBoom`, `asianTradeDisruption` | `dairyEmbargo`, `mediterraneanEmbargo`, `monsoonBounty` |
| Biofuel | `ethanolBoom` | `ethanolGlut` |
| Winter | `harshWinter` | |
| Supplies | `naturalDisaster`, `inputShock` | |
| Consumer | `pandemicCrisis` and `trendyLifestyle`: each moves one group up and another down | |

### Forecasts, for `mswForecast`

| Id | Variants | Moves |
|---|---|---|
| `millingGrains` | `up`, `down` | Wheat, oat; then flour, bread, cake, cereal, straw, hay |
| `vegetableOil` | `up`, `down` | Canola, sunflower; then canola oil, sunflower oil |
| `biofuel` | `up`, `down` | Corn, soybean; then silage |
| `foodProcessors` | `up`, `down` | Potato, sugar beet, sugarcane; then potato chips, potato soup, sugar, chocolate |
| `sawmill` | `open`, `close` | Timber one way; boards, planks, wood beams, prefab walls, wood chips the other |
| `winterFeed` | `severe`, `long` | Silage, hay, grass, straw, mixed ration; then corn. A severe winter also lifts diesel, electricity and methane |

A map that lacks a forecast's crops does not offer that forecast; `mswForecasts`
lists what is available.

### Product names, for `mswPrice`

The game's internal names, in capitals: `WHEAT`, `OAT`, `BARLEY`, `CANOLA`,
`SUNFLOWER`, `MAIZE`, `SOYBEAN`, `POTATO`, `SUGARBEET`, `FLOUR`, `BREAD`, `CAKE`,
`SUGAR`, `MILK`, `CHEESE`, `SILAGE`, `STRAW`, `DRYGRASS_WINDROW` (hay),
`GRASS_WINDROW` (grass), `WOOD`, `PLANKS`, `WOODCHIPS`, `DIESEL`, `FERTILIZER`,
`LETTUCE`, `TOMATO`, `OLIVE_OIL`.

---

## Demonstrations

Each one starts from a clean slate. Sleep one night between steps where it says
"next month" (with one day per month).

### 1. The basic event: a severe grain drought

Shows the market report, the markers and a price that keeps climbing.

```
mswClear
mswTrigger grainDrought high
```

- Close the console to read the report.
- Open the price list: the eight grains carry a marker.
- Sleep a few times and watch wheat climb, then level off.

### 2. The ripple down the chain

The best single shot of what the mod does. Continue from demonstration 1.

```
mswPrice WHEAT
mswPrice FLOUR
mswPrice BREAD
mswPrice CAKE
```

- Right after the trigger, wheat has moved and bread has barely started.
- Check again each month: flour follows wheat, bread follows flour, cake comes
  last and moves least.
- The Market tab in the ESC menu shows the same thing as a growing list.

### 3. Severity changes how far it reaches

```
mswClear
mswTrigger grainDrought low
```

- Check the same four products over a few months: a mild drought stops at flour
  and never reaches cake.
- Compare with the `high` run from demonstration 1.

### 4. Same report, different event

The opening messages give little away. Show two and let the viewer guess.

```
mswNotify grainDrought low
mswNotify grainDrought high
```

`mswNotify` only shows the message; nothing starts.

### 5. Mirror events cannot overlap

```
mswClear
mswTrigger ethanolBoom
mswTrigger ethanolGlut
```

The second command is refused, and the console names the event that blocks it.

### 6. Two events on the same crop: stacking

```
mswClear
mswTrigger grainDrought high
mswTrigger ethanolBoom high
mswPrice MAIZE
mswPrice WHEAT
```

- Corn is hit by both, wheat only by the drought, so corn rises further.
- The two effects are not simply added: the smaller one counts for less. Corn
  ends up well short of double.

### 7. Two events pulling against each other

```
mswClear
mswTrigger rootDrought high
mswTrigger ethanolGlut high
mswPrice SUGARBEET
mswPrice POTATO
```

Sugar beet is pushed up by the drought and down by the biofuel glut, and lands
in between. Potato only feels the drought.

### 8. One event, two directions: the pandemic

```
mswClear
mswTrigger pandemicCrisis high
mswPrice SOUPCANSPOTATO
mswPrice LETTUCE
mswPrice CHEESE
```

- Canned soups and preserves go up, and so do the vegetables that go into them.
- Fresh greenhouse produce, cheese, olive oil and grape juice go down.
- `mswClear`, then `mswTrigger trendyLifestyle high` shows the exact reverse.

### 9. A demand shock that works backwards

```
mswClear
mswTrigger naturalDisaster high
mswPrice PREFABWALL
mswPrice WOOD
mswPrice CLOTHES
```

Rebuilding lifts construction materials first, and that demand then pulls
timber, fabric and cotton up behind them.

### 10. A hard spring

```
mswClear
mswTrigger harshWinter high
mswTrigger inputShock high
mswPrice DIESEL
mswPrice FERTILIZER
mswPrice SILAGE
```

Energy and farm inputs are both dear at once. Manure, slurry and silage firm up
too, as the substitutes people reach for.

### 11. A forecast from start to finish

The full life of a forecast in three sleeps.

```
mswClear
mswForecast millingGrains up 80
```

- The first forecast of a savegame is preceded by a short explanation of what
  forecasts are. Then the forecast itself opens.
- `mswPrice WHEAT` shows no change. The Forecasts tab lists it as **Open**.

```
mswForecastSkip
mswPrice WHEAT
```

- Wheat has edged up a little: the pre-move. The Forecasts tab now reads
  **Verdict close**.
- Sleep. The verdict message opens, wheat jumps to its outcome, and the forecast
  moves from the Forecasts tab to **In the news** on the Market tab.
- The History tab shows the forecast and its verdict, linked.

### 12. "Even experts can be wrong": a backfire

```
mswClear
mswForecast millingGrains up 90
mswForecastSkip
mswPrice WHEAT
mswVerdict backfire
mswPrice WHEAT
```

- Experts were unanimous that wheat would rise, and the pre-move agreed.
- The verdict says everyone planted for the boom. Wheat falls.

Use `mswVerdict stronger`, `milder` or `wrongReason` on a fresh forecast to show
the other outcomes. Without an outcome, `mswVerdict` rolls one honestly.

### 13. The sawmill: one product up, another down

```
mswClear
mswForecast sawmill open
mswVerdict asForecast
mswPrice WOOD
mswPrice PLANKS
mswPrice WOODCHIPS
```

- Timber rises while boards, planks, beams and wood chips fall, as the new mill
  bids for logs and sells cheap.
- Over the following months the sawn products return to normal well before
  timber does.
- `mswForecast sawmill close` is the mirror: a big mill shutting down.

### 14. The severe winter

```
mswClear
mswForecast winterFeed severe
mswVerdict stronger
mswPrice SILAGE
mswPrice DRYGRASS_WINDROW
mswPrice DIESEL
```

- A winter harsher than forecast starts two things at once: the feed shortage
  and the mod's ordinary Harsh Winter event.
- Silage is pushed by both, which makes this the most extreme price the mod
  produces. It is meant to be rare and short.
- `mswVerdict backfire` on a fresh forecast shows the opposite: everyone filled
  their barns, the winter was mild, and feed goes cheap.

### 15. Turning the dials

```
mswSet intensity 2
mswClear
mswTrigger grainDrought high
mswPrice WHEAT
mswReset
```

- Intensity scales every swing; 2 is the maximum.
- `mswSet supplyChainDepth 0` keeps shocks on raw crops only.
- The same settings are on the Settings tab of the Market Shockwaves page.

### 16. A tour of the menu page

After any of the demonstrations above, open the ESC menu and go to the Market
Shockwaves page:

- **Market:** select a product to see which events are moving it.
- **Forecasts:** select an open forecast to read its message again.
- **History:** scroll back through every report, forecast and verdict.

---

## Suggested structure for a highlight video

1. **The problem:** vanilla prices are predictable (a few seconds on the price
   list).
2. **An event:** demonstration 1, then the ripple in demonstration 2.
3. **The decision:** sell now or hold? Sleep a few months and show the result.
4. **Variety:** quick cuts of demonstrations 8 and 9.
5. **Forecasts:** demonstration 11, then the backfire in 12.
6. **The menu page:** demonstration 16.
7. **Settings and compatibility:** works on any map, other price mods stack with
   it, singleplayer for now.

---

## A request about numbers

The mod is built on the player not knowing how big an event will get or how
long it will last. Showing prices and markers in a video is fine, and so is
everything in this guide. Please avoid presenting the results as a rule ("a
severe drought is always this much for this long"): every event rolls its own
numbers, so any figure seen in one recording will be different in the next.

---

## Facts for the description box

- **Name:** Market Shockwaves
- **Author:** Tony_Carboni
- **Game:** Farming Simulator 25, singleplayer
- **Download:** https://github.com/Tony-carboni/FS25_MarketShockwaves/releases
- **Maps:** any, including maps with their own crops and crop calendars
- **Other mods:** does not edit fill types; other price mods stack with it
