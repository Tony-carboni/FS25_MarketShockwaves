# Screenshots

In-game captures kept for the mod landing page and the ModHub / KingMods
listings. Source material, not generated — safe to edit, add to and curate.

## Naming

```
NN-subject.png
```

Two-digit prefix for display order, then a short subject in kebab-case:

```
01-event-message-drought.png
02-price-list-markers.png
03-settings-menu.png
```

Renumbering is cheap; keep the order the one you'd want on the page.

## What is worth capturing

The listing copy in [`../mod-description.md`](../mod-description.md) leads on
what the mod *feels like*, so the shots should carry that rather than
documentation:

- **An event message dialog.** The single most useful image — it shows the tone,
  and that the player gets a market report rather than a number.
- **The price list with markers on** (`mswMarkers on`). Several products showing
  different figures at once demonstrates the ripple and the damping in one frame
  — e.g. `Wheat [+60%]`, `Straw [+57%]`, `Bread [+16%]`.
- **The settings menu**, showing the `MARKET SHOCKWAVES` block in GAME SETTINGS.
  This is what tells a prospective user the mod is configurable.
- **A sell point** with a modified price, if it reads clearly.

## Two rules for captions and choice of shot

**1. Don't reveal the curve.** The listing copy deliberately names no
magnitudes, durations, severity odds or ripple timings, because the whole
decision the mod is built around — sell now or hold — only works while the
player cannot tell a mild event from a severe one. A screenshot showing one
instantaneous price marker is fine. Avoid:

- console output from `mswStatus` or `mswDump`, which prints peak factors,
  durations and day counts
- captions that name a maximum, a duration, or how often something fires

**2. Don't imply mechanics the mod doesn't have.** It moves *prices*. It does not
change yields, growth, spoilage or weather. A caption like "drought damages your
crop" promises something that will not happen and earns a bad first rating.

Also: the in-game price graph plots elapsed months only, so an event mid-run
shows partially. Don't caption a graph shot as showing an event's full history.

## Practical

- **PNG**, and web-sized — 1920×1080 is plenty. These live in git forever, so a
  handful of 5 MB captures is a permanent cost on every clone.
- Prefer daylight and a clean HUD where the subject is the menu or a dialog.
- If a shot needs explaining to be understood, it is probably the wrong shot.
