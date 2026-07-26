--[[
    Random — small deterministic RNG helpers.

    Event instances need two kinds of randomness:

      * one-off rolls when an event fires (severity, magnitude, duration, curve
        shape). Plain math.random is fine there.

      * per-day jitter, which must be REPRODUCIBLE: the ripple model reads an
        event's factor at (today - lag) days, so asking for "the factor 30 days
        ago" must give the same answer it gave 30 days ago. A stored history
        would also have to survive save/load. Instead jitter is a pure hash of
        (event seed, day offset) — same inputs, same output, forever, with
        nothing to persist.
]]

MSWRandom = {}

--- Uniform float in [min, max].
function MSWRandom.range(min, max)
    if max <= min then return min end
    return min + math.random() * (max - min)
end

--- Integer in [min, max].
function MSWRandom.rangeInt(min, max)
    if max <= min then return min end
    return math.random(min, max)
end

--- Pick a key from a {key = weight} table. Returns nil if all weights are <= 0.
function MSWRandom.weightedPick(weights)
    local total = 0
    for _, w in pairs(weights) do
        if w > 0 then total = total + w end
    end
    if total <= 0 then return nil end

    local roll = math.random() * total
    local acc = 0
    -- Iterate deterministically for reproducibility across runs.
    local keys = {}
    for k in pairs(weights) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)

    for _, k in ipairs(keys) do
        local w = weights[k]
        if w > 0 then
            acc = acc + w
            if roll <= acc then return k end
        end
    end
    return keys[#keys]
end

--- Deterministic pseudo-random in [-1, 1] from an integer seed and day offset.
---
--- PRECISION MATTERS HERE. Lua numbers are doubles, exact only up to 2^53, and an
--- earlier version multiplied the raw seed by 73856093 - which for a real seed
--- (~1e9) reaches ~8e16 and blows straight past that. The seed's contribution
--- then collapsed to a fixed imprecise constant and the day term added linearly,
--- so successive days came out as a constant-step ramp that wrapped around:
---
---   -0.9462  -0.5779  -0.2096  +0.1588   (step +0.3683 every day)
---
--- Aggregate statistics looked fine, which is how it went unnoticed, but the
--- jitter was a visible sawtooth rather than noise.
---
--- Measured: consecutive-day step deviation 0.83 (was 0.00), worst decile
--- deviation from uniform 0.5%. tools/test_model.lua guards both.
function MSWRandom.signedNoise(seed, day)
    seed = math.floor(seed or 0)
    day = math.floor(day or 0)

    -- Fold both inputs into a small range first, so the squaring below stays
    -- exact: 65521^2 is only 4.3e9.
    local h = (seed % 65521) * 31 + (day + 1) * 8191
    h = h % 65521

    -- SQUARING IS THE POINT. Multiply-and-mod alone is affine, so consecutive
    -- days always differ by a constant - which is what produced the sawtooth.
    -- Squaring is non-linear and breaks that.
    h = (h * h + 74531) % 65521

    -- Spread the small value across the full range. 65521 * 2.65e9 = 1.7e14,
    -- comfortably inside 2^53.
    h = (h * 2654435761) % 2147483647
    h = (h + math.floor(h / 4096)) % 2147483647

    return (h / 2147483647) * 2 - 1
end
