import random

BASE = {"WHEAT": 337, "FLOUR": 690, "BREAD": 1650, "CAKE": 3300}
CHAIN = ["WHEAT", "FLOUR", "BREAD", "CAKE"]
HOPS = [("FLOUR", 1.0, 0.60), ("BREAD", 1.0, 0.60), ("CAKE", 1.0, 0.55)]  # lag_mo, passthrough

SEV = {
    "LOW": dict(mag=1.18, months=4,  peak=0.18, rise=0.7, hold=0.55, jit=0.015, depth=1, pscale=0.55, corr=0.8),
    "MED": dict(mag=1.26, months=7,  peak=0.32, rise=1.2, hold=0.62, jit=0.020, depth=2, pscale=1.00, corr=1.1),
    "HI":  dict(mag=1.67, months=12, peak=0.30, rise=1.6, hold=0.72, jit=0.025, depth=3, pscale=1.30, corr=1.2),
}

def smoothstep(x):
    x = max(0.0, min(1.0, x)); return x * x * (3 - 2 * x)

def core(u, peak, rise, hold):
    """Rise to early peak, then slow plateau decay toward `hold`. No end snap."""
    if u <= 0: return 0.0
    if u < peak: return (u / peak) ** rise
    return 1.0 - (1.0 - hold) * ((u - peak) / (1 - peak)) ** 1.3

def harvest_envelope(month, months, corr):
    """Market-wide stabilization: 1.0 during event, smooth fast ease to 0 over
    the last `corr` months (new-harvest estimates), synchronized across products."""
    sStart = months - corr
    return 1.0 - smoothstep((month - sStart) / corr)

def build(sev):
    c = SEV[sev]; D = 10; days = int(round(c["months"] * D))
    rng = random.Random(hash(sev) % 100)
    # base (wheat) factor with jitter, no end correction yet
    wheat = []
    for d in range(days + 1):
        u = (d / D) / c["months"]
        f = 1 + (c["mag"] - 1) * core(u, c["peak"], c["rise"], c["hold"])
        if 0 < u < 1: f *= 1 + rng.uniform(-c["jit"], c["jit"])
        wheat.append(f)
    series = {"WHEAT": wheat}
    up = "WHEAT"
    for i in range(c["depth"]):
        name, lag_mo, pt = HOPS[i]; lag = int(round(lag_mo * D)); pt = min(pt * c["pscale"], 0.95)
        series[name] = [1 + ((series[up][d - lag] if d - lag >= 0 else 1.0) - 1) * pt for d in range(days + 1)]
        up = name
    # apply synchronized harvest stabilization to every product
    for name in series:
        for d in range(days + 1):
            month = d / D
            s = harvest_envelope(month, c["months"], c["corr"])
            series[name][d] = 1 + (series[name][d] - 1) * s
    return series, c, D

def mod(f):
    p = (f - 1) * 100
    return f"{'+' if p>=0.05 else ('-' if p<=-0.05 else ' ')}{abs(p):4.1f}%"

for sev in ("LOW", "MED", "HI"):
    series, c, D = build(sev)
    prods = [p for p in CHAIN if p in series]
    step = 0.5
    print(f"\n===== {sev} DROUGHT =====  (peak +{(c['mag']-1)*100:.0f}%, {c['months']} months, "
          f"chain: {' -> '.join(prods)})")
    header = "Month | " + " | ".join(f"{p:^15}" for p in prods)
    print(header); print("-" * len(header))
    m = -1.0
    while m <= c["months"] + 1e-9:
        if m < 0:
            cells = " | ".join(f"{BASE[p]:5d} {'  0.0%':>7}" for p in prods)
            tag = "  (pre-event)"
        else:
            d = min(int(round(m * D)), c["months"] * D)
            cells = " | ".join(f"{round(BASE[p]*series[p][d]):5d} {mod(series[p][d]):>7}" for p in prods)
            tag = ""
        print(f"{m:4.1f}  | {cells}{tag}")
        m += step
