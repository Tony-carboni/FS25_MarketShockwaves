--[[
    Curve — the shape of a price event over time.

    Direct port of the model validated in tools/*.py (see DESIGN.md). Over
    normalised time u = elapsedDays / durationDays, 0 -> 1:

      rise    (u < peakPos) : intensity = (u / peakPos) ^ riseExp     -> 1.0 at the peak
      plateau (u >= peakPos): intensity decays slowly from 1.0 toward `hold`

    then a market-wide stabilisation envelope eases the whole thing to zero over
    the final `correctionMonths` (new-harvest estimates / the spring thaw), using
    a smoothstep so it is fast but not a cliff.

    The envelope is applied to the *deviation*, synchronised across every product
    an event touches, so the base product stays elevated while the ripple works
    up the chain and everything corrects together. That's what stops "cake is
    still +30% but wheat is already back to normal".
]]

MSWCurve = {}

local function clamp01(x)
    if x < 0 then return 0 end
    if x > 1 then return 1 end
    return x
end

local function smoothstep(x)
    x = clamp01(x)
    return x * x * (3 - 2 * x)
end

--- Core intensity in [0, 1]: rise to the peak, then a slow plateau decay.
--- @param u number normalised elapsed time
function MSWCurve.intensity(u, peakPos, riseExp, hold)
    if u <= 0 then return 0 end
    if u >= 1 then return hold end

    if u < peakPos then
        return (u / peakPos) ^ riseExp
    end

    local v = (u - peakPos) / (1 - peakPos)   -- 0 at the peak -> 1 at the end
    return 1.0 - (1.0 - hold) * (v ^ 1.3)
end

--- Market-wide stabilisation multiplier in [0, 1].
--- 1.0 while the event runs, easing to 0 over the last `correctionDays`.
function MSWCurve.stabilisation(elapsedDays, durationDays, correctionDays)
    if correctionDays <= 0 then
        return elapsedDays >= durationDays and 0 or 1
    end
    local start = durationDays - correctionDays
    if elapsedDays <= start then return 1 end
    return 1.0 - smoothstep((elapsedDays - start) / correctionDays)
end

--- The event's shape on a given day, WITHOUT the stabilisation envelope.
---
--- Downstream products read this at (elapsed - lag), so it must not include the
--- envelope: the envelope is synchronised market-wide and is applied separately
--- by ActiveEvent using the event's *unlagged* elapsed time. Baking it in here
--- would delay each layer's correction too, leaving cake elevated long after
--- wheat had normalised — exactly the inconsistency the design forbids.
---
--- @param elapsedDays number days since the event started; <= 0 yields 1.0, so
---        looking "before the start" for a lagged product is safe
--- @param p table durationDays, peakFactor, peakPos, riseExp, hold, jitter, seed
--- @return number price factor (1.0 = unchanged)
function MSWCurve.shapeAt(elapsedDays, p)
    if elapsedDays <= 0 then return 1.0 end

    -- Past the end the shape holds at its plateau level; the envelope is what
    -- brings it home. Clamping (rather than snapping to 1.0) keeps a lagged
    -- product from jumping when the source's window ends.
    local u = elapsedDays / p.durationDays
    if u > 1 then u = 1 end

    local intensity = MSWCurve.intensity(u, p.peakPos, p.riseExp, p.hold)
    local deviation = (p.peakFactor - 1.0) * intensity

    -- Reproducible daily jitter so the number is never static.
    if p.jitter and p.jitter > 0 then
        local n = MSWRandom.signedNoise(p.seed or 0, math.floor(elapsedDays))
        deviation = deviation * (1.0 + n * p.jitter)
    end

    return 1.0 + deviation
end
