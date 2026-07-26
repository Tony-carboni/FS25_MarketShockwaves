"""Cooldown effect on the annual event rate.

The scheduler divides each event's daily probability by daysPerMonth, so the
per-day odds shrink as months get longer. The probabilities below were logged at
dpm=1, so they must be divided by dpm to model any other setting.
"""
import random

P1 = [0.00810,0.02833,0.01133,0.02728,0.0,0.00768,0.0,
      0.00944,0.00944,0.00944,0.00944,0.00944,0.00944,0.01085,0.01085]

def sim(dpm, cooldown_months, years=30000, seed=1):
    rng = random.Random(seed)
    P = [p / dpm for p in P1]            # <- the correction
    cd_days = cooldown_months * dpm
    days_per_year = 12 * dpm
    fired, last, day = 0, None, 0
    gaps = []
    for _ in range(years):
        for _ in range(days_per_year):
            day += 1
            if last is not None and (day - last) < cd_days:
                continue
            if any(rng.random() < p for p in P):   # one event per day, max
                if last is not None:
                    gaps.append((day - last) / dpm)   # gap in MONTHS
                fired += 1
                last = day
    import statistics
    return fired / years, (statistics.mean(gaps) if gaps else 0), \
           (sum(1 for g in gaps if g < 1.0) / len(gaps) if gaps else 0)

print("effective events/year   (target 1.70)")
print(f"{'dpm':>4} {'no cooldown':>12} {'1 month':>9} {'2 months':>10} {'3 months':>10}")
for dpm in (1, 3, 10):
    print(f"{dpm:>4} " + " ".join(f"{sim(dpm,c)[0]:>11.2f}" for c in (0,1,2,3)))

print("\ngap between consecutive events, in game MONTHS")
print(f"{'dpm':>4} {'cooldown':>9} {'mean gap':>9} {'% under 1 month':>16}")
for dpm in (1, 3, 10):
    for c in (0, 1, 2):
        rate, mean_gap, frac = sim(dpm, c)
        print(f"{dpm:>4} {c:>9} {mean_gap:>9.1f} {frac*100:>15.1f}%")
