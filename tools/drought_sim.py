import random

BASE_WHEAT = 1731  # illustrative in-game display price (per 1000L)
BLOCKS = "_.:-=+*#%@"

# Per-severity PARAMETER RANGES. Every event rolls its own curve within these,
# so no two droughts feel the same (replayability, no "figuring it out").
#   mag  = peak price factor        dur  = duration in months
#   peak = peak position (fraction of window)   never lets late events peak early
#   rise = onset steepness (>1 = slow/accelerating buildup, <1 = fast spike)
#   fall = decay steepness (<1 = sharp drop, >1 = gentle taper)
#   jit  = daily wiggle amplitude
SEVERITY = {
    "light":  dict(mag=(1.15, 1.20), dur=(3, 6),   peak=(0.10, 0.40), rise=(0.5, 0.9), fall=(1.3, 1.8), jit=0.015),
    "medium": dict(mag=(1.20, 1.30), dur=(6, 8),   peak=(0.35, 0.60), rise=(1.0, 1.5), fall=(1.0, 1.4), jit=0.020),
    "strong": dict(mag=(1.60, 1.70), dur=(10, 12), peak=(0.68, 0.90), rise=(1.8, 2.5), fall=(0.6, 0.9), jit=0.025),
}

def roll_event(severity, rng, intensity=1.0):
    """Roll a unique drought curve. `intensity` is the 0-2 user setting."""
    s = SEVERITY[severity]
    mag = rng.uniform(*s["mag"])
    return dict(
        mag=1 + (mag - 1) * intensity,          # user setting scales the swing
        months=rng.uniform(*s["dur"]),
        peak_pos=rng.uniform(*s["peak"]),
        rise=rng.uniform(*s["rise"]),
        fall=rng.uniform(*s["fall"]),
        jit=s["jit"] * intensity,
    )

def bump(u, peak_pos, rise, fall):
    if u <= 0 or u >= 1:
        return 0.0
    if u < peak_pos:
        return (u / peak_pos) ** rise
    return ((1 - u) / (1 - peak_pos)) ** fall

def simulate(ev, D, rng):
    days = int(round(ev["months"] * D))
    daily = []
    for d in range(days + 1):
        u = d / days
        base = 1 + (ev["mag"] - 1) * bump(u, ev["peak_pos"], ev["rise"], ev["fall"])
        n = 1 + rng.uniform(-ev["jit"], ev["jit"]) if 0 < u < 1 else 1.0
        daily.append(base * n)
    return days, daily

def spark(vals, lo, hi):
    out = []
    for v in vals:
        t = 0.0 if hi <= lo else max(0.0, min(1.0, (v - lo) / (hi - lo)))
        out.append(BLOCKS[int(round(t * (len(BLOCKS) - 1)))])
    return "".join(out)

def pk(daily, D):
    i = max(range(len(daily)), key=lambda k: daily[k])
    return i / D, (daily[i] - 1) * 100, round(BASE_WHEAT * daily[i])

print("=== Replayability: 4 STRONG droughts, same severity, all different ===")
for seed in (1, 2, 3, 4):
    rng = random.Random(seed)
    ev = roll_event("strong", rng)
    days, daily = simulate(ev, 10, rng)
    pm, pp, pv = pk(daily, 10)
    print(f"#{seed}: dur={ev['months']:4.1f}mo  peak +{(ev['mag']-1)*100:2.0f}%  "
          f"peaks month {pm:4.1f} (wheat {pv}, {pp:+.0f}%)")
    print("      " + spark(daily, 1.0, max(daily)))
print("  -> all peak late (month ~8-11), none early; every curve unique.\n")

print("=== User 'Event Intensity' setting on one MEDIUM drought ===")
for inten in (0.5, 1.0, 2.0):
    rng = random.Random(77)
    ev = roll_event("medium", rng, intensity=inten)
    days, daily = simulate(ev, 10, rng)
    pm, pp, pv = pk(daily, 10)
    print(f"intensity {inten:>3}: peak {pp:+5.1f}%  (wheat {pv})   {spark(daily,1.0,1.6)}")
print("  -> 0 = event does nothing, 2 = double the swing; slider default 1.0")
