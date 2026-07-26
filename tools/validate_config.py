#!/usr/bin/env python3
"""
Structural validation of config/events.xml, plus its l10n messages.

This exists because a scripted edit once silently dropped the `tier` attribute
from eight chains, which promoted soup cans from tier 2 to tier 1 and changed
how far LOW events rippled. Nothing failed; the mod just quietly behaved
differently. Every rule below is either something that has already gone wrong or
something the model relies on and cannot check for itself at runtime.

Usage:
    python3 tools/validate_config.py          # exit 1 on any error
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVENTS = ROOT / "FS25_MarketShockwaves/config/events.xml"
L10N = ROOT / "FS25_MarketShockwaves/l10n/l10n_en.xml"
FILLTYPES = ROOT / "reference/fillTypes_basegame.xml"

# The public repository ships no GIANTS game data, so this file is absent there.
# Checks that need it are skipped with a clear note rather than crashing: a
# contributor without a game install should still be able to run the tools.
ABSENT_NOTE = (
    "reference/fillTypes_basegame.xml not present — skipping the checks that "
    "need game data.\n"
    "    To enable them, copy fillTypes.xml from your Farming Simulator 25\n"
    "    install (data/maps/maps_fillTypes.xml) to that path. It is deliberately\n"
    "    not redistributed."
)

MONTHS = "jan feb mar apr may jun jul aug sep oct nov dec".split()
SEVERITIES = ("low", "medium", "high")
CATEGORIES = {"crops", "greenhouse", "trade", "biofuel", "winter", "supplies"}

errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


# How products are actually written in prose. Without this, a message saying
# "dried fruit" would be reported as failing to mention RAISINS.
PROSE_NAMES = {
    "OLIVE_OIL": ["olive oil"],
    "SUNFLOWER_OIL": ["sunflower oil"],
    "CANOLA_OIL": ["canola oil", "rapeseed oil"],
    "RICE_OIL": ["rice oil", "rice bran"],
    "GRAPEJUICE": ["grape juice", "juice"],
    "RAISINS": ["raisin", "dried fruit"],
    "MILK_BOTTLED": ["bottled milk", "milk"],
    "GOATMILK_BOTTLED": ["goat milk", "goat's milk", "bottled milk"],
    "BUFFALOMILK_BOTTLED": ["buffalo milk", "bottled milk"],
    "BUFFALOMOZZARELLA": ["mozzarella"],
    "GOATCHEESE": ["goat cheese", "cheese"],
    "LIQUIDFERTILIZER": ["liquid fertiliser", "liquid fertilizer", "fertilis",
                         "fertiliz"],
    "FERTILIZER": ["fertilis", "fertiliz"],
    "ELECTRICCHARGE": ["electric", "power"],
    "METHANE": ["methane", "gas", "biogas"],
    "CEMENTBRICKS": ["brick"],
    "ROOFPLATES": ["roof"],
    "PREFABWALL": ["prefab", "wall"],
    "SPRING_ONION": ["spring onion"],
    "NAPACABBAGE": ["napa cabbage", "cabbage"],
    "RICELONGGRAIN": ["long grain"],
    "SUGARBEET": ["sugarbeet", "sugar beet"],
    "SUGARCANE": ["sugarcane", "sugar cane"],
    "GREENBEAN": ["green bean"],
    "DRYGRASS_WINDROW": ["hay"],
    "GRASS_WINDROW": ["grass"],
    "SEEDS": ["seed"],
    "LIME": ["lime"],
    "DIESEL": ["diesel", "fuel"],
    "CLOTHES": ["clothing", "clothes"],
}


def variants(word: str) -> list[str]:
    """A word and its plausible plurals.

    Messages name products naturally, so they say "strawberries" and
    "tomatoes". Testing for the bare singular reported six greenhouse messages
    as omitting STRAWBERRY when every one of them named it — "strawberry" is
    not a substring of "strawberries".
    """
    out = [word, word + "s", word + "es"]
    if word.endswith("y"):
        out.append(word[:-1] + "ies")
    if word.endswith("o"):
        out.append(word + "es")
    return out


def mentions(body: str, name: str) -> bool:
    """Is this product plausibly named in the message prose?"""
    for phrase in PROSE_NAMES.get(name, []):
        if any(v in body for v in variants(phrase)):
            return True
    # Fall back to the bare name, and to its first word for compounds like
    # POTATOCHIPS or SOUPCANSMIXED.
    plain = name.lower().replace("_", " ")
    for candidate in (plain, plain.split()[0]):
        if any(v in body for v in variants(candidate)):
            return True
    return False


def direction_of(event) -> str:
    """Which way this event moves prices: 'up', 'down' or '?'."""
    sevs = list(event.find("severities") or [])
    if not sevs:
        return "?"
    highs = [float(s.get("priceFactorMax", 1)) for s in sevs]
    if all(h > 1.0 for h in highs):
        return "up"
    if all(h < 1.0 for h in highs):
        return "down"
    return "?"


def known_filltypes() -> set[str] | None:
    """Every fill type the game defines, or None if the data is not present."""
    if not FILLTYPES.exists():
        return None
    import re
    return set(re.findall(r'<fillType name="([^"]+)"',
                          FILLTYPES.read_text(encoding="utf-8")))


def main() -> int:
    root = ET.parse(EVENTS).getroot()
    l10n_text = {t.get("name"): (t.get("text") or "")
                 for t in ET.parse(L10N).getroot().iter("text")}
    l10n_keys = set(l10n_text)
    fills = known_filltypes()
    if fills is None:
        print(f"NOTE  {ABSENT_NOTE}")

    events = list(root.iter("event"))
    if not events:
        err("no events found")

    seen_ids: set[str] = set()

    for e in events:
        eid = e.get("id")
        where = f"{eid}"

        if not eid:
            err("an event has no id")
            continue
        if eid in seen_ids:
            err(f"{where}: duplicate event id")
        seen_ids.add(eid)

        if e.get("category") not in CATEGORIES:
            err(f"{where}: category {e.get('category')!r} is not one of "
                f"{sorted(CATEGORIES)} — the settings menu would never toggle it")

        if e.get("type") not in ("win", "lose", "neutral"):
            err(f"{where}: type {e.get('type')!r} is not win/lose/neutral")

        try:
            if float(e.get("baseWeight", "")) <= 0:
                err(f"{where}: baseWeight must be > 0")
        except ValueError:
            err(f"{where}: baseWeight is missing or not a number")

        # ---- affects ----
        affects = (e.findtext("affects") or "").split()
        if not affects:
            err(f"{where}: <affects> is empty — the event would move nothing")
        for name in affects:
            if fills is not None and name not in fills:
                warn(f"{where}: affects {name}, which is not in the base game "
                     f"fill types (fine if a map or DLC adds it)")

        # ---- month weights ----
        mw = e.find("monthWeights")
        if mw is None:
            err(f"{where}: no <monthWeights>")
        else:
            missing = [m for m in MONTHS if mw.get(m) is None]
            if missing:
                err(f"{where}: monthWeights missing {', '.join(missing)}")
            total = sum(float(mw.get(m, 0)) for m in MONTHS)
            if total <= 0:
                err(f"{where}: all month weights are zero — the event can never fire")

        # ---- chains ----
        chains = e.find("chains")
        drivers: dict[str, str] = {}
        for c in (chains if chains is not None else []):
            src, dst = c.get("from"), c.get("to")
            if not src or not dst:
                err(f"{where}: a chain is missing from/to")
                continue

            # The regression this file was written for.
            if c.get("tier") is None:
                err(f"{where}: chain {src}->{dst} has no explicit tier — "
                    f"ripple depth would silently change")
            else:
                tier = int(c.get("tier"))
                if tier not in (1, 2, 3):
                    err(f"{where}: chain {src}->{dst} tier={tier}, must be 1..3")

            # Single-driver rule: each processed good has exactly one source
            # within an event, so nothing is impacted twice.
            if dst in drivers:
                err(f"{where}: {dst} is driven by both {drivers[dst]} and {src} "
                    f"— violates the single-driver rule")
            drivers[dst] = src

            if dst in affects:
                err(f"{where}: {dst} is both in <affects> and a chain target "
                    f"— it would move twice")

            for name in (src, dst):
                if fills is not None and name not in fills:
                    warn(f"{where}: chain references {name}, not in base game "
                         f"fill types")

            pt = c.get("passThrough")
            if pt is not None and not (0 < float(pt) <= 1):
                err(f"{where}: chain {src}->{dst} passThrough={pt}, "
                    f"must be within (0, 1]")

        # A chain source must be reachable: either directly affected, or the
        # target of another chain in the same event.
        for c in (chains if chains is not None else []):
            src = c.get("from")
            if src and src not in affects and src not in drivers:
                err(f"{where}: chain from {src}, which the event never moves "
                    f"— that hop can never fire")

        # ---- severities ----
        sevs = {s.get("class"): s for s in (e.find("severities") or [])}
        for level in SEVERITIES:
            if level not in sevs:
                err(f"{where}: no {level} severity")
                continue
            s = sevs[level]
            lo = float(s.get("priceFactorMin", 0))
            hi = float(s.get("priceFactorMax", 0))
            if lo <= 0 or hi <= 0:
                err(f"{where}/{level}: priceFactor must be > 0")
            elif lo > hi:
                err(f"{where}/{level}: priceFactorMin {lo} > Max {hi}")

            # NOTE: `type` is the PLAYER's outcome, not the price direction.
            # inputShock is type="lose" and raises prices, because the player
            # buys fertiliser rather than selling it. So direction cannot be
            # checked against type — only for consistency, below.

            dmin = float(s.get("durationMonthsMin", 0))
            dmax = float(s.get("durationMonthsMax", 0))
            if dmin <= 0 or dmax <= 0:
                err(f"{where}/{level}: duration must be > 0")
            elif dmin > dmax:
                err(f"{where}/{level}: durationMonthsMin {dmin} > Max {dmax}")

            depth = s.get("rippleDepth")
            if depth is None:
                err(f"{where}/{level}: no rippleDepth")
            elif int(depth) not in (0, 1, 2, 3):
                err(f"{where}/{level}: rippleDepth {depth} must be 0..3")

            peak_lo = float(s.get("peakPosMin", -1))
            peak_hi = float(s.get("peakPosMax", -1))
            if not (0 < peak_lo <= peak_hi < 1):
                err(f"{where}/{level}: peakPos {peak_lo}..{peak_hi} must sit "
                    f"within (0, 1) and be ordered")

        if all(l in sevs for l in SEVERITIES):
            # Every severity of one event must push prices the same way. A
            # single flipped bound would make an event raise prices on a low
            # roll and lower them on a high one.
            directions = set()
            for level in SEVERITIES:
                s = sevs[level]
                lo = float(s.get("priceFactorMin", 1))
                hi = float(s.get("priceFactorMax", 1))
                if lo >= 1.0 and hi >= 1.0:
                    directions.add("up")
                elif lo <= 1.0 and hi <= 1.0:
                    directions.add("down")
                else:
                    err(f"{where}/{level}: priceFactor {lo}..{hi} straddles 1.0 "
                        f"— the same severity could raise or lower prices")
            if len(directions) > 1:
                err(f"{where}: severities disagree on direction {sorted(directions)} "
                    f"— an event must move prices one way at every severity")

            # High must actually be more severe than low, or the severity roll
            # is decorative.
            def swing(level: str) -> float:
                return abs(float(sevs[level].get("priceFactorMax", 1)) - 1.0)
            if not (swing("low") <= swing("medium") <= swing("high")):
                err(f"{where}: severities are not ordered by magnitude "
                    f"(low {swing('low'):.3f}, medium {swing('medium'):.3f}, "
                    f"high {swing('high'):.3f})")

            # Longer events for worse events, same reasoning.
            def dur(level: str) -> float:
                return float(sevs[level].get("durationMonthsMax", 0))
            if not (dur("low") <= dur("medium") <= dur("high")):
                warn(f"{where}: durations are not ordered "
                     f"(low {dur('low')}, medium {dur('medium')}, high {dur('high')})")

        # ---- messages ----
        for level in SEVERITIES:
            for part in ("title", "text"):
                key = f"msw_{eid}_{level}_{part}"
                if key not in l10n_keys:
                    err(f"{where}: missing l10n key {key}")

        # Every directly-hit product should be named in the message, or the
        # player is told less than the event does. TOMATO sat in the two
        # Mediterranean events for weeks without appearing in any of their six
        # messages; this is the check that would have caught it.
        #
        # A warning, not an error: the messages are prose, so the match is
        # necessarily fuzzy — a legitimate phrasing may not contain the product
        # name at all.
        for level in SEVERITIES:
            body = (l10n_text.get(f"msw_{eid}_{level}_text") or "").lower()
            if not body:
                continue
            unmentioned = [name for name in affects
                           if not mentions(body, name)]
            if unmentioned:
                warn(f"{where}/{level}: message does not appear to mention "
                     f"{', '.join(unmentioned)} — directly affected but unnamed")

    # ---- subtype / mutual exclusion ----
    #
    # Events sharing a subtype can never run at once. Two things can go wrong
    # and neither shows up at runtime: a typo invents a group of one, and a new
    # mirror pair gets added without being grouped at all.
    explicit: dict[str, list[str]] = {}
    for e in events:
        sub = e.get("subtype")
        if sub is not None:
            explicit.setdefault(sub, []).append(e.get("id"))

    for sub, members in sorted(explicit.items()):
        if len(members) == 1:
            warn(f"subtype {sub!r} has only one member ({members[0]}) — a group "
                 f"of one excludes nothing, so this is probably a typo; omit the "
                 f"attribute if the event is genuinely unpaired")

    # Look for un-grouped mirrors: same products, opposite price direction.
    by_products: dict[frozenset, list] = {}
    for e in events:
        key = frozenset((e.findtext("affects") or "").split())
        if key:
            by_products.setdefault(key, []).append(e)

    for products, group in by_products.items():
        ups = [e for e in group if direction_of(e) == "up"]
        downs = [e for e in group if direction_of(e) == "down"]
        for a in ups:
            for b in downs:
                sub_a = a.get("subtype") or a.get("id")
                sub_b = b.get("subtype") or b.get("id")
                if sub_a != sub_b:
                    warn(f"{a.get('id')} and {b.get('id')} hit the same products "
                         f"in opposite directions but have different subtypes "
                         f"({sub_a!r} vs {sub_b!r}) — mirrored events should share "
                         f"a subtype so they can never overlap")

    # ---- roster-level balance ----
    wins = sum(1 for e in events if e.get("type") == "win")
    loses = sum(1 for e in events if e.get("type") == "lose")
    if abs(wins - loses) > 1:
        warn(f"roster is {wins} win vs {loses} lose — the design calls for "
             f"players winning and losing about equally often")

    # ---- report ----
    for w in warnings:
        print(f"WARN  {w}")
    for e_ in errors:
        print(f"ERROR {e_}")

    print(f"\n{len(events)} events, {wins} win / {loses} lose / "
          f"{len(events) - wins - loses} neutral — "
          f"{len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
