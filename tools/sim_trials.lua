--[[
    A few short playthroughs, written out as a timeline: which year and month
    each event and forecast lands in, and which products it moves.

    Uses the mod's own model and config at the shipped default settings, one
    day per month, starting in January of year 1.

    Run:  lua tools/sim_trials.lua [trials] [years] [seed]     (default 5 5 1)
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

local TRIALS = tonumber(arg and arg[1]) or 5
local YEARS  = tonumber(arg and arg[2]) or 5
local SEED   = tonumber(arg and arg[3]) or 1
local DPM = 1
local SETTINGS = { eventsPerYear = 2.0, minMonthsBetweenEvents = 2, maxConcurrentEvents = 3 }
local SCALERS = { intensity = 1.0, duration = 1.0, supplyChainDepth = 3 }
local MONTHS = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }

local l10n = {}
do
    local handle = parseXML(MOD .. "l10n/l10n_en.xml")
    for _, child in ipairs(handle.tree.children[1].children) do
        if child.attrs.name ~= nil then l10n[child.attrs.name] = child.attrs.text end
    end
end

--- "wheat, oat (+6 down the chain)", with the direction and peak of the move.
local function describe(ev, def)
    local lead = {}
    for _, name in ipairs(def.affects) do lead[#lead + 1] = name:lower() end
    local followers = #ev:getProducts() - #def.affects - #(def.opposite or {})
    local text = ("%s %+.0f%%"):format(table.concat(lead, ", "), (ev.peakFactor - 1) * 100)
    if #(def.opposite or {}) > 0 then
        local opp = {}
        for _, name in ipairs(def.opposite) do opp[#opp + 1] = name:lower() end
        text = text .. ("; opposite way at %.0f%%: %s")
            :format((def.oppositeScale or 0.5) * 100, table.concat(opp, ", "))
    end
    if followers > 0 then
        local chain = {}
        for _, name in ipairs(ev:getProducts()) do
            local isLead = false
            for _, a in ipairs(def.affects) do if a == name then isLead = true end end
            for _, o in ipairs(def.opposite or {}) do if o == name then isLead = true end end
            if not isLead then chain[#chain + 1] = name:lower() end
        end
        text = text .. "; follows: " .. table.concat(chain, ", ")
    end
    return text, ev.durationDays
end

for trial = 1, TRIALS do
    math.randomseed(SEED * 1000 + trial)
    local config = MSWEventDef.loadAll(MOD .. "config/events.xml", log)
    local fc = MSWForecastDef.loadAll(MOD .. "config/forecasts.xml", config, log)
    local scheduler = MSWEventScheduler.new(config, log)
    local engine = MSWForecastEngine.new(fc, config,
        function(name) return MSWCropCalendar.BASE[name] end, log)
    local model = MSWPriceModel.new(function() return 1 end, log)

    print(("\n=== Trial %d ==="):format(trial))
    local lastEventDay, lastYear = nil, 0

    local function line(day, text)
        local year = math.floor((day - 1) / 12) + 1
        local month = (day - 1) % 12 + 1
        if year ~= lastYear then
            print(("Year %d"):format(year))
            lastYear = year
        end
        print(("  %s  %s"):format(MONTHS[month], text))
    end

    local function start(def, severity, day, opts)
        if model:findActiveBySubtype(def.subtype or def.id, day) ~= nil then return nil end
        local ev = MSWActiveEvent.new(def, severity, day, DPM, SCALERS, opts)
        model:addEvent(ev)
        return ev
    end

    for day = 1, YEARS * 12 do
        local month = (day - 1) % 12 + 1
        model:pruneExpired(day)

        for _, verdict in ipairs(engine:collectDue(day)) do
            local title = l10n[verdict.titleKey] or verdict.outcome
            for _, item in ipairs(verdict.events) do
                local def = MSWEventDef.findById(config, item.eventId)
                local ev = start(def, item.severity, day,
                                 { durationMonths = item.durationMonths, forecastId = item.forecastId })
                if ev ~= nil then
                    local what, days = describe(ev, def)
                    if item.companion then
                        line(day, ("   + EVENT with it: %s [%s], %d months: %s")
                            :format(l10n[("msw_%s_%s_title"):format(def.id, item.severity)] or def.id,
                                    item.severity, days, what))
                    else
                        line(day, ("VERDICT (%s) \"%s\", %d months: %s")
                            :format(verdict.outcome, title, days, what))
                    end
                end
            end
        end

        local entry = engine:rollStart(day, month, DPM, function(_, variant)
            local def = MSWEventDef.findById(config, variant.event)
            return model:findActiveBySubtype(def.subtype, day) ~= nil
        end)
        if entry ~= nil then
            local f = engine:start(entry.def, entry.variant, entry.timing, day, month, DPM,
                                   { intensity = 1 })
            local titleKey = MSWForecastDef.messageKeys(entry.def.id, entry.variant.id, "open")
            local leads = {}
            for _, name in ipairs(f.products) do leads[#leads + 1] = name:lower() end
            local vDay = f.verdictDay
            line(day, ("FORECAST \"%s\" (confidence %d): %s; verdict %s year %d")
                :format(l10n[titleKey] or entry.def.id, f.confidence, table.concat(leads, ", "),
                        MONTHS[(vDay - 1) % 12 + 1], math.floor((vDay - 1) / 12) + 1))
        end

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
            if fired[1] ~= nil then
                local ev = start(fired[1].def, fired[1].severity, day)
                if ev ~= nil then
                    lastEventDay = day
                    local what, days = describe(ev, fired[1].def)
                    line(day, ("EVENT \"%s\" [%s], %d months: %s")
                        :format(l10n[("msw_%s_%s_title"):format(fired[1].def.id, fired[1].severity)]
                                or fired[1].def.id, fired[1].severity, days, what))
                end
            end
        end
    end
    local stillOpen = {}
    for _, f in ipairs(engine:getOpen()) do
        stillOpen[#stillOpen + 1] = f.forecastId .. "/" .. f.variantId
    end
    if #stillOpen > 0 then
        print("  (still open after year " .. YEARS .. ": " .. table.concat(stillOpen, ", ") .. ")")
    end
end
