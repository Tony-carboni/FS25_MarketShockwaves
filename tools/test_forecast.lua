--[[
    Offline tests for forecasts (speculation), the crop calendar and the
    message history.

    Unlike test_model.lua, this harness LOADS THE REAL CONFIG: a small XML
    reader stands in for the engine's, so config/forecasts.xml, config/events.xml
    and the l10n file go through the mod's own loaders. A forecast whose event
    is misspelt, or whose message is missing, fails here and not in the game.

      1. the crop calendar: walking a growth table from sowing to harvest
      2. the config loads, and every forecast has its events and its messages
      3. timing from the base calendar
      4. the actionability check: a forecast the player cannot act on is refused
      5. announcing a forecast: dates, pre-move size and direction
      6. the pre-move: flat, then a small move, and part of the price model
      7. the verdict: which event each outcome starts
      8. the stated confidence is the true chance
      9. about one forecast a year, never two of a kind
     10. events a forecast starts: exact length, year-long shape, early recovery
     11. the random scheduler never rolls a forecast's event
     12. the history: order, cap, status, text
     13. saving and loading
     14. the hub's market view: pre-moves and verdict news
     15. what the player pays: shop items, helper refills, the fuel pump

    Run:  lua tools/test_forecast.lua
]]

-- ---- engine stubs, and a small XML reader standing in for the engine's ---
dofile("tools/xml_stub.lua")

-- ---- load the mod's pure-logic modules ------------------------------------
local MOD = "FS25_MarketShockwaves/"
local function load(rel) dofile(MOD .. "scripts/" .. rel) end
load("lib/Random.lua")
load("model/Curve.lua")
load("model/EventDef.lua")
load("model/ActiveEvent.lua")
load("model/EventScheduler.lua")
load("model/PriceModel.lua")
load("model/CropCalendar.lua")
load("model/Forecast.lua")
load("model/History.lua")
load("model/MarketView.lua")

local warnings = {}
local log = {
    info = function() end, debug = function() end,
    warn = function(_, m) warnings[#warnings + 1] = tostring(m) end,
    error = function(_, m) print("ERROR: " .. tostring(m)) end,
}

local pass, fail = 0, 0
local function check(label, cond, detail)
    if cond then pass = pass + 1; print(("  PASS  %s"):format(label))
    else fail = fail + 1; print(("  FAIL  %s  %s"):format(label, detail or "")) end
end
local function near(a, b, tol) return a ~= nil and b ~= nil and math.abs(a - b) <= (tol or 1e-9) end
local function list(t) return table.concat(t, ",") end
local function keys(set)
    local out = {}
    for k in pairs(set) do out[#out + 1] = k end
    table.sort(out)
    return list(out)
end

-- ===========================================================================
print("\n[1] crop calendar: walking a growth table")

check("period 1 is March, period 11 is January",
      MSWCropCalendar.periodToMonth(1) == 3 and MSWCropCalendar.periodToMonth(10) == 12
      and MSWCropCalendar.periodToMonth(11) == 1 and MSWCropCalendar.periodToMonth(12) == 2)

-- An invented winter crop: sown in periods 7-8 (September, October), five
-- growth steps, ready in early summer, withering after two harvest months.
local function period(allowed, updates)
    local out = { plantingAllowed = allowed, updates = {} }
    for _, u in ipairs(updates or {}) do out.updates[#out.updates + 1] = { from = u[1], to = u[2] } end
    return out
end
local winterCrop = {
    sownState = "seed", harvestStates = { ripe = true },
    periods = {
        period(false, { { "small", "mid" } }),                    -- 1  Mar
        period(false, { { "mid", "tall" } }),                     -- 2  Apr
        period(false, { { "tall", "heading" } }),                 -- 3  May
        period(false, { { "heading", "ripe" } }),                 -- 4  Jun
        period(false, { { "heading", "ripe" } }),                 -- 5  Jul
        period(false, { { "ripe", "withered" } }),                -- 6  Aug
        period(true,  { { "seed", "small" } }),                   -- 7  Sep
        period(true,  { { "seed", "small" } }),                   -- 8  Oct
        period(false), period(false), period(false),              -- 9-11
        period(false),                                            -- 12 Feb
    },
}
local wc = MSWCropCalendar.fromGrowthTable(winterCrop)
check("sowing months are read from the planting periods",
      wc ~= nil and list(wc.sow) == "9,10" and wc.sowFirst == 9, wc and list(wc.sow))
check("a growth step applies at the END of its period: ready in June means harvest from July",
      wc ~= nil and wc.harvestFirst == 7, wc and tostring(wc.harvestFirst))
check("harvest lasts until the plant withers",
      wc ~= nil and list(wc.harvest) == "7,8", wc and list(wc.harvest))

local allYear = { sownState = "seed", harvestStates = { ripe = true }, periods = {} }
for p = 1, 12 do allYear.periods[p] = period(true, { { "seed", "ripe" } }) end
check("a crop sowable all year gives no calendar", MSWCropCalendar.fromGrowthTable(allYear) == nil)

local neverRipe = { sownState = "seed", harvestStates = { ripe = true }, periods = {} }
for p = 1, 12 do neverRipe.periods[p] = period(p == 1, { { "seed", "small" } }) end
check("a crop that never reaches harvest gives no calendar",
      MSWCropCalendar.fromGrowthTable(neverRipe) == nil)

-- Sowing window that wraps the year end: periods 12 and 1 (February, March).
local wrap = { sownState = "seed", harvestStates = { ripe = true }, periods = {} }
for p = 1, 12 do wrap.periods[p] = period(p == 12 or p == 1, { { "seed", "small" }, { "small", "ripe" } }) end
local wr = MSWCropCalendar.fromGrowthTable(wrap)
check("a sowing window across the year end starts at its first month",
      wr ~= nil and wr.sowFirst == 2 and list(wr.sow) == "2,3", wr and list(wr.sow))

check("the fallback table knows every crop a forecast is timed by",
      MSWCropCalendar.BASE.WHEAT ~= nil and MSWCropCalendar.BASE.CANOLA ~= nil
      and MSWCropCalendar.BASE.MAIZE ~= nil and MSWCropCalendar.BASE.POTATO ~= nil)

-- ===========================================================================
print("\n[2] the real config loads, with its events and messages")

local config = MSWEventDef.loadAll(MOD .. "config/events.xml", log)
local randomCount = #config.events
local fc = MSWForecastDef.loadAll(MOD .. "config/forecasts.xml", config, log)

local variantCount = 0
for _, def in ipairs(fc.forecasts) do variantCount = variantCount + #def.variants end
check("six forecasts, twelve variants", #fc.forecasts == 6 and variantCount == 12,
      ("%d forecasts, %d variants"):format(#fc.forecasts, variantCount))
check("fourteen outcome events, kept apart from the random ones",
      #config.forecastEvents == 14 and #config.events == randomCount,
      tostring(#config.forecastEvents))
check("the confidence never starts below 70",
      fc.settings.confidence[70] > 0 and fc.settings.confidence[60] == nil)

local l10n = {}
do
    local handle = parseXML(MOD .. "l10n/l10n_en.xml")
    for _, child in ipairs(handle.tree.children[1].children) do
        if child.attrs.name ~= nil then l10n[child.attrs.name] = child.attrs.text end
    end
end
local i18n = {
    hasText = function(_, key) return l10n[key] ~= nil end,
    getText = function(_, key) return l10n[key] end,
}

local missingEvents, missingTexts, badPlaceholders = {}, {}, {}
for _, def in ipairs(fc.forecasts) do
    for _, variant in ipairs(def.variants) do
        for _, id in ipairs({ variant.event, variant.backfire, variant.extraEvent }) do
            if MSWEventDef.findById(config, id) == nil then missingEvents[#missingEvents + 1] = id end
        end
        for _, stage in ipairs({ "open", "asForecast", "stronger", "milder", "wrongReason", "backfire" }) do
            local titleKey, textKey = MSWForecastDef.messageKeys(def.id, variant.id, stage)
            if l10n[titleKey] == nil or l10n[textKey] == nil then
                missingTexts[#missingTexts + 1] = textKey
            else
                local _, n = l10n[textKey]:gsub("%%s", "")
                if n ~= (stage == "open" and 1 or 0) then badPlaceholders[#badPlaceholders + 1] = textKey end
            end
        end
    end
end
check("every variant's outcome events are defined", #missingEvents == 0, list(missingEvents))
check("every variant has an opening and five outcome messages", #missingTexts == 0, list(missingTexts))
check("only the opening carries the confidence placeholder", #badPlaceholders == 0, list(badPlaceholders))
check("the three confidence lines exist",
      l10n[MSWForecastDef.confidenceKey(70)] ~= nil and l10n[MSWForecastDef.confidenceKey(80)] ~= nil
      and l10n[MSWForecastDef.confidenceKey(90)] ~= nil)

-- No numbers in what the player reads: sizes and lengths stay unknown.
local withDigits = {}
for key, value in pairs(l10n) do
    if key:match("^msw_fc_") and not key:match("^msw_fc_confidence") and value:match("%d") then
        withDigits[#withDigits + 1] = key
    end
end
check("no forecast message states a number", #withDigits == 0, list(withDigits))

-- Both sides of a forecast share a subtype, so they can never run together.
local mirrored = true
for _, def in ipairs(fc.forecasts) do
    for _, variant in ipairs(def.variants) do
        local a = MSWEventDef.findById(config, variant.event)
        local b = MSWEventDef.findById(config, variant.backfire)
        if a == nil or b == nil or a.subtype ~= b.subtype or a.id == b.id then mirrored = false end
    end
end
check("an outcome and its backfire are different events of one family", mirrored)

local function direction(eventId)
    local sev = MSWEventDef.findById(config, eventId).severities.medium
    return (sev.priceFactorMin + sev.priceFactorMax) / 2 >= 1 and 1 or -1
end
local opposed = true
for _, def in ipairs(fc.forecasts) do
    for _, variant in ipairs(def.variants) do
        if direction(variant.event) == direction(variant.backfire) then opposed = false end
    end
end
check("a backfire moves the lead products the other way", opposed)

-- ===========================================================================
print("\n[3] timing from the base calendar")

local function baseCalendar(name) return MSWCropCalendar.BASE[name] end
local engine = MSWForecastEngine.new(fc, config, baseCalendar, log)

local function timingOf(forecastId, variantId, eng)
    local def = MSWForecastDef.findById(fc, forecastId)
    return (eng or engine):resolveTiming(def, MSWForecastDef.findVariant(def, variantId))
end

local grains = timingOf("millingGrains", "up")
check("milling grains: message in July-August, before wheat sowing opens",
      grains ~= nil and keys(grains.arrive) == "7,8", grains and keys(grains.arrive))
check("milling grains: verdict at the wheat harvest, effect until the next one",
      grains ~= nil and grains.verdictMonth == 7 and grains.durationMonths == 12)
check("milling grains: a year from a July message, eleven months from August",
      grains ~= nil and grains.leadFrom(7) == 12 and grains.leadFrom(8) == 11)

local oil = timingOf("vegetableOil", "down")
check("vegetable oil: message in June-July, verdict the July after",
      oil ~= nil and keys(oil.arrive) == "6,7" and oil.verdictMonth == 7
      and oil.leadFrom(6) == 13 and oil.leadFrom(7) == 12)

local fuel = timingOf("biofuel", "up")
check("biofuel: message in February-March, verdict in October",
      fuel ~= nil and keys(fuel.arrive) == "2,3" and fuel.verdictMonth == 10
      and fuel.leadFrom(2) == 8 and fuel.leadFrom(3) == 7)

local processors = timingOf("foodProcessors", "up")
check("food processors: message in January-February, verdict in August",
      processors ~= nil and keys(processors.arrive) == "1,2" and processors.verdictMonth == 8)

local severe, long = timingOf("winterFeed", "severe"), timingOf("winterFeed", "long")
check("severe winter: message February-April, verdict November, over in April",
      severe ~= nil and keys(severe.arrive) == "2,3,4" and severe.verdictMonth == 11
      and severe.durationMonths == 5 and severe.premoveMonths == 2)
check("long summer: verdict October, over in April",
      long ~= nil and long.verdictMonth == 10 and long.durationMonths == 6 and long.premoveMonths == 1)

local mill = timingOf("sawmill", "open")
check("sawmill: any month, a year's notice, a two-month pre-move",
      mill ~= nil and mill.numArrive == 12 and mill.leadFrom(5) == 12 and mill.premoveMonths == 2)

check("all twelve variants are offered on the base calendar", #engine:getAvailable() == 12,
      tostring(#engine:getAvailable()))

-- ===========================================================================
print("\n[4] the actionability check")

-- A map without wheat: the forecast is timed by oats instead.
local noWheat = MSWForecastEngine.new(fc, config, function(name)
    if name == "WHEAT" then return nil end
    return MSWCropCalendar.BASE[name]
end, log)
local byOats = timingOf("millingGrains", "up", noWheat)
check("without wheat, milling grains is timed by oats",
      byOats ~= nil and keys(byOats.arrive) == "1,2" and byOats.verdictMonth == 7)

-- A map with none of a forecast's crops: not offered at all.
local noRoots = MSWForecastEngine.new(fc, config, function(name)
    if name == "POTATO" or name == "SUGARBEET" or name == "SUGARCANE" then return nil end
    return MSWCropCalendar.BASE[name]
end, log)
local refused, why = timingOf("foodProcessors", "up", noRoots)
check("a forecast for crops the map does not have is not offered", refused == nil and why ~= nil)
check("the other forecasts are unaffected", #noRoots:getAvailable() == 10,
      tostring(#noRoots:getAvailable()))

-- A crop harvested a month after it is sown: nothing the player could plan.
local tooFast = MSWForecastEngine.new(fc, config, function(name)
    if name == "MAIZE" then return { sowFirst = 5, harvestFirst = 6 } end
    return MSWCropCalendar.BASE[name]
end, log)
local fast, fastWhy = timingOf("biofuel", "up", tooFast)
check("too little time between message and verdict: refused, with the reason",
      fast == nil and type(fastWhy) == "string" and fastWhy:find("month") ~= nil, tostring(fastWhy))

-- The same crop with a workable season is accepted.
local slowEnough = MSWForecastEngine.new(fc, config, function(name)
    if name == "MAIZE" then return { sowFirst = 5, harvestFirst = 9 } end
    return MSWCropCalendar.BASE[name]
end, log)
local shifted = timingOf("biofuel", "up", slowEnough)
check("a map with a different calendar moves the forecast with it",
      shifted ~= nil and keys(shifted.arrive) == "3,4" and shifted.verdictMonth == 9)

-- ===========================================================================
print("\n[5] announcing a forecast")

local function open(eng, forecastId, variantId, day, month, dpm, opts)
    local def = MSWForecastDef.findById(fc, forecastId)
    local variant = MSWForecastDef.findVariant(def, variantId)
    return eng:start(def, variant, eng:resolveTiming(def, variant), day, month, dpm, opts)
end

local e5 = MSWForecastEngine.new(fc, config, baseCalendar, log)
local f5 = open(e5, "millingGrains", "up", 100, 8, 1, { confidence = 80 })
check("one day per month: the verdict is eleven days after an August message",
      f5.verdictDay == 111 and f5.premoveDays == 1, ("%d / %d"):format(f5.verdictDay, f5.premoveDays))

local upDef = MSWEventDef.findById(config, "fcGrainsUp").severities.medium
local expected = ((upDef.priceFactorMin + upDef.priceFactorMax) / 2 - 1) * 0.25
check("the pre-move is a quarter of the expected move", near(f5.premoveDeviation, expected, 1e-9),
      ("%.4f vs %.4f"):format(f5.premoveDeviation, expected))
check("its products are the lead crops", list(f5.products) == "WHEAT,OAT")

local e5b = MSWForecastEngine.new(fc, config, baseCalendar, log)
local f5b = open(e5b, "millingGrains", "down", 100, 8, 1, { confidence = 70, intensity = 2 })
check("a 'price will fall' forecast pre-moves downwards", f5b.premoveDeviation < 0)
check("the intensity setting scales the pre-move",
      near(f5b.premoveDeviation,
           ((MSWEventDef.findById(config, "fcGrainsDown").severities.medium.priceFactorMin
             + MSWEventDef.findById(config, "fcGrainsDown").severities.medium.priceFactorMax) / 2 - 1) * 0.25 * 2, 1e-9))

-- Three days per month, message on the second day of the month.
local e5c = MSWForecastEngine.new(fc, config, baseCalendar, log)
local f5c = open(e5c, "biofuel", "up", 50, 3, 3, { confidence = 70, dayInMonth = 2 })
check("the verdict falls on the first day of its month",
      f5c.verdictDay == 50 + 7 * 3 - 1 and f5c.premoveDays == 3, tostring(f5c.verdictDay))

local e5d = MSWForecastEngine.new(fc, config, baseCalendar, log)
local f5d = open(e5d, "sawmill", "open", 10, 5, 1, { confidence = 90 })
check("the sawmill gets a two-day pre-move a year out",
      f5d.verdictDay == 22 and f5d.premoveDays == 2)

local rolled = {}
math.randomseed(7)
for _ = 1, 4000 do
    local c = e5:rollConfidence()
    rolled[c] = (rolled[c] or 0) + 1
end
check("confidence is 70, 80 or 90, most often 70",
      rolled[70] ~= nil and rolled[80] ~= nil and rolled[90] ~= nil
      and rolled[70] > rolled[80] and rolled[80] > rolled[90]
      and (rolled[70] + rolled[80] + rolled[90]) == 4000)

-- ===========================================================================
print("\n[6] the pre-move")

local flat = true
for day = 100, 109 do
    if f5:getFactorFor("WHEAT", day) ~= 1.0 then flat = false end
end
check("months of uncertainty: no price movement at all", flat)
check("the day before the verdict, wheat edges the forecast way",
      near(f5:getFactorFor("WHEAT", 110), 1 + expected, 1e-9), tostring(f5:getFactorFor("WHEAT", 110)))
check("the pre-move is over once the verdict falls", f5:getFactorFor("WHEAT", 111) == 1.0)
check("only the lead crops pre-move, not the chain",
      f5:getFactorFor("FLOUR", 110) == 1.0 and f5:getFactorFor("OAT", 110) ~= 1.0)
check("a two-day pre-move builds: half on the first day, full on the second",
      near(f5d:getFactorFor("WOOD", 20), 1 + f5d.premoveDeviation * 0.5, 1e-9)
      and near(f5d:getFactorFor("WOOD", 21), 1 + f5d.premoveDeviation, 1e-9))

local INDEX = { WHEAT = 1, OAT = 2, FLOUR = 3, WOOD = 4, PLANKS = 5, SILAGE = 6, MAIZE = 7 }
local pm = MSWPriceModel.new(function(name) return INDEX[name] end, log)
pm:setExtraSources(function() return e5:getOpen() end)
pm:rebuild(105)
check("the price model is untouched while the forecast is only open", pm:getModifier(1) == 1.0)
pm:rebuild(110)
check("the price model carries the pre-move", near(pm:getModifier(1), 1 + expected, 1e-9),
      tostring(pm:getModifier(1)))

-- A running event on the same product stacks with it by the usual rule.
math.randomseed(11)
local drought = MSWActiveEvent.new(MSWEventDef.findById(config, "grainDrought"), "medium", 104, 1,
                                   { intensity = 1, duration = 1 })
pm:addEvent(drought)
pm:rebuild(110)
check("a pre-move stacks with a running event by diminishing returns",
      near(pm:getModifier(1), MSWPriceModel.combineFactors({
          drought:getFactorFor("WHEAT", 110), f5:getFactorFor("WHEAT", 110) }), 1e-9))

-- ===========================================================================
print("\n[7] the verdict")

local function verdictFor(forecastId, variantId, outcome)
    local eng = MSWForecastEngine.new(fc, config, baseCalendar, log)
    local forecast = open(eng, forecastId, variantId, 100, 3, 1, { confidence = 80 })
    return eng:buildVerdict(forecast, { outcome = outcome }), forecast
end

local v = verdictFor("millingGrains", "up", "asForecast")
check("as forecast: the event at medium severity",
      v.events[1].eventId == "fcGrainsUp" and v.events[1].severity == "medium" and #v.events == 1)
check("the event carries the verdict's news item and the forecast's length",
      v.events[1].titleKey == v.titleKey and v.events[1].durationMonths == 12
      and v.titleKey == "msw_fc_millingGrains_up_asForecast_title")
check("stronger is high, milder is low",
      verdictFor("millingGrains", "up", "stronger").events[1].severity == "high"
      and verdictFor("millingGrains", "up", "milder").events[1].severity == "low")
check("right price, wrong reason: still the forecast's own event",
      verdictFor("millingGrains", "up", "wrongReason").events[1].eventId == "fcGrainsUp")
check("backfire: the mirror event",
      verdictFor("millingGrains", "up", "backfire").events[1].eventId == "fcGrainsDown"
      and verdictFor("millingGrains", "down", "backfire").events[1].eventId == "fcGrainsUp")
check("the sawmill's two backfires are their own events",
      verdictFor("sawmill", "open", "backfire").events[1].eventId == "fcSawmillOpenBackfire"
      and verdictFor("sawmill", "close", "backfire").events[1].eventId == "fcSawmillCloseBackfire")

local winter = verdictFor("winterFeed", "severe", "stronger")
check("a severe winter that happens also starts Harsh Winter, at the same severity",
      #winter.events == 2 and winter.events[2].eventId == "harshWinter"
      and winter.events[2].severity == "high" and winter.events[2].companion == true)
check("Harsh Winter keeps its own length and its own news item",
      winter.events[2].durationMonths == nil and winter.events[2].titleKey == nil)
check("no Harsh Winter when feed rose for another reason, or the winter was mild",
      #verdictFor("winterFeed", "severe", "wrongReason").events == 1
      and #verdictFor("winterFeed", "severe", "backfire").events == 1)
check("a long summer never touches energy",
      #verdictFor("winterFeed", "long", "asForecast").events == 1)
check("the winter effect lasts until April",
      winter.events[1].durationMonths == 5
      and verdictFor("winterFeed", "long", "asForecast").events[1].durationMonths == 6)

local e7 = MSWForecastEngine.new(fc, config, baseCalendar, log)
open(e7, "millingGrains", "up", 100, 8, 1, { confidence = 80 })
open(e7, "sawmill", "open", 100, 8, 1, { confidence = 80 })
check("nothing is due before its day", #e7:collectDue(110) == 0 and #e7:getOpen() == 2)
local due = e7:collectDue(111)
check("the verdict falls on its day, and the forecast is no longer open",
      #due == 1 and due[1].forecast.forecastId == "millingGrains" and #e7:getOpen() == 1)
check("every verdict moves the market: there is no 'nothing happened'",
      #due[1].events >= 1 and due[1].events[1].eventId ~= nil)

-- ===========================================================================
print("\n[8] the stated confidence is the true chance")

math.randomseed(20261127)
local honest = true
local shares = {}
for _, confidence in ipairs({ 70, 80, 90 }) do
    local right, n = 0, 40000
    local seen = {}
    for _ = 1, n do
        local outcome, severity = engine:rollOutcome(confidence)
        if outcome ~= "backfire" then right = right + 1 end
        seen[outcome] = true
        if outcome == "backfire" and severity ~= "low" and severity ~= "medium" then honest = false end
    end
    shares[#shares + 1] = ("%d%%->%.1f%%"):format(confidence, right / n * 100)
    if math.abs(right / n * 100 - confidence) > 1.0 then honest = false end
    if not (seen.asForecast and seen.stronger and seen.milder and seen.wrongReason and seen.backfire) then
        honest = false
    end
end
check("experts are right exactly as often as they say", honest, list(shares))

-- ===========================================================================
print("\n[9] about one forecast a year")

local function simulate(dpm, years, frequency)
    math.randomseed(4242 + dpm)
    local eng = MSWForecastEngine.new(fc, config, baseCalendar, log)
    if frequency ~= nil then eng:setFrequency(frequency) end
    local starts, sameOpen, minGap, lastStart = 0, false, math.huge, nil
    local byId = {}
    for day = 1, years * 12 * dpm do
        local month = math.floor((day - 1) / dpm) % 12 + 1
        eng:collectDue(day)
        local entry = eng:rollStart(day, month, dpm)
        if entry ~= nil then
            if eng:isOpen(entry.def.id) then sameOpen = true end
            if lastStart ~= nil then minGap = math.min(minGap, (day - lastStart) / dpm) end
            lastStart = day
            eng:start(entry.def, entry.variant, entry.timing, day, month, dpm)
            starts = starts + 1
            byId[entry.def.id] = (byId[entry.def.id] or 0) + 1
        end
    end
    return starts / years, sameOpen, minGap, byId
end

local rate1, same1, gap1, byId1 = simulate(1, 600)
local rate3 = simulate(3, 600)
check("roughly one a year at one day per month", rate1 > 0.75 and rate1 < 1.15, ("%.2f"):format(rate1))
check("the same at three days per month", rate3 > 0.75 and rate3 < 1.15, ("%.2f"):format(rate3))
check("never two forecasts of one kind open together", not same1)
check("at least nine months between forecasts", gap1 >= 9, tostring(gap1))
local allSeen = true
for _, def in ipairs(fc.forecasts) do
    if (byId1[def.id] or 0) < 20 then allSeen = false end
end
check("every forecast gets its turn", allSeen)

-- The player's "Forecasts per year" setting.
local rateHalf, _, gapHalf = simulate(1, 600, 0.5)
local rateDouble, sameDouble, gapDouble = simulate(1, 600, 2)
check("the setting at 0.5 gives about half as many",
      rateHalf > rate1 * 0.4 and rateHalf < rate1 * 0.65, ("%.2f vs %.2f"):format(rateHalf, rate1))
check("the setting at 2 gives clearly more, and still never two of a kind",
      rateDouble > rate1 * 1.5 and not sameDouble, ("%.2f vs %.2f"):format(rateDouble, rate1))
check("the quiet time between forecasts scales with it",
      gapHalf >= 18 and gapDouble >= 4.5 and gapDouble < 9,
      ("%s / %s"):format(tostring(gapHalf), tostring(gapDouble)))
local rateZero = simulate(1, 100, 0)
check("at zero no forecast is ever announced", rateZero == 0)

local blockedEngine = MSWForecastEngine.new(fc, config, baseCalendar, log)
math.randomseed(1)
local blockedStart = false
for day = 1, 2400 do
    if blockedEngine:rollStart(day, (day - 1) % 12 + 1, 1, function() return true end) ~= nil then
        blockedStart = true
    end
end
check("a blocked forecast is never announced", not blockedStart)

-- ===========================================================================
print("\n[10] events a forecast starts")

math.randomseed(99)
local scalers = { intensity = 1, duration = 2 }     -- the player's duration setting at 200%
local yearLong = MSWActiveEvent.new(MSWEventDef.findById(config, "fcGrainsUp"), "medium", 0, 1,
                                    scalers, { durationMonths = 12, titleKey = "t", textKey = "x",
                                               forecastId = "millingGrains" })
check("the effect lasts exactly as long as the forecast says, whatever the duration setting",
      yearLong.durationDays == 12, tostring(yearLong.durationDays))

math.randomseed(99)
local rolledLength = MSWActiveEvent.new(MSWEventDef.findById(config, "grainDrought"), "medium", 0, 1, scalers)
check("an ordinary event still scales with the duration setting", rolledLength.durationDays >= 12)

local peak, peakDay = 1, 0
for day = 0, 11 do
    local f = yearLong:getFactorFor("WHEAT", day)
    if f > peak then peak, peakDay = f, day end
end
check("the year-long shape peaks early", peakDay <= 2, ("day %d"):format(peakDay))
check("it is already moving in the verdict month", yearLong:getFactorFor("WHEAT", 0) > 1.03)
check("it is still clearly up late in the season, but below its peak",
      yearLong:getFactorFor("WHEAT", 9) > 1.05 and yearLong:getFactorFor("WHEAT", 9) < peak)
check("it clears when the new harvest arrives", yearLong:getFactorFor("WHEAT", 12) == 1.0)
check("flour and hay follow wheat",
      yearLong:getFactorFor("FLOUR", 4) > 1.0 and yearLong:getFactorFor("DRYGRASS_WINDROW", 4) > 1.0
      and yearLong:getFactorFor("DRYGRASS_WINDROW", 4) < yearLong:getFactorFor("WHEAT", 4))

math.randomseed(5)
local millOpen = MSWActiveEvent.new(MSWEventDef.findById(config, "fcSawmillOpen"), "medium", 0, 1,
                                    { intensity = 1, duration = 1 }, { durationMonths = 12 })
check("a new sawmill: timber up, sawn wood and wood chips down",
      millOpen:getFactorFor("WOOD", 2) > 1.15 and millOpen:getFactorFor("PLANKS", 2) < 0.95
      and millOpen:getFactorFor("WOODCHIPS", 2) < 0.95)
check("sawn wood falls about half as far as timber rises",
      near((1 - millOpen:getFactorFor("PLANKS", 1)) / (millOpen:getFactorFor("WOOD", 1) - 1), 0.5, 0.2))
check("sawn wood is back to normal while timber is still dear",
      millOpen:getFactorFor("PLANKS", 8) == 1.0 and millOpen:getFactorFor("WOOD", 8) > 1.05,
      ("%.3f / %.3f"):format(millOpen:getFactorFor("PLANKS", 8), millOpen:getFactorFor("WOOD", 8)))

math.randomseed(5)
local millClose = MSWActiveEvent.new(MSWEventDef.findById(config, "fcSawmillClose"), "medium", 0, 1,
                                     { intensity = 1, duration = 1 }, { durationMonths = 12 })
check("a sawmill closing is the mirror: timber down, sawn wood and wood chips up",
      millClose:getFactorFor("WOOD", 2) < 0.9 and millClose:getFactorFor("BOARDS", 2) > 1.03
      and millClose:getFactorFor("WOODCHIPS", 2) > 1.03)

math.randomseed(5)
local feed = MSWActiveEvent.new(MSWEventDef.findById(config, "fcFeedUp"), "medium", 0, 1,
                                { intensity = 1, duration = 1 }, { durationMonths = 5 })
check("winter feed: silage, hay, grass and straw up; corn at about half",
      feed:getFactorFor("SILAGE", 2) > 1.2 and feed:getFactorFor("DRYGRASS_WINDROW", 2) > 1.2
      and feed:getFactorFor("GRASS_WINDROW", 2) > 1.2 and feed:getFactorFor("STRAW", 2) > 1.2
      and feed:getFactorFor("MAIZE", 2) > 1.05
      and feed:getFactorFor("MAIZE", 2) < feed:getFactorFor("SILAGE", 2))

-- An ordinary event is untouched by the new option.
math.randomseed(31)
local plain = MSWActiveEvent.new(MSWEventDef.findById(config, "pandemicCrisis"), "medium", 0, 10,
                                 { intensity = 1, duration = 1 })
local lastDay = plain.durationDays - 1
check("an opposite group without a duration share still lasts the whole event",
      plain:getFactorFor("LETTUCE", math.floor(plain.durationDays * 0.8)) < 1.0
      and plain:getFactorFor("LETTUCE", lastDay) <= 1.0)

-- ===========================================================================
print("\n[11] the random scheduler never rolls a forecast's event")

local scheduler = MSWEventScheduler.new(config, log)
local onlyRandom = true
for _, def in ipairs(config.events) do
    if def.forecastOnly then onlyRandom = false end
end
check("forecast events are not in the scheduler's list", onlyRandom)
local neverRolled = true
for _, def in ipairs(config.forecastEvents) do
    if not def.forecastOnly or def.baseWeight ~= 0 then neverRolled = false end
    for month = 1, 12 do
        if scheduler:dailyProbability(def, month, 1, 2.0) ~= 0 then neverRolled = false end
    end
end
check("and could not be rolled if they were: no weight, no season", neverRolled)
check("loading them warned about nothing", #warnings == 0, list(warnings))

-- ===========================================================================
print("\n[12] the history")

local history = MSWHistory.new(5)
for n = 1, 7 do
    history:add({ kind = "event", titleKey = "title" .. n, textKey = "text" .. n, day = n })
end
check("it keeps the newest entries up to its limit", history:count() == 5)
check("newest first", history:getNewestFirst()[1].titleKey == "title7"
      and history:getNewestFirst()[5].titleKey == "title3")

history:add({ kind = "forecast", titleKey = "f", textKey = "ft", ref = "sawmill@10", status = "open" })
history:add({ kind = "forecast", titleKey = "g", textKey = "gt", ref = "biofuel@20", status = "open" })
history:setStatus("forecast", "sawmill@10", "backfire")
local statuses = {}
for _, entry in ipairs(history:getNewestFirst()) do
    if entry.kind == "forecast" then statuses[entry.ref] = entry.status end
end
check("a verdict updates its own forecast and no other",
      statuses["sawmill@10"] == "backfire" and statuses["biofuel@20"] == "open")
check("an unknown forecast changes nothing", history:setStatus("forecast", "nope@1", "x") == nil)

check("a plain key resolves to its text",
      MSWHistory.resolveText(i18n, "msw_fc_confidence_80") == l10n.msw_fc_confidence_80)
local tip = MSWHistory.resolveText(i18n, "msw_fc_tip")
check("a long message is its paragraphs, joined by blank lines",
      tip:find(l10n.msw_fc_tip_p1, 1, true) == 1 and tip:find("\n\n", 1, true) ~= nil
      and tip:find(l10n.msw_fc_tip_p4, 1, true) ~= nil)
local opening = MSWHistory.resolveText(i18n, "msw_fc_millingGrains_up_open_text", "msw_fc_confidence_90")
check("the confidence line is put into the opening message",
      opening:find(l10n.msw_fc_confidence_90, 1, true) ~= nil and opening:find("%s", 1, true) == nil)
check("a missing key comes back as itself, not as an error",
      MSWHistory.resolveText(i18n, "msw_nope") == "msw_nope" and MSWHistory.resolveText(nil, "k") == "k")
check("the welcome message resolves the same way",
      MSWHistory.resolveText(i18n, "msw_welcome"):find(l10n.msw_welcome_p1, 1, true) == 1)

-- ===========================================================================
print("\n[13] saving and loading")

local e13 = MSWForecastEngine.new(fc, config, baseCalendar, log)
local saved = open(e13, "winterFeed", "severe", 200, 3, 1, { confidence = 90 })
e13.tipShown = true
local xml = memoryXML()
e13:saveToXML(xml, "msw.forecasts")
local loaded = MSWForecastEngine.new(fc, config, baseCalendar, log)
loaded:loadFromXML(xml, "msw.forecasts")
local restored = loaded:getOpen()[1]
check("an open forecast survives a save",
      restored ~= nil and restored.forecastId == "winterFeed" and restored.variantId == "severe"
      and restored.confidence == 90 and restored.verdictDay == saved.verdictDay
      and near(restored.premoveDeviation, saved.premoveDeviation))
check("so does its pre-move",
      restored ~= nil and near(restored:getFactorFor("SILAGE", saved.verdictDay - 1),
                               saved:getFactorFor("SILAGE", saved.verdictDay - 1)))
check("and the cooldown and the one-time tip", loaded.lastStartDay == 200 and loaded.tipShown == true)

local empty = MSWForecastEngine.new(fc, config, baseCalendar, log)
empty:loadFromXML(memoryXML(), "msw.forecasts")
check("a savegame from before forecasts loads as 'none open, tip not shown'",
      #empty:getOpen() == 0 and empty.tipShown == false and empty.lastStartDay == nil)

local hxml = memoryXML()
history:saveToXML(hxml, "msw.history")
local history2 = MSWHistory.new()
history2:loadFromXML(hxml, "msw.history")
check("the history survives a save, in order, with its statuses",
      history2:count() == history:count()
      and history2:getNewestFirst()[1].ref == "biofuel@20"
      and history2:getNewestFirst()[2].status == "backfire")

math.randomseed(77)
local evSaved = MSWActiveEvent.new(MSWEventDef.findById(config, "fcSawmillOpen"), "high", 30, 1,
                                   { intensity = 1, duration = 1 },
                                   { durationMonths = 12, titleKey = "msw_fc_sawmill_open_stronger_title",
                                     textKey = "msw_fc_sawmill_open_stronger_text", forecastId = "sawmill" })
local exml = memoryXML()
evSaved:saveToXML(exml, "e")
local evLoaded = MSWActiveEvent.loadFromXML(exml, "e", MSWEventDef.findById(config, "fcSawmillOpen"), 1, 3)
check("an event a forecast started keeps its news item and its origin",
      evLoaded ~= nil and evLoaded.titleKey == "msw_fc_sawmill_open_stronger_title"
      and evLoaded.forecastId == "sawmill" and evLoaded.durationDays == 12)
check("and its prices, sawn wood's early recovery included",
      evLoaded ~= nil and near(evLoaded:getFactorFor("WOOD", 33), evSaved:getFactorFor("WOOD", 33))
      and near(evLoaded:getFactorFor("PLANKS", 33), evSaved:getFactorFor("PLANKS", 33))
      and evLoaded:getFactorFor("PLANKS", 39) == 1.0)
check("a restored event keeps its family, so its mirror stays excluded",
      evLoaded ~= nil and evLoaded.subtype == "fcSawmill")

-- ===========================================================================
print("\n[14] the hub's market view")

local e14 = MSWForecastEngine.new(fc, config, baseCalendar, log)
local f14 = open(e14, "millingGrains", "up", 100, 8, 1, { confidence = 70 })
local pm14 = MSWPriceModel.new(function(name) return INDEX[name] end, log)
pm14:setExtraSources(function() return e14:getOpen() end)

pm14:rebuild(105)
local quiet = MSWMarketView.build(pm14, 105, e14:getOpen())
check("an open forecast that is not moving prices is not on the Market tab",
      #quiet.products == 0 and #quiet.events == 0)

pm14:rebuild(110)
local premove = MSWMarketView.build(pm14, 110, e14:getOpen())
local wheatRow
for _, p in ipairs(premove.products) do if p.name == "WHEAT" then wheatRow = p end end
check("in its pre-move the lead crops are listed as moving",
      wheatRow ~= nil and near(wheatRow.factor, f14:getFactorFor("WHEAT", 110)))
check("with the forecast named as the cause",
      wheatRow ~= nil and #wheatRow.eventIds == 0
      and wheatRow.forecastTitleKeys[1] == "msw_fc_millingGrains_up_open_title")
check("a pre-move is not news: nothing has happened yet", #premove.events == 0)

pm14:addEvent(evSaved)
local after = MSWMarketView.build(pm14, 32, {})
check("an event a forecast started is in the news under the verdict's headline",
      #after.events == 1 and after.events[1].titleKey == "msw_fc_sawmill_open_stronger_title"
      and after.events[1].textKey == "msw_fc_sawmill_open_stronger_text")

-- ===========================================================================
print("\n[15] what the player PAYS for inputs")

-- Stand-ins for the game: its price functions, its fill types, its shop items.
Utils = { overwrittenFunction = function(old, new)
    return function(self, ...) return new(self, old, ...) end
end }
local FILL = { FERTILIZER = 11, LIME = 12, SEEDS = 13, HERBICIDE = 14, DIESEL = 15, WHEAT = 16 }
g_fillTypeManager = { getFillTypeIndexByName = function(_, name) return FILL[name] end }
SellingStation = { getEffectiveFillTypePrice = function() return 100 end }
EconomyManager = {
    getPricePerLiter = function() return 2 end,
    getCostPerLiter = function() return 3 end,
    -- Returns two values, the second nil-able, like a real price function might.
    getBuyPrice = function(_, storeItem) return storeItem.price, storeItem.extra end,
}
local specLoads = 0
StoreItemUtil = { loadSpecsFromXML = function(item)
    specLoads = specLoads + 1
    item.specs = { fillTypes = { fillTypeNames = item.holds } }
end }

load("game/EconomyAdapter.lua")
local payModel = { mods = { [11] = 1.20, [15] = 1.50 },
                   getModifier = function(self, index) return self.mods[index] or 1.0 end }
local pay = EconomyAdapter.new(payModel, log)
pay:install()
local manager = {}

local fertBag   = { price = 1000, holds = "fertilizer", categoryNames = { "BIGBAGS", "PALLETFERTILIZERHERBICIDE" } }
local limeBag   = { price = 500,  holds = "lime", categoryNames = { "bigbags" } }
local spreader  = { price = 40000, holds = "fertilizer lime", categoryNames = { "FERTILIZERSPREADERS" } }
local fuelTank  = { price = 9000, holds = "diesel", categoryNames = { "TRAILERS" } }
local mixedPal  = { price = 800,  holds = "fertilizer seeds", categoryNames = { "PALLETS" } }
local usedBag   = { price = 1000, holds = "fertilizer", categoryNames = { "BIGBAGS" } }

check("a big bag of fertiliser costs more in the shop while fertiliser is up",
      EconomyManager.getBuyPrice(manager, fertBag) == 1200, tostring(EconomyManager.getBuyPrice(manager, fertBag)))
check("a product no event is moving keeps its price", EconomyManager.getBuyPrice(manager, limeBag) == 500)
check("a machine that can carry fertiliser does not", EconomyManager.getBuyPrice(manager, spreader) == 40000)
check("a fuel trailer is a machine, even though it holds one product",
      EconomyManager.getBuyPrice(manager, fuelTank) == 9000)
check("a pallet of several products is left alone", EconomyManager.getBuyPrice(manager, mixedPal) == 800)
check("a used-market item keeps its own price",
      EconomyManager.getBuyPrice(manager, usedBag, nil, { some = "sale" }) == 1000)

local a, b = EconomyManager.getBuyPrice(manager, { price = 10, extra = "kept", holds = "wheat",
                                                   categoryNames = { "PALLETS" } })
check("every value the game's function returns is passed on", a == 10 and b == "kept")
local n = select("#", EconomyManager.getBuyPrice(manager, fertBag))
check("including a trailing nil", n == 2)

local before = specLoads
EconomyManager.getBuyPrice(manager, fertBag)
EconomyManager.getBuyPrice(manager, spreader)
check("what an item holds is looked up once, and not at all for machines", specLoads == before)

check("a helper refilling on the go pays the moved price",
      near(EconomyManager.getCostPerLiter(manager, 11), 3 * 1.20) and EconomyManager.getCostPerLiter(manager, 12) == 3)
check("the fuel pump pays the moved price", near(EconomyManager.getPricePerLiter(manager, 15), 2 * 1.50))

pay:setEnabled(false)
check("with the mod switched off the shop charges the normal price",
      EconomyManager.getBuyPrice(manager, fertBag) == 1000 and EconomyManager.getCostPerLiter(manager, 11) == 3)
pay:setEnabled(true)

-- verifyHooks() may run install() again; the purchase hooks must not stack.
pay.installed = false
pay:install()
check("installing twice does not apply the change twice",
      EconomyManager.getBuyPrice(manager, fertBag) == 1200
      and near(EconomyManager.getCostPerLiter(manager, 11), 3 * 1.20))

print(("\n===== %d passed, %d failed =====\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
