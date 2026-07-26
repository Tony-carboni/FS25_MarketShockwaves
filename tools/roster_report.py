#!/usr/bin/env python3
"""
Roster report — month-by-month view of the whole event roster.

Reads FS25_MarketShockwaves/config/events.xml (the real config, so this never
drifts from what the mod actually does) and reports:

  1. configured month weights per event
  2. relative chance by month (each event's peak month = 100%)
  3. expected events per year, per event per month (comparable across events)
  4. total market activity per month, and the win / lose / neutral split

Usage:  python3 tools/roster_report.py [--markdown]
"""
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

CONFIG = Path(__file__).resolve().parent.parent / "FS25_MarketShockwaves/config/events.xml"
MONTHS = ["jan", "feb", "mar", "apr", "may", "jun",
          "jul", "aug", "sep", "oct", "nov", "dec"]
LABELS = [m.capitalize() for m in MONTHS]


def load():
    root = ET.parse(CONFIG).getroot()
    settings = root.find("settings")
    events_per_year = float(settings.find("eventsPerYear").get("value"))

    events = []
    for ev in root.find("events").findall("event"):
        mw = ev.find("monthWeights")
        weights = [float(mw.get(m, 0)) for m in MONTHS]
        events.append({
            "id": ev.get("id"),
            "type": ev.get("type"),
            "baseWeight": float(ev.get("baseWeight", 1.0)),
            "weights": weights,
            "total": sum(weights),
        })
    return events_per_year, events


def main():
    md = "--markdown" in sys.argv
    E, events = load()
    total_bw = sum(e["baseWeight"] for e in events)

    # annual rate per event = E * baseWeight / sum(baseWeight)
    for e in events:
        e["annual"] = E * e["baseWeight"] / total_bw
        e["share"] = [(w / e["total"] if e["total"] else 0) for w in e["weights"]]
        e["perMonth"] = [e["annual"] * s for s in e["share"]]

    names = [e["id"] for e in events]
    w = max(len(n) for n in names) + 1

    def table(title, rows, header, note=""):
        print(f"\n{title}")
        if note:
            print(note)
        if md:
            print("| " + " | ".join(header) + " |")
            print("|" + "|".join(["---"] * len(header)) + "|")
            for r in rows:
                print("| " + " | ".join(r) + " |")
        else:
            widths = [max(len(header[i]), *(len(r[i]) for r in rows)) for i in range(len(header))]
            print("  " + "  ".join(h.rjust(widths[i]) for i, h in enumerate(header)))
            print("  " + "  ".join("-" * widths[i] for i in range(len(header))))
            for r in rows:
                print("  " + "  ".join(c.rjust(widths[i]) for i, c in enumerate(r)))

    print("=" * 78)
    print(f"MARKET SHOCKWAVES — ROSTER REPORT")
    print(f"eventsPerYear = {E}   events = {len(events)}   "
          f"each event = {E/total_bw:.3f}/yr (equal base weight)")
    print("=" * 78)

    # ---- 1. configured weights ------------------------------------------
    rows = [[e["id"]] + [(f"{v:g}" if v else "·") for v in e["weights"]]
            for e in events]
    table("1) CONFIGURED MONTH WEIGHTS  (· = cannot fire)",
          rows, ["event"] + LABELS)

    # ---- 2. relative chance, peak month = 100% ---------------------------
    # Normalised within each event: how likely is this month compared to the
    # event's own busiest month? Independent of the annual rate entirely.
    rows = []
    for e in events:
        peak = max(e["weights"]) or 1
        rows.append([e["id"]] +
                    [(f"{wgt/peak*100:.0f}%" if wgt else "·")
                     for wgt in e["weights"]])
    table("2) RELATIVE CHANCE BY MONTH  (each event's peak month = 100%)",
          rows, ["event"] + LABELS,
          "   Read along a row: how likely is this month vs the event's busiest\n"
          "   month. Independent of how often the event fires per year.")

    # ---- 3. expected events per year ------------------------------------
    rows = []
    for e in events:
        rows.append([e["id"]] +
                    [(f"{v:.3f}" if v else "·") for v in e["perMonth"]] +
                    [f"{e['annual']:.2f}"])
    totals = [sum(e["perMonth"][m] for e in events) for m in range(12)]
    rows.append(["TOTAL"] + [f"{t:.3f}" for t in totals] + [f"{sum(totals):.2f}"])
    table("3) EXPECTED EVENTS PER YEAR  (per event, per month)",
          rows, ["event"] + LABELS + ["year"],
          "   Directly comparable across events and months.")

    # ---- 4. activity + balance ------------------------------------------
    print("\n4) TOTAL MARKET ACTIVITY BY MONTH")
    mx = max(totals)
    for i, m in enumerate(LABELS):
        pct = 100 * totals[i] / sum(totals)
        bar = "#" * round(totals[i] / mx * 34)
        print(f"  {m}  {totals[i]:.3f}  ({pct:4.1f}%)  {bar}")

    print("\n5) WIN / LOSE / NEUTRAL BY MONTH  (expected events per year)")
    kinds = ["win", "lose", "neutral"]
    rows = []
    for k in kinds:
        vals = [sum(e["perMonth"][m] for e in events if e["type"] == k)
                for m in range(12)]
        rows.append([k] + [f"{v:.3f}" for v in vals] + [f"{sum(vals):.2f}"])
    table("", rows, ["type"] + LABELS + ["year"])

    counts = {k: sum(1 for e in events if e["type"] == k) for k in kinds}
    print(f"\n  event counts: " +
          "  ".join(f"{k}={counts[k]}" for k in kinds))
    wins = sum(e["annual"] for e in events if e["type"] == "win")
    loses = sum(e["annual"] for e in events if e["type"] == "lose")
    print(f"  annual rate:  win={wins:.2f}/yr  lose={loses:.2f}/yr  "
          f"ratio={wins/loses:.2f}:1" if loses else "")

    # ---- quiet / busy notes ---------------------------------------------
    order = sorted(range(12), key=lambda i: totals[i])
    print(f"\n  quietest: {', '.join(LABELS[i] for i in order[:3])}")
    print(f"  busiest:  {', '.join(LABELS[i] for i in reversed(order[-3:]))}")
    dead = [LABELS[i] for i in range(12) if totals[i] == 0]
    print(f"  months with no possible event: {', '.join(dead) if dead else 'none'}")


if __name__ == "__main__":
    main()
