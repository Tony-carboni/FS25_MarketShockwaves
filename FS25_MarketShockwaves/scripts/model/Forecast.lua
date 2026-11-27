--[[
    Forecast — speculation: a market change announced long before it happens.

    An EVENT is a surprise: it rewards a quick reaction and leaves the player's
    plans alone. A FORECAST is the opposite. It arrives early enough to change
    what gets planted, felled or stored, and it is never certain.

    THE LIFE OF A FORECAST

      1. the opening message: who expects what, and how sure they are
      2. months of uncertainty, with no price movement at all
      3. the pre-move: just before the verdict, prices edge the way the
         analysts called it (about a quarter of the expected move). It says the
         verdict is close, not which way it goes
      4. the verdict message: what actually happened, and why
      5. a real event, started by the verdict. From here the forecast is over
         and the ordinary event engine takes it: curve, chains, markers, news

    THE VERDICT STARTS AN ORDINARY EVENT. A forecast carries no price logic of
    its own beyond the pre-move. Its outcome is "start event X at severity Y
    today", where X is defined like any other event (in forecasts.xml, under
    outcomeEvents, so the random scheduler never rolls it) or IS an existing
    one: a severe winter starts the same Harsh Winter the scheduler can.

        milder       the event, low severity
        as forecast  the event, medium severity
        stronger     the event, high severity
        wrong reason the event, medium severity (prices went the forecast way,
                     for a different cause), without any companion event
        backfire     the MIRROR event: everyone acted on the forecast, and the
                     market went the other way

    There is no "nothing happened" outcome. Every forecast ends in a move.

    THE STATED CONFIDENCE IS HONEST. It is rolled per forecast (70, 80 or 90)
    and is exactly the chance prices go the analysts' way. The player is told
    in words, never as a number.

    EVERY FORECAST MUST BE ACTIONABLE. resolveTiming() works the dates out from
    the map's own crop calendar and refuses a forecast the player could not act
    on: one for a crop the map does not have, or with too little time between
    the message and the verdict. Such a forecast is simply never offered there.

    Pure logic. The game layer supplies the crop calendar, performs the actions
    this module returns (start events, show messages) and saves its state.
]]

MSWForecastDef = {}
MSWActiveForecast = {}
MSWForecastEngine = {}

local MSWActiveForecast_mt = Class(MSWActiveForecast)
local MSWForecastEngine_mt = Class(MSWForecastEngine)

MSWForecastDef.OUTCOMES = { "asForecast", "stronger", "milder", "wrongReason", "backfire" }

--- Which severity of the outcome event each "analysts were right" outcome
--- starts. A backfire rolls its own (see rollOutcome).
MSWForecastDef.SEVERITY_OF = {
    asForecast = "medium", stronger = "high", milder = "low", wrongReason = "medium",
}

local function splitWords(s)
    local out = {}
    if s == nil then return out end
    for word in string.gmatch(s, "%S+") do out[#out + 1] = word end
    return out
end

local function splitNumbers(s)
    local out = {}
    for _, word in ipairs(splitWords(s)) do
        local n = tonumber(word)
        if n ~= nil then out[#out + 1] = n end
    end
    return out
end

--- Defaults, also used by the tests, which build their definitions in code.
function MSWForecastDef.defaultSettings()
    return {
        -- Roll rate BEFORE the cooldown. With nine quiet months after each
        -- forecast this comes out at about one forecast a year.
        forecastsPerYear = 4.0,
        cooldownMonths   = 9,
        maxOpen          = 2,
        minLeadMonths    = 4,
        premoveShare     = 0.25,
        confidence       = { [70] = 0.50, [80] = 0.35, [90] = 0.15 },
        -- Shares WITHIN "the analysts were right" ...
        outcomes         = { asForecast = 40, stronger = 12, milder = 8, wrongReason = 10 },
        -- ... and within a backfire: how hard the mirror event hits.
        backfire         = { low = 60, medium = 40 },
    }
end

--- Load config/forecasts.xml: the forecasts, and the events only they start.
--- @param eventConfig table the config MSWEventDef.loadAll returned; the
---        outcome events are added to it as eventConfig.forecastEvents
function MSWForecastDef.loadAll(path, eventConfig, log)
    local fc = { settings = MSWForecastDef.defaultSettings(), forecasts = {} }

    local xml = loadXMLFile("mswForecasts", path)
    if xml == nil or xml == 0 then
        log:error("ForecastDef: could not load " .. tostring(path))
        eventConfig.forecastEvents = eventConfig.forecastEvents or {}
        return fc
    end
    local root = "forecasts"
    local s = fc.settings

    s.forecastsPerYear = getXMLFloat(xml, root .. ".settings.forecastsPerYear#value") or s.forecastsPerYear
    s.cooldownMonths   = getXMLFloat(xml, root .. ".settings.cooldownMonths#value") or s.cooldownMonths
    s.maxOpen          = getXMLInt(xml,   root .. ".settings.maxOpen#value") or s.maxOpen
    s.minLeadMonths    = getXMLFloat(xml, root .. ".settings.minLeadMonths#value") or s.minLeadMonths
    s.premoveShare     = getXMLFloat(xml, root .. ".settings.premoveShare#value") or s.premoveShare
    for _, level in ipairs({ 70, 80, 90 }) do
        local v = getXMLFloat(xml, ("%s.settings.confidence#c%d"):format(root, level))
        if v ~= nil then s.confidence[level] = v end
    end
    for name in pairs(s.outcomes) do
        local v = getXMLFloat(xml, root .. ".settings.outcomes#" .. name)
        if v ~= nil then s.outcomes[name] = v end
    end
    for name in pairs(s.backfire) do
        local v = getXMLFloat(xml, root .. ".settings.backfire#" .. name)
        if v ~= nil then s.backfire[name] = v end
    end

    MSWEventDef.loadForecastEvents(xml, root, eventConfig, log)

    local i = 0
    while true do
        local key = ("%s.forecast(%d)"):format(root, i)
        if not hasXMLProperty(xml, key) then break end

        local def = {
            id             = getXMLString(xml, key .. "#id") or ("forecast" .. i),
            kind           = getXMLString(xml, key .. "#kind") or "fixed",
            weight         = getXMLFloat(xml, key .. "#weight") or 1.0,
            anchors        = splitWords(getXMLString(xml, key .. "#anchors")),
            arriveMonths   = splitNumbers(getXMLString(xml, key .. "#arriveMonths")),
            endMonth       = getXMLInt(xml, key .. "#endMonth"),
            leadMonths     = getXMLFloat(xml, key .. "#leadMonths"),
            durationMonths = getXMLFloat(xml, key .. "#durationMonths"),
            premoveMonths  = getXMLFloat(xml, key .. "#premoveMonths") or 1,
            premove        = splitWords(getXMLString(xml, key .. ".premove")),
            variants       = {},
        }
        local v = 0
        while true do
            local vkey = ("%s.variant(%d)"):format(key, v)
            if not hasXMLProperty(xml, vkey) then break end
            def.variants[#def.variants + 1] = {
                id            = getXMLString(xml, vkey .. "#id") or ("variant" .. v),
                event         = getXMLString(xml, vkey .. "#event"),
                backfire      = getXMLString(xml, vkey .. "#backfire"),
                extraEvent    = getXMLString(xml, vkey .. "#extraEvent"),
                verdictMonth  = getXMLInt(xml, vkey .. "#verdictMonth"),
                premoveMonths = getXMLFloat(xml, vkey .. "#premoveMonths"),
            }
            v = v + 1
        end
        fc.forecasts[#fc.forecasts + 1] = def
        i = i + 1
    end

    delete(xml)
    log:info(("ForecastDef: loaded %d forecasts and %d outcome events")
        :format(#fc.forecasts, #(eventConfig.forecastEvents or {})))
    return fc
end

function MSWForecastDef.findById(fc, id)
    for _, def in ipairs(fc.forecasts) do
        if def.id == id then return def end
    end
    return nil
end

function MSWForecastDef.findVariant(def, variantId)
    for _, variant in ipairs(def.variants) do
        if variant.id == variantId then return variant end
    end
    return nil
end

--- l10n keys for one stage of a forecast: "open" or an outcome.
function MSWForecastDef.messageKeys(forecastId, variantId, stage)
    local base = ("msw_fc_%s_%s_%s"):format(tostring(forecastId), tostring(variantId),
                                            tostring(stage))
    return base .. "_title", base .. "_text"
end

--- l10n key of the line that tells the player how sure the experts are.
function MSWForecastDef.confidenceKey(confidence)
    return ("msw_fc_confidence_%d"):format(confidence)
end

-- ---------------------------------------------------------------------------
-- ActiveForecast: one announced forecast, still waiting for its verdict
-- ---------------------------------------------------------------------------

local FORECAST_NUMBERS = { "confidence", "startDay", "verdictDay", "premoveDays",
                           "premoveDeviation", "durationMonths" }

function MSWActiveForecast.new(fields)
    local self = setmetatable({}, MSWActiveForecast_mt)
    for k, v in pairs(fields) do self[k] = v end
    self.productSet = {}
    for _, name in ipairs(self.products or {}) do self.productSet[name] = true end
    return self
end

function MSWActiveForecast:isDue(day)
    return day >= self.verdictDay
end

function MSWActiveForecast:getProducts()
    return self.products or {}
end

--- The pre-move: 1.0 until shortly before the verdict, then a small move the
--- way the analysts called it. It reaches full size halfway through, so a
--- one-day pre-move (one day per month) is already at full size on that day.
function MSWActiveForecast:getFactorFor(productName, day)
    if not self.productSet[productName] then return 1.0 end
    local premoveDays = self.premoveDays or 0
    if premoveDays <= 0 then return 1.0 end
    local start = self.verdictDay - premoveDays
    if day < start or day >= self.verdictDay then return 1.0 end
    local progress = (day - start + 0.5) / (premoveDays / 2)
    if progress > 1 then progress = 1 end
    return 1.0 + (self.premoveDeviation or 0) * progress
end

function MSWActiveForecast:isInPremove(day)
    local premoveDays = self.premoveDays or 0
    return premoveDays > 0 and day >= self.verdictDay - premoveDays and day < self.verdictDay
end

function MSWActiveForecast:saveToXML(xmlFile, key)
    setXMLString(xmlFile, key .. "#forecastId", self.forecastId)
    setXMLString(xmlFile, key .. "#variantId", self.variantId)
    for _, f in ipairs(FORECAST_NUMBERS) do
        if type(self[f]) == "number" then setXMLFloat(xmlFile, key .. "#" .. f, self[f]) end
    end
    setXMLString(xmlFile, key .. "#products", table.concat(self.products or {}, " "))
end

function MSWActiveForecast.loadFromXML(xmlFile, key)
    local fields = {
        forecastId = getXMLString(xmlFile, key .. "#forecastId"),
        variantId  = getXMLString(xmlFile, key .. "#variantId"),
        products   = splitWords(getXMLString(xmlFile, key .. "#products")),
    }
    for _, f in ipairs(FORECAST_NUMBERS) do
        fields[f] = getXMLFloat(xmlFile, key .. "#" .. f)
    end
    if fields.forecastId == nil or fields.variantId == nil or fields.verdictDay == nil then
        return nil
    end
    return MSWActiveForecast.new(fields)
end

-- ---------------------------------------------------------------------------
-- ForecastEngine: which forecast starts, when its verdict falls, what it does
-- ---------------------------------------------------------------------------

--- @param fc table what MSWForecastDef.loadAll returned
--- @param eventConfig table event definitions (for the outcome events)
--- @param calendarOf function(cropName) -> { sowFirst, harvestFirst } | nil
function MSWForecastEngine.new(fc, eventConfig, calendarOf, logger)
    local self = setmetatable({}, MSWForecastEngine_mt)
    self.fc = fc
    self.eventConfig = eventConfig
    self.calendarOf = calendarOf or function() return nil end
    self.log = logger
    self.open = {}              -- MSWActiveForecast, announced and undecided
    self.lastStartDay = nil
    self.tipShown = false       -- the one-time explanation of speculation
    self.timingCache = {}
    self.frequency = 1.0        -- the player's "forecasts per year" setting
    return self
end

--- The player's "forecasts per year" setting. The config is tuned for one a
--- year; this scales it: the roll rate goes up and the quiet time between
--- forecasts comes down by the same factor, and more may be open at once.
function MSWForecastEngine:setFrequency(perYear)
    if type(perYear) ~= "number" or perYear < 0 then perYear = 1.0 end
    self.frequency = perYear
end

function MSWForecastEngine:getMaxOpen()
    local base = self.fc.settings.maxOpen or 2
    return math.max(base, math.ceil(2 * self.frequency))
end

--- Forget cached timings: the crop calendar is only readable once a map is in.
function MSWForecastEngine:resetTiming()
    self.timingCache = {}
end

local function monthsUntil(a, b) return (b - a) % 12 end

--- Work out when a forecast may arrive, when its verdict falls and how long
--- the effect lasts, or why it cannot be offered on this map.
---
--- @return table|nil { arrive = {month = true}, numArrive, verdictMonth,
---                     durationMonths, premoveMonths, leadFrom = fn(month) }
--- @return string|nil the reason, when nil
function MSWForecastEngine:resolveTiming(def, variant)
    local cacheKey = def.id .. "/" .. variant.id
    local cached = self.timingCache[cacheKey]
    if cached ~= nil then
        if cached.timing == nil then return nil, cached.reason end
        return cached.timing
    end

    local timing, reason
    local premoveMonths = variant.premoveMonths or def.premoveMonths or 1

    if def.kind == "crop" then
        -- Timed by the first anchor crop this map can tell us about.
        local calendar
        for _, crop in ipairs(def.anchors or {}) do
            calendar = self.calendarOf(crop)
            if calendar ~= nil and calendar.sowFirst ~= nil and calendar.harvestFirst ~= nil then
                break
            end
            calendar = nil
        end
        if calendar == nil then
            reason = "none of its crops has a readable calendar on this map"
        else
            local sow, harvest = calendar.sowFirst, calendar.harvestFirst
            local growing = monthsUntil(sow, harvest)
            if growing == 0 then growing = 12 end
            -- The message arrives in the two months before sowing opens...
            local arrive = { [(sow - 3) % 12 + 1] = true, [(sow - 2) % 12 + 1] = true }
            timing = {
                arrive = arrive, numArrive = 2,
                -- ...the verdict falls when the harvest starts...
                verdictMonth = harvest,
                -- ...and the effect lasts until the harvest after that.
                durationMonths = 12,
                premoveMonths = premoveMonths,
                leadFrom = function(month)
                    return monthsUntil(month, sow) + growing
                end,
            }
        end
    elseif def.kind == "window" then
        local verdictMonth = variant.verdictMonth
        if verdictMonth == nil or def.endMonth == nil or #(def.arriveMonths or {}) == 0 then
            reason = "window forecast without arriveMonths, endMonth or verdictMonth"
        else
            local arrive, n = {}, 0
            for _, month in ipairs(def.arriveMonths) do
                if not arrive[month] then arrive[month] = true; n = n + 1 end
            end
            local duration = monthsUntil(verdictMonth, def.endMonth)
            if duration == 0 then duration = 12 end
            timing = {
                arrive = arrive, numArrive = n, verdictMonth = verdictMonth,
                durationMonths = duration, premoveMonths = premoveMonths,
                leadFrom = function(month)
                    local lead = monthsUntil(month, verdictMonth)
                    if lead == 0 then lead = 12 end
                    return lead
                end,
            }
        end
    else
        local lead = def.leadMonths or 12
        local arrive = {}
        for month = 1, 12 do arrive[month] = true end
        timing = {
            arrive = arrive, numArrive = 12, verdictMonth = nil,
            durationMonths = def.durationMonths or 12, premoveMonths = premoveMonths,
            leadFrom = function() return lead end,
        }
    end

    -- THE ACTIONABILITY CHECK: from every month the message can arrive in,
    -- there must be enough time left to change a plan.
    if timing ~= nil then
        local minLead = self.fc.settings.minLeadMonths or 0
        for month in pairs(timing.arrive) do
            if timing.leadFrom(month) < minLead then
                reason = ("only %d month(s) between the message and the verdict; "
                    .. "at least %d are needed to act on it")
                    :format(timing.leadFrom(month), minLead)
                timing = nil
                break
            end
        end
    end

    -- Its outcome events must exist, or the verdict would have nothing to start.
    if timing ~= nil then
        for _, id in ipairs({ variant.event, variant.backfire }) do
            if id == nil or MSWEventDef.findById(self.eventConfig, id) == nil then
                reason = ("outcome event '%s' is not defined"):format(tostring(id))
                timing = nil
                break
            end
        end
    end

    self.timingCache[cacheKey] = { timing = timing, reason = reason }
    if timing == nil and self.log ~= nil then
        self.log:info(("forecast %s/%s is not offered on this map: %s")
            :format(def.id, variant.id, tostring(reason)))
    end
    return timing, reason
end

--- Every forecast variant that can be offered on this map.
function MSWForecastEngine:getAvailable()
    local out = {}
    for _, def in ipairs(self.fc.forecasts) do
        local usable = {}
        for _, variant in ipairs(def.variants) do
            local timing = self:resolveTiming(def, variant)
            if timing ~= nil then usable[#usable + 1] = { variant = variant, timing = timing } end
        end
        for _, u in ipairs(usable) do
            out[#out + 1] = { def = def, variant = u.variant, timing = u.timing,
                              share = 1 / #usable }
        end
    end
    return out
end

--- Chance that one variant's message arrives today. Same construction as the
--- event scheduler: a yearly rate, split by weight, spread over the months the
--- message may arrive in, divided by days per month.
function MSWForecastEngine:dailyProbability(entry, month, daysPerMonth, totalWeight)
    if totalWeight <= 0 or daysPerMonth <= 0 then return 0 end
    if not entry.timing.arrive[month] then return 0 end
    local rate = (self.fc.settings.forecastsPerYear or 0) * self.frequency
    return rate * (entry.def.weight * entry.share) / totalWeight
           / entry.timing.numArrive / daysPerMonth
end

function MSWForecastEngine:getCooldownRemaining(day, daysPerMonth)
    if self.lastStartDay == nil then return 0 end
    if self.frequency <= 0 then return 0 end
    local cooldownDays = (self.fc.settings.cooldownMonths or 0) / self.frequency * daysPerMonth
    local since = day - self.lastStartDay
    if since >= cooldownDays then return 0 end
    return cooldownDays - since
end

function MSWForecastEngine:isOpen(forecastId)
    for _, forecast in ipairs(self.open) do
        if forecast.forecastId == forecastId then return true end
    end
    return false
end

--- Roll for a new forecast today.
--- @param isBlocked function|nil (def, variant) -> true to skip it today
--- @return table|nil { def, variant, timing }
function MSWForecastEngine:rollStart(day, month, daysPerMonth, isBlocked)
    if self.frequency <= 0 then return nil end
    if self:getCooldownRemaining(day, daysPerMonth) > 0 then return nil end
    if #self.open >= self:getMaxOpen() then return nil end

    local available = self:getAvailable()
    local totalWeight, seen = 0, {}
    for _, entry in ipairs(available) do
        if not seen[entry.def.id] then
            seen[entry.def.id] = true
            totalWeight = totalWeight + entry.def.weight
        end
    end

    for _, entry in ipairs(available) do
        if not self:isOpen(entry.def.id)
           and (isBlocked == nil or not isBlocked(entry.def, entry.variant)) then
            local p = self:dailyProbability(entry, month, daysPerMonth, totalWeight)
            if p > 0 and math.random() < p then return entry end
        end
    end
    return nil
end

function MSWForecastEngine:rollConfidence()
    local c = self.fc.settings.confidence
    local picked = MSWRandom.weightedPick({ c70 = c[70] or 0, c80 = c[80] or 0, c90 = c[90] or 0 })
    if picked == "c90" then return 90 end
    if picked == "c80" then return 80 end
    return 70
end

--- The middle of an event definition's medium swing, as a deviation from 1.0.
local function expectedDeviation(eventDef)
    local sev = eventDef ~= nil and eventDef.severities ~= nil and eventDef.severities.medium or nil
    if sev == nil then return 0 end
    return (sev.priceFactorMin + sev.priceFactorMax) / 2 - 1.0
end

--- Announce a forecast: fix its confidence and its dates.
--- @param opts table|nil { confidence = 70|80|90, intensity = number,
---        dayInMonth = 1..daysPerMonth, so the verdict falls on the FIRST day
---        of its month however far into this month the message arrives }
--- @return table MSWActiveForecast
function MSWForecastEngine:start(def, variant, timing, day, month, daysPerMonth, opts)
    opts = opts or {}
    local leadDays = math.floor(timing.leadFrom(month) * daysPerMonth + 0.5)
    local dayInMonth = opts.dayInMonth
    if type(dayInMonth) == "number" and dayInMonth >= 1 and dayInMonth <= daysPerMonth then
        leadDays = leadDays - (dayInMonth - 1)
    end
    if leadDays < 2 then leadDays = 2 end
    local premoveDays = math.floor(timing.premoveMonths * daysPerMonth + 0.5)
    if premoveDays < 1 then premoveDays = 1 end
    if premoveDays > leadDays - 1 then premoveDays = leadDays - 1 end

    local eventDef = MSWEventDef.findById(self.eventConfig, variant.event)
    local forecast = MSWActiveForecast.new({
        forecastId = def.id,
        variantId  = variant.id,
        confidence = opts.confidence or self:rollConfidence(),
        startDay   = day,
        verdictDay = day + leadDays,
        premoveDays = premoveDays,
        premoveDeviation = expectedDeviation(eventDef) * (self.fc.settings.premoveShare or 0.25)
                           * (opts.intensity or 1.0),
        durationMonths = timing.durationMonths,
        products   = def.premove or {},
    })
    self.open[#self.open + 1] = forecast
    self.lastStartDay = day
    return forecast
end

--- Roll what actually happens. The stated confidence is the chance the
--- analysts were right.
--- @return string outcome, string severity of the event it starts
function MSWForecastEngine:rollOutcome(confidence)
    if math.random() * 100 < confidence then
        local outcome = MSWRandom.weightedPick(self.fc.settings.outcomes) or "asForecast"
        return outcome, MSWForecastDef.SEVERITY_OF[outcome] or "medium"
    end
    return "backfire", MSWRandom.weightedPick(self.fc.settings.backfire) or "low"
end

--- Turn a forecast into its verdict: the message to show and the events to
--- start. Does not start anything itself.
--- @param forced table|nil { outcome = string } to skip the roll (console, tests)
function MSWForecastEngine:buildVerdict(forecast, forced)
    local def = MSWForecastDef.findById(self.fc, forecast.forecastId)
    local variant = def ~= nil and MSWForecastDef.findVariant(def, forecast.variantId) or nil
    if variant == nil then return nil end

    local outcome, severity
    if forced ~= nil and forced.outcome ~= nil then
        outcome = forced.outcome
        severity = MSWForecastDef.SEVERITY_OF[outcome] or "medium"
    else
        outcome, severity = self:rollOutcome(forecast.confidence or 70)
    end

    local titleKey, textKey = MSWForecastDef.messageKeys(def.id, variant.id, outcome)
    local verdict = {
        forecast = forecast, def = def, variant = variant,
        outcome = outcome, titleKey = titleKey, textKey = textKey, events = {},
    }
    verdict.events[1] = {
        eventId = outcome == "backfire" and variant.backfire or variant.event,
        severity = severity,
        durationMonths = forecast.durationMonths,
        titleKey = titleKey, textKey = textKey, forecastId = def.id,
    }
    -- A companion event only when the forecast's own cause really happened: a
    -- severe winter raises energy, a feed shortage for another reason does not.
    if variant.extraEvent ~= nil
       and (outcome == "asForecast" or outcome == "stronger" or outcome == "milder") then
        verdict.events[2] = { eventId = variant.extraEvent, severity = severity,
                              forecastId = def.id, companion = true }
    end
    return verdict
end

--- Verdicts that fall due today. The forecasts leave the open list.
function MSWForecastEngine:collectDue(day)
    local due, kept = {}, {}
    for _, forecast in ipairs(self.open) do
        if forecast:isDue(day) then
            local verdict = self:buildVerdict(forecast)
            if verdict ~= nil then due[#due + 1] = verdict end
        else
            kept[#kept + 1] = forecast
        end
    end
    self.open = kept
    return due
end

function MSWForecastEngine:getOpen()
    return self.open
end

function MSWForecastEngine:clear()
    self.open = {}
    self.lastStartDay = nil
end

-- ---- persistence -----------------------------------------------------------

function MSWForecastEngine:saveToXML(xmlFile, key)
    if self.lastStartDay ~= nil then
        setXMLFloat(xmlFile, key .. "#lastStartDay", self.lastStartDay)
    end
    setXMLFloat(xmlFile, key .. "#tipShown", self.tipShown and 1 or 0)
    for i, forecast in ipairs(self.open) do
        forecast:saveToXML(xmlFile, ("%s.open(%d)"):format(key, i - 1))
    end
end

function MSWForecastEngine:loadFromXML(xmlFile, key)
    self.lastStartDay = getXMLFloat(xmlFile, key .. "#lastStartDay")
    self.tipShown = (getXMLFloat(xmlFile, key .. "#tipShown") or 0) >= 0.5
    self.open = {}
    local i = 0
    while true do
        local okey = ("%s.open(%d)"):format(key, i)
        if not hasXMLProperty(xmlFile, okey) then break end
        local forecast = MSWActiveForecast.loadFromXML(xmlFile, okey)
        -- A forecast removed from the config since the save is dropped.
        if forecast ~= nil and MSWForecastDef.findById(self.fc, forecast.forecastId) ~= nil then
            self.open[#self.open + 1] = forecast
        end
        i = i + 1
    end
end
