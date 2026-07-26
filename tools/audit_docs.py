#!/usr/bin/env python3
"""
Audit the HAND-WRITTEN docs against config/events.xml.

The generated docs cannot drift - build.sh rewrites them and CI checks them. The
hand-written ones can, and have: DESIGN.md once described a chain that had been
removed, and cross-referenced an event as the home of a product that no longer
lived there. This checks the facts in those files that are also facts in the
config, so a stale claim fails instead of quietly misleading.

What it checks, per doc:
  * every event id named actually exists
  * every fill type named in a chain notation exists in the game data
  * chain notations `A ──▶ B (t1, +1.0mo, 0.60)` match the config exactly
  * 12-column month tables match the configured weights
  * quoted event counts and coverage totals match reality
  * quoted test counts match the suites

Usage:
    python3 tools/audit_docs.py         # exit 1 on any mismatch
"""
import re
import subprocess
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
EVENTS = ROOT / "FS25_MarketShockwaves/config/events.xml"
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

HAND_WRITTEN = ["DESIGN.md", "README.md", "TESTING.md", "TESTPLAN.md",
                "docs/mod-description.md", "docs/screenshots/README.md"]

problems: list[str] = []
notes: list[str] = []


def bad(where: str, msg: str) -> None:
    problems.append(f"{where}: {msg}")


def load_config():
    root = ET.parse(EVENTS).getroot()
    events = {}
    for e in root.iter("event"):
        chains = {}
        for c in (e.find("chains") or []):
            chains[(c.get("from"), c.get("to"))] = (
                c.get("tier"),
                float(c.get("lagMonths", 1.0)),
                float(c.get("passThrough", 0.60)),
            )
        mw = e.find("monthWeights")
        events[e.get("id")] = {
            "affects": set((e.findtext("affects") or "").split()),
            "chains": chains,
            "weights": [float(mw.get(m, 0)) for m in MONTHS] if mw is not None else [],
            "type": e.get("type"),
            "subtype": e.get("subtype") or e.get("id"),
        }
    return events


def fill_names() -> set[str] | None:
    """Every fill type the game defines, or None if the data is not present."""
    if not FILLTYPES.exists():
        return None
    return set(re.findall(r'<fillType name="([^"]+)"',
                          FILLTYPES.read_text(encoding="utf-8")))


def check_ids(text: str, where: str, events: dict) -> None:
    """Any CamelCase token in backticks that looks like an event id must be one."""
    for token in set(re.findall(r'`([a-z][A-Za-z]*(?:Drought|Bumper|Embargo|Boom|'
                                r'Glut|Pest|Bounty|Winter|Disaster|Shock|'
                                r'Disruption))`', text)):
        if token not in events:
            bad(where, f"names event `{token}`, which does not exist")


def check_chains(text: str, where: str, events: dict, fills: set) -> None:
    """Chain notations must match the config.

    Two layouts appear in DESIGN.md. A flat one, where the source is on the line:

        FERTILIZER ──▶ HERBICIDE (t1, +0.5mo, 0.65)

    and a tree, where the source is implied by indentation:

        RICE ──▶ RICEFLOUR ──▶ RICEROLLS
                          ──▶ NOODLESOUP  (t3, +2.0mo, 0.45)   <- off RICEFLOUR
             ──▶ RICE_BAGS (t1, +0.5mo, 0.70)                   <- off RICE

    Resolving that nesting properly means tracking column offsets, which is more
    machinery than a doc audit deserves. So: when the source is explicit on the
    line, the full triple is verified; when it is implied, only the destination
    and its numbers are. That still catches the two failures that matter - a
    chain that no longer exists, and a number that has drifted - and it does not
    invent mismatches from layout it cannot read.
    """
    arrow = re.compile(r'▶ *([A-Z][A-Z_]*) *\(t(\d), *\+([\d.]+)mo, *([\d.]+)\)')
    lead = re.compile(r'^([A-Z][A-Z_]*) *[─┬├└│]')
    full, partial = 0, 0

    for line in text.splitlines():
        stripped = line.strip()
        # Context does not survive a blank line or a fence, so a source can
        # never leak from one diagram into the next.
        if not stripped or stripped.startswith("```"):
            source = None
            continue
        m = lead.match(line)
        source = m.group(1) if m else locals().get("source")

        for dst, tier, lag, pt in arrow.findall(line):
            if fills is not None and dst not in fills:
                bad(where, f"chain names {dst}, not a game fill type")
            want = (tier, float(lag), float(pt))
            explicit = m is not None

            candidates = [(eid, a, v) for eid, ev in events.items()
                          for (a, b), v in ev["chains"].items() if b == dst]
            if not candidates:
                bad(where, f"documents a chain to {dst}, which no event has")
                continue

            if explicit:
                full += 1
                same_source = [(eid, v) for eid, a, v in candidates if a == source]
                if not same_source:
                    bad(where, f"documents chain {source} -> {dst}, but "
                               f"{dst} is driven by "
                               f"{', '.join(sorted({a for _, a, _ in candidates}))}")
                elif not any(v == want for _, v in same_source):
                    actual = "; ".join(f"{eid}: t{v[0]}, +{v[1]}mo, {v[2]}"
                                       for eid, v in same_source)
                    bad(where, f"chain {source} -> {dst} documented as "
                               f"t{tier}, +{lag}mo, {pt} but config has {actual}")
            else:
                partial += 1
                if not any(v == want for _, _, v in candidates):
                    actual = "; ".join(f"{eid} ({a}): t{v[0]}, +{v[1]}mo, {v[2]}"
                                       for eid, a, v in candidates)
                    bad(where, f"chain to {dst} documented as "
                               f"t{tier}, +{lag}mo, {pt} but config has {actual}")

    notes.append(f"{where}: checked {full + partial} chain notation(s) "
                 f"({full} with an explicit source, {partial} with an implied one)")


def check_month_tables(text: str, where: str, events: dict) -> None:
    """A 12-cell numeric table row must match some event's weights."""
    configured = {tuple(ev["weights"]) for ev in events.values()}
    rows = re.findall(r'^\|((?: *[\d.]+ *\|){12})\s*$', text, re.M)
    for row in rows:
        cells = [c.strip() for c in row.strip().strip("|").split("|")]
        try:
            values = tuple(float(c) for c in cells)
        except ValueError:
            continue
        if values not in configured:
            bad(where, f"month table {list(cells)} matches no event's weights")
    notes.append(f"{where}: checked {len(rows)} month table(s)")


def check_product_lists(text: str, where: str, events: dict, fills: set) -> None:
    """A backtick-quoted run of ALL-CAPS names should be a real product list.

    Recognised by SHAPE, not by a list of exceptions: a block only counts if
    every token is a real game fill type. That skips log section names like
    `PRICE PROBE` and menu headings like `AI WORKERS` automatically, and keeps
    doing so when new ones are written.

    Compared against each event's affects PLUS its chain destinations, since docs
    legitimately quote the full set of products an event moves - the console
    prints exactly that.
    """
    if fills is None:
        notes.append(f"{where}: product lists not checked (no game data)")
        return
    reach = []
    for ev in events.values():
        reach.append(ev["affects"] | {dst for (_, dst) in ev["chains"]})
    checked = 0
    for block in re.findall(r'`([A-Z][A-Z_]*(?: [A-Z][A-Z_]*)+)`', text):
        names = set(block.split())
        if not names <= fills:
            continue          # not a product list at all
        checked += 1
        if not any(names <= s for s in reach):
            bad(where, f"product list `{block}` is not covered by any single event")
    notes.append(f"{where}: checked {checked} product list(s)")


def check_subtype_table(text: str, where: str, events: dict) -> None:
    """The mutual-exclusion table must list exactly the configured pairs.

    Anchored to the table that follows a "Subtype | Members" header. Matching
    any two-column table instead picked up the console command table and
    reported mswClear as an unconfigured subtype.
    """
    header = re.search(r'^\| *Subtype *\| *Members *\|.*\n\|[-| :]+\|\n', text, re.M)
    if header is None:
        return

    groups: dict[str, list[str]] = {}
    for eid, ev in events.items():
        groups.setdefault(ev["subtype"], []).append(eid)
    pairs = {k: sorted(v) for k, v in groups.items() if len(v) > 1}

    documented = {}
    for line in text[header.end():].splitlines():
        row = re.match(r'^\| `(\w+)` \| ([\w ·]+) \|$', line)
        if row is None:
            break                      # table ends at the first non-row
        documented[row.group(1)] = sorted(row.group(2).replace("·", " ").split())

    for sub, members in pairs.items():
        if sub not in documented:
            bad(where, f"mutual-exclusion table omits subtype `{sub}` "
                       f"({' + '.join(members)})")
        elif documented[sub] != members:
            bad(where, f"subtype `{sub}` documented as "
                       f"{documented[sub]} but config has {members}")
    for sub in documented:
        if sub not in pairs:
            bad(where, f"mutual-exclusion table lists subtype `{sub}`, "
                       f"which is not a configured pair")
    notes.append(f"{where}: checked {len(documented)} subtype pair(s)")


def check_counts(text: str, where: str, events: dict, coverage: dict) -> None:
    n = len(events)
    words = {13: "thirteen", 14: "fourteen", 15: "fifteen", 16: "sixteen",
             17: "seventeen", 18: "eighteen"}
    for m in re.finditer(r'(?<![\d.])(\d+) events\b', text):
        if int(m.group(1)) != n:
            bad(where, f"says \"{m.group(0)}\" but there are {n}")
    for word, value in ((v, k) for k, v in words.items()):
        if re.search(rf'\b{word} events\b', text, re.I) and value != n:
            bad(where, f"says \"{word} events\" but there are {n}")

    wins = sum(1 for e in events.values() if e["type"] == "win")
    loses = sum(1 for e in events.values() if e["type"] == "lose")
    # DESIGN.md records parity as the roster grew, so earlier notes are true of
    # a smaller roster. Those are marked "(roster at this point)"; anything
    # unmarked is a claim about the shipped mod and must be current.
    for m in re.finditer(r'(\d+) win\s*[:/]\s*(\d+) lose', text):
        line_start = text.rfind("\n", 0, m.start()) + 1
        line_end = text.find("\n", m.end())
        context = text[line_start:line_end if line_end > 0 else len(text)]
        prev_start = text.rfind("\n", 0, line_start - 1) + 1
        context += text[prev_start:line_start]
        if "roster at this point" in context:
            continue
        if (int(m.group(1)), int(m.group(2))) != (wins, loses):
            bad(where, f"says \"{m.group(0)}\" but it is {wins} win / {loses} lose")

    # Coverage totals, e.g. "93 -> 96" or "96 of 110".
    for m in re.finditer(r'\b(\d+)\s*(?:of|/)\s*110\b', text):
        if int(m.group(1)) != coverage["covered"]:
            bad(where, f"says \"{m.group(0)}\" but coverage is "
                       f"{coverage['covered']} of {coverage['workable']}")


def coverage_totals() -> dict:
    out = subprocess.run([sys.executable, "tools/filltype_coverage.py"],
                         cwd=ROOT, capture_output=True, text=True).stdout
    m = re.search(r'TOTALS: (\d+) workable, (\d+) covered', out)
    return {"workable": int(m.group(1)), "covered": int(m.group(2))} if m else {}


def check_test_counts() -> None:
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    for script, label in (("tools/test_model.lua", "test_model"),
                          ("tools/test_settings_menu.lua", "test_settings_menu")):
        out = subprocess.run(["lua", script], cwd=ROOT,
                             capture_output=True, text=True).stdout
        m = re.search(r'(\d+) passed', out)
        if not m:
            bad("tests", f"{label} produced no summary line")
            continue
        actual = int(m.group(1))
        claimed = re.search(rf'\| `lua {re.escape(script)}` \| (\d+) offline tests',
                            readme)
        if claimed and int(claimed.group(1)) != actual:
            bad("README.md", f"claims {claimed.group(1)} tests for {label}, "
                             f"actual {actual}")


def main() -> int:
    events = load_config()
    fills = fill_names()
    if fills is None:
        print(f"NOTE  {ABSENT_NOTE}")
    coverage = coverage_totals()

    for rel in HAND_WRITTEN:
        path = ROOT / rel
        if not path.exists():
            bad(rel, "listed as hand-written but missing")
            continue
        text = path.read_text(encoding="utf-8")
        check_ids(text, rel, events)
        check_chains(text, rel, events, fills)
        check_month_tables(text, rel, events)
        check_product_lists(text, rel, events, fills)
        check_subtype_table(text, rel, events)
        check_counts(text, rel, events, coverage)

    check_test_counts()

    for n in notes:
        print(f"  {n}")
    print()
    for p in problems:
        print(f"MISMATCH {p}")
    print(f"\n{len(events)} events, {len(problems)} mismatch(es) across "
          f"{len(HAND_WRITTEN)} hand-written doc(s)")
    return 1 if problems else 0


if __name__ == "__main__":
    raise SystemExit(main())
