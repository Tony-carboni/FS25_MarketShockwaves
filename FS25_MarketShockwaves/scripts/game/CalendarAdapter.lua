--[[
    CalendarAdapter — reads the in-game date.

    Market Shockwaves needs three things from the calendar:
      * the current day    (to detect "a new day has started" and roll events)
      * the current month  (1..12 for seasonal trigger weights)
      * days-per-month     (to convert month-based durations into game days,
                            and to normalise the daily trigger probability)

    `environment.currentDay` and `.currentHour` are confirmed. The period fields
    are not, and their names have moved between FS versions, so instead of
    hard-coding a guess we probe a list of candidates once at load and log which
    one matched. If nothing matches the mod degrades gracefully (safe defaults)
    and says so loudly in the log rather than silently misbehaving.

    NOTE ON MONTHS: the base game's fillTypes.xml documents period 1 = March.
    We convert to calendar months (1 = January) so config month weights read
    naturally.
]]

CalendarAdapter = {}
local CalendarAdapter_mt = Class(CalendarAdapter)

-- period 1 is March, so calendar month = ((period - 1) + 2) % 12 + 1
local PERIOD_ONE_IS_MONTH = 3

-- Candidate accessors, tried in order. Each returns a number or nil.
local PERIOD_CANDIDATES = {
    { name = "environment.currentPeriod",       get = function(e) return e.currentPeriod end },
    { name = "environment.period",              get = function(e) return e.period end },
    { name = "environment:getPeriod()",         get = function(e) return e.getPeriod and e:getPeriod() end },
    { name = "environment.currentMonth",        get = function(e) return e.currentMonth end },
}

local DAYS_PER_PERIOD_CANDIDATES = {
    { name = "environment.daysPerPeriod",       get = function(e) return e.daysPerPeriod end },
    { name = "environment:getDaysPerPeriod()",  get = function(e) return e.getDaysPerPeriod and e:getDaysPerPeriod() end },
    { name = "environment.daysPerMonth",        get = function(e) return e.daysPerMonth end },
    { name = "g_currentMission.missionInfo.daysPerPeriod",
      get = function() local mi = g_currentMission and g_currentMission.missionInfo
                       return mi and mi.daysPerPeriod end },
}

local DAY_CANDIDATES = {
    { name = "environment.currentDay",          get = function(e) return e.currentDay end },
    { name = "environment.dayIndex",            get = function(e) return e.dayIndex end },
}

function CalendarAdapter.new(logger)
    local self = setmetatable({}, CalendarAdapter_mt)
    self.log = logger
    self.periodAccessor = nil
    self.daysPerPeriodAccessor = nil
    self.dayAccessor = nil
    self.resolved = false
    return self
end

--- Try each candidate in order. Returns the first usable one, plus a report of
--- what EVERY candidate produced - that report is the single most useful thing
--- in a test log, because it shows which names exist on this build and what
--- they hold, even when none of them qualified.
local function probe(candidates, env)
    local report = {}
    local chosen, chosenValue = nil, nil
    for _, c in ipairs(candidates) do
        local ok, value = pcall(c.get, env)
        local desc
        if not ok then
            desc = "error"
        elseif value == nil then
            desc = "nil"
        else
            desc = ("%s(%s)"):format(type(value), tostring(value))
        end
        report[#report + 1] = ("%s=%s"):format(c.name, desc)
        if chosen == nil and ok and type(value) == "number" and value > 0 then
            chosen, chosenValue = c, value
        end
    end
    return chosen, chosenValue, table.concat(report, "  ")
end

--- Resolve which field names this game build actually uses. Safe to call again.
function CalendarAdapter:resolve()
    local env = g_currentMission and g_currentMission.environment
    if env == nil then
        self.log:warn("CalendarAdapter: no g_currentMission.environment yet; deferring")
        return false
    end

    local periodAcc, periodVal, periodReport = probe(PERIOD_CANDIDATES, env)
    local dppAcc,    dppVal,    dppReport    = probe(DAYS_PER_PERIOD_CANDIDATES, env)
    local dayAcc,    dayVal,    dayReport    = probe(DAY_CANDIDATES, env)

    -- Full candidate reports, always logged: this is what lets an unresolved
    -- field be fixed from a single log without another round trip.
    self.log:info("CalendarAdapter candidates [period]:        " .. periodReport)
    self.log:info("CalendarAdapter candidates [daysPerPeriod]: " .. dppReport)
    self.log:info("CalendarAdapter candidates [day]:           " .. dayReport)

    self.periodAccessor        = periodAcc
    self.daysPerPeriodAccessor = dppAcc
    self.dayAccessor           = dayAcc

    -- Log exactly what we found. This is the diagnostic that tells us the real
    -- field names on a live install.
    self.log:info(("CalendarAdapter probe: period=%s (%s), daysPerPeriod=%s (%s), day=%s (%s)")
        :format(periodAcc and periodAcc.name or "NOT FOUND", tostring(periodVal),
                dppAcc    and dppAcc.name    or "NOT FOUND", tostring(dppVal),
                dayAcc    and dayAcc.name    or "NOT FOUND", tostring(dayVal)))

    if periodAcc == nil or dppAcc == nil or dayAcc == nil then
        self.log:warn("CalendarAdapter: some fields unresolved — using safe defaults. "
                   .. "Please report the line above so the accessor list can be fixed.")
        -- Dump the environment's numeric keys once to make fixing this trivial.
        local keys = {}
        for k, v in pairs(env) do
            if type(v) == "number" then keys[#keys + 1] = ("%s=%s"):format(k, tostring(v)) end
        end
        table.sort(keys)
        self.log:info("CalendarAdapter: numeric environment fields: " .. table.concat(keys, ", "))
    end

    self.resolved = true
    return true
end

--- Current day counter (monotonic). Defaults to 1.
function CalendarAdapter:getDay()
    local env = g_currentMission and g_currentMission.environment
    if env == nil or self.dayAccessor == nil then return 1 end
    local ok, v = pcall(self.dayAccessor.get, env)
    return (ok and type(v) == "number") and v or 1
end

--- Days per month as configured by the player. Defaults to 1 (the game default).
function CalendarAdapter:getDaysPerMonth()
    local env = g_currentMission and g_currentMission.environment
    if env == nil or self.daysPerPeriodAccessor == nil then return 1 end
    local ok, v = pcall(self.daysPerPeriodAccessor.get, env)
    if ok and type(v) == "number" and v > 0 then return v end
    return 1
end

--- Current calendar month, 1 = January. Defaults to 1.
function CalendarAdapter:getMonth()
    local env = g_currentMission and g_currentMission.environment
    if env == nil or self.periodAccessor == nil then return 1 end
    local ok, period = pcall(self.periodAccessor.get, env)
    if not ok or type(period) ~= "number" then return 1 end
    -- period 1 = March -> calendar month
    return ((period - 1) + (PERIOD_ONE_IS_MONTH - 1)) % 12 + 1
end
