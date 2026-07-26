import random

BASE = {"WHEAT": 337, "FLOUR": 690, "BREAD": 1650, "CAKE": 3300}
# chain hops: (downstream, lag_months, base_passthrough) -- ~1mo lag per layer
HOPS = [("FLOUR", 1.0, 0.60), ("BREAD", 1.0, 0.60), ("CAKE", 1.0, 0.55)]

# Curve: rise to an early peak, HOLD high on a slowly-decaying plateau, then a
# SHARP correction at the end of the period.
#   peak         = peak position (fraction of window)
#   rise         = onset steepness
#   hold         = plateau level as fraction of peak swing (0.7 = stays at 70%)
#   corr         = where the sharp end-correction begins (fraction of post-peak)
SEV = {
    "LOW": dict(mag=1.18, months=4,  peak=0.15, rise=0.6, hold=0.45, corr=0.70, jit=0.015, depth=1, pscale=0.55),
    "MED": dict(mag=1.26, months=7,  peak=0.35, rise=1.2, hold=0.60, corr=0.78, jit=0.020, depth=2, pscale=1.00),
    "HI":  dict(mag=1.67, months=12, peak=0.30, rise=1.6, hold=0.72, corr=0.82, jit=0.025, depth=3, pscale=1.30),
}

def intensity(u, peak, rise, hold, corr):
    if u <= 0 or u >= 1:
        return 0.0
    if u < peak:                                   # rise to 1.0 at the peak
        return (u / peak) ** rise
    v = (u - peak) / (1 - peak)                     # 0 at peak -> 1 at end
    if v < corr:                                    # slow decay across plateau
        return 1.0 - (1.0 - hold) * (v / corr) ** 1.3
    t = (v - corr) / (1 - corr)                     # sharp end correction
    return hold * (1 - t)

def wheat_curve(c, D, seed):
    rng = random.Random(seed); days = int(round(c["months"] * D)); out = []
    for d in range(days + 1):
        u = (d / D) / c["months"]
        base = 1 + (c["mag"] - 1) * intensity(u, c["peak"], c["rise"], c["hold"], c["corr"])
        n = 1 + rng.uniform(-c["jit"], c["jit"]) if 0 < u < 1 else 1.0
        out.append(base * n)
    return out

def propagate(up, D, lag_m, pt):
    lag = int(round(lag_m * D)); pt = min(pt, 0.95)
    return [1 + ((up[d - lag] if d - lag >= 0 else 1.0) - 1) * pt for d in range(len(up))]

def arrow(f):
    p = (f - 1) * 100
    return f"{'^' if p>=0.05 else ('v' if p<=-0.05 else '-')}{abs(p):4.1f}%"

def build(sev):
    c = SEV[sev]; D = 10
    chain = {"WHEAT": wheat_curve(c, D, seed=hash(sev) % 100)}
    up = "WHEAT"
    for i in range(c["depth"]):
        name, lag, pt = HOPS[i]
        chain[name] = propagate(chain[up], D, lag, pt * c["pscale"])
        up = name
    return chain, c, D

for sev in ("LOW", "MED"):
    chain, c, D = build(sev)
    print(f"=== {sev} drought (depth {c['depth']}: {' -> '.join(chain)}) ===")
    for name, arr in chain.items():
        i = max(range(len(arr)), key=lambda k: arr[k])
        print(f"  {name:5} peak {arrow(arr[i]):>7} @ month {i/D:4.1f}")
    print()

# Full monthly table for HI to show base stays high while chain peaks
chain, c, D = build("HI")
days = c["months"] * D
print("=== HI drought — monthly modifiers (base stays high until sharp end) ===")
print("Month | WHEAT  | FLOUR  | BREAD  |  CAKE")
print("------+--------+--------+--------+--------")
m = 0.0
while m <= c["months"] + 1e-9:
    d = min(int(round(m * D)), days)
    cells = " | ".join(arrow(chain[n][d]) for n in ("WHEAT","FLOUR","BREAD","CAKE"))
    print(f"{m:4.1f}  | {cells}")
    m += 1.0
