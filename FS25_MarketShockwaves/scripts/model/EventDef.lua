--[[
    EventDef — loads config/events.xml into event definitions.

    Definitions are static templates. Firing one produces an ActiveEvent (a
    rolled instance with concrete magnitude, duration and curve shape).

    Month weights are stored NORMALISED (they sum to 1). That is what makes the
    season control *when* an event fires without changing *how often* — the
    annual rate comes from baseWeight alone. See DESIGN.md.
]]

MSWEventDef = {}
local MSWEventDef_mt = Class(MSWEventDef)

local MONTH_KEYS = { "jan", "feb", "mar", "apr", "may", "jun",
                     "jul", "aug", "sep", "oct", "nov", "dec" }

local SEVERITY_CLASSES = { "low", "medium", "high" }

--- Split a whitespace-separated product list into an array.
local function splitProducts(s)
    local out = {}
    if s == nil then return out end
    for word in string.gmatch(s, "%S+") do
        out[#out + 1] = word
    end
    return out
end

--- @return table config { eventsPerYear, severityChances, ripple, events = {defs} }
function MSWEventDef.loadAll(path, log)
    local config = {
        eventsPerYear   = 2.0,
        severityChances = { low = 0.60, medium = 0.30, high = 0.10 },
        ripple          = { lagMonths = 1.0, passThrough = 0.60 },
        events          = {},
    }

    local xml = loadXMLFile("mswEvents", path)
    if xml == nil or xml == 0 then
        log:error("EventDef: could not load " .. tostring(path))
        return config
    end

    local root = "marketShockwaves"

    config.eventsPerYear = getXMLFloat(xml, root .. ".settings.eventsPerYear#value")
                           or config.eventsPerYear

    for _, cls in ipairs(SEVERITY_CLASSES) do
        local v = getXMLFloat(xml, root .. ".settings.severityChances#" .. cls)
        if v ~= nil then config.severityChances[cls] = v end
    end

    config.ripple.lagMonths = getXMLFloat(xml, root .. ".settings.ripple#lagMonths")
                              or config.ripple.lagMonths
    config.ripple.passThrough = getXMLFloat(xml, root .. ".settings.ripple#passThrough")
                                or config.ripple.passThrough

    local i = 0
    while true do
        local key = ("%s.events.event(%d)"):format(root, i)
        if not hasXMLProperty(xml, key) then break end
        config.events[#config.events + 1] = MSWEventDef.readEvent(xml, key, i, config, log, false)
        i = i + 1
    end

    delete(xml)

    log:info(("EventDef: loaded %d events, eventsPerYear=%.2f")
        :format(#config.events, config.eventsPerYear))
    return config
end

--- Read the events a forecast can start (config/forecasts.xml, under
--- `<outcomeEvents>`). Same schema as a random event, but the scheduler never
--- rolls them: they have no weight and no season, and only a forecast's verdict
--- starts one. Kept in their own list so nothing that walks `config.events`
--- (the scheduler, the diagnostics, the documentation tools) ever sees them.
function MSWEventDef.loadForecastEvents(xml, root, config, log)
    config.forecastEvents = {}
    local i = 0
    while true do
        local key = ("%s.outcomeEvents.event(%d)"):format(root, i)
        if not hasXMLProperty(xml, key) then break end
        config.forecastEvents[#config.forecastEvents + 1] =
            MSWEventDef.readEvent(xml, key, i, config, log, true)
        i = i + 1
    end
    return config.forecastEvents
end

--- Read one `<event>` element.
--- @param forecastOnly boolean true for an event only a forecast may start
function MSWEventDef.readEvent(xml, key, i, config, log, forecastOnly)
    do
        local def = setmetatable({}, MSWEventDef_mt)
        def.forecastOnly = forecastOnly == true
        def.id         = getXMLString(xml, key .. "#id") or ("event" .. i)
        def.type       = getXMLString(xml, key .. "#type") or "neutral"
        -- Which settings-menu group switches this event on and off.
        def.category   = getXMLString(xml, key .. "#category") or "other"
        -- Mutual-exclusion group. Two events sharing a subtype can never run at
        -- the same time: a biofuel boom on top of a biofuel glut is a
        -- contradiction, not a compounding shock. Defaults to the event's own
        -- id, so an event without a subtype blocks only itself - exactly the
        -- self-overlap rule that already applied.
        def.subtype    = getXMLString(xml, key .. "#subtype") or def.id
        def.baseWeight = getXMLFloat(xml, key .. "#baseWeight") or 1.0
        if forecastOnly then def.baseWeight = 0 end
        def.affects    = splitProducts(getXMLString(xml, key .. ".affects"))
        -- Products this event moves the OTHER way, at `scale` times the swing.
        -- A consumer trend has a winner and a loser: shoppers who fill their
        -- baskets with fresh food leave the tins on the shelf. These are direct
        -- products (no lag), they never feed a chain, and the scale is what
        -- keeps the adverse side at the usual downtuned strength.
        def.opposite      = splitProducts(getXMLString(xml, key .. ".opposite"))
        def.oppositeScale = getXMLFloat(xml, key .. ".opposite#scale") or 0.5
        -- Share of the event's length the opposite side lasts. Below 1 it
        -- recovers sooner than the main side: a new sawmill keeps timber dear
        -- for a year, but its price war on sawn wood burns out earlier.
        def.oppositeDurationShare = getXMLFloat(xml, key .. ".opposite#durationShare") or 1.0

        -- ---- month weights, normalised to shares -------------------------
        def.monthShare = {}
        local total = 0
        local raw = {}
        for m, mk in ipairs(MONTH_KEYS) do
            local w = getXMLFloat(xml, key .. ".monthWeights#" .. mk) or 0
            if w < 0 then w = 0 end
            raw[m] = w
            total = total + w
        end
        for m = 1, 12 do
            def.monthShare[m] = (total > 0) and (raw[m] / total) or 0
        end
        if total <= 0 and not forecastOnly then
            log:warn(("EventDef: event '%s' has no positive month weights; it can never fire")
                :format(def.id))
        end

        -- ---- chains ------------------------------------------------------
        -- Stored as from -> { to, ... }. The single-driver rule is enforced
        -- here: a product may only be the target of one chain per event.
        def.chains = {}
        local seenTargets = {}
        local c = 0
        while true do
            local ckey = ("%s.chains.chain(%d)"):format(key, c)
            if not hasXMLProperty(xml, ckey) then break end
            local from = getXMLString(xml, ckey .. "#from")
            local to   = getXMLString(xml, ckey .. "#to")
            local lag  = getXMLFloat(xml, ckey .. "#lagMonths")
            local pt   = getXMLFloat(xml, ckey .. "#passThrough")
            local tier = getXMLInt(xml,   ckey .. "#tier")

            if from ~= nil and to ~= nil then
                if seenTargets[to] then
                    log:warn(("EventDef: '%s' drives '%s' more than once — ignoring the "
                           .. "duplicate (single-driver rule)"):format(def.id, to))
                else
                    seenTargets[to] = true
                    def.chains[from] = def.chains[from] or {}
                    table.insert(def.chains[from], {
                        to = to,
                        tier = tier or 1,
                        lagMonths = lag or config.ripple.lagMonths,
                        passThrough = pt or config.ripple.passThrough,
                    })
                end
            end
            c = c + 1
        end

        -- ---- severities --------------------------------------------------
        def.severities = {}
        local s = 0
        while true do
            local skey = ("%s.severities.severity(%d)"):format(key, s)
            if not hasXMLProperty(xml, skey) then break end
            local cls = getXMLString(xml, skey .. "#class")
            if cls ~= nil then
                def.severities[cls] = {
                    priceFactorMin    = getXMLFloat(xml, skey .. "#priceFactorMin") or 1.0,
                    priceFactorMax    = getXMLFloat(xml, skey .. "#priceFactorMax") or 1.0,
                    durationMonthsMin = getXMLFloat(xml, skey .. "#durationMonthsMin") or 3,
                    durationMonthsMax = getXMLFloat(xml, skey .. "#durationMonthsMax") or 6,
                    peakPosMin        = getXMLFloat(xml, skey .. "#peakPosMin") or 0.3,
                    peakPosMax        = getXMLFloat(xml, skey .. "#peakPosMax") or 0.5,
                    riseExpMin        = getXMLFloat(xml, skey .. "#riseExpMin") or 1.0,
                    riseExpMax        = getXMLFloat(xml, skey .. "#riseExpMax") or 1.5,
                    hold              = getXMLFloat(xml, skey .. "#hold") or 0.6,
                    correctionMonths  = getXMLFloat(xml, skey .. "#correctionMonths") or 1.0,
                    jitter            = getXMLFloat(xml, skey .. "#jitter") or 0.02,
                    rippleDepth       = getXMLInt(xml,   skey .. "#rippleDepth") or 1,
                    rippleScale       = getXMLFloat(xml, skey .. "#rippleScale") or 1.0,
                }
            end
            s = s + 1
        end

        return def
    end
end

--- Find a definition by id: a random event, or one only a forecast starts.
function MSWEventDef.findById(config, id)
    for _, def in ipairs(config.events) do
        if def.id == id then return def end
    end
    for _, def in ipairs(config.forecastEvents or {}) do
        if def.id == id then return def end
    end
    return nil
end
