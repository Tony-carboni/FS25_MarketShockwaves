--[[
    EventScheduler — decides whether an event fires today.

    One roll per in-game day PER EVENT (events stack, so an active event doesn't
    block another). For event e in calendar month m:

        p_e(m) = K * baseWeight_e * monthShare_e[m] / daysPerMonth
        K      = eventsPerYear / sum(baseWeight)

    Two properties this guarantees, both verified in tools/trigger_timing_sim.py:

      * dividing by daysPerMonth keeps the ANNUAL rate identical whether the
        player runs 1, 3 or 10 days per month (only the per-day odds change);

      * monthShare is normalised per event, so a longer season changes WHEN an
        event fires, not HOW OFTEN. Equal baseWeight => equal frequency, which is
        what keeps player-win and player-lose events balanced.

    Severity is then rolled 60/30/10 (configurable).
]]

MSWEventScheduler = {}
local MSWEventScheduler_mt = Class(MSWEventScheduler)

function MSWEventScheduler.new(config, logger)
    local self = setmetatable({}, MSWEventScheduler_mt)
    self.config = config
    self.log = logger
    self.totalBaseWeight = 0
    for _, def in ipairs(config.events) do
        self.totalBaseWeight = self.totalBaseWeight + (def.baseWeight or 0)
    end
    if self.totalBaseWeight <= 0 then
        self.log:warn("EventScheduler: total base weight is 0 — no events can fire")
    end
    return self
end

--- Daily probability for one event in the given month.
function MSWEventScheduler:dailyProbability(def, month, daysPerMonth, eventsPerYear)
    if self.totalBaseWeight <= 0 or daysPerMonth <= 0 then return 0 end
    local share = def.monthShare[month] or 0
    if share <= 0 then return 0 end
    local K = eventsPerYear / self.totalBaseWeight
    return K * (def.baseWeight or 0) * share / daysPerMonth
end

--- Roll severity using the configured distribution.
function MSWEventScheduler:rollSeverity()
    local c = self.config.severityChances
    return MSWRandom.weightedPick({
        low = c.low or 0, medium = c.medium or 0, high = c.high or 0,
    }) or "low"
end

--- Roll every event for today.
--- @param isBlocked function|nil (def) -> true to skip this event's roll.
---        Covers the self-overlap guard, the settings-menu category switches and
---        the concurrent-event ceiling. Skipping (rather than roll-and-discard)
---        leaves every other event's odds untouched, since rolls are independent
---        per event.
--- @return table array of { def = def, severity = string }
function MSWEventScheduler:rollForDay(month, daysPerMonth, eventsPerYear, isBlocked)
    local fired = {}
    if eventsPerYear <= 0 then return fired end

    for _, def in ipairs(self.config.events) do
        if isBlocked == nil or not isBlocked(def) then
            local p = self:dailyProbability(def, month, daysPerMonth, eventsPerYear)
            if p > 0 and math.random() < p then
                fired[#fired + 1] = { def = def, severity = self:rollSeverity() }
            end
        end
    end
    return fired
end
