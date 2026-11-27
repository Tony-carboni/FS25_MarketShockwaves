--[[
    Do forecasts create unwanted price spikes on top of the random events?

    Runs the mod's own model (real config, real curves, real stacking) for many
    years at one day per month, twice from the same seed: once with random
    events only, once with forecasts as well. The daily loop mirrors
    MarketShockwaves:onNewDay.

    Reported per run: how often any product sits beyond a threshold, the most
    extreme prices seen, and which sources were behind them.

    Run:  lua tools/sim_forecast_spikes.lua [years]      (default 30000)
]]

dofile("tools/xml_stub.lua")

local MOD = "FS25_MarketShockwaves/"
for _, rel in ipairs({ "lib/Random.lua", "model/Curve.lua", "model/EventDef.lua",
                       "model/ActiveEvent.lua", "model/EventScheduler.lua",
                       "model/PriceModel.lua", "model/CropCalendar.lua",
                       "model/Forecast.lua" }) do
    dofile(MOD .. "scripts/" .. rel)
end

local log = { info = function() end, debug = function() end, warn = function() end,
              error = function(_, m) print("ERROR " .. tostring(m)) end }

local YEARS = tonumber(arg and arg[1]) or 30000
local DPM = 1
local SETTINGS = { eventsPerYear = 2.0, minMonthsBetweenEvents = 2, maxConcurrentEvents = 3 }
local SCALERS = { intensity = 1.0, duration = 1.0, supplyChainDepth = 3 }
local UP = { 0.50, 0.75, 1.00, 1.50 }
local DOWN = { -0.30, -0.40, -0.50 }

local function run(withForecasts, seed)
    math.randomseed(seed)
    local config = MSWEventDef.loadAll(MOD .. "config/events.xml", log)
    local fc = MSWForecastDef.loadAll(MOD .. "config/forecasts.xml", config, log)
    local scheduler = MSWEventScheduler.new(config, log)
    local engine = MSWForecastEngine.new(fc, config,
        function(name) return MSWCropCalendar.BASE[name] end, log)

    local names, indexOf = {}, {}
    local model = MSWPriceModel.new(function(name)
        if indexOf[name] == nil then
            names[#names + 1] = name
            indexOf[name] = #names
        end
        return indexOf[name]
    end, log)
    if withForecasts then model:setExtraSources(function() return engine:getOpen() end) end

    local stats = {
        productDays = 0, up = {}, down = {}, yearsUp = {}, peak = {}, trough = {},
        events = 0, forecasts = 0, verdicts = 0, outcomes = {},
        overlapDays = 0, forecastEventDays = 0, top = {},
    }
    for _, t in ipairs(UP) do stats.up[t] = 0; stats.yearsUp[t] = 0 end
    for _, t in ipairs(DOWN) do stats.down[t] = 0 end

    local function start(def, severity, day, opts)
        if model:findActiveBySubtype(def.subtype or def.id, day) ~= nil then return nil end
        local ev = MSWActiveEvent.new(def, severity, day, DPM, SCALERS, opts)
        model:addEvent(ev)
        return ev
    end

    local lastEventDay = nil
    local yearFlag = {}
    for day = 1, YEARS * 12 * DPM do
        local month = math.floor((day - 1) / DPM) % 12 + 1
        if month == 1 and day > 1 then
            for _, t in ipairs(UP) do
                if yearFlag[t] then stats.yearsUp[t] = stats.yearsUp[t] + 1 end
            end
            yearFlag = {}
        end
        model:pruneExpired(day)

        if withForecasts then
            for _, verdict in ipairs(engine:collectDue(day)) do
                stats.verdicts = stats.verdicts + 1
                stats.outcomes[verdict.outcome] = (stats.outcomes[verdict.outcome] or 0) + 1
                for _, item in ipairs(verdict.events) do
                    start(MSWEventDef.findById(config, item.eventId), item.severity, day,
                          { durationMonths = item.durationMonths, forecastId = item.forecastId })
                end
            end
            local entry = engine:rollStart(day, month, DPM, function(_, variant)
                local def = MSWEventDef.findById(config, variant.event)
                return model:findActiveBySubtype(def.subtype, day) ~= nil
            end)
            if entry ~= nil then
                engine:start(entry.def, entry.variant, entry.timing, day, month, DPM, { intensity = 1 })
                stats.forecasts = stats.forecasts + 1
            end
        end

        -- Random events: ceiling (forecast events do not count), cooldown,
        -- exclusion by subtype, one per day.
        local random = 0
        for _, ev in ipairs(model:getActiveEvents()) do
            if ev.forecastId == nil then random = random + 1 end
        end
        local cooled = lastEventDay == nil
                       or day - lastEventDay >= SETTINGS.minMonthsBetweenEvents * DPM
        if random < SETTINGS.maxConcurrentEvents and cooled then
            local fired = scheduler:rollForDay(month, DPM, SETTINGS.eventsPerYear, function(def)
                return model:findActiveBySubtype(def.subtype or def.id, day) ~= nil
            end)
            if fired[1] ~= nil and start(fired[1].def, fired[1].severity, day) ~= nil then
                lastEventDay = day
                stats.events = stats.events + 1
            end
        end

        model:invalidate()
        model:rebuild(day)

        local hasForecastEvent = false
        for _, ev in ipairs(model:getActiveEvents()) do
            if ev.forecastId ~= nil then hasForecastEvent = true end
        end
        if hasForecastEvent then stats.forecastEventDays = stats.forecastEventDays + 1 end

        for index, factor in pairs(model.modifiers) do
            local d = factor - 1
            stats.productDays = stats.productDays + 1
            for _, t in ipairs(UP) do
                if d >= t then
                    stats.up[t] = stats.up[t] + 1
                    yearFlag[t] = true
                end
            end
            for _, t in ipairs(DOWN) do
                if d <= t then stats.down[t] = stats.down[t] + 1 end
            end
            local name = names[index]
            if stats.peak[name] == nil or factor > stats.peak[name] then stats.peak[name] = factor end
            if stats.trough[name] == nil or factor < stats.trough[name] then stats.trough[name] = factor end

            -- Remember what was behind the largest rises.
            if d >= 1.0 then
                local sources, viaForecast = {}, false
                for _, src in ipairs(model:getSources()) do
                    if src:getFactorFor(name, day) > 1.01 then
                        sources[#sources + 1] = src.eventId and (src.eventId .. "/" .. src.severity)
                                                or ("premove:" .. src.forecastId)
                        if src.forecastId ~= nil then viaForecast = true end
                    end
                end
                table.sort(sources)
                local key = name .. " <- " .. table.concat(sources, " + ")
                local row = stats.top[key]
                if row == nil then
                    row = { days = 0, max = 0, viaForecast = viaForecast }
                    stats.top[key] = row
                end
                row.days = row.days + 1
                if factor > row.max then row.max = factor end
            end
        end
    end
    stats.names = names
    stats.days = YEARS * 12 * DPM
    return stats
end

local function report(title, s)
    print(("\n== %s =="):format(title))
    print(("  %.2f random events/year, %.2f forecasts/year, %.2f verdicts/year")
        :format(s.events / YEARS, s.forecasts / YEARS, s.verdicts / YEARS))
    if s.verdicts > 0 then
        local parts = {}
        for _, o in ipairs({ "asForecast", "stronger", "milder", "wrongReason", "backfire" }) do
            parts[#parts + 1] = ("%s %.1f%%"):format(o, (s.outcomes[o] or 0) / s.verdicts * 100)
        end
        print("  outcomes: " .. table.concat(parts, ", "))
        print(("  a forecast's event is running on %.0f%% of days")
            :format(s.forecastEventDays / s.days * 100))
    end
    for _, t in ipairs(UP) do
        print(("  some product at or above %+4.0f%%: %8.4f%% of moving product-days; %6.2f%% of years")
            :format(t * 100, s.up[t] / s.productDays * 100, s.yearsUp[t] / YEARS * 100))
    end
    for _, t in ipairs(DOWN) do
        print(("  some product at or below %+4.0f%%: %8.4f%% of moving product-days")
            :format(t * 100, s.down[t] / s.productDays * 100))
    end
end

local function extremes(s, n)
    local rows = {}
    for name, factor in pairs(s.peak) do rows[#rows + 1] = { name = name, factor = factor } end
    table.sort(rows, function(a, b) return a.factor > b.factor end)
    local out = {}
    for i = 1, math.min(n, #rows) do
        out[#out + 1] = ("%s %+.0f%%"):format(rows[i].name, (rows[i].factor - 1) * 100)
    end
    return table.concat(out, ", ")
end

local function lows(s, n)
    local rows = {}
    for name, factor in pairs(s.trough) do rows[#rows + 1] = { name = name, factor = factor } end
    table.sort(rows, function(a, b) return a.factor < b.factor end)
    local out = {}
    for i = 1, math.min(n, #rows) do
        out[#out + 1] = ("%s %+.0f%%"):format(rows[i].name, (rows[i].factor - 1) * 100)
    end
    return table.concat(out, ", ")
end

print(("simulating %d years at %d day(s) per month, twice"):format(YEARS, DPM))
local base = run(false, 20261127)
local both = run(true, 20261127)

report("random events only", base)
print("  highest ever: " .. extremes(base, 8))
print("  lowest ever:  " .. lows(base, 8))
report("random events and forecasts", both)
print("  highest ever: " .. extremes(both, 8))
print("  lowest ever:  " .. lows(both, 8))

print("\n== products whose all-time high or low moved most with forecasts ==")
local diffs = {}
for name, factor in pairs(both.peak) do
    local before = base.peak[name] or 1
    diffs[#diffs + 1] = { name = name, before = before, after = factor,
                          lowBefore = base.trough[name] or 1, lowAfter = both.trough[name] or 1 }
end
table.sort(diffs, function(a, b) return (a.after - a.before) > (b.after - b.before) end)
for i = 1, math.min(14, #diffs) do
    local d = diffs[i]
    print(("  %-18s high %+5.0f%% -> %+5.0f%%    low %+5.0f%% -> %+5.0f%%")
        :format(d.name, (d.before - 1) * 100, (d.after - 1) * 100,
                (d.lowBefore - 1) * 100, (d.lowAfter - 1) * 100))
end

print("\n== what was behind rises of +100% or more, with forecasts (days over 30,000 years) ==")
local tops = {}
for key, row in pairs(both.top) do tops[#tops + 1] = { key = key, row = row } end
table.sort(tops, function(a, b) return a.row.days > b.row.days end)
local viaForecastDays, allDays = 0, 0
for _, t in ipairs(tops) do
    allDays = allDays + t.row.days
    if t.row.viaForecast then viaForecastDays = viaForecastDays + t.row.days end
end
print(("  %d product-days at +100%% or more; %d of them (%.0f%%) involve a forecast")
    :format(allDays, viaForecastDays, allDays > 0 and viaForecastDays / allDays * 100 or 0))
local shown = 0
for _, t in ipairs(tops) do
    if t.row.viaForecast and shown < 15 then
        shown = shown + 1
        print(("  %5d days, max %+4.0f%%  %s"):format(t.row.days, (t.row.max - 1) * 100, t.key))
    end
end
