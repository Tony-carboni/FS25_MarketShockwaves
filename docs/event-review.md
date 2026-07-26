# Event review sheet

Every event's player-facing messages next to the products it actually
moves, so the writing and the coverage can be checked against each other.

**Generated — do not edit.** `python3 tools/event_review.py -o docs/event-review.md`
Source: `config/events.xml` and `l10n/l10n_en.xml`.

17 events — 8 win / 8 lose / 1 neutral.

Roster defaults: **1.7 events per year** on average across the whole roster, severity rolled low 60% / medium 30% / high 10%.

Every event carries equal `baseWeight`, so they fire equally often; the
events-per-year figure is a **budget split across the roster**, which means
adding an event makes each individual one rarer rather than making the
market busier. Players can raise it in the settings menu.

| # | Event | Category | Direction | Season | Excludes |
|---|---|---|---|---|---|
| 1 | `grainDrought` | crops | player win, prices up | Feb–Sep (8 months), peaking May/Jun | `grainBumper` |
| 2 | `grainBumper` | crops | player lose, prices down | Jun–Nov (6 months), peaking Sep | `grainDrought` |
| 3 | `rootDrought` | crops | player win, prices up | Mar–Oct (8 months), peaking Jun/Jul | `rootBumper` |
| 4 | `rootBumper` | crops | player lose, prices down | Jul–Nov (5 months), peaking Oct | `rootDrought` |
| 5 | `harshWinter` | winter | neutral, prices up | Nov–Mar (5 months), peaking Jan | — |
| 6 | `naturalDisaster` | supplies | player win, prices up | all year, peaking Jan/Dec | — |
| 7 | `inputShock` | supplies | player lose, prices up | Dec–May (6 months), peaking Mar | — |
| 8 | `dairyEmbargo` | trade | player lose, prices down | all year, flat | `dairyExportBoom` |
| 9 | `mediterraneanEmbargo` | trade | player lose, prices down | all year, flat | `mediterraneanExportBoom` |
| 10 | `dairyExportBoom` | trade | player win, prices up | all year, flat | `dairyEmbargo` |
| 11 | `mediterraneanExportBoom` | trade | player win, prices up | all year, flat | `mediterraneanEmbargo` |
| 12 | `asianTradeDisruption` | trade | player win, prices up | all year, flat | `monsoonBounty` |
| 13 | `monsoonBounty` | trade | player lose, prices down | Aug–Feb (7 months), peaking Oct/Nov | `asianTradeDisruption` |
| 14 | `ethanolGlut` | biofuel | player lose, prices down | all year, flat | `ethanolBoom` |
| 15 | `ethanolBoom` | biofuel | player win, prices up | all year, flat | `ethanolGlut` |
| 16 | `greenhousePest` | greenhouse | player win, prices up | all year, peaking Jun/Jul | `greenhouseBounty` |
| 17 | `greenhouseBounty` | greenhouse | player lose, prices down | all year, peaking Jun/Jul | `greenhousePest` |

**Excludes** is the mutual-exclusion rule: events sharing a `subtype` can
never run at the same time, because a boom on top of its own glut is a
contradiction rather than a compounding shock. They may alternate freely —
the moment one expires the other becomes eligible. Everything else stacks,
even where two events share products.

---

## 1. `grainDrought`

**crops** · player win · prices up · Feb–Sep (8 months), peaking May/Jun

Never runs alongside `grainBumper` (shared subtype `grain`).

### Products moved (17)

**Direct — full magnitude (8)**

`WHEAT` · `BARLEY` · `OAT` · `CANOLA` · `MAIZE` · `SORGHUM` · `SUNFLOWER` · `SOYBEAN`

**Ripple — damped and delayed (9)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `CANOLA_OIL` | `CANOLA` | 1 | +1.0 mo | 0.60 |
| `CEREAL` | `OAT` | 1 | +1.0 mo | 0.60 |
| `DRYGRASS_WINDROW` | `WHEAT` | 1 | +0.5 mo | 0.45 |
| `FLOUR` | `WHEAT` | 1 | +1.0 mo | 0.60 |
| `GRASS_WINDROW` | `WHEAT` | 1 | +0.25 mo | 0.45 |
| `STRAW` | `WHEAT` | 1 | +0.25 mo | 0.80 |
| `SUNFLOWER_OIL` | `SUNFLOWER` | 1 | +1.0 mo | 0.60 |
| `BREAD` | `FLOUR` | 2 | +1.0 mo | 0.60 |
| `CAKE` | `FLOUR` | 3 | +2.0 mo | 0.45 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | +15% to +20% | 3–6 months | tier 1 |
| MEDIUM | 30% | +20% to +30% | 6–8 months | tier 2 |
| HIGH | 10% | +60% to +70% | 10–12 months | tier 3 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 10–40% in | 0.5–0.9 | 55% of peak | 0.8 mo | ±1.5% | 0.55 |
| MEDIUM | 35–60% in | 1–1.5 | 62% of peak | 1.1 mo | ±2% | 1.00 |
| HIGH | 30–45% in | 1.5–2 | 72% of peak | 1.2 mo | ±2.5% | 1.30 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | – | 0.4 | 0.8 | 1.3 | 1.5 | 1.5 | 1.3 | 1 | 0.6 | – | – | – |
| **Share** | – | 5% | 10% | 15% | 18% | 18% | 15% | 12% | 7% | – | – | – |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Dry Spell**

> A brief dry spell has lightly stressed the region's field crops - wheat,
> barley, oats, maize, sorghum, canola, sunflower and soybean. Prices should
> tick up modestly before easing back, and with a little less coming off the
> field, straw firms up alongside. Grass crops are feeling the dry too, so
> grass and hay are fetching a little more, and millers may feel a faint
> knock-on.

**MEDIUM — Market Report: Drought**

> A moderate drought is tightening supplies of the region's field crops -
> wheat, barley, oats, maize, sorghum, canola, sunflower and soybean. Prices
> will climb over the coming months before gradually easing. Straw is scarcer
> too, with less coming off the field, and as stocks draw down the squeeze is
> likely to work its way into processed goods further down the chain. Grass
> crops are struggling in the dry as well, pushing grass and hay prices up
> with everything else.

**HIGH — Market Alert: Severe Drought**

> A severe, prolonged drought has struck the region's field crops - wheat,
> barley, oats, maize, sorghum, canola, sunflower and soybean - and prices are
> spiking fast. Straw is scarce as well, with thin harvests leaving little
> behind. The shortage will hold high for an extended spell, likely up to the
> next harvest, and ripple deep through the production chain as processed
> goods grow scarce in turn. Grass crops are struggling badly in the dry, and
> grass and hay will command a premium for a long while yet.

---

## 2. `grainBumper`

**crops** · player lose · prices down · Jun–Nov (6 months), peaking Sep

Never runs alongside `grainDrought` (shared subtype `grain`).

### Products moved (15)

**Direct — full magnitude (8)**

`WHEAT` · `BARLEY` · `OAT` · `CANOLA` · `MAIZE` · `SORGHUM` · `SUNFLOWER` · `SOYBEAN`

**Ripple — damped and delayed (7)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `CANOLA_OIL` | `CANOLA` | 1 | +1.0 mo | 0.60 |
| `CEREAL` | `OAT` | 1 | +1.0 mo | 0.60 |
| `FLOUR` | `WHEAT` | 1 | +1.0 mo | 0.60 |
| `STRAW` | `WHEAT` | 1 | +0.25 mo | 0.80 |
| `SUNFLOWER_OIL` | `SUNFLOWER` | 1 | +1.0 mo | 0.60 |
| `BREAD` | `FLOUR` | 2 | +1.0 mo | 0.60 |
| `CAKE` | `FLOUR` | 3 | +2.0 mo | 0.45 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | −7.5% to −10% | 3–6 months | tier 1 |
| MEDIUM | 30% | −10% to −15% | 6–8 months | tier 2 |
| HIGH | 10% | −30% to −35% | 10–12 months | tier 3 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 10–40% in | 0.5–0.9 | 55% of peak | 0.8 mo | ±1.5% | 0.55 |
| MEDIUM | 35–60% in | 1–1.5 | 62% of peak | 1.1 mo | ±2% | 1.00 |
| HIGH | 30–45% in | 1.5–2 | 72% of peak | 1.2 mo | ±2.5% | 1.30 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | – | – | – | – | – | 0.5 | 1 | 1.4 | 1.5 | 1.1 | 0.5 | – |
| **Share** | – | – | – | – | – | 8% | 17% | 23% | 25% | 18% | 8% | – |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Strong Harvest**

> Favourable weather has delivered a better-than-expected harvest across the
> region's field crops - wheat, barley, oats, maize, sorghum, canola,
> sunflower and soybean. With a little extra grain on the market, prices
> should dip modestly before recovering, and the extra straw coming off the
> field softens that market too. Processors may see a slight easing.

**MEDIUM — Market Report: Bumper Harvest**

> An unexpectedly strong harvest has flooded the region's silos - wheat,
> barley, oats, maize, sorghum, canola, sunflower and soybean. Prices will
> slide over the coming months as the surplus works through the market. Straw
> is piling up alongside it and selling cheap, and the drop will filter into
> processed goods as cheap raw stock spreads down the chain.

**HIGH — Market Alert: Record Glut**

> A record-breaking harvest has overwhelmed the region's field crops - wheat,
> barley, oats, maize, sorghum, canola, sunflower and soybean - and prices are
> tumbling fast. Straw is heaped up everywhere and barely worth hauling.
> Expect a prolonged slump as the oversupply lingers, likely until the next
> planting season, with the glut rippling deep through the production chain as
> cheap goods pile up.

---

## 3. `rootDrought`

**crops** · player win · prices up · Mar–Oct (8 months), peaking Jun/Jul

Never runs alongside `rootBumper` (shared subtype `root`).

### Products moved (23)

**Direct — full magnitude (8)**

`POTATO` · `SUGARBEET` · `BEETROOT` · `CARROT` · `PARSNIP` · `GREENBEAN` · `PEA` · `SPINACH`

**Ripple — damped and delayed (15)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `CANNED_PEAS` | `PEA` | 1 | +1.0 mo | 0.60 |
| `DRYGRASS_WINDROW` | `POTATO` | 1 | +0.5 mo | 0.45 |
| `GRASS_WINDROW` | `POTATO` | 1 | +0.25 mo | 0.45 |
| `JARRED_GREENBEAN` | `GREENBEAN` | 1 | +1.0 mo | 0.60 |
| `POTATOCHIPS` | `POTATO` | 1 | +1.0 mo | 0.60 |
| `PRESERVEDBEETROOT` | `BEETROOT` | 1 | +1.0 mo | 0.60 |
| `PRESERVEDCARROTS` | `CARROT` | 1 | +1.0 mo | 0.60 |
| `PRESERVEDPARSNIP` | `PARSNIP` | 1 | +1.0 mo | 0.60 |
| `SPINACH_BAGS` | `SPINACH` | 1 | +1.0 mo | 0.60 |
| `SUGAR` | `SUGARBEET` | 1 | +1.0 mo | 0.60 |
| `SOUPCANSBEETROOT` | `BEETROOT` | 2 | +1.0 mo | 0.60 |
| `SOUPCANSCARROTS` | `CARROT` | 2 | +1.0 mo | 0.60 |
| `SOUPCANSPARSNIP` | `PARSNIP` | 2 | +1.0 mo | 0.60 |
| `SOUPCANSPOTATO` | `POTATO` | 2 | +1.0 mo | 0.60 |
| `CHOCOLATE` | `SUGAR` | 3 | +1.5 mo | 0.45 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | +15% to +20% | 3–6 months | tier 1 |
| MEDIUM | 30% | +20% to +30% | 6–8 months | tier 2 |
| HIGH | 10% | +60% to +70% | 10–12 months | tier 3 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 10–40% in | 0.5–0.9 | 55% of peak | 0.8 mo | ±1.5% | 0.55 |
| MEDIUM | 35–60% in | 1–1.5 | 62% of peak | 1.1 mo | ±2% | 1.00 |
| HIGH | 30–45% in | 1.5–2 | 72% of peak | 1.2 mo | ±2.5% | 1.30 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | – | – | 0.5 | 0.9 | 1.2 | 1.5 | 1.5 | 1.3 | 0.8 | 0.3 | – | – |
| **Share** | – | – | 6% | 11% | 15% | 19% | 19% | 16% | 10% | 4% | – | – |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Dry Spell**

> A brief dry spell has lightly stressed the region's root and vegetable crops
> - potatoes, sugar beet, beetroot, carrots, parsnips, green beans, peas and
> spinach. Prices should tick up modestly before easing back. Grass crops are
> feeling the dry too, so grass and hay are fetching a little more, and
> canneries may feel a faint knock-on.

**MEDIUM — Market Report: Drought**

> A moderate drought is tightening supplies of the region's root and vegetable
> crops - potatoes, sugar beet, beetroot, carrots, parsnips, green beans, peas
> and spinach. Prices will climb over the coming months before gradually
> easing, and the squeeze will work its way into canned and preserved goods as
> stocks draw down. Grass crops are struggling in the dry as well, pushing
> grass and hay prices up with everything else.

**HIGH — Market Alert: Severe Drought**

> A severe, prolonged drought has struck the region's root and vegetable crops
> - potatoes, sugar beet, beetroot, carrots, parsnips, green beans, peas and
> spinach - and prices are spiking fast. The shortage will hold high for an
> extended spell, likely up to the next harvest, and ripple deep through the
> chain as canned, preserved and processed goods grow scarce in turn. Grass
> crops are struggling badly in the dry, and grass and hay will command a
> premium for a long while yet.

---

## 4. `rootBumper`

**crops** · player lose · prices down · Jul–Nov (5 months), peaking Oct

Never runs alongside `rootDrought` (shared subtype `root`).

### Products moved (21)

**Direct — full magnitude (8)**

`POTATO` · `SUGARBEET` · `BEETROOT` · `CARROT` · `PARSNIP` · `GREENBEAN` · `PEA` · `SPINACH`

**Ripple — damped and delayed (13)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `CANNED_PEAS` | `PEA` | 1 | +1.0 mo | 0.60 |
| `JARRED_GREENBEAN` | `GREENBEAN` | 1 | +1.0 mo | 0.60 |
| `POTATOCHIPS` | `POTATO` | 1 | +1.0 mo | 0.60 |
| `PRESERVEDBEETROOT` | `BEETROOT` | 1 | +1.0 mo | 0.60 |
| `PRESERVEDCARROTS` | `CARROT` | 1 | +1.0 mo | 0.60 |
| `PRESERVEDPARSNIP` | `PARSNIP` | 1 | +1.0 mo | 0.60 |
| `SPINACH_BAGS` | `SPINACH` | 1 | +1.0 mo | 0.60 |
| `SUGAR` | `SUGARBEET` | 1 | +1.0 mo | 0.60 |
| `SOUPCANSBEETROOT` | `BEETROOT` | 2 | +1.0 mo | 0.60 |
| `SOUPCANSCARROTS` | `CARROT` | 2 | +1.0 mo | 0.60 |
| `SOUPCANSPARSNIP` | `PARSNIP` | 2 | +1.0 mo | 0.60 |
| `SOUPCANSPOTATO` | `POTATO` | 2 | +1.0 mo | 0.60 |
| `CHOCOLATE` | `SUGAR` | 3 | +1.5 mo | 0.45 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | −7.5% to −10% | 3–6 months | tier 1 |
| MEDIUM | 30% | −10% to −15% | 6–8 months | tier 2 |
| HIGH | 10% | −30% to −35% | 10–12 months | tier 3 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 10–40% in | 0.5–0.9 | 55% of peak | 0.8 mo | ±1.5% | 0.55 |
| MEDIUM | 35–60% in | 1–1.5 | 62% of peak | 1.1 mo | ±2% | 1.00 |
| HIGH | 30–45% in | 1.5–2 | 72% of peak | 1.2 mo | ±2.5% | 1.30 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | – | – | – | – | – | – | 0.5 | 0.9 | 1.3 | 1.5 | 1.2 | – |
| **Share** | – | – | – | – | – | – | 9% | 17% | 24% | 28% | 22% | – |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Strong Harvest**

> Favourable conditions have delivered a bumper root and vegetable harvest -
> potatoes, sugar beet, beetroot, carrots, parsnips, green beans, peas and
> spinach. With extra produce reaching market, prices should dip modestly
> before recovering. Canneries may see a slight easing too.

**MEDIUM — Market Report: Bumper Harvest**

> An unexpectedly strong root and vegetable harvest is flooding the region's
> stores - potatoes, sugar beet, beetroot, carrots, parsnips, green beans,
> peas and spinach. Prices will slide over the coming months as the surplus
> works through the market, and the drop will filter into canned and preserved
> goods as cheap stock spreads down the chain.

**HIGH — Market Alert: Record Glut**

> A record-breaking root and vegetable harvest has overwhelmed the market -
> potatoes, sugar beet, beetroot, carrots, parsnips, green beans, peas and
> spinach - and prices are tumbling fast. Expect a prolonged slump as the
> oversupply lingers, likely until the next planting season, with the glut
> rippling deep through the chain as cheap canned and preserved goods pile up.

---

## 5. `harshWinter`

**winter** · neutral · prices up · Nov–Mar (5 months), peaking Jan

### Products moved (6)

**Direct — full magnitude (3)**

`DIESEL` · `ELECTRICCHARGE` · `METHANE`

**Ripple — damped and delayed (3)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `LIQUIDMANURE` | `METHANE` | 1 | +1.0 mo | 0.60 |
| `MANURE` | `METHANE` | 1 | +1.0 mo | 0.60 |
| `SILAGE` | `METHANE` | 1 | +1.0 mo | 0.60 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | +15% to +20% | 1–2 months | tier 1 |
| MEDIUM | 30% | +20% to +30% | 2–3 months | tier 1 |
| HIGH | 10% | +60% to +70% | 3–4 months | tier 1 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 20–45% in | 0.6–1 | 55% of peak | 0.4 mo | ±1.5% | 0.55 |
| MEDIUM | 25–50% in | 0.8–1.3 | 62% of peak | 0.5 mo | ±2% | 1.00 |
| HIGH | 30–50% in | 1–1.5 | 72% of peak | 0.6 mo | ±2.5% | 1.30 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | 1.5 | 1.2 | 0.5 | – | – | – | – | – | – | – | 0.6 | 1.4 |
| **Share** | 29% | 23% | 10% | – | – | – | – | – | – | – | 12% | 27% |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Cold Snap**

> A brief cold snap has nudged energy demand higher across the region. Diesel,
> electricity and gas prices should tick up before easing as the weather turns
> - a minor pinch at the pump, but a small boon for anyone selling power.
> Biogas feedstock like silage and manure may firm up slightly too.

**MEDIUM — Market Report: Harsh Winter**

> A harsh winter has settled over the region, lifting demand for fuel and
> power. Diesel, electricity and gas prices will climb through the cold months
> before easing with the thaw. Costly at the pump - but a good stretch for
> biogas and energy producers, and feedstock like silage and manure will firm
> up as energy grows dear.

**HIGH — Market Alert: Deep Freeze**

> A brutal, prolonged freeze grips the region, sending energy prices soaring.
> Diesel, electricity and gas will stay high well into the season. A heavy hit
> for fuel buyers - but a windfall for anyone selling power, and with energy
> at a premium, biogas feedstock like silage and manure is dragged up sharply
> in turn.

---

## 6. `naturalDisaster`

**supplies** · player win · prices up · all year, peaking Jan/Dec

### Products moved (14)

**Direct — full magnitude (5)**

`PREFABWALL` · `ROOFPLATES` · `CEMENT` · `CEMENTBRICKS` · `CLOTHES`

**Ripple — damped and delayed (9)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `BOARDS` | `PREFABWALL` | 1 | +0.5 mo | 0.75 |
| `FABRIC` | `CLOTHES` | 1 | +0.5 mo | 0.75 |
| `PLANKS` | `PREFABWALL` | 1 | +0.5 mo | 0.75 |
| `WOODBEAM` | `PREFABWALL` | 1 | +0.5 mo | 0.75 |
| `COTTON` | `FABRIC` | 2 | +0.5 mo | 0.70 |
| `WOOD` | `BOARDS` | 2 | +0.5 mo | 0.70 |
| `WOODCHIPS` | `BOARDS` | 2 | +0.5 mo | 0.70 |
| `BATHTUB` | `PREFABWALL` | 3 | +2.0 mo | 0.50 |
| `FURNITURE` | `PLANKS` | 3 | +1.5 mo | 0.50 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | +15% to +20% | 2–4 months | tier 3 |
| MEDIUM | 30% | +20% to +30% | 4–7 months | tier 3 |
| HIGH | 10% | +60% to +70% | 8–12 months | tier 3 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 10–20% in | 0.5–0.8 | 75% of peak | 0.6 mo | ±1.5% | 1.00 |
| MEDIUM | 10–20% in | 0.5–0.8 | 80% of peak | 0.8 mo | ±2% | 1.00 |
| HIGH | 10–20% in | 0.5–0.8 | 85% of peak | 1 mo | ±2.5% | 1.00 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | 1.5 | 1.4 | 1.2 | 1 | 0.5 | 0.4 | 0.4 | 0.5 | 0.8 | 1.2 | 1.4 | 1.5 |
| **Share** | 13% | 12% | 10% | 8% | 4% | 3% | 3% | 4% | 7% | 10% | 12% | 13% |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Severe Storm**

> A severe storm has damaged homes and outbuildings across the region. Local
> government is funding repairs, and demand for prefab walls, roofing, cement
> and brick has firmed up. Relief centres are handing out blankets and warm
> clothing too, so clothing is moving briskly and the weavers are buying
> fabric to keep up. Sawmills are running longer shifts as well, pulling
> timber, boards and woodchips along with them. Cotton growers should see the
> benefit before long.

**MEDIUM — Market Alert: Natural Disaster**

> A natural disaster has struck the region, and government relief is shipping
> building materials in by the truckload. Prefab walls, roofing, cement and
> brick are climbing hard, and the surge is pulling timber, beams, planks and
> woodchips up with it as mills scramble for logs. Thousands have been put out
> of their homes, so blankets and clothing are being bought in bulk - the
> mills are chasing fabric, and cotton with it. Furniture will follow as homes
> are made liveable again. Good months ahead for anyone with wood or fibre to
> sell.

**HIGH — Market Alert: Regional Catastrophe**

> A catastrophe has devastated the region and a major reconstruction effort is
> under way. Every building material is in desperate short supply - prefab
> walls, roofing, cement and brick command a premium, while timber, beams,
> planks and woodchips are bought at almost any price. With whole communities
> displaced, relief agencies are buying clothing and blankets by the
> container, and the demand is running straight back through the weavers to
> raw cotton. As homes go back up, furniture and fittings will follow. This
> will run for the best part of a year.

---

## 7. `inputShock`

**supplies** · player lose · prices up · Dec–May (6 months), peaking Mar

### Products moved (8)

**Direct — full magnitude (4)**

`FERTILIZER` · `LIQUIDFERTILIZER` · `LIME` · `SEEDS`

**Ripple — damped and delayed (4)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `DIGESTATE` | `FERTILIZER` | 1 | +0.75 mo | 0.35 |
| `HERBICIDE` | `FERTILIZER` | 1 | +0.5 mo | 0.65 |
| `LIQUIDMANURE` | `FERTILIZER` | 1 | +0.75 mo | 0.35 |
| `MANURE` | `FERTILIZER` | 1 | +0.75 mo | 0.35 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | +8% to +10% | 1–3 months | tier 1 |
| MEDIUM | 30% | +10% to +15% | 3–5 months | tier 1 |
| HIGH | 10% | +30% to +35% | 6–10 months | tier 1 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 15–35% in | 0.5–0.9 | 65% of peak | 0.5 mo | ±1.5% | 1.00 |
| MEDIUM | 15–35% in | 0.5–0.9 | 70% of peak | 0.7 mo | ±2% | 1.00 |
| HIGH | 15–35% in | 0.5–0.9 | 75% of peak | 1 mo | ±2.5% | 1.00 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | 1 | 1.4 | 1.5 | 1.1 | 0.5 | – | – | – | – | – | – | 0.6 |
| **Share** | 16% | 23% | 25% | 18% | 8% | – | – | – | – | – | – | 10% |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Input Costs Rising**

> Suppliers are quoting higher prices on farm inputs this season - fertiliser,
> lime and seed are all creeping up, and herbicide is following. Nothing
> dramatic yet, but if you were planning to restock for spring, sooner may
> beat later. Manure, slurry and digestate are edging up as growers look for
> cheaper alternatives.

**MEDIUM — Market Alert: Supply Squeeze**

> A supply squeeze has hit the farm input market. With fertiliser plants
> throttling back and freight costs climbing, prices for fertiliser, lime and
> seed are rising sharply, and herbicide is being dragged up with them.
> Dealers expect the squeeze to last well into the season - budget
> accordingly. With growers turning to organic muck instead, manure, slurry
> and digestate are quietly gaining value.

**HIGH — Market Alert: Global Input Crisis**

> A global input crisis has erupted. Fertiliser production is being curtailed
> on expensive gas, mineral freight is disrupted, and seed stocks are tight
> worldwide - prices for fertiliser, lime, seed and herbicide are surging and
> expected to stay punishing for months. Every pass over the field now costs
> real money. There is one bright spot: with synthetic fertiliser priced out
> of reach, growers are bidding hard for manure, slurry and digestate, so
> anyone with muck to shift, a biogas plant running - or crushing their own
> lime - is suddenly sitting on something worth selling.

---

## 8. `dairyEmbargo`

**trade** · player lose · prices down · all year, flat

Never runs alongside `dairyExportBoom` (shared subtype `dairyTrade`).

### Products moved (10)

**Direct — full magnitude (7)**

`CHEESE` · `BUTTER` · `GOATCHEESE` · `BUFFALOMOZZARELLA` · `MILK_BOTTLED` · `GOATMILK_BOTTLED` · `BUFFALOMILK_BOTTLED`

**Ripple — damped and delayed (3)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `BUFFALOMILK` | `BUFFALOMOZZARELLA` | 1 | +0.5 mo | 0.80 |
| `GOATMILK` | `GOATCHEESE` | 1 | +0.5 mo | 0.80 |
| `MILK` | `CHEESE` | 1 | +0.5 mo | 0.80 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | −7.5% to −10% | 2–4 months | tier 1 |
| MEDIUM | 30% | −10% to −15% | 4–8 months | tier 1 |
| HIGH | 10% | −30% to −35% | 8–12 months | tier 1 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 10–25% in | 0.5–0.8 | 75% of peak | 0.6 mo | ±1.5% | 1.00 |
| MEDIUM | 10–25% in | 0.5–0.8 | 80% of peak | 0.8 mo | ±2% | 1.00 |
| HIGH | 10–25% in | 0.5–0.8 | 85% of peak | 1 mo | ±2.5% | 1.00 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| **Share** | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Dairy Trade Friction**

> A diplomatic spat has led to new import checks on dairy, and a share of the
> region's exports are sitting in cold stores instead of shipping out. Cheese,
> butter, mozzarella and bottled milk are softening, and dairies with full
> warehouses are already trimming what they pay at the farm gate. Milk cheques
> will look a little thinner.

**MEDIUM — Market Alert: Dairy Export Sanctions**

> Sanctions have closed a major export market to the region's dairy industry.
> Cheese, butter, mozzarella and bottled milk are piling up unsold, and prices
> are falling across the board. With processors unable to move stock, they are
> cutting farm gate prices for cow, goat and buffalo milk in turn. Expect this
> to grind on until new buyers are found.

**HIGH — Market Alert: Dairy Trade War**

> A full trade war has erupted and the region's dairy exports are frozen out
> of their biggest markets. Cheese, butter, mozzarella and bottled milk are
> being dumped at whatever the domestic market will bear, and with warehouses
> overflowing the dairies have slashed what they pay for raw milk. This is a
> hard season for anyone milking - it may take the better part of a year to
> find new markets.

---

## 9. `mediterraneanEmbargo`

**trade** · player lose · prices down · all year, flat

Never runs alongside `mediterraneanExportBoom` (shared subtype `medTrade`).

### Products moved (6)

**Direct — full magnitude (4)**

`OLIVE_OIL` · `GRAPEJUICE` · `RAISINS` · `TOMATO`

**Ripple — damped and delayed (2)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `GRAPE` | `GRAPEJUICE` | 1 | +0.5 mo | 0.80 |
| `OLIVE` | `OLIVE_OIL` | 1 | +0.5 mo | 0.80 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | −7.5% to −10% | 2–4 months | tier 1 |
| MEDIUM | 30% | −10% to −15% | 4–8 months | tier 1 |
| HIGH | 10% | −30% to −35% | 8–12 months | tier 1 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 10–25% in | 0.5–0.8 | 75% of peak | 0.6 mo | ±1.5% | 1.00 |
| MEDIUM | 10–25% in | 0.5–0.8 | 80% of peak | 0.8 mo | ±2% | 1.00 |
| HIGH | 10–25% in | 0.5–0.8 | 85% of peak | 1 mo | ±2.5% | 1.00 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| **Share** | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Export Red Tape**

> New customs barriers are slowing shipments of olive oil, juice and dried
> fruit out of the region, and crates of fresh tomatoes are held up with them.
> Prices are easing as stock backs up at the docks, and pressers and bottlers
> are offering growers a little less for olives and grapes. Tomatoes ship
> fresh with no processor to cushion them, so they feel it most directly. An
> inconvenient time to be holding fruit.

**MEDIUM — Market Alert: Mediterranean Export Sanctions**

> Sanctions have shut the region's olive oil, juice, raisin and fresh tomato
> exports out of a key market. With tanks and warehouses full and nowhere to
> ship, prices are sliding - and the pressers and bottlers are passing the
> pain straight back to growers, paying noticeably less for olives and grapes.
> Tomatoes have no processor to absorb the shock and are being discounted hard
> to move at all. A poor season to bring in a big harvest.

**HIGH — Market Alert: Mediterranean Trade Blockade**

> A trade blockade has severed the region's Mediterranean export routes. Olive
> oil, grape juice and raisins are stranded with no buyers, fresh tomatoes are
> going for whatever price will move them, and prices are collapsing across
> the board. Growers are being offered a fraction of the usual rate for olives
> and grapes as mills and bottlers refuse to take on more stock. Groves,
> vineyards and tomato growers will feel this for a long season to come.

---

## 10. `dairyExportBoom`

**trade** · player win · prices up · all year, flat

Never runs alongside `dairyEmbargo` (shared subtype `dairyTrade`).

### Products moved (10)

**Direct — full magnitude (7)**

`CHEESE` · `BUTTER` · `GOATCHEESE` · `BUFFALOMOZZARELLA` · `MILK_BOTTLED` · `GOATMILK_BOTTLED` · `BUFFALOMILK_BOTTLED`

**Ripple — damped and delayed (3)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `BUFFALOMILK` | `BUFFALOMOZZARELLA` | 1 | +0.5 mo | 0.80 |
| `GOATMILK` | `GOATCHEESE` | 1 | +0.5 mo | 0.80 |
| `MILK` | `CHEESE` | 1 | +0.5 mo | 0.80 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | +15% to +20% | 2–4 months | tier 1 |
| MEDIUM | 30% | +20% to +30% | 4–8 months | tier 1 |
| HIGH | 10% | +60% to +70% | 8–12 months | tier 1 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 20–40% in | 0.8–1.3 | 75% of peak | 0.6 mo | ±1.5% | 1.00 |
| MEDIUM | 20–40% in | 0.8–1.3 | 80% of peak | 0.8 mo | ±2% | 1.00 |
| HIGH | 20–40% in | 0.8–1.3 | 85% of peak | 1 mo | ±2.5% | 1.00 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| **Share** | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Dairy Demand Firming**

> A modest new export order has come through for the region's dairies. Cheese,
> butter, mozzarella and bottled milk are firming up, and with a little more
> product to ship the dairies are competing for supply again. Milk cheques
> should look slightly healthier.

**MEDIUM — Market Report: Dairy Export Deal**

> A trade deal has opened a substantial new export market to the region's
> dairy industry. Cheese, butter, mozzarella and bottled milk are all climbing
> as contracts are signed, and processors chasing volume are bidding up cow,
> goat and buffalo milk at the farm gate. A good stretch ahead for anyone
> milking.

**HIGH — Market Alert: Dairy Export Boom**

> A landmark trade agreement has thrown open the world's biggest dairy markets
> to the region. Cheese, butter, mozzarella and bottled milk are commanding
> premium prices, and with processors desperate for volume they are paying
> whatever it takes for raw milk. If your parlour can run at capacity, now is
> the time - a window like this may not come again for years.

---

## 11. `mediterraneanExportBoom`

**trade** · player win · prices up · all year, flat

Never runs alongside `mediterraneanEmbargo` (shared subtype `medTrade`).

### Products moved (6)

**Direct — full magnitude (4)**

`OLIVE_OIL` · `GRAPEJUICE` · `RAISINS` · `TOMATO`

**Ripple — damped and delayed (2)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `GRAPE` | `GRAPEJUICE` | 1 | +0.5 mo | 0.80 |
| `OLIVE` | `OLIVE_OIL` | 1 | +0.5 mo | 0.80 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | +15% to +20% | 2–4 months | tier 1 |
| MEDIUM | 30% | +20% to +30% | 4–8 months | tier 1 |
| HIGH | 10% | +60% to +70% | 8–12 months | tier 1 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 20–40% in | 0.8–1.3 | 75% of peak | 0.6 mo | ±1.5% | 1.00 |
| MEDIUM | 20–40% in | 0.8–1.3 | 80% of peak | 0.8 mo | ±2% | 1.00 |
| HIGH | 20–40% in | 0.8–1.3 | 85% of peak | 1 mo | ±2.5% | 1.00 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| **Share** | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Export Orders Up**

> Fresh export orders are trickling in for olive oil, juice, dried fruit and
> tomatoes. Prices are firming as stock moves off the docks, and pressers and
> bottlers are offering growers a little more for olives and grapes. Tomatoes
> ship straight to the buyer with nobody taking a cut in between, so they
> catch the upside first. A decent time to be holding fruit.

**MEDIUM — Market Report: Mediterranean Export Deal**

> A new trade agreement has opened a strong market for the region's olive oil,
> juice, raisins and fresh tomatoes. Prices are rising as shipments ramp up,
> and the mills and bottlers are passing it back to growers, paying noticeably
> more for olives and grapes. Tomatoes go straight to the buyer with no
> processor taking a margin, so growers see the full benefit. A fine season to
> bring in a big harvest.

**HIGH — Market Alert: Mediterranean Export Boom**

> Mediterranean produce has become the export story of the year. Olive oil,
> grape juice, raisins and fresh tomatoes are fetching extraordinary prices
> abroad, and with mills and bottlers unable to source enough, growers are
> being courted with premium offers for every olive and grape they can pick.
> Tomato buyers are taking everything that can be crated. Groves, vineyards
> and tomato growers will remember this season for a long time.

---

## 12. `asianTradeDisruption`

**trade** · player win · prices up · all year, flat

Never runs alongside `monsoonBounty` (shared subtype `asiaTrade`).

### Products moved (10)

**Direct — full magnitude (3)**

`RICE` · `RICELONGGRAIN` · `ENOKI`

**Ripple — damped and delayed (7)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `OYSTER` | `ENOKI` | 1 | +0.5 mo | 0.35 |
| `RICEFLOUR` | `RICE` | 1 | +1.0 mo | 0.60 |
| `RICE_BAGS` | `RICE` | 1 | +0.5 mo | 0.70 |
| `RICE_OIL` | `RICE` | 1 | +1.0 mo | 0.55 |
| `RICEROLLS` | `RICEFLOUR` | 2 | +1.0 mo | 0.60 |
| `RICE_BOXES` | `RICE` | 2 | +1.0 mo | 0.50 |
| `NOODLESOUP` | `RICEFLOUR` | 3 | +2.0 mo | 0.45 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | +15% to +20% | 2–4 months | tier 1 |
| MEDIUM | 30% | +20% to +30% | 4–8 months | tier 2 |
| HIGH | 10% | +60% to +70% | 8–12 months | tier 3 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 15–35% in | 0.5–0.9 | 70% of peak | 0.6 mo | ±1.5% | 0.55 |
| MEDIUM | 15–35% in | 0.5–0.9 | 78% of peak | 0.8 mo | ±2% | 1.00 |
| HIGH | 15–35% in | 0.5–0.9 | 85% of peak | 1 mo | ±2.5% | 1.30 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| **Share** | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Shipping Delays in the East**

> Port delays across Southeast Asia are holding up rice shipments, and
> cultivated mushrooms are caught in the same backlog. Rice, long grain rice
> and enoki are all firming, and buyers turned away from enoki are reaching
> for locally grown oyster mushrooms instead, nudging those up too. Millers
> and packers may feel it as the delays work through.

**MEDIUM — Market Report: Southeast Asian Export Controls**

> Export controls across the region have cut off a large share of the world's
> rice trade. Rice, long grain rice and enoki mushrooms are climbing steadily,
> with oyster mushrooms pulled along as buyers look for a substitute. Expect
> the squeeze to work down through milled and packed goods over the coming
> months. Growers holding rice are in a strong position.

**HIGH — Market Alert: Southeast Asian Trade Crisis**

> A full breakdown in Southeast Asian trade relations has closed the region's
> export routes, and the world's rice market has gone with it. Rice, long
> grain rice and enoki mushrooms are spiking hard, oyster mushrooms are being
> bid up in their place, and the shortage will hold high for an extended spell
> while alternative supply is arranged. It will ripple deep through everything
> milled, packed and prepared from rice. Anyone with rice in store is sitting
> on a windfall.

---

## 13. `monsoonBounty`

**trade** · player lose · prices down · Aug–Feb (7 months), peaking Oct/Nov

Never runs alongside `asianTradeDisruption` (shared subtype `asiaTrade`).

### Products moved (10)

**Direct — full magnitude (3)**

`RICE` · `RICELONGGRAIN` · `ENOKI`

**Ripple — damped and delayed (7)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `OYSTER` | `ENOKI` | 1 | +0.5 mo | 0.35 |
| `RICEFLOUR` | `RICE` | 1 | +1.0 mo | 0.60 |
| `RICE_BAGS` | `RICE` | 1 | +0.5 mo | 0.70 |
| `RICE_OIL` | `RICE` | 1 | +1.0 mo | 0.55 |
| `RICEROLLS` | `RICEFLOUR` | 2 | +1.0 mo | 0.60 |
| `RICE_BOXES` | `RICE` | 2 | +1.0 mo | 0.50 |
| `NOODLESOUP` | `RICEFLOUR` | 3 | +2.0 mo | 0.45 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | −7.5% to −10% | 3–6 months | tier 1 |
| MEDIUM | 30% | −10% to −15% | 6–8 months | tier 2 |
| HIGH | 10% | −30% to −35% | 10–12 months | tier 3 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 10–40% in | 0.5–0.9 | 60% of peak | 0.8 mo | ±1.5% | 0.55 |
| MEDIUM | 35–60% in | 1–1.5 | 68% of peak | 1.1 mo | ±2% | 1.00 |
| HIGH | 30–45% in | 1.5–2 | 76% of peak | 1.2 mo | ±2.5% | 1.30 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | 0.8 | 0.3 | – | – | – | – | – | 0.3 | 0.9 | 1.5 | 1.5 | 1.2 |
| **Share** | 12% | 5% | – | – | – | – | – | 5% | 14% | 23% | 23% | 18% |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Kind Monsoon Season**

> A generous monsoon has given Southeast Asia a comfortable rice crop, and the
> surplus is finding its way onto the market. Rice, long grain rice and enoki
> are all easing back a little, with oyster mushrooms softening as cheap
> imports arrive alongside. Millers and packers should see the benefit before
> long.

**MEDIUM — Market Report: Strong Monsoon Harvest**

> The monsoon arrived on time and stayed, and Southeast Asia has brought in a
> big rice harvest. Cheap freight is carrying the surplus - and the region's
> cultivated mushrooms with it - into every market. Rice, long grain rice and
> enoki are sliding, oyster mushrooms are being undercut, and the pressure
> will work its way through milled and packed goods in the months ahead.

**HIGH — Market Alert: Record Monsoon Harvest**

> A near-perfect monsoon has produced a record Southeast Asian rice harvest,
> and the region is exporting everything it can move. Rice, long grain rice
> and enoki mushrooms are falling steeply, oyster mushrooms are being undercut
> badly, and the glut will hold prices down for a long stretch while it clears
> - all the way through the milled, packed and prepared goods further down the
> chain. Anyone selling rice this year will feel it.

---

## 14. `ethanolGlut`

**biofuel** · player lose · prices down · all year, flat

Never runs alongside `ethanolBoom` (shared subtype `ethanol`).

### Products moved (6)

**Direct — full magnitude (4)**

`MAIZE` · `SUGARBEET` · `SUGARCANE` · `SOYBEAN`

**Ripple — damped and delayed (2)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `SILAGE` | `MAIZE` | 1 | +0.5 mo | 0.50 |
| `SUGAR` | `SUGARBEET` | 1 | +0.5 mo | 0.60 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | −7.5% to −10% | 2–4 months | tier 1 |
| MEDIUM | 30% | −10% to −15% | 4–8 months | tier 1 |
| HIGH | 10% | −30% to −35% | 8–12 months | tier 1 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 15–30% in | 0.5–0.9 | 75% of peak | 0.6 mo | ±1.5% | 1.00 |
| MEDIUM | 15–30% in | 0.5–0.9 | 80% of peak | 0.8 mo | ±2% | 1.00 |
| HIGH | 15–30% in | 0.5–0.9 | 85% of peak | 1 mo | ±2.5% | 1.00 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| **Share** | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Ethanol Stocks Building**

> Ethanol stocks are running high and the refineries have trimmed their
> intake. Maize, sugar beet, sugar cane and soybean are softening as a result,
> and with a little more crop going to food and feed instead, sugar and silage
> are easing too.

**MEDIUM — Market Alert: Biofuel Mandate Cut**

> With ethanol overstocked, the government has cut its biofuel blending
> mandate. The refineries are buying far less, and prices for maize, sugar
> beet, sugar cane and soybean are sliding. Crops that would have gone to fuel
> are being diverted into food and feed instead, so sugar and silage are
> coming down with them. Cheaper feed is small consolation if you grow for the
> refineries.

**HIGH — Market Alert: Biofuel Mandate Slashed**

> A glut of ethanol has forced the government to slash its biofuel programme.
> Refinery contracts are being torn up and demand for maize, sugar beet, sugar
> cane and soybean has fallen off a cliff. With the whole feedstock harvest
> now chasing food and feed buyers instead, sugar and silage are being dragged
> down too. Expect this to grind on for the best part of a year - livestock
> farmers buying feed will be the only ones smiling.

---

## 15. `ethanolBoom`

**biofuel** · player win · prices up · all year, flat

Never runs alongside `ethanolGlut` (shared subtype `ethanol`).

### Products moved (6)

**Direct — full magnitude (4)**

`MAIZE` · `SUGARBEET` · `SUGARCANE` · `SOYBEAN`

**Ripple — damped and delayed (2)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `SILAGE` | `MAIZE` | 1 | +0.5 mo | 0.50 |
| `SUGAR` | `SUGARBEET` | 1 | +0.5 mo | 0.60 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | +15% to +20% | 2–4 months | tier 1 |
| MEDIUM | 30% | +20% to +30% | 4–8 months | tier 1 |
| HIGH | 10% | +60% to +70% | 8–12 months | tier 1 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 20–40% in | 0.8–1.3 | 75% of peak | 0.6 mo | ±1.5% | 1.00 |
| MEDIUM | 20–40% in | 0.8–1.3 | 80% of peak | 0.8 mo | ±2% | 1.00 |
| HIGH | 20–40% in | 0.8–1.3 | 85% of peak | 1 mo | ±2.5% | 1.00 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 | 1 |
| **Share** | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% | 8% |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Biofuel Demand Firming**

> The refineries have nudged up their biofuel intake this season. Maize, sugar
> beet, sugar cane and soybean are firming, and with a little more crop
> heading to fuel, sugar and silage are tightening slightly too.

**MEDIUM — Market Report: Biofuel Mandate Raised**

> The government has raised its biofuel blending target, and the refineries
> are competing hard for feedstock. Maize, sugar beet, sugar cane and soybean
> are all climbing as contracts are signed. With crops pulled away from food
> and feed, sugar and silage are tightening as well. A good stretch for anyone
> growing for the refineries.

**HIGH — Market Alert: Biofuel Boom**

> An ambitious new biofuel programme has sent the refineries scrambling for
> every tonne of feedstock they can secure. Maize, sugar beet, sugar cane and
> soybean are commanding premium prices, and with the harvest being pulled
> away from food and feed, sugar and silage are climbing sharply in turn. If
> you can get a crop off the field, the refineries will take it - though feed
> will cost you dearly this year.

---

## 16. `greenhousePest`

**greenhouse** · player win · prices up · all year, peaking Jun/Jul

Never runs alongside `greenhouseBounty` (shared subtype `greenhouse`).

### Products moved (8)

**Direct — full magnitude (7)**

`LETTUCE` · `TOMATO` · `STRAWBERRY` · `SPRING_ONION` · `NAPACABBAGE` · `CHILLI` · `GARLIC`

**Ripple — damped and delayed (1)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `FERMENTEDNAPACABBAGE` | `NAPACABBAGE` | 1 | +0.5 mo | 0.60 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | +15% to +20% | 1–3 months | tier 1 |
| MEDIUM | 30% | +20% to +30% | 3–5 months | tier 1 |
| HIGH | 10% | +60% to +70% | 5–8 months | tier 1 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 35–55% in | 1.3–1.8 | 55% of peak | 0.5 mo | ±1.5% | 0.55 |
| MEDIUM | 35–55% in | 1.3–1.8 | 62% of peak | 0.7 mo | ±2% | 1.00 |
| HIGH | 35–55% in | 1.3–1.8 | 70% of peak | 0.9 mo | ±2.5% | 1.30 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | 0.2 | 0.3 | 0.5 | 0.9 | 1.3 | 1.5 | 1.5 | 1.3 | 0.9 | 0.5 | 0.3 | 0.2 |
| **Share** | 2% | 3% | 5% | 10% | 14% | 16% | 16% | 14% | 10% | 5% | 3% | 2% |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Beetle Sightings**

> Beetles have turned up in a few of the region's glasshouses and growers are
> losing some produce to them. Lettuce, tomatoes, strawberries, spring onions,
> cabbage, chilli and garlic are firming up as supply thins. A minor nuisance
> - but if your glass is clean, there is a little more money on the table.

**MEDIUM — Market Alert: Beetle Infestation**

> A beetle infestation is spreading through the region's glasshouses and
> spreading fast. Growers are losing whole benches, and prices for lettuce,
> tomatoes, strawberries, spring onions, cabbage, chilli and garlic are
> climbing steadily as supply falls short. Fermented cabbage will follow as
> the processors run short of raw stock. Whoever keeps their crop clean will
> sell it well.

**HIGH — Market Alert: Beetle Plague**

> A full beetle plague has swept the region's glasshouses. Entire crops have
> been stripped, growers are burning infested benches, and prices for lettuce,
> tomatoes, strawberries, spring onions, cabbage, chilli and garlic are
> soaring as the market runs dry. Anyone who kept the beetles out is looking
> at the best prices in years - though it will take months to bring the
> infestation under control.

---

## 17. `greenhouseBounty`

**greenhouse** · player lose · prices down · all year, peaking Jun/Jul

Never runs alongside `greenhousePest` (shared subtype `greenhouse`).

### Products moved (8)

**Direct — full magnitude (7)**

`LETTUCE` · `TOMATO` · `STRAWBERRY` · `SPRING_ONION` · `NAPACABBAGE` · `CHILLI` · `GARLIC`

**Ripple — damped and delayed (1)**

| Product | Driven by | Tier | Lag | Pass-through |
|---|---|:-:|:-:|:-:|
| `FERMENTEDNAPACABBAGE` | `NAPACABBAGE` | 1 | +0.5 mo | 0.60 |

Tier is the ripple depth a severity must reach for that hop to
apply: LOW reaches tier 1, MEDIUM tier 2, HIGH tier 3.

### Severity ranges

Rolled per firing, then the actual values are rolled again inside the
range — so two events of the same severity never share a curve.

| Severity | Chance | Price change | Duration | Ripple reaches |
|---|:-:|---|---|:-:|
| LOW | 60% | −7.5% to −10% | 1–3 months | tier 1 |
| MEDIUM | 30% | −10% to −15% | 3–5 months | tier 1 |
| HIGH | 10% | −30% to −35% | 5–8 months | tier 1 |

<details><summary>Curve shape per severity</summary>

| Severity | Peak at | Rise | Plateau holds | Correction | Daily jitter | Ripple scale |
|---|---|---|---|---|---|---|
| LOW | 25–45% in | 0.8–1.2 | 55% of peak | 0.5 mo | ±1.5% | 0.55 |
| MEDIUM | 25–45% in | 0.8–1.2 | 62% of peak | 0.7 mo | ±2% | 1.00 |
| HIGH | 25–45% in | 0.8–1.2 | 70% of peak | 0.9 mo | ±2.5% | 1.30 |

*Peak at* is a fraction of the event's duration. *Rise* is the onset
exponent: below 1 climbs fast then flattens, above 1 starts slow and
accelerates. *Plateau holds* is where the price settles after the peak,
as a share of the peak swing — high values keep the base product
elevated while the ripple travels up the chain.

</details>

### Weighting per month

| | Jan | Feb | Mar | Apr | May | Jun | Jul | Aug | Sep | Oct | Nov | Dec |
|---|---|---|---|---|---|---|---|---|---|---|---|---|
| **Weight** | 0.2 | 0.3 | 0.5 | 0.9 | 1.3 | 1.5 | 1.5 | 1.3 | 0.9 | 0.5 | 0.3 | 0.2 |
| **Share** | 2% | 3% | 5% | 10% | 14% | 16% | 16% | 14% | 10% | 5% | 3% | 2% |

*Share* is the chance of this event firing in that month given that
it fires at all — the weights are normalised, so the window sets
**when** the event happens, never **how often**. A dash means the
event cannot start that month.

### Messages

**LOW — Market Report: Clean Glasshouses**

> Beetle numbers are down this season and the region's glasshouses are running
> clean. Crops are coming in a touch heavier than usual, so lettuce, tomatoes,
> strawberries, spring onions, cabbage, chilli and garlic are easing back
> slightly.

**MEDIUM — Market Report: Pest-Free Season**

> A hard winter has knocked back the beetle population and the region's
> glasshouses are having an exceptional run. With crop after crop coming in
> clean, lettuce, tomatoes, strawberries, spring onions, cabbage, chilli and
> garlic are sliding as the market fills up, and fermented cabbage is
> following them down.

**HIGH — Market Alert: Greenhouse Glut**

> Barely a beetle to be found this year, and the region's glasshouses are
> producing like never before. Lettuce, tomatoes, strawberries, spring onions,
> cabbage, chilli and garlic are flooding the market and prices are tumbling.
> Wonderful growing conditions, dreadful prices - expect the glut to hang
> around for months.

---

