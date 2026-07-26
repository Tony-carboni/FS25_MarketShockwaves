import random

# Real FS25 base prices (per 1000L) from fillTypes_basegame.xml
BASE = {"WHEAT": 337, "FLOUR": 690, "BREAD": 1650}

# Supply chain: WHEAT --(lag, passthrough)--> FLOUR --> BREAD
CHAIN = [
    ("WHEAT", "FLOUR", 0.75, 0.55),   # flour echoes wheat: 0.75mo later, 55% of the swing
    ("FLOUR", "BREAD", 0.50, 0.70),   # bread echoes flour: 0.50mo later, 70% of the swing
]

def bump(u, peak_pos, rise, fall):
    if u <= 0 or u >= 1:
        return 0.0
    return (u / peak_pos) ** rise if u < peak_pos else ((1 - u) / (1 - peak_pos)) ** fall

def wheat_curve(days, D, mag, months, peak_pos, rise, fall, jit, seed):
    rng = random.Random(seed)
    f = []
    for d in range(days + 1):
        u = (d / D) / months
        base = 1 + (mag - 1) * bump(u, peak_pos, rise, fall)
        n = 1 + rng.uniform(-jit, jit) if 0 < u < 1 else 1.0
        f.append(base * n)
    return f

def propagate(upstream, D, lag_months, passthrough):
    lag = int(round(lag_months * D))
    out = []
    for d in range(len(upstream)):
        src = upstream[d - lag] if d - lag >= 0 else 1.0
        out.append(1 + (src - 1) * passthrough)
    return out

def arrow(f):
    p = (f - 1) * 100
    return f"{'^' if p>=0.05 else ('v' if p<=-0.05 else '-')}{abs(p):4.1f}%"

# One MEDIUM drought (peak +26%, 7 months), late-ish peak
D = 10
months = 7
days = months * D
wheat = wheat_curve(days, D, mag=1.26, months=months, peak_pos=0.45, rise=1.3, fall=1.2, jit=0.02, seed=22)
flour = propagate(wheat, D, *[c[2:] for c in CHAIN if c[1]=="FLOUR"][0])
bread = propagate(flour, D, *[c[2:] for c in CHAIN if c[1]=="BREAD"][0])

print("MEDIUM drought — supply-chain propagation (real base prices)")
print("WHEAT 337  ->  FLOUR 690  ->  BREAD 1650  (per 1000L)\n")
print("Month |        WHEAT        |        FLOUR        |        BREAD")
print("------+---------------------+---------------------+--------------------")
m = 0.0
while m <= months + 1e-9:
    d = min(int(round(m * D)), days)
    def cell(name, arr):
        return f"{round(BASE[name]*arr[d]):5d} {arrow(arr[d]):>7}"
    print(f"{m:4.1f}  |  {cell('WHEAT',wheat)}   |  {cell('FLOUR',flour)}   |  {cell('BREAD',bread)}")
    m += 0.5

def pk(name, arr):
    i = max(range(len(arr)), key=lambda k: arr[k])
    return f"{name}: peak {arrow(arr[i])} at month {i/D:.1f} (price {round(BASE[name]*arr[i])})"
print()
for n, a in (("WHEAT", wheat), ("FLOUR", flour), ("BREAD", bread)):
    print("  " + pk(n, a))
