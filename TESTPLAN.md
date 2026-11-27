# Test script

~10 minutes. Six checks, in order. Each says what to run, what a **pass** looks
like, and what to write down.

Your setup: **daysPerMonth = 1**, so sleeping one day advances one game month.

Console: **`~`** (or `^` / `ù`). Enable it in `game.xml` if you haven't —
`<development><controls>true</controls></development>`.

---

## Setup

Install the new zip, start a **new game**, and let it load fully.

```
mswStatus
```

**Pass:** shows a calendar line, `events loaded: 15`, and `active: 0`.

Write down: the `day=` / `month=` / `daysPerMonth=` numbers.

---

## 1. Baseline — what prices look like with no event

```
mswPrice WHEAT
mswPrice FLOUR
```

**Pass:** both report `modifier 1.0000 (+0.00%)`. That is correct with nothing
running — it is the reference point for everything below.

Then open **Prices → Wheat** and note the selling price at one station (any one,
just be consistent). Write it down.

---

## 2. Trigger — does the modifier apply at all?

```
mswTrigger grainDrought high
```

**Pass:** a **dialog pops up** that you have to click OK on, naming the crops.

Then:

```
mswPrice WHEAT
```

**Pass:** modifier is **above 1.0** — expect roughly `1.03` to `1.12` on day one
(the curve starts low and builds; it does not open at peak).

**This is the single most important check.** If the modifier is above 1.0, the
engine works.

Now re-check that same station price in Prices → Wheat.

Write down: the modifier, and the station price before vs after.

---

## 3. Does the curve move, and does the ripple lag?

Sleep **3 days** (three months, at your setting), then:

```
mswPrice WHEAT
mswPrice FLOUR
mswPrice BREAD
mswStatus
```

**Pass:**
- `WHEAT` modifier is **higher than it was** in step 2 (climbing toward peak)
- `FLOUR` has now moved **but is smaller** than wheat
- `BREAD` is smaller still, or possibly still `1.0000` — it lags two months
- `mswStatus` shows `1 active event(s)` and a day count like `day 4/11`

The staggering is the point: wheat first, flour behind it, bread behind that.

Write down: all three modifiers and the `day X/11` figure.

---

## 4. Persistence — brand new code, never run

```
mswPrice WHEAT      <- note this number exactly
```

Now **save the game**, quit to the main menu, and **load that save**. Then:

```
mswStatus
mswPrice WHEAT
```

**Pass:**
- `mswStatus` still shows `1 active event(s)` with the **same** `day X/11`
- `mswPrice WHEAT` shows **the same modifier** as before the reload

**Fail looks like:** `active: 0`, or modifier back to `1.0000`. If it fails the
log will contain a `restore:` line saying why — that is what I need.

Write down: whether the event survived, and both modifiers.

---

## 5. Self-overlap guard

```
mswTrigger grainDrought low
```

**Pass:** it **refuses**, saying grainDrought is already active. Two droughts must
never stack on themselves.

Then check a different event still works:

```
mswTrigger harshWinter medium
mswPrice DIESEL
```

**Pass:** harsh winter starts (different event, so overlap is allowed) and
`DIESEL` shows a modifier above 1.0.

⚠️ Note: harshWinter is **out of season** in your current month, but `mswTrigger`
bypasses the season check deliberately — that is expected.

---

## 6. The visual indicator (confirmed working — a regression check now)

Open **Prices** and look at the commodity list on the left.

**Looking for:** `Wheat  [+8%]` instead of plain `Wheat`.

This was a guess about how the list reads names, so it may well not work. Either
way, **leave the Prices menu open** and run:

```
mswDump
```

That captures the GUI probe while the prices screen is live, which is what I need
to do this properly.

Write down: whether the marker appeared.

---

## 7. The settings menu (confirmed — steps 4–7 still unrun)

Open the ESC menu and pick the **Market Shockwaves** tab in the left-hand
column (it sits just above the settings tab). The page opens on its **Market**
sub-tab; switch to **Settings**. NOT YET CONFIRMED IN GAME as of build b20 —
the page was built against other mods' working ESC pages, not a live run.

If the log says `hub page unavailable`, the rows are instead at the bottom of
**ESC → Settings → GAME SETTINGS**, under a `MARKET SHOCKWAVES` header.

Either way there should be fifteen rows:

```
Enable Market Shockwaves        On
Events per year (average)       2
Minimum time between events     2
Maximum events at once          3
Event intensity                 100%
Event duration                  100%
Supply chain effects            Full production chains
Show price markers              On
Crop events                     On
Greenhouse events               On
Trade events                    On
Biofuel events                  On
Winter events                   On
Supply events                   On
Consumer events                 On
```

Check, in this order:

1. **The rows are there at all**, and the section header reads
   MARKET SHOCKWAVES.
2. **Each label is a real sentence**, not a setting key like `catCrops`.
3. **Hover or focus each row** — the description appears in the panel on the
   right. Confirmed working, so this is a regression check. It took two attempts:
   the label was first written into the tooltip element, leaving every row titled
   "Autosave Interval". If that ever returns, the row shape is logged on first
   open — search the log for `cloned row shape`.
4. **Change one row** — set *Event intensity* to `150%`. Then close the menu,
   open the console and run `mswSettings`. It should report `intensity 1.5`.
5. **The reverse direction**: run `mswSet duration 0.5`, then reopen
   ESC → Settings. *Event duration* should read `50%`.
6. **Nothing base-game moved.** Scroll up and confirm *Growth mode*, *Seasonal
   growth* and *Crop destruction* are still what they were. Cloned rows inherit
   the template's callback, and if I failed to cut that wire, changing a mod row
   would change a game row instead. This is the failure I most want to catch.
7. **Arrow keys / controller**: move up and down through our rows. They should
   focus one at a time like any other row.

Then run `mswDump` **with the settings page still open** and note whether the
game logged a `SettingsMenu: cloned row shape` block.

Write down: which of 1–7 held, and anything that looked cosmetically off
(spacing, truncated labels, wrong column).

---

## Finally

Quit to the main menu and send me:

```
Documents\My Games\FarmingSimulator2025\log.txt
```

**`log.txt` itself**, not the timestamped `log_2026...txt` files — those are
previous sessions. This is the one gap in the last round.

---

## Quick results sheet

Copy this back with your numbers if it's easy:

```
setup:        day=___  month=___  daysPerMonth=___
1 baseline:   WHEAT 1.0000?  ___    station price ___
2 trigger:    dialog shown? ___     WHEAT modifier ___    station price ___
3 curve:      WHEAT ___   FLOUR ___   BREAD ___   day __/11
4 reload:     survived? ___   before ___   after ___
5 guard:      refused duplicate? ___   DIESEL after harshWinter ___
6 marker:     [+8%] visible in Prices? ___
7 settings:   rows present? ___  labels ok? ___  descriptions ok? ___
              menu -> console ok? ___  console -> menu ok? ___
              base-game rows untouched? ___
```

Anything that looks wrong but isn't on this list — note it, that's often the
useful stuff.
