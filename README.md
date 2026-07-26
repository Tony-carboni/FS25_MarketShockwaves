# Market Shockwaves

A **global economy mod** for Farming Simulator 25. Market events — droughts,
embargoes, gluts, export booms, bad winters — move prices along a curve that
builds over weeks, holds, and corrects when the new harvest lands. Shocks ripple
down the production chain: wheat first, then flour, then bread, each later and
softer than the last.

Works on **any map**. It wraps the game's price lookup and multiplies the result,
so it ships no map data and edits no `fillTypes.xml` — any map's own prices, and
any crops it adds, keep working underneath.

Author: **Tony_Carboni** · singleplayer (multiplayer sync planned) ·
`descVersion="96"`

---

## Start here

| If you want to… | Read |
|---|---|
| **See every event in detail** — its three messages, the products it moves, its severity ranges and its month-by-month weighting | **[`docs/event-review.md`](docs/event-review.md)** |
| Understand *why* the mod behaves as it does — the curve model, the ripple rules, the balance decisions | [`DESIGN.md`](DESIGN.md) |
| Know which products are covered and which are still free | [`docs/filltype-coverage.txt`](docs/filltype-coverage.txt) |
| Tune the events yourself | [`FS25_MarketShockwaves/config/events.xml`](FS25_MarketShockwaves/config/events.xml) — fully commented, player-editable |
| Test a build in game | [`TESTPLAN.md`](TESTPLAN.md) |
| Know what has actually been verified in game vs. assumed | [`TESTING.md`](TESTING.md) |
| Publish it | [`docs/mod-description.md`](docs/mod-description.md) |
| Find or add a screenshot | [`docs/screenshots/`](docs/screenshots/) — naming, what to capture, and two rules for captions |

**`docs/event-review.md` is the reference to reach for first.** For each of the
17 events it gives:

- the three severity messages, in full
- every product moved, split into direct hits and ripple targets (with driver,
  tier, lag and pass-through)
- the severity ranges — price swing, duration and ripple depth per severity,
  plus the curve shape behind them
- the weighting for all twelve months, as raw weights and as the share of the
  event's firings each month takes

Having the messages next to the numbers is the point: it is the only way to catch
a message promising something the config does not do, or a chain wired and never
mentioned.

---

## Repository layout

```
FS25_MarketShockwaves/      the mod itself; this directory is what gets zipped
  modDesc.xml               mod manifest, script load order, l10n
  config/events.xml         the event roster — heavily commented, editable
  l10n/l10n_en.xml          every player-facing string
  scripts/
    lib/                    Logger, Random, Diagnostics
    model/                  pure logic, no game API: Curve, EventDef,
                            ActiveEvent, EventScheduler, PriceModel
    game/                   the game-integration layer: Economy, Calendar,
                            Settings, SettingsMenu, PriceDisplay, Notification
    MarketShockwaves.lua    entry point, lifecycle hooks, console commands

tools/                      build, validation, tests, simulators, report generators
docs/                       generated references, store copy, screenshots
reference/                  the game's own data, for cross-checking
DESIGN.md                   the design record, including decisions reversed
TESTPLAN.md / TESTING.md    manual in-game test cases, and what they proved
```

The split between `scripts/model/` and `scripts/game/` is deliberate: everything
in `model/` is pure Lua with no game API, which is what makes the offline test
suite possible.

---

## Build

```sh
./tools/build.sh          # -> build/FS25_MarketShockwaves.zip
```

Then copy the zip into:

```
Windows:  %USERPROFILE%\Documents\My Games\FarmingSimulator2025\mods\
```

The build syntax-checks every script, validates the event config, regenerates the
reference docs, and runs both test suites before packaging. It refuses to produce
a zip if any of that fails.

**Delete the old zip from your mods folder before copying a new one in.** A stale
install once cost a full round trip of diagnosis — the log looked like a code bug
when the game was simply running yesterday's files. Every build stamps its id
into `log.txt` (`build=bNN`) and into `modDesc`, so this is always checkable —
compare that line against the build you meant to install before trusting anything
you see.

---

## Releasing

Tag it; Actions does the rest.

```sh
# 1. set the version in FS25_MarketShockwaves/modDesc.xml, e.g. 0.9.0.0
# 2. commit that
git tag v0.9.0.0
git push origin v0.9.0.0
```

`.github/workflows/release.yml` then checks the tag matches `modDesc`, runs the
full build — config validation, doc audit, both test suites — and publishes the
zip as a release asset marked pre-release. **The published zip is built by the
pipeline, never uploaded from a laptop**, so no hand-made build can reach a
release.

Two things that will bite otherwise:

- **The tag must match `<version>` in `modDesc.xml`.** The workflow fails
  otherwise. A release labelled v0.9.0.0 containing a zip that reports `0.1.0.14`
  in the mod list costs a support thread to untangle.
- **Never rename the zip.** In FS25 the filename *is* the mod name, so
  `FS25_MarketShockwaves_v0.9.zip` would rename the mod, orphan savegame data and
  break the l10n prefix. It stays `FS25_MarketShockwaves.zip`.

**Release assets on a private repo are only downloadable by people with repo
access.** For a public beta link the repo has to be public first — and see the
licence and third-party-file notes below before flipping that switch.

### This repo stays private; a separate one is published

**This repository is private and keeps the full development history.** It contains
third-party reference material used during development — GIANTS and DLC
`fillTypes.xml` data, and another modder's source under CC BY-NC-ND — none of
which should be in a public repository. Deleting those files would not remove them
from git history, so the public repo is a **fresh tree with one squashed commit**
rather than a deletion commit.

```sh
./tools/make_public_tree.sh            # -> ../FS25_MarketShockwaves
```

The script refuses to run on a dirty tree, builds and tests first, excludes
`reference/`, then **verifies nothing leaked** — no file containing
`<fillType name=`, nothing named after the excluded paths, and the licence
present. It then re-runs validation, the doc audit, both freshness checks and both
test suites *inside the copied tree* to prove the tools still work with no game
data, and prints the exact publish and tag commands.

The tools degrade deliberately when `reference/` is absent: they print what is
missing, where to copy it from, and skip only the checks that need it. So a
contributor with no game install can still run everything else.

The public repo is named **`FS25_MarketShockwaves`** — matching the mod, the zip
and the mod folder, which is what someone arriving from a KingMods link expects.
Its download page is
`https://github.com/Tony-carboni/FS25_MarketShockwaves/releases` — the index, not
`/releases/latest`. **GitHub's "latest" excludes prereleases**, so while the beta
is flagged as one, `/releases/latest/download/…` returns 404. The index always
lists the newest first, prerelease included, and never needs changing between
versions. Verified: the index and the per-tag asset URL both return 200
unauthenticated; the `latest/download` shortcut returns 404.

Publishing a new version is: develop here, re-run the script, force-push the
public repo. It is a snapshot, not a working history.

Note the mod lives in a `FS25_MarketShockwaves/` subfolder rather than at the
repo root, so the public repo reads `FS25_MarketShockwaves/FS25_MarketShockwaves/`.
That is deliberate — the repo also carries the tools, tests and docs — and it does
not affect the built zip, which has `modDesc.xml` at its root as the game
requires.

### Licence

**CC BY-NC-ND 4.0** — see [`LICENSE`](LICENSE). Share it unchanged with credit,
non-commercially; no reuploads, forks or repacks. The NoDerivatives clause is
deliberate, and the LICENSE file names its cost honestly: it blocks other modders
adapting this the same way this project was blocked from adapting someone else's.

---

## Tools

| Command | What it does |
|---|---|
| `./tools/build.sh` | check, validate, regenerate, test, package |
| `python3 tools/validate_config.py` | structural rules the price model relies on |
| `python3 tools/audit_docs.py` | the hand-written docs still match the config |
| `./tools/make_public_tree.sh` | build the publishable tree, leak-checked |
| `python3 tools/event_review.py -o docs/event-review.md` | regenerate the event review sheet |
| `python3 tools/filltype_coverage.py -o docs/filltype-coverage.txt` | regenerate the coverage report |
| `python3 tools/roster_report.py --markdown` | month-by-month view of the whole roster |
| `lua tools/test_model.lua` | 71 offline tests of the curve, ripple, scheduler and mutual exclusion |
| `lua tools/test_settings_menu.lua` | 36 offline tests of the settings rows |

The `*_sim.py` scripts are the Python simulators the Lua model was validated
against — propagation, severity ripple, trigger timing, cooldown.

---

## Keeping the generated docs honest

`docs/event-review.md` and `docs/filltype-coverage.txt` are **generated — do not
edit them by hand.** `./tools/build.sh` rewrites both on every build, and CI runs
the same tools with `--check`, which fails if a config change was committed
without regenerating. A generated reference that has drifted is worse than none,
because it is trusted.

If CI reports one stale, the fix is the command in the error message.

The **hand-written** docs can drift, and have — DESIGN.md once described a chain
that had been removed. `tools/audit_docs.py` cross-checks the facts they share
with the config: chain values, month-weight tables, product lists, the
mutual-exclusion pairs, event counts, coverage totals and test counts. It runs in
the build and in CI. Anything it cannot determine, it says so rather than
guessing — see the note in that file about tree-form chain diagrams.

---

## Working on the events

`config/events.xml` is the file to edit, and the comments in it carry the
reasoning for each event. Two rules the model depends on and cannot check at
runtime — both enforced by `tools/validate_config.py`:

- **Every chain needs an explicit `tier`.** Tier is the ripple depth a severity
  must reach for that hop to apply (LOW reaches tier 1, MEDIUM 2, HIGH 3). It is
  *not* derived from the graph shape: cake is made from flour, a sibling of bread,
  yet should move later and only on severe shocks.
- **Single-driver rule.** Within one event, each processed good is driven by
  exactly one source, so nothing is impacted twice. Wheat drives flour, so barley
  does not.

One thing that catches people: **`type` is the *player's* outcome, not the price
direction.** `inputShock` is `type="lose"` and *raises* prices, because the player
buys fertiliser rather than selling it.

After editing, run `./tools/build.sh` — it will validate the config, regenerate
the docs and re-run the tests.

---

## In-game console

Enable the developer console in `game.xml`, then press `~`:

```
mswStatus                       settings, calendar and active events
mswTrigger <eventId> [severity] force an event now (bypasses season and cooldown)
mswPrice <PRODUCT>              current modifier for a product
mswClear                        remove all active events
mswSettings                     every setting with its current value
mswSet <setting> <value>        change a setting
mswReset                        restore defaults
mswNotify <id> [severity]       preview a message without starting an event
mswMarkers on|off               the [+14%] commodity name markers
mswHooks                        check our price hooks are still installed
mswDebug                        toggle verbose logging
mswDump                         full diagnostic dump to log.txt
```

Player settings also live in **ESC → Settings → Game Settings**, under a
`MARKET SHOCKWAVES` heading.

### Event ids, for `mswTrigger`

| Category | Ids |
|---|---|
| crops | `grainDrought` `grainBumper` `rootDrought` `rootBumper` |
| greenhouse | `greenhousePest` `greenhouseBounty` |
| trade | `dairyEmbargo` `dairyExportBoom` `mediterraneanEmbargo` `mediterraneanExportBoom` `asianTradeDisruption` `monsoonBounty` |
| biofuel | `ethanolGlut` `ethanolBoom` |
| winter | `harshWinter` |
| supplies | `naturalDisaster` `inputShock` |

`mswStatus` lists them too. Severity is `low`, `medium` or `high`, defaulting to
`medium`.

Each row of that table is a mirror pair except winter and supplies, and **paired
events can never run at once** — triggering one while its mirror is active is
refused, and the message names the blocker. That is the rule working, not a bug;
`mswClear` first if you want the other one.

### Recipes

**Take a screenshot of an event message**

```
mswClear
mswTrigger grainDrought medium
```

`mswNotify <id> <severity>` shows the same dialog *without* starting an event, if
you only want the text.

**Show the ripple and its damping in one frame**

```
mswMarkers on
mswTrigger grainDrought high
```

Then open the price list: wheat, straw, flour and bread each carry their own
figure, so the lag and the damping are visible at a glance. The markers also
appear in the shop and in storage.

**Check a ripple has actually travelled**

```
mswPrice WHEAT      # the direct hit
mswPrice FLOUR      # one hop, ~1 month behind
mswPrice BREAD      # two hops
```

Early in an event the downstream products still read `1.0000` — that is the lag,
not a fault. Advance a month and check again.

**Verify a setting bites**

```
mswSet supplyChainDepth 0
mswTrigger grainDrought high
mswPrice WHEAT      # up
mswPrice FLOUR      # 1.0000 — ripples disabled
mswClear
mswSet supplyChainDepth 3
```

**Reset**

| | |
|---|---|
| `mswClear` | ends all active events, prices back to 1.0 |
| `mswReset` | settings back to shipped defaults (does not touch events) |

`mswClear` does not reset the cooldown clock — the minimum gap still counts from
when the last event *started*. `mswTrigger` ignores the cooldown anyway.

**Diagnose anything**

```
mswDump
```

Writes a full dump to `log.txt`: calendar, config, fill-type resolution, active
events, resolved prices and the GUI structure. Run it with the relevant menu page
open — the settings and price frames only exist while they are on screen. Send
that file with any bug report.
