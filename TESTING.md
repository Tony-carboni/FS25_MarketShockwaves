# Testing Market Shockwaves

This build ships with **verbose diagnostics on**, so a single session produces a
log with almost everything I need. The simulation logic is already covered
offline by `tools/test_model.lua` (56 checks); what we're testing here is
**integration with the real game**.

## 1. Install

```
build/FS25_MarketShockwaves.zip
   ->  Documents\My Games\FarmingSimulator2025\mods\
```

Rebuild any time with `./tools/build.sh`.

## 2. Enable the developer console

In `Documents\My Games\FarmingSimulator2025\game.xml`:

```xml
<controls>
    <development>
        <controls>true</controls>
    </development>
</controls>
```

Console opens with **`~`** (or **`^`** / **`ù`**, depending on keyboard layout).

## 3. Commands

| Command | What it does |
|---|---|
| `mswStatus` | settings, calendar, active events, all event ids |
| `mswDump` | **write a full diagnostic dump to the log** — use this if anything looks wrong |
| `mswTrigger <eventId> [severity]` | force an event now, e.g. `mswTrigger grainDrought high` |
| `mswPrice <PRODUCT>` | current modifier for one product |
| `mswHooks` | check our price hooks are still installed |
| `mswClear` | remove all active events |
| `mswSettings` | every setting with its current value |
| `mswSet <setting> <value>` | change any setting; `mswSettings` lists all 14 |
| `mswReset` | settings back to shipped defaults |
| `mswNotify <id> [severity]` | preview a message without starting an event |
| `mswMarkers on\|off` | the `[+14%]` commodity name markers |
| `mswDebug` | toggle extra debug lines |

Event ids: `grainDrought grainBumper rootDrought rootBumper harshWinter
naturalDisaster inputShock dairyEmbargo mediterraneanEmbargo dairyExportBoom
mediterraneanExportBoom asianTradeDisruption monsoonBounty ethanolGlut
ethanolBoom greenhousePest greenhouseBounty`

The README's console section has these grouped by category, plus recipes.

## 4. The test run

### a) Load a savegame and check the calendar

```
mswStatus
```

Expect a day/month/daysPerMonth line and `events loaded: 15`.

👉 **This is the single most important unknown.** The calendar field names are
unverified, so the mod probes candidates and logs **every** one with its value.
If `daysPerMonth` shows `1` while your game is set to 3, that's the bug — and the
`CalendarAdapter candidates [...]` lines in the log will tell me the real field
name straight away.

### b) Do prices actually move?

1. Go to a sell point that buys wheat, note the price.
2. `mswTrigger grainDrought high`
3. Check the price again — should be higher. `mswPrice WHEAT` should show a
   positive modifier.
4. Sleep/skip a few days and watch it climb toward the peak.

The log's `PRICE PROBE` block prints base price, modifier and result side by
side. **If those columns are identical while an event is active, the hook isn't
reaching the price the player sees** — that's the key failure to catch.

### c) Does the ripple work?

```
mswPrice FLOUR      lags wheat, then rises
mswPrice BREAD
mswPrice CAKE       high severity only
```

Early on, wheat moves and flour/bread/cake don't yet — that's the lag working.

### d) Notification

A message should appear naming the crops. It's always written to the log too, so
check there if nothing shows on screen.

### e) A few more worth trying

```
mswTrigger harshWinter high        then check DIESEL and SILAGE
mswTrigger inputShock high         then check FERTILIZER and MANURE
mswTrigger naturalDisaster high    then check PREFABWALL and WOOD
mswTrigger greenhousePest high     then check TOMATO and LETTUCE
mswTrigger grainDrought low        should be REFUSED if one is already active
```

That last one tests the self-overlap guard — it should decline rather than start
a second drought.

## 5. What to send back

1. **`log.txt`** from `Documents\My Games\FarmingSimulator2025\` — by far the most
   useful artefact. Every `[MSW]` line matters.
2. Whether the sell-point price visibly changed after `mswTrigger`.
3. Anything that looked wrong on screen.

If the log is huge, the blocks I care most about are `ENVIRONMENT DUMP`,
`CalendarAdapter candidates`, `FILL TYPE RESOLUTION` and `PRICE PROBE`.

## Confirmed working in game

Everything below was verified against a running game, not assumed. Each line is
the evidence, so a future regression has something to be measured against.

- **Prices actually move.** `PRICE PROBE` and the sell-point price both track the
  modifier; `WHEAT basePricePerLiter=0.337 modifier=1.6027 => 0.5401`.
- **Calendar resolution.** `environment.currentPeriod` / `.daysPerPeriod` /
  `.currentDay`, found by probe rather than guessed.
- **The ripple, with its lag.** One high drought produced `WHEAT +60.27%`,
  `FLOUR +34.68%`, `BREAD +16.43%`, `CAKE +5.77%` in a single dump — damping and
  staggering visible together.
- **The market-wide correction.** Downstream products normalise with the base
  rather than staying high after it recovers.
- **Event messages.** `InfoDialog.show`, queued and drained from `update()` only
  when it is safe. This was a hard freeze before queueing: a modal opened while
  the player slept corrupted the input context.
- **Commodity name markers** appear in the price list, shop and storage, each
  product carrying its own figure.
- **The price graph reflects events** for elapsed months — no UI work needed.
- **Savegame persistence.** Active events and settings survive save and reload.
- **The settings menu.** All 14 rows in ESC → Settings → GAME SETTINGS with real
  labels, correct values, and each description appearing in the right-hand panel.
- **Mutual exclusion of mirrored events.** `mswTrigger ethanolGlut medium`
  started normally (6 products: `MAIZE SILAGE SOYBEAN SUGAR SUGARBEET SUGARCANE`
  — 4 direct plus 2 ripple, as configured), and `mswTrigger ethanolBoom medium`
  was then refused with the blocker named: *"they are mirrors of the same market
  (subtype 'ethanol') and never overlap"*.

## Verified offline only — worth a spot check in game

- **The event rate holding across month lengths.** Simulated at 1, 3 and 10
  days per month; not measured over a long real playthrough.
- **The seasonal windows over many years.** The month weights are normalised and
  unit-tested, but no long playthrough has confirmed the distribution in practice.

## Still open

- **Multiplayer** not supported. `update` is gated on `g_server` so the structure
  is ready, but nothing is synced to clients.
- **Settings menu, remaining checks.** The menu → console and console → menu
  round trip, that the base-game rows above our block are untouched, and
  controller navigation through our rows.
- **Diagnostics default to off.** `MSWDiag.enabled = false`; `mswDump` enables it
  for one call and `mswDebug` toggles it for a session. `scripts/lib/Diagnostics.lua`
  is self-contained — delete it plus its `<sourceFile>` line in `modDesc.xml` to
  remove diagnostics entirely.

## If it fails to load

Search `log.txt` for `Error` near `MarketShockwaves`. Most likely causes are a
wrong `descVersion` for your patch (currently `96`) or a renamed engine function
— both will name themselves in the log.
