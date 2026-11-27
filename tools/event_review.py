#!/usr/bin/env python3
"""
Event review sheet — every event's player-facing messages next to the products
it actually moves.

Written for reviewing the writing and the coverage together: it is easy to say
"grain drought hits the oils" in a message and then not wire the chain, or to
wire a chain and never mention it. Reading both side by side is the only way to
catch that.

Generated from the real config and the real l10n file, so it cannot drift from
what the mod does.

Usage:
    python3 tools/event_review.py                  # print
    python3 tools/event_review.py -o docs/event-review.md
"""
import argparse
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVENTS = ROOT / "FS25_MarketShockwaves/config/events.xml"
L10N = ROOT / "FS25_MarketShockwaves/l10n/l10n_en.xml"

MONTHS = "jan feb mar apr may jun jul aug sep oct nov dec".split()
LABELS = [m.capitalize() for m in MONTHS]
SEVERITIES = ("low", "medium", "high")

TYPE_WORD = {"win": "player win", "lose": "player lose", "neutral": "neutral"}


def season_line(mw) -> str:
    """A compact description of when the event may fire."""
    if mw is None:
        return "unknown"
    weights = [float(mw.get(m, 0)) for m in MONTHS]
    live = [i for i, w in enumerate(weights) if w > 0]
    peak = max(weights)
    peaks = "/".join(LABELS[i] for i, w in enumerate(weights) if w == peak)

    if not live:
        return "never fires"
    if len(live) == 12:
        if len(set(weights)) == 1:
            return "all year, flat"
        return f"all year, peaking {peaks}"

    # The window is circular: a winter event runs Nov-Mar, so the live months
    # are not a simple ascending run and reading live[0]..live[-1] would report
    # "Jan-Dec". Start from the first live month whose predecessor is dead.
    starts = [i for i in live if (i - 1) % 12 not in live]
    if len(starts) != 1:
        # More than one separate window; name the months rather than guess.
        return (f"{'/'.join(LABELS[i] for i in live)} "
                f"({len(live)} months), peaking {peaks}")
    start = starts[0]
    end = (start + len(live) - 1) % 12
    return (f"{LABELS[start]}–{LABELS[end]} ({len(live)} months), "
            f"peaking {peaks}")


def direction(event) -> str:
    """Which way this event moves the prices it touches."""
    sevs = list(event.find("severities") or [])
    if not sevs:
        return "?"
    highs = [float(s.get("priceFactorMax", 1)) for s in sevs]
    return "prices up" if all(h > 1.0 for h in highs) else "prices down"


def num(x: float, places: int = 1) -> str:
    """Trim a float to the shortest honest form: 1.0 -> 1, 7.50 -> 7.5.

    Only strips zeros AFTER a decimal point. Stripping unconditionally turned
    60 into 6 and 10-40% into 1-4%, which is the kind of wrong that looks
    plausible on a reference sheet.
    """
    s = f"{x:.{places}f}"
    if "." in s:
        s = s.rstrip("0").rstrip(".")
    return s or "0"


def pct_change(factor: float) -> str:
    """1.15 -> +15%, 0.925 -> -7.5%."""
    delta = (factor - 1.0) * 100.0
    sign = "+" if delta > 0 else ("−" if delta < 0 else "")
    return f"{sign}{num(abs(delta))}%"


def price_range(sev) -> str:
    """The severity's price swing, read smallest to largest."""
    lo = float(sev.get("priceFactorMin", 1))
    hi = float(sev.get("priceFactorMax", 1))
    # For a down event, priceFactorMin is the BIGGER swing, so order by size
    # rather than by value — the sheet reads as intensity either way.
    a, b = sorted((lo, hi), key=lambda f: abs(f - 1.0))
    return f"{pct_change(a)} to {pct_change(b)}"


def wrap(text: str, width: int = 78, indent: str = "> ") -> str:
    import textwrap
    return "\n".join(textwrap.wrap(text, width, initial_indent=indent,
                                   subsequent_indent=indent))


def render() -> str:
    root = ET.parse(EVENTS).getroot()
    texts = {t.get("name"): t.get("text")
             for t in ET.parse(L10N).getroot().iter("text")}
    events = list(root.iter("event"))

    # Read from the config rather than hardcoding 60/30/10, so the sheet follows
    # the file if the distribution is ever retuned.
    sc = root.find("settings/severityChances")
    chances = {level: float(sc.get(level, 0)) if sc is not None else 0.0
               for level in SEVERITIES}
    epy_el = root.find("settings/eventsPerYear")
    epy = epy_el.get("value") if epy_el is not None else "?"

    out: list[str] = []
    w = out.append

    w("# Event review sheet")
    w("")
    w("Every event's player-facing messages next to the products it actually")
    w("moves, so the writing and the coverage can be checked against each other.")
    w("")
    w("**Generated — do not edit.** `python3 tools/event_review.py -o docs/event-review.md`")
    w("Source: `config/events.xml` and `l10n/l10n_en.xml`.")
    w("")

    wins = sum(1 for e in events if e.get("type") == "win")
    loses = sum(1 for e in events if e.get("type") == "lose")
    neutral = len(events) - wins - loses
    w(f"{len(events)} events — {wins} win / {loses} lose / {neutral} neutral.")
    w("")
    w(f"Roster defaults: **{epy} events per year** on average across the whole "
      f"roster, severity rolled "
      + " / ".join(f"{level} {num(chances[level] * 100, 0)}%"
                   for level in SEVERITIES) + ".")
    w("")
    w("Every event carries equal `baseWeight`, so they fire equally often; the")
    w("events-per-year figure is a **budget split across the roster**, which means")
    w("adding an event makes each individual one rarer rather than making the")
    w("market busier. Players can raise it in the settings menu.")
    w("")

    # ---- contents ----
    # Which events can never run together, so the pairs are visible at a glance.
    groups: dict[str, list[str]] = {}
    for e in events:
        groups.setdefault(e.get("subtype") or e.get("id"), []).append(e.get("id"))

    w("| # | Event | Category | Direction | Season | Excludes |")
    w("|---|---|---|---|---|---|")
    for i, e in enumerate(events, 1):
        sub = e.get("subtype") or e.get("id")
        others = [m for m in groups[sub] if m != e.get("id")]
        w(f"| {i} | `{e.get('id')}` | {e.get('category')} | "
          f"{TYPE_WORD.get(e.get('type'), '?')}, {direction(e)} | "
          f"{season_line(e.find('monthWeights'))} | "
          f"{'`' + '`, `'.join(others) + '`' if others else '—'} |")
    w("")
    w("**Excludes** is the mutual-exclusion rule: events sharing a `subtype` can")
    w("never run at the same time, because a boom on top of its own glut is a")
    w("contradiction rather than a compounding shock. They may alternate freely —")
    w("the moment one expires the other becomes eligible. Everything else stacks,")
    w("even where two events share products.")
    w("")
    w("---")
    w("")

    for i, e in enumerate(events, 1):
        eid = e.get("id")
        w(f"## {i}. `{eid}`")
        w("")
        w(f"**{e.get('category')}** · {TYPE_WORD.get(e.get('type'), '?')} · "
          f"{direction(e)} · {season_line(e.find('monthWeights'))}")
        w("")
        sub = e.get("subtype")
        if sub is not None:
            partners = [m for m in groups[sub] if m != eid]
            if partners:
                w(f"Never runs alongside {', '.join('`' + p + '`' for p in partners)} "
                  f"(shared subtype `{sub}`).")
                w("")

        # ---- products ----
        affects = (e.findtext("affects") or "").split()
        chains = list(e.find("chains") or [])
        opp = e.find("opposite")
        opposite = (opp.text or "").split() if opp is not None else []

        w(f"### Products moved ({len(affects) + len(chains) + len(opposite)})")
        w("")
        w(f"**Direct — full magnitude ({len(affects)})**")
        w("")
        w("`" + "` · `".join(affects) + "`" if affects else "*none*")
        w("")

        if opposite:
            scale = float(opp.get("scale", "0.5"))
            w(f"**Opposite — moves the other way, at {scale:.0%} of the swing "
              f"({len(opposite)})**")
            w("")
            w("`" + "` · `".join(opposite) + "`")
            w("")

        if chains:
            w(f"**Ripple — damped and delayed ({len(chains)})**")
            w("")
            w("| Product | Driven by | Tier | Lag | Pass-through |")
            w("|---|---|:-:|:-:|:-:|")
            for c in sorted(chains, key=lambda c: (int(c.get("tier", 9)),
                                                   c.get("to") or "")):
                lag = c.get("lagMonths", "1.0")
                pt = c.get("passThrough", "0.60")
                w(f"| `{c.get('to')}` | `{c.get('from')}` | {c.get('tier')} "
                  f"| +{lag} mo | {pt} |")
            w("")
            w("Tier is the ripple depth a severity must reach for that hop to")
            w("apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.")
            w("")
        else:
            w("**Ripple** — *none; this event moves only what it hits directly.*")
            w("")

        # ---- severities ----
        sevs = {s.get("class"): s for s in (e.find("severities") or [])}
        w("### Severity ranges")
        w("")
        w("Rolled per firing, then the actual values are rolled again inside the")
        w("range — so two events of the same severity never share a curve.")
        w("")
        w("| Severity | Chance | Price change | Duration | Ripple reaches |")
        w("|---|:-:|---|---|:-:|")
        for level in SEVERITIES:
            s = sevs.get(level)
            if s is None:
                w(f"| {level.upper()} | — | *missing* | | |")
                continue
            chance = chances.get(level)
            dmin = num(float(s.get("durationMonthsMin", 0)))
            dmax = num(float(s.get("durationMonthsMax", 0)))
            w(f"| {level.upper()} | {num(chance * 100, 0)}% | {price_range(s)} "
              f"| {dmin}–{dmax} months | tier {s.get('rippleDepth')} |")
        w("")

        w("<details><summary>Curve shape per severity</summary>")
        w("")
        w("| Severity | Peak at | Rise | Plateau holds | Correction | "
          "Daily jitter | Ripple scale |")
        w("|---|---|---|---|---|---|---|")
        for level in SEVERITIES:
            s = sevs.get(level)
            if s is None:
                continue
            peak = (f"{num(float(s.get('peakPosMin', 0)) * 100, 0)}–"
                    f"{num(float(s.get('peakPosMax', 0)) * 100, 0)}% in")
            rise = (f"{num(float(s.get('riseExpMin', 1)), 2)}–"
                    f"{num(float(s.get('riseExpMax', 1)), 2)}")
            hold = f"{num(float(s.get('hold', 0)) * 100, 0)}% of peak"
            corr = f"{num(float(s.get('correctionMonths', 0)))} mo"
            jit = f"±{num(float(s.get('jitter', 0)) * 100, 1)}%"
            w(f"| {level.upper()} | {peak} | {rise} | {hold} | {corr} "
              f"| {jit} | {s.get('rippleScale', '1.00')} |")
        w("")
        w("*Peak at* is a fraction of the event's duration. *Rise* is the onset")
        w("exponent: below 1 climbs fast then flattens, above 1 starts slow and")
        w("accelerates. *Plateau holds* is where the price settles after the peak,")
        w("as a share of the peak swing — high values keep the base product")
        w("elevated while the ripple travels up the chain.")
        w("")
        w("</details>")
        w("")

        # ---- month weights ----
        mw = e.find("monthWeights")
        if mw is not None:
            weights = [float(mw.get(m, 0)) for m in MONTHS]
            total = sum(weights) or 1.0
            w("### Weighting per month")
            w("")
            w("| | " + " | ".join(LABELS) + " |")
            w("|---" * 13 + "|")
            w("| **Weight** | "
              + " | ".join(num(x, 2) if x else "–" for x in weights) + " |")
            w("| **Share** | "
              + " | ".join(f"{x / total * 100:.0f}%" if x else "–"
                           for x in weights) + " |")
            w("")
            w("*Share* is the chance of this event firing in that month given that")
            w("it fires at all — the weights are normalised, so the window sets")
            w("**when** the event happens, never **how often**. A dash means the")
            w("event cannot start that month.")
            w("")

        # ---- messages ----
        w("### Messages")
        w("")
        for sev in SEVERITIES:
            title = texts.get(f"msw_{eid}_{sev}_title", "*MISSING*")
            body = texts.get(f"msw_{eid}_{sev}_text", "*MISSING*")
            w(f"**{sev.upper()} — {title}**")
            w("")
            w(wrap(body))
            w("")

        w("---")
        w("")

    return "\n".join(out)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("-o", "--output", type=Path)
    ap.add_argument("--check", action="store_true",
                    help="exit 1 if --output is missing or out of date, without "
                         "writing it (for CI)")
    args = ap.parse_args()
    text = render() + "\n"

    if args.check:
        if args.output is None:
            print("--check needs --output")
            return 2
        current = (args.output.read_text(encoding="utf-8")
                   if args.output.exists() else None)
        if current != text:
            print(f"STALE {args.output} — regenerate with "
                  f"python3 tools/event_review.py -o {args.output}")
            return 1
        print(f"{args.output} is up to date")
        return 0

    if args.output:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(text, encoding="utf-8")
        print(f"wrote {args.output}")
    else:
        print(text, end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
