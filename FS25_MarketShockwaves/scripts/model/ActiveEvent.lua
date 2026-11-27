--[[
    ActiveEvent — one rolled, running instance of an event definition.

    Firing an event rolls every curve parameter within its severity's ranges, so
    no two instances share a shape (replayability: the player can't learn "the
    drought pattern").

    It also flattens the chain graph into a per-product reach map:

        product -> { lagDays, passThrough }

    built by walking outward from the affected raw products, up to the severity's
    rippleDepth, multiplying passThrough at each hop (so influence diminishes)
    and accumulating lag (so each layer peaks about a month after the one before).

    Because the curve is a pure function of elapsed time and jitter is a hash of
    (seed, day), a product's factor at (today - lag) can be computed on demand.
    No price history is stored, and nothing extra has to survive a save/load.
]]

MSWActiveEvent = {}
local MSWActiveEvent_mt = Class(MSWActiveEvent)

--- Roll a new instance.
--- @param def table event definition
--- @param severityClass string "low" | "medium" | "high"
--- @param startDay number game day the event began
--- @param daysPerMonth number player's days-per-month setting
--- @param settings table { intensity, duration, supplyChainDepth } user settings
--- @param opts table|nil for an event started by a forecast's verdict:
---        durationMonths  exact length, replacing the rolled one (the effect
---                        has to last until the crop's next harvest, which
---                        depends on the map's calendar, not on the config)
---        titleKey, textKey  the news item the player was shown, when it is
---                        the verdict message and not the event's own
---        forecastId      which forecast started it
function MSWActiveEvent.new(def, severityClass, startDay, daysPerMonth, settings, opts)
    local self = setmetatable({}, MSWActiveEvent_mt)
    local sev = def.severities[severityClass]
    opts = opts or {}
    self.titleKey   = opts.titleKey
    self.textKey    = opts.textKey
    self.forecastId = opts.forecastId

    self.eventId       = def.id
    self.subtype       = def.subtype or def.id
    self.severity      = severityClass
    self.startDay      = startDay
    self.type          = def.type
    self.seed          = math.random(1, 2147483000)

    local intensity = (settings and settings.intensity) or 1.0
    local durScale  = (settings and settings.duration)  or 1.0
    -- Player-facing cap on how far a ripple may travel. 0 disables ripple
    -- entirely (raw products only); otherwise it caps the severity's own depth.
    local depthCap  = (settings and settings.supplyChainDepth) or 3

    -- Magnitude: scale the *deviation* from 1.0 by the intensity setting, so a
    -- setting of 0 neutralises the event and 2 doubles the swing, in the right
    -- direction for both price-up and price-down events.
    local rolledFactor = MSWRandom.range(sev.priceFactorMin, sev.priceFactorMax)
    self.peakFactor = 1.0 + (rolledFactor - 1.0) * intensity

    local months = MSWRandom.range(sev.durationMonthsMin, sev.durationMonthsMax) * durScale
    -- A forecast's effect runs to a point on the calendar, so the player's
    -- duration setting does not stretch it either.
    if opts.durationMonths ~= nil then months = opts.durationMonths end
    if months < 0.25 then months = 0.25 end
    self.durationMonths = months
    self.durationDays   = math.max(1, math.floor(months * daysPerMonth + 0.5))

    self.peakPos         = MSWRandom.range(sev.peakPosMin, sev.peakPosMax)
    self.riseExp         = MSWRandom.range(sev.riseExpMin, sev.riseExpMax)
    self.hold            = sev.hold
    self.correctionDays  = math.max(1, sev.correctionMonths * daysPerMonth)
    self.jitter          = sev.jitter

    self.reach = MSWActiveEvent.buildReach(def, sev, daysPerMonth, depthCap,
                                           self.durationDays)
    return self
end

--- Largest share of an event's duration that ONE MONTH of chain lag may take
--- up. See buildReach.
MSWActiveEvent.MAX_HOP_LAG_SHARE = 0.12

--- A game day covers the interval [d, d+1), and a day's price is read at the
--- MIDDLE of it, not its first instant. Reading at the start meant the firing
--- day always sat at exactly 1.0 - the news arrived and nothing moved until the
--- next day, which at 1 day per month threw away up to half of a short event.
--- At long seasons half a day is noise, so this changes nothing there; it is
--- what makes short seasons trace the same monthly profile as long ones.
MSWActiveEvent.DAY_SAMPLE_OFFSET = 0.5

--- Flatten the chain graph into product -> { lagDays, passThrough }.
---
--- Walks outward from the affected raw products. Each hop carries an explicit
--- `tier` (how far up the processing chain the product sits) and its own
--- `lagMonths`, and is only included when tier <= the severity's rippleDepth.
---
--- Tier is explicit rather than derived from graph shape because the two differ:
--- cake is made from flour, not from bread, so it is a *sibling* of bread in the
--- recipe graph — yet it is a more processed good that should move later and
--- only when a shock is severe. An explicit tier expresses that directly, and
--- lets LOW stop at flour, MED reach bread, and only HI reach cake.
function MSWActiveEvent.buildReach(def, sev, daysPerMonth, depthCap, durationDays)
    local reach = {}
    -- LAG IS CAPPED RELATIVE TO THE EVENT. A hop's lag is written in months
    -- (flour follows wheat by about a month), which is right for a drought that
    -- runs most of a year and wrong for a cold snap that runs a month or two:
    -- there a one-month lag is most of the event, so the downstream product
    -- barely moved, or - at 1-2 days per month, where everything is a handful of
    -- whole days - never moved at all. Capping each hop at a share of the
    -- event's own length keeps long cascades exactly as designed and guarantees
    -- every configured chain has room to play out, at any season length.
    --
    -- The cap is applied to the LENGTH OF A LAG-MONTH rather than to each hop's
    -- total, so hops keep their relative order: cake's two-month hop is still
    -- twice bread's one-month hop, however short the event.
    local lagMonthDays = daysPerMonth
    if durationDays ~= nil then
        lagMonthDays = math.min(daysPerMonth,
                                MSWActiveEvent.MAX_HOP_LAG_SHARE * durationDays)
    end
    local maxDepth = sev.rippleDepth or 1
    -- The player's "Supply chain effects" setting can only ever REDUCE reach,
    -- never extend an event past what its severity allows.
    if depthCap ~= nil then maxDepth = math.min(maxDepth, depthCap) end
    local scale = sev.rippleScale or 1.0

    -- Source products: full strength, no lag.
    for _, name in ipairs(def.affects) do
        reach[name] = { lagDays = 0, passThrough = 1.0 }
    end

    -- Opposite products: full timing, no lag, but a NEGATIVE pass-through, so
    -- the same curve pushes them the other way at `oppositeScale` of the swing.
    -- Registered before the chains, so the single-driver rule also stops a
    -- chain from claiming one of them. They are direct products, so neither the
    -- severity's ripple depth nor the player's supply-chain setting removes
    -- them.
    if def.opposite ~= nil then
        local oppositeScale = def.oppositeScale or 0.5
        for _, name in ipairs(def.opposite) do
            if reach[name] == nil then
                reach[name] = { lagDays = 0, passThrough = -oppositeScale }
                -- Only stored when it shortens: nil means "as long as the event".
                local share = def.oppositeDurationShare
                if share ~= nil and share > 0 and share < 1 then
                    reach[name].durationShare = share
                end
            end
        end
    end

    -- Iterate by tier so a hop's parent is always resolved before it.
    for tier = 1, maxDepth do
        for from, hops in pairs(def.chains) do
            local parent = reach[from]
            if parent ~= nil then
                for _, hop in ipairs(hops) do
                    -- Single-driver rule: first (and only) writer wins.
                    if hop.tier == tier and reach[hop.to] == nil then
                        reach[hop.to] = {
                            lagDays = parent.lagDays + hop.lagMonths * lagMonthDays,
                            passThrough = parent.passThrough
                                * math.min(hop.passThrough * scale, 0.95),
                        }
                    end
                end
            end
        end
    end

    return reach
end

--- Days elapsed since the event started.
function MSWActiveEvent:elapsed(currentDay)
    return currentDay - self.startDay
end

function MSWActiveEvent:isExpired(currentDay)
    return self:elapsed(currentDay) >= self.durationDays
end

--- Price factor this event applies to one product today (1.0 = no effect).
--- Downstream products read the source curve at (elapsed - lagDays) and scale
--- the deviation by passThrough.
function MSWActiveEvent:getFactorFor(productName, currentDay)
    local r = self.reach[productName]
    if r == nil then return 1.0 end

    local elapsed = self:elapsed(currentDay)
    if elapsed < 0 or elapsed >= self.durationDays then return 1.0 end

    -- A product with a duration share plays the whole curve out in that share
    -- of the event's length, correction included, and is then back to normal.
    local durationDays, correctionDays = self.durationDays, self.correctionDays
    if r.durationShare ~= nil then
        durationDays = math.max(1, durationDays * r.durationShare)
        correctionDays = math.min(correctionDays, durationDays)
        if elapsed >= durationDays then return 1.0 end
    end

    -- Mid-day sample: see DAY_SAMPLE_OFFSET.
    elapsed = elapsed + MSWActiveEvent.DAY_SAMPLE_OFFSET

    -- Shape is read at the LAGGED time, so each layer peaks later than the one
    -- feeding it...
    local shape = MSWCurve.shapeAt(elapsed - r.lagDays, {
        durationDays = durationDays,
        peakFactor   = self.peakFactor,
        peakPos      = self.peakPos,
        riseExp      = self.riseExp,
        hold         = self.hold,
        jitter       = self.jitter,
        seed         = self.seed,
    })

    -- ...but the stabilisation envelope is read at the UNLAGGED time, so the
    -- new-harvest correction hits every product simultaneously and the whole
    -- chain returns to baseline together.
    local envelope = MSWCurve.stabilisation(elapsed, durationDays, correctionDays)

    return 1.0 + (shape - 1.0) * r.passThrough * envelope
end

--- Products this event currently touches (for logging / UI).
function MSWActiveEvent:getProducts()
    local out = {}
    for name in pairs(self.reach) do out[#out + 1] = name end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

local SAVED_FIELDS = {
    "eventId", "severity", "startDay", "type", "seed", "peakFactor",
    "durationMonths", "durationDays", "peakPos", "riseExp", "hold",
    "correctionDays", "jitter",
    -- Only set on an event a forecast started; absent otherwise.
    "titleKey", "textKey", "forecastId",
}

local STRING_FIELDS = { eventId = true, severity = true, type = true,
                        titleKey = true, textKey = true, forecastId = true }

function MSWActiveEvent:saveToXML(xmlFile, key)
    for _, f in ipairs(SAVED_FIELDS) do
        local v = self[f]
        if type(v) == "number" then
            setXMLFloat(xmlFile, key .. "#" .. f, v)
        elseif type(v) == "string" then
            setXMLString(xmlFile, key .. "#" .. f, v)
        end
    end
end

--- Restore an instance. `def` is needed to rebuild the reach map.
function MSWActiveEvent.loadFromXML(xmlFile, key, def, daysPerMonth, depthCap)
    local self = setmetatable({}, MSWActiveEvent_mt)
    self.eventId  = getXMLString(xmlFile, key .. "#eventId")
    self.severity = getXMLString(xmlFile, key .. "#severity")
    self.type     = getXMLString(xmlFile, key .. "#type") or "neutral"
    for _, f in ipairs(SAVED_FIELDS) do
        if not STRING_FIELDS[f] then
            self[f] = getXMLFloat(xmlFile, key .. "#" .. f)
        end
    end
    self.titleKey   = getXMLString(xmlFile, key .. "#titleKey")
    self.textKey    = getXMLString(xmlFile, key .. "#textKey")
    self.forecastId = getXMLString(xmlFile, key .. "#forecastId")
    self.subtype    = (def ~= nil and def.subtype) or self.eventId
    if self.eventId == nil or self.startDay == nil or self.durationDays == nil then
        return nil
    end
    if def ~= nil and def.severities[self.severity] ~= nil then
        self.reach = MSWActiveEvent.buildReach(def, def.severities[self.severity],
                                               daysPerMonth, depthCap,
                                               self.durationDays)
    else
        self.reach = {}
    end
    return self
end
