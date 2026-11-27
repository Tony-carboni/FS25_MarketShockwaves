--[[
    PriceModel — combines all running events into one modifier per fill type.

    Overlapping events STACK WITH DIMINISHING RETURNS, per product:

        the largest effect today counts in full,
        the second at 60%, the third and any later one at 30%,

    and the weighted factors are then multiplied:

        modifier = (1 + d1) * (1 + 0.6 * d2) * (1 + 0.3 * d3) ...

    Two +20% events give 1.2 * 1.12 = 1.34 rather than 1.44, and two +70% events
    give +141% rather than +189%. A second event still clearly matters; a pile-up
    of severe ones can no longer triple a price.

    RANKED BY SIZE, NOT BY ARRIVAL. If the first event to start always counted in
    full, the price would jump on the day it ended and the next one was promoted.
    Ranking by today's size has no such jump: where two effects cross they are
    equal, so swapping their weights changes nothing.

    RISES AND FALLS ARE RANKED SEPARATELY. A drought against a glut is two real
    forces pulling against each other and still nets out in full; only effects
    pushing the SAME way dampen one another.

    Multiplying can never push a price to zero or negative, however many negative
    events overlap.

    PERFORMANCE: the price hook is called very frequently (potentially many times
    per frame, per station, per fill type). Recomputing curves there would be
    wasteful, so modifiers are computed once per game day into a flat
    fillTypeIndex -> number table, and the hook just does a table lookup.
]]

MSWPriceModel = {}
local MSWPriceModel_mt = Class(MSWPriceModel)

--- @param resolveIndex function(name) -> fillTypeIndex|nil
function MSWPriceModel.new(resolveIndex, logger)
    local self = setmetatable({}, MSWPriceModel_mt)
    self.resolveIndex = resolveIndex
    self.log = logger
    self.activeEvents = {}
    self.modifiers = {}      -- fillTypeIndex -> factor
    self.builtForDay = nil
    self.indexCache = {}     -- productName -> fillTypeIndex (resolved lazily)
    return self
end

function MSWPriceModel:getIndexFor(name)
    local cached = self.indexCache[name]
    if cached ~= nil then
        return cached ~= false and cached or nil
    end
    local idx = self.resolveIndex(name)
    self.indexCache[name] = idx or false
    return idx
end

function MSWPriceModel:addEvent(activeEvent)
    self.activeEvents[#self.activeEvents + 1] = activeEvent
    self.builtForDay = nil   -- force a rebuild
end

function MSWPriceModel:clearEvents()
    self.activeEvents = {}
    self.modifiers = {}
    self.builtForDay = nil
end

function MSWPriceModel:getActiveEvents()
    return self.activeEvents
end

--- Is an instance of this event id still running?
--- Self-overlap guard: the same event must never run twice at once (a low
--- drought during a high drought reads as nonsense and double-stacks the same
--- products). Back-to-back instances are fine once the previous one expires;
--- DIFFERENT events still stack freely.
function MSWPriceModel:hasActiveEvent(eventId, currentDay)
    for _, ev in ipairs(self.activeEvents) do
        if ev.eventId == eventId and not ev:isExpired(currentDay) then
            return true
        end
    end
    return false
end

--- The running event that conflicts with this subtype, or nil.
---
--- Mutual exclusion for MIRRORED events: a biofuel boom must never run on top of
--- a biofuel glut, because they are the same market telling two opposite
--- stories. That is not a compounding shock, it is a contradiction, and the
--- ripple maths would have them fighting over the same products.
---
--- Returns the offending event rather than a boolean so callers can name it -
--- "blocked by ethanolGlut" is a far more useful log line than "blocked".
---
--- Subtype defaults to the event id, so this also subsumes the self-overlap
--- rule: an event with no subtype conflicts only with itself.
function MSWPriceModel:findActiveBySubtype(subtype, currentDay)
    if subtype == nil then return nil end
    for _, ev in ipairs(self.activeEvents) do
        if (ev.subtype or ev.eventId) == subtype
           and not ev:isExpired(currentDay) then
            return ev
        end
    end
    return nil
end

--- Drop finished events. Returns the list that expired.
function MSWPriceModel:pruneExpired(currentDay)
    local kept, expired = {}, {}
    for _, ev in ipairs(self.activeEvents) do
        if ev:isExpired(currentDay) then
            expired[#expired + 1] = ev
        else
            kept[#kept + 1] = ev
        end
    end
    if #expired > 0 then
        self.activeEvents = kept
        self.builtForDay = nil
    end
    return expired
end

--- Share of its own swing an effect keeps, by rank among the effects pushing a
--- product the same way: largest first. Ranks past the end reuse the last entry.
MSWPriceModel.STACK_WEIGHTS = { 1.0, 0.6, 0.3 }

local function largestFirst(a, b) return math.abs(a) > math.abs(b) end

--- Combine same-direction deviations (factor - 1) into one factor.
local function stackOneWay(deviations)
    if deviations == nil then return 1.0 end
    if #deviations > 1 then table.sort(deviations, largestFirst) end
    local weights = MSWPriceModel.STACK_WEIGHTS
    local factor = 1.0
    for rank, deviation in ipairs(deviations) do
        factor = factor * (1.0 + deviation * (weights[rank] or weights[#weights]))
    end
    return factor
end

--- Combine every running event's factor for ONE product into its modifier.
--- @param factors table array of price factors (1.0 = no effect)
function MSWPriceModel.combineFactors(factors)
    local ups, downs
    for _, factor in ipairs(factors) do
        if factor > 1.0 then
            ups = ups or {}
            ups[#ups + 1] = factor - 1.0
        elseif factor < 1.0 then
            downs = downs or {}
            downs[#downs + 1] = factor - 1.0
        end
    end
    return stackOneWay(ups) * stackOneWay(downs)
end

--- Recompute the modifier table for `currentDay`. Cheap to call repeatedly.
function MSWPriceModel:rebuild(currentDay)
    if self.builtForDay == currentDay then return end

    -- Gather every event's factor per product first: the stacking weights
    -- depend on how the effects rank against each other, so they cannot be
    -- folded in one event at a time.
    local perProduct = {}
    for _, ev in ipairs(self.activeEvents) do
        for _, productName in ipairs(ev:getProducts()) do
            local factor = ev:getFactorFor(productName, currentDay)
            if factor ~= 1.0 then
                local idx = self:getIndexFor(productName)
                if idx ~= nil then
                    local list = perProduct[idx]
                    if list == nil then
                        list = {}
                        perProduct[idx] = list
                    end
                    list[#list + 1] = factor
                end
            end
        end
    end

    local mods = {}
    for idx, factors in pairs(perProduct) do
        mods[idx] = MSWPriceModel.combineFactors(factors)
    end

    self.modifiers = mods
    self.builtForDay = currentDay
end

--- Modifier for a fill type. 1.0 when nothing is affecting it.
function MSWPriceModel:getModifier(fillTypeIndex)
    return self.modifiers[fillTypeIndex] or 1.0
end

--- Human-readable list of current modifiers, for the console command.
function MSWPriceModel:describe()
    local lines = {}
    for _, ev in ipairs(self.activeEvents) do
        lines[#lines + 1] = ("  %s [%s] peak=%.3f dur=%.1fmo (%d days) started day %d")
            :format(ev.eventId, ev.severity, ev.peakFactor, ev.durationMonths,
                    ev.durationDays, ev.startDay)
    end
    return lines
end
