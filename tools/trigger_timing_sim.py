import random

E = 1.7  # target events per year, TOTAL across all events

# Each event: base weight (sets its share of the total budget) + a month SHAPE.
# The shape is normalized internally, so how many active months an event has does
# NOT change how often it fires -- only baseWeight does. Profiles set WHEN, weight
# sets HOW OFTEN.  -> equal baseWeight = equal frequency (win vs lose parity).
EVENTS = {
    "Drought (win) ": dict(w=1.0, months={"Feb":0.4,"Mar":0.8,"Apr":1.3,"May":1.5,
                                          "Jun":1.5,"Jul":1.3,"Aug":1.0,"Sep":0.6}),
    "Bumper  (lose)": dict(w=1.0, months={"Jun":0.6,"Jul":0.9,"Aug":1.3,"Sep":1.5,
                                          "Oct":1.5,"Nov":0.8}),
}
MONTHS = ["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]

sumW = sum(e["w"] for e in EVENTS.values())
K = E / sumW
for e in EVENTS.values():
    s = sum(e["months"].values())
    e["share"] = {m: e["months"].get(m, 0) / s for m in MONTHS}

def sim(D, years, seed=0):
    rng = random.Random(seed)
    per_event = {name: 0 for name in EVENTS}
    per_month = {m: 0 for m in MONTHS}
    for _ in range(years):
        for m in MONTHS:
            for name, e in EVENTS.items():
                p = K * e["w"] * e["share"][m] / D
                for _day in range(D):
                    if rng.random() < p:
                        per_event[name] += 1; per_month[m] += 1
    return {n: per_event[n]/years for n in EVENTS}, {m: per_month[m]/years for m in MONTHS}

ev, _ = sim(3, 40000)
print("Per-event annual rate (equal base weight -> equal win/lose frequency):")
for n, r in ev.items():
    print(f"  {n}: {r:.3f} /year")
print(f"  TOTAL: {sum(ev.values()):.3f} /year  (target {E})\n")

print("Days/month independence (total events/year):")
for D in (1, 3, 10):
    e2, _ = sim(D, 30000)
    print(f"  D={D:2d} -> {sum(e2.values()):.3f}")

print("\nCombined monthly distribution (D=3, avg triggers/month/year):")
_, dist = sim(3, 40000)
mx = max(dist.values())
for m in MONTHS:
    bar = "#" * round(dist[m]/mx*28) if dist[m] > 0 else ""
    print(f"  {m}: {dist[m]:.3f}  {bar}")
