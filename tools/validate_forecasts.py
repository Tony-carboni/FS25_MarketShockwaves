#!/usr/bin/env python3
"""
Structural validation of config/forecasts.xml, plus its l10n messages.

The rule this file exists for is THE ACTIONABILITY CHECK. A forecast is only
worth having if the player can act on it: it has to arrive before the crop is
sown and pay out once it can be harvested, with enough months in between to
change a plan. The mod checks this again in game against the loaded map's own
calendar; here it is checked against the base game's months, so a forecast that
could never work fails the build instead of quietly never appearing.

The rest are the mistakes the model cannot report for itself at runtime: an
outcome event that is misspelt, a backfire that moves the same way as the
forecast, a message that is missing or states a number.

Usage:
    python3 tools/validate_forecasts.py          # exit 1 on any error
"""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MOD = ROOT / "FS25_MarketShockwaves"
FORECASTS = MOD / "config/forecasts.xml"
EVENTS = MOD / "config/events.xml"
L10N = MOD / "l10n/l10n_en.xml"
CALENDAR = MOD / "scripts/model/CropCalendar.lua"
FILLTYPES = ROOT / "reference/fillTypes_basegame.xml"

SEVERITIES = ("low", "medium", "high")
STAGES = ("open", "asForecast", "stronger", "milder", "wrongReason", "backfire")
KINDS = ("crop", "window", "fixed")

errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def base_calendar() -> dict[str, tuple[int, int]]:
    """sowFirst and harvestFirst per crop, read from the Lua fallback table so
    the two can never disagree."""
    out = {}
    pattern = re.compile(r"^\s*(\w+)\s*=\s*\{\s*sowFirst\s*=\s*(\d+).*?harvestFirst\s*=\s*(\d+)")
    for line in CALENDAR.read_text(encoding="utf-8").splitlines():
        m = pattern.match(line)
        if m:
            out[m.group(1)] = (int(m.group(2)), int(m.group(3)))
    return out


def months_until(a: int, b: int) -> int:
    return (b - a) % 12


def direction(event) -> int:
    sev = {s.get("class"): s for s in event.find("severities")}["medium"]
    mid = (float(sev.get("priceFactorMin")) + float(sev.get("priceFactorMax"))) / 2
    return 1 if mid >= 1.0 else -1


def check_event(e, fills) -> None:
    where = f"outcome event {e.get('id')}"
    affects = (e.findtext("affects") or "").split()
    if not affects:
        err(f"{where}: <affects> is empty")
    opp = e.find("opposite")
    opposite = (opp.text or "").split() if opp is not None else []
    if opp is not None:
        if not opposite:
            err(f"{where}: <opposite> is empty")
        for attr in ("scale", "durationShare"):
            v = opp.get(attr)
            if v is not None and not (0 < float(v) <= 1):
                err(f"{where}: <opposite {attr}={v}> must be within (0, 1]")
        for name in opposite:
            if name in affects:
                err(f"{where}: {name} is in both <affects> and <opposite>")

    drivers = {}
    chains = e.find("chains")
    for c in (chains if chains is not None else []):
        src, dst = c.get("from"), c.get("to")
        if c.get("tier") is None or int(c.get("tier")) not in (1, 2, 3):
            err(f"{where}: chain {src}->{dst} needs an explicit tier of 1..3")
        if dst in drivers:
            err(f"{where}: {dst} is driven twice (single-driver rule)")
        drivers[dst] = src
        if dst in affects:
            err(f"{where}: {dst} is both in <affects> and a chain target")
        if dst in opposite or src in opposite:
            err(f"{where}: chain {src}->{dst} touches an <opposite> product")
        pt = c.get("passThrough")
        if pt is not None and not (0 < float(pt) <= 1):
            err(f"{where}: chain {src}->{dst} passThrough={pt} must be within (0, 1]")
    for c in (chains if chains is not None else []):
        src = c.get("from")
        if src not in affects and src not in drivers:
            err(f"{where}: chain from {src}, which the event never moves")

    if fills is not None:
        for name in set(affects) | set(opposite) | set(drivers):
            if name not in fills:
                warn(f"{where}: {name} is not a base-game fill type")

    sevs = {s.get("class"): s for s in (e.find("severities") or [])}
    directions, swings = set(), {}
    for level in SEVERITIES:
        s = sevs.get(level)
        if s is None:
            err(f"{where}: no {level} severity")
            continue
        lo, hi = float(s.get("priceFactorMin")), float(s.get("priceFactorMax"))
        if lo <= 0 or lo > hi:
            err(f"{where}/{level}: bad priceFactor range {lo}..{hi}")
        if (lo < 1.0) != (hi < 1.0) and lo != 1.0 and hi != 1.0:
            err(f"{where}/{level}: priceFactor {lo}..{hi} straddles 1.0")
        directions.add(1 if (lo + hi) / 2 >= 1 else -1)
        swings[level] = abs((lo + hi) / 2 - 1)
        peak_lo, peak_hi = float(s.get("peakPosMin")), float(s.get("peakPosMax"))
        if not (0 < peak_lo <= peak_hi < 1):
            err(f"{where}/{level}: peakPos {peak_lo}..{peak_hi} must sit within (0, 1)")
        if s.get("rippleDepth") is None:
            err(f"{where}/{level}: no rippleDepth")
    if len(directions) > 1:
        err(f"{where}: severities disagree on direction")
    if len(swings) == 3 and not (swings["low"] <= swings["medium"] <= swings["high"]):
        err(f"{where}: swings must grow from low to high")


def main() -> int:
    tree = ET.parse(FORECASTS).getroot()
    texts = {t.get("name"): t.get("text") for t in ET.parse(L10N).getroot().iter("text")}
    random_events = {e.get("id"): e for e in ET.parse(EVENTS).getroot().iter("event")}
    fills = None
    if FILLTYPES.exists():
        fills = {f.get("name") for f in ET.parse(FILLTYPES).getroot().iter("fillType")}
    else:
        print("note: reference/fillTypes_basegame.xml not present — product names not checked")
    calendar = base_calendar()
    if not calendar:
        err("could not read the base calendar from CropCalendar.lua")

    outcome = {}
    for e in tree.find("outcomeEvents"):
        eid = e.get("id")
        if eid in outcome or eid in random_events:
            err(f"outcome event {eid}: duplicate id")
        outcome[eid] = e
        check_event(e, fills)
    known = {**random_events, **outcome}

    settings = tree.find("settings")
    min_lead = float(settings.find("minLeadMonths").get("value"))
    conf = settings.find("confidence")
    if any(k not in ("c70", "c80", "c90") for k in conf.keys()):
        err("settings: confidence may only be 70, 80 or 90 (70 is the minimum)")
    if abs(sum(float(conf.get(k, 0)) for k in ("c70", "c80", "c90")) - 1.0) > 1e-6:
        err("settings: the confidence shares must add up to 1")

    seen = set()
    variants = 0
    for f in tree.findall("forecast"):
        fid = f.get("id")
        where = f"forecast {fid}"
        if fid in seen:
            err(f"{where}: duplicate id")
        seen.add(fid)
        kind = f.get("kind")
        if kind not in KINDS:
            err(f"{where}: kind {kind!r} is not one of {KINDS}")
            continue
        premove = (f.findtext("premove") or "").split()
        if not premove:
            err(f"{where}: no <premove> products")

        # ---- when can it arrive, and how long until the verdict? ------------
        leads = {}      # variant id -> list of lead months, one per arrival month
        if kind == "crop":
            anchors = (f.get("anchors") or "").split()
            if not anchors:
                err(f"{where}: a crop forecast needs anchors")
            for crop in anchors:
                if crop not in calendar:
                    err(f"{where}: anchor {crop} has no base calendar in CropCalendar.lua")
            usable = [c for c in anchors if c in calendar]
            if usable:
                # Checked for EVERY anchor: on a map without the first crop the
                # forecast is timed by the next one, and must still work.
                for crop in usable:
                    sow, harvest = calendar[crop]
                    growing = months_until(sow, harvest) or 12
                    for arrive in ((sow - 3) % 12 + 1, (sow - 2) % 12 + 1):
                        lead = months_until(arrive, sow) + growing
                        if lead < min_lead:
                            err(f"{where}: timed by {crop}, a message in month {arrive} "
                                f"leaves only {lead} month(s) before the verdict "
                                f"(minimum {min_lead:g}) — the player could not act on it")
        elif kind == "window":
            arrive_months = [int(m) for m in (f.get("arriveMonths") or "").split()]
            if not arrive_months or f.get("endMonth") is None:
                err(f"{where}: a window forecast needs arriveMonths and endMonth")
        else:
            lead = float(f.get("leadMonths") or 0)
            if lead < min_lead:
                err(f"{where}: leadMonths {lead:g} is below the minimum {min_lead:g}")
            if float(f.get("durationMonths") or 0) <= 0:
                err(f"{where}: a fixed forecast needs durationMonths")

        vs = f.findall("variant")
        if not vs:
            err(f"{where}: no variants")
        for v in vs:
            variants += 1
            vid = v.get("id")
            vwhere = f"{where}/{vid}"
            ev, back = v.get("event"), v.get("backfire")
            for label, eid in (("event", ev), ("backfire", back)):
                if eid not in outcome:
                    err(f"{vwhere}: {label} {eid!r} is not an outcome event in forecasts.xml")
            extra = v.get("extraEvent")
            if extra is not None and extra not in known:
                err(f"{vwhere}: extraEvent {extra!r} is not a known event")
            if ev in outcome and back in outcome:
                if ev == back:
                    err(f"{vwhere}: the backfire is the same event as the forecast")
                if direction(outcome[ev]) == direction(outcome[back]):
                    err(f"{vwhere}: the backfire moves the same way as the forecast")
                if outcome[ev].get("subtype") != outcome[back].get("subtype"):
                    err(f"{vwhere}: {ev} and {back} must share a subtype, so they "
                        f"can never run together")
            if ev in outcome:
                moved = (outcome[ev].findtext("affects") or "").split()
                for name in premove:
                    if name not in moved:
                        err(f"{vwhere}: pre-move product {name} is not one {ev} leads with")

            if kind == "window":
                vm = v.get("verdictMonth")
                if vm is None:
                    err(f"{vwhere}: a window forecast's variant needs verdictMonth")
                else:
                    for arrive in arrive_months:
                        lead = months_until(arrive, int(vm)) or 12
                        if lead < min_lead:
                            err(f"{vwhere}: a message in month {arrive} leaves only "
                                f"{lead} month(s) before the verdict (minimum {min_lead:g})")

            # ---- messages ---------------------------------------------------
            for stage in STAGES:
                base = f"msw_fc_{fid}_{vid}_{stage}"
                title, text = texts.get(base + "_title"), texts.get(base + "_text")
                if not title or not text:
                    err(f"{vwhere}: no message for '{stage}' ({base}_title / _text)")
                    continue
                n = text.count("%s")
                if stage == "open" and n != 1:
                    err(f"{base}_text: the opening needs exactly one %s for the confidence line")
                if stage != "open" and n != 0:
                    err(f"{base}_text: only the opening may contain %s")
                # The owner's rule: no hard numbers about size or length.
                if re.search(r"\d", title + text):
                    err(f"{base}: a forecast message must not state a number")

    for level in (70, 80, 90):
        if not texts.get(f"msw_fc_confidence_{level}"):
            err(f"no text for msw_fc_confidence_{level}")

    for w in warnings:
        print(f"  warn  {w}")
    for e in errors:
        print(f"  FAIL  {e}")
    if errors:
        print(f"\n{len(errors)} error(s) in forecasts.xml")
        return 1
    print(f"  ok  forecasts.xml: {len(seen)} forecasts, {variants} variants, "
          f"{len(outcome)} outcome events, {variants * len(STAGES)} messages; "
          f"every forecast is actionable on the base calendar")
    return 0


if __name__ == "__main__":
    sys.exit(main())
