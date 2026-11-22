--[[
    Offline test harness for the pure-logic model.

    Runs scripts/model/* and scripts/lib/* outside Farming Simulator by stubbing
    the handful of globals the engine normally provides. Verifies the Lua
    reproduces the behaviour validated in the Python simulators:

      1. the wheat -> flour -> bread -> cake cascade (staggered ~1 month per
         layer, diminishing, base still elevated when the top of the chain peaks)
      2. severity-scaled ripple depth (LOW 1 hop, MED 2, HI 3)
      3. multiplicative stacking
      4. the annual event rate: ~eventsPerYear regardless of days-per-month
      5. seasonal distribution respects the month windows
      6. straw behaves as a co-product of grain (same direction, no real lag)
      7. the natural disaster demand shock: uniform reach, backward ripple\n      8. the self-overlap guard: one instance per event id at a time\n     8b. mutual exclusion by subtype: mirrored events never overlap\n      9. the input shock's substitution effect on manure/slurry\n     10. forage damped in every drought, compounding across events\n     11. jitter noise quality: non-affine, uniform, reproducible
     12. commodity markers follow the curve day by day
     13. short seasons (1-2 days/month): chains fire, the news day moves

    Run:  lua tools/test_model.lua
]]

-- ---- minimal engine stubs -------------------------------------------------
function Class(base)
    local c = {}
    c.__index = c
    if base then setmetatable(c, { __index = base }) end
    return c
end

local ROOT = "FS25_MarketShockwaves/scripts/"
local function load(rel) dofile(ROOT .. rel) end

load("lib/Random.lua")
load("model/Curve.lua")
load("model/ActiveEvent.lua")
load("model/PriceModel.lua")
load("model/EventScheduler.lua")

local log = {
    info = function() end, warn = function(_, m) print("WARN: " .. tostring(m)) end,
    error = function(_, m) print("ERROR: " .. tostring(m)) end, debug = function() end,
}

-- ---- a grain-drought definition mirroring config/events.xml ---------------
local function severity(t) return t end

local grainDrought = {
    id = "grainDrought", type = "win", baseWeight = 1.0,
    affects = { "WHEAT", "BARLEY", "OAT", "CANOLA", "MAIZE",
                "SORGHUM", "SUNFLOWER", "SOYBEAN" },
    chains = {
        WHEAT     = { { to = "FLOUR",            tier = 1, lagMonths = 1.0,  passThrough = 0.60 },
                      { to = "STRAW",            tier = 1, lagMonths = 0.25, passThrough = 0.80 },
                      { to = "GRASS_WINDROW",    tier = 1, lagMonths = 0.25, passThrough = 0.45 },
                      { to = "DRYGRASS_WINDROW", tier = 1, lagMonths = 0.5,  passThrough = 0.45 } },
        FLOUR     = { { to = "BREAD",         tier = 2, lagMonths = 1.0, passThrough = 0.60 },
                      { to = "CAKE",          tier = 3, lagMonths = 2.0, passThrough = 0.45 } },
        OAT       = { { to = "CEREAL",        tier = 1, lagMonths = 1.0, passThrough = 0.60 } },
        CANOLA    = { { to = "CANOLA_OIL",    tier = 1, lagMonths = 1.0, passThrough = 0.60 } },
        SUNFLOWER = { { to = "SUNFLOWER_OIL", tier = 1, lagMonths = 1.0, passThrough = 0.60 } },
    },
    severities = {
        low = severity{ priceFactorMin=1.15, priceFactorMax=1.20,
            durationMonthsMin=3, durationMonthsMax=6, peakPosMin=0.10, peakPosMax=0.40,
            riseExpMin=0.5, riseExpMax=0.9, hold=0.55, correctionMonths=0.8,
            jitter=0.015, rippleDepth=1, rippleScale=0.55 },
        medium = severity{ priceFactorMin=1.20, priceFactorMax=1.30,
            durationMonthsMin=6, durationMonthsMax=8, peakPosMin=0.35, peakPosMax=0.60,
            riseExpMin=1.0, riseExpMax=1.5, hold=0.62, correctionMonths=1.1,
            jitter=0.020, rippleDepth=2, rippleScale=1.00 },
        high = severity{ priceFactorMin=1.60, priceFactorMax=1.70,
            durationMonthsMin=10, durationMonthsMax=12, peakPosMin=0.30, peakPosMax=0.45,
            riseExpMin=1.5, riseExpMax=2.0, hold=0.72, correctionMonths=1.2,
            jitter=0.025, rippleDepth=3, rippleScale=1.30 },
    },
    monthShare = {},
}
-- FEB-SEP weights, normalised
do
    local w = { 0, 0.4, 0.8, 1.3, 1.5, 1.5, 1.3, 1.0, 0.6, 0, 0, 0 }
    local t = 0; for _, v in ipairs(w) do t = t + v end
    for m = 1, 12 do grainDrought.monthShare[m] = w[m] / t end
end

local BASE = { WHEAT = 337, FLOUR = 690, BREAD = 1650, CAKE = 3300 }
local D = 10   -- days per month
local pass, fail = 0, 0

local function check(label, cond, detail)
    if cond then pass = pass + 1; print(("  PASS  %s"):format(label))
    else fail = fail + 1; print(("  FAIL  %s  %s"):format(label, detail or "")) end
end

-- ===========================================================================
print("\n[1] HI drought cascade: wheat -> flour -> bread -> cake")
math.randomseed(20240726)
local ev = MSWActiveEvent.new(grainDrought, "high", 0, D, { intensity = 1, duration = 1 })

print(("  peak=%.3f  duration=%.1f months (%d days)  peakPos=%.2f")
    :format(ev.peakFactor, ev.durationMonths, ev.durationDays, ev.peakPos))

local chain = { "WHEAT", "FLOUR", "BREAD", "CAKE" }
local peakDay, peakVal = {}, {}
for _, p in ipairs(chain) do
    peakVal[p], peakDay[p] = 1.0, 0
    for d = 0, ev.durationDays do
        local f = ev:getFactorFor(p, d)
        if f > peakVal[p] then peakVal[p], peakDay[p] = f, d end
    end
end

print("  Month |  WHEAT  |  FLOUR  |  BREAD  |   CAKE")
for m = 0, math.floor(ev.durationDays / D) do
    local d = m * D
    local cells = {}
    for _, p in ipairs(chain) do
        cells[#cells + 1] = ("%+6.1f%%"):format((ev:getFactorFor(p, d) - 1) * 100)
    end
    print(("  %4d  | %s"):format(m, table.concat(cells, " | ")))
end
for _, p in ipairs(chain) do
    print(("    %-6s peak %+.1f%% at month %.1f  (price %d)")
        :format(p, (peakVal[p] - 1) * 100, peakDay[p] / D,
                math.floor(BASE[p] * peakVal[p] + 0.5)))
end

check("all four layers reached", peakVal.CAKE > 1.0, "cake never moved")
check("peaks are staggered in chain order",
      peakDay.WHEAT < peakDay.FLOUR and peakDay.FLOUR < peakDay.BREAD
      and peakDay.BREAD < peakDay.CAKE,
      ("days: %d %d %d %d"):format(peakDay.WHEAT, peakDay.FLOUR, peakDay.BREAD, peakDay.CAKE))
check("~1 month lag per layer",
      math.abs((peakDay.FLOUR - peakDay.WHEAT) - D) <= 2
      and math.abs((peakDay.BREAD - peakDay.FLOUR) - D) <= 2,
      ("gaps: %d %d"):format(peakDay.FLOUR - peakDay.WHEAT, peakDay.BREAD - peakDay.FLOUR))
check("impact diminishes up the chain",
      peakVal.WHEAT > peakVal.FLOUR and peakVal.FLOUR > peakVal.BREAD
      and peakVal.BREAD > peakVal.CAKE)
check("base still elevated when cake peaks (consistency)",
      ev:getFactorFor("WHEAT", peakDay.CAKE) > 1.20,
      ("wheat was %+.1f%%"):format((ev:getFactorFor("WHEAT", peakDay.CAKE) - 1) * 100))
check("everything back to baseline at the end",
      math.abs(ev:getFactorFor("WHEAT", ev.durationDays) - 1) < 0.001
      and math.abs(ev:getFactorFor("CAKE", ev.durationDays) - 1) < 0.001)

-- ===========================================================================
print("\n[2] severity-scaled ripple depth")
for _, spec in ipairs({ { "low", 1 }, { "medium", 2 }, { "high", 3 } }) do
    local cls, expectedHops = spec[1], spec[2]
    local e = MSWActiveEvent.new(grainDrought, cls, 0, D, { intensity = 1, duration = 1 })
    local reached = {}
    for _, p in ipairs({ "FLOUR", "BREAD", "CAKE" }) do
        if e.reach[p] ~= nil then reached[#reached + 1] = p end
    end
    check(("%s reaches %d hop(s)"):format(cls, expectedHops),
          #reached == expectedHops,
          "got: " .. (#reached > 0 and table.concat(reached, ",") or "none"))
end

-- ===========================================================================
print("\n[3] multiplicative stacking")
local model = MSWPriceModel.new(function(name)
    local map = { WHEAT = 1, FLOUR = 2, BREAD = 3, CAKE = 4 }
    return map[name]
end, log)
math.randomseed(7)
local a = MSWActiveEvent.new(grainDrought, "medium", 0, D, { intensity = 1, duration = 1 })
local b = MSWActiveEvent.new(grainDrought, "medium", 0, D, { intensity = 1, duration = 1 })
model:addEvent(a); model:addEvent(b)
local probe = math.floor(a.durationDays * 0.4)
model:rebuild(probe)
local combined = model:getModifier(1)
local expected = a:getFactorFor("WHEAT", probe) * b:getFactorFor("WHEAT", probe)
check("two events multiply", math.abs(combined - expected) < 1e-9,
      ("%.4f vs %.4f"):format(combined, expected))
check("stacked result exceeds either alone",
      combined > a:getFactorFor("WHEAT", probe),
      ("%.4f"):format(combined))

-- ===========================================================================
print("\n[4] annual event rate is days-per-month independent")
local scheduler = MSWEventScheduler.new({
    events = { grainDrought },
    severityChances = { low = 0.6, medium = 0.3, high = 0.1 },
}, log)

local TARGET = 1.7
for _, dpm in ipairs({ 1, 3, 10 }) do
    math.randomseed(99)
    local years, count = 4000, 0
    for _ = 1, years do
        for m = 1, 12 do
            for _ = 1, dpm do
                if #scheduler:rollForDay(m, dpm, TARGET) > 0 then count = count + 1 end
            end
        end
    end
    local rate = count / years
    check(("daysPerMonth=%d -> %.3f/yr"):format(dpm, rate),
          math.abs(rate - TARGET) < 0.12, ("expected ~%.2f"):format(TARGET))
end

-- ===========================================================================
print("\n[5] seasonal window respected (no events Oct-Jan)")
math.randomseed(123)
local byMonth = {}
for m = 1, 12 do byMonth[m] = 0 end
for _ = 1, 20000 do
    for m = 1, 12 do
        for _ = 1, 3 do
            if #scheduler:rollForDay(m, 3, TARGET) > 0 then byMonth[m] = byMonth[m] + 1 end
        end
    end
end
local names = { "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec" }
local maxv = 0; for m = 1, 12 do maxv = math.max(maxv, byMonth[m]) end
for m = 1, 12 do
    local bar = string.rep("#", math.floor(byMonth[m] / math.max(maxv, 1) * 28 + 0.5))
    print(("  %s %6d %s"):format(names[m], byMonth[m], bar))
end
check("no events in Oct/Nov/Dec/Jan",
      byMonth[10] == 0 and byMonth[11] == 0 and byMonth[12] == 0 and byMonth[1] == 0)
check("May/Jun are the busiest months",
      byMonth[5] >= byMonth[4] and byMonth[6] >= byMonth[7])

-- ===========================================================================
-- ===========================================================================
print("\n[6] straw is a co-product: same direction as grain, near-zero lag")

-- A bumper harvest definition: identical chains, but priceFactor < 1.
local grainBumper = {}
for k, v in pairs(grainDrought) do grainBumper[k] = v end
grainBumper.id, grainBumper.type = "grainBumper", "lose"
grainBumper.severities = {
    medium = severity{ priceFactorMin=0.85, priceFactorMax=0.90,
        durationMonthsMin=6, durationMonthsMax=8, peakPosMin=0.35, peakPosMax=0.60,
        riseExpMin=1.0, riseExpMax=1.5, hold=0.62, correctionMonths=1.1,
        jitter=0.020, rippleDepth=2, rippleScale=1.00 },
}

math.randomseed(4242)
local dr = MSWActiveEvent.new(grainDrought, "medium", 0, D, { intensity = 1, duration = 1 })
local bu = MSWActiveEvent.new(grainBumper,  "medium", 0, D, { intensity = 1, duration = 1 })

local function peakOf(e, p)
    local best, bestDay = 1.0, 0
    for d = 0, e.durationDays do
        local f = e:getFactorFor(p, d)
        if math.abs(f - 1) > math.abs(best - 1) then best, bestDay = f, d end
    end
    return best, bestDay
end

local dWheat, dWheatDay = peakOf(dr, "WHEAT")
local dStraw, dStrawDay = peakOf(dr, "STRAW")
local bWheat            = peakOf(bu, "WHEAT")
local bStraw            = peakOf(bu, "STRAW")

print(("  drought: wheat %+.1f%% (m%.1f)   straw %+.1f%% (m%.1f)")
    :format((dWheat-1)*100, dWheatDay/D, (dStraw-1)*100, dStrawDay/D))
print(("  bumper : wheat %+.1f%%          straw %+.1f%%")
    :format((bWheat-1)*100, (bStraw-1)*100))

check("drought raises straw (less grain -> less straw)", dStraw > 1.0,
      ("straw %+.2f%%"):format((dStraw-1)*100))
check("bumper lowers straw (excess straw on the market)", bStraw < 1.0,
      ("straw %+.2f%%"):format((bStraw-1)*100))
check("straw moves the same direction as grain in both events",
      (dWheat > 1) == (dStraw > 1) and (bWheat < 1) == (bStraw < 1))
check("straw is damped relative to grain",
      math.abs(dStraw - 1) < math.abs(dWheat - 1))
check("straw tracks grain closely in time (co-product, not downstream)",
      math.abs(dStrawDay - dWheatDay) <= math.ceil(0.5 * D),
      ("wheat m%.1f vs straw m%.1f"):format(dWheatDay/D, dStrawDay/D))
check("straw reached even at LOW severity (direct co-product)",
      MSWActiveEvent.new(grainDrought, "low", 0, D,
          { intensity = 1, duration = 1 }).reach["STRAW"] ~= nil)

-- ===========================================================================
print("\n[7] natural disaster: demand shock, uniform reach at every severity")

local disaster = {
    id = "naturalDisaster", type = "win", baseWeight = 1.0,
    affects = { "PREFABWALL", "ROOFPLATES", "CEMENT", "CEMENTBRICKS" },
    chains = {
        PREFABWALL = { { to = "WOODBEAM", tier = 1, lagMonths = 0.5, passThrough = 0.75 },
                       { to = "PLANKS",   tier = 1, lagMonths = 0.5, passThrough = 0.75 },
                       { to = "BOARDS",   tier = 1, lagMonths = 0.5, passThrough = 0.75 },
                       { to = "BATHTUB",  tier = 3, lagMonths = 2.0, passThrough = 0.50 } },
        BOARDS     = { { to = "WOOD",      tier = 2, lagMonths = 0.5, passThrough = 0.70 },
                       { to = "WOODCHIPS", tier = 2, lagMonths = 0.5, passThrough = 0.70 } },
        PLANKS     = { { to = "FURNITURE", tier = 3, lagMonths = 1.5, passThrough = 0.50 } },
    },
    severities = {},
    monthShare = {},
}
for _, spec in ipairs({ { "low", 1.18, 3 }, { "medium", 1.26, 5 }, { "high", 1.65, 10 } }) do
    disaster.severities[spec[1]] = severity{
        priceFactorMin = spec[2], priceFactorMax = spec[2],
        durationMonthsMin = spec[3], durationMonthsMax = spec[3],
        peakPosMin = 0.10, peakPosMax = 0.20, riseExpMin = 0.5, riseExpMax = 0.8,
        hold = 0.80, correctionMonths = 0.8, jitter = 0.0,
        rippleDepth = 3, rippleScale = 1.00 }
end
do
    local w = { 1.5,1.4,1.2,1.0,0.5,0.4,0.4,0.5,0.8,1.2,1.4,1.5 }
    local t = 0; for _, v in ipairs(w) do t = t + v end
    for m = 1, 12 do disaster.monthShare[m] = w[m] / t end
end

local ALL = { "PREFABWALL","ROOFPLATES","CEMENT","CEMENTBRICKS",
              "WOODBEAM","PLANKS","BOARDS","WOOD","WOODCHIPS","FURNITURE","BATHTUB" }

math.randomseed(99)
local reachCounts = {}
for _, cls in ipairs({ "low", "medium", "high" }) do
    local e = MSWActiveEvent.new(disaster, cls, 0, D, { intensity = 1, duration = 1 })
    local missing = {}
    for _, p in ipairs(ALL) do
        if e.reach[p] == nil then missing[#missing + 1] = p end
    end
    reachCounts[cls] = 11 - #missing
    check(("%s reaches all %d products"):format(cls, #ALL), #missing == 0,
          "missing: " .. table.concat(missing, ","))
end
check("reach is identical across severities",
      reachCounts.low == reachCounts.medium and reachCounts.medium == reachCounts.high)

-- cement is direct, so it must move at full magnitude in every severity
for _, cls in ipairs({ "low", "medium", "high" }) do
    local e = MSWActiveEvent.new(disaster, cls, 0, D, { intensity = 1, duration = 1 })
    check(("cement is full-strength at %s"):format(cls),
          math.abs(e.reach["CEMENT"].passThrough - 1.0) < 1e-9)
end

-- timing: walls spike first, timber follows, furniture last
local e = MSWActiveEvent.new(disaster, "high", 0, D, { intensity = 1, duration = 1 })
local function peakDayOf(p)
    local best, day = 1.0, 0
    for d = 0, e.durationDays do
        local f = e:getFactorFor(p, d)
        if f > best then best, day = f, d end
    end
    return day, best
end
local dWall,  vWall  = peakDayOf("PREFABWALL")
local dBoard, vBoard = peakDayOf("BOARDS")
local dWood,  vWood  = peakDayOf("WOOD")
local dFurn,  vFurn  = peakDayOf("FURNITURE")
print(("  HI: walls %+.1f%% (m%.1f) -> boards %+.1f%% (m%.1f) -> wood %+.1f%% (m%.1f) -> furniture %+.1f%% (m%.1f)")
    :format((vWall-1)*100, dWall/D, (vBoard-1)*100, dBoard/D,
            (vWood-1)*100, dWood/D, (vFurn-1)*100, dFurn/D))
check("demand pulls back in order: walls -> boards -> wood",
      dWall <= dBoard and dBoard <= dWood,
      ("m%.1f m%.1f m%.1f"):format(dWall/D, dBoard/D, dWood/D))
check("furniture arrives last", dFurn >= dWood)
check("timber moves meaningfully on a severe disaster", vWood > 1.25,
      ("wood only %+.1f%%"):format((vWood-1)*100))
check("onset is fast (peaks in the first third)",
      dWall <= e.durationDays / 3,
      ("peaked at day %d of %d"):format(dWall, e.durationDays))

-- ===========================================================================
print("\n[8] self-overlap guard: same event never runs twice at once")

local guardModel = MSWPriceModel.new(function() return 1 end, log)
math.randomseed(555)
local g1 = MSWActiveEvent.new(grainDrought, "high", 0, D, { intensity = 1, duration = 1 })
guardModel:addEvent(g1)

local midway = math.floor(g1.durationDays / 2)
local after  = g1.durationDays + 1

check("id is reported active while running",
      guardModel:hasActiveEvent("grainDrought", midway))
check("id is free again after expiry",
      not guardModel:hasActiveEvent("grainDrought", after))
check("other ids are never blocked",
      not guardModel:hasActiveEvent("rootDrought", midway))

-- Scheduler skips a blocked event's roll entirely: with the block in place the
-- event can never fire, without it it eventually does.
local guardSched = MSWEventScheduler.new({
    events = { grainDrought },
    severityChances = { low = 0.6, medium = 0.3, high = 0.1 },
}, log)
local function countFires(blocked)
    math.randomseed(31337)
    local n = 0
    for _ = 1, 3000 do
        for m = 1, 12 do
            for _ = 1, 3 do
                local fired = guardSched:rollForDay(m, 3, 1.7,
                    blocked and function() return true end or nil)
                n = n + #fired
            end
        end
    end
    return n
end
check("blocked event never fires", countFires(true) == 0)
check("unblocked event still fires normally", countFires(false) > 0)

-- Back-to-back is allowed: expire, then a new instance of the same id.
guardModel:pruneExpired(after)
check("expired instance is pruned",
      #guardModel:getActiveEvents() == 0)
local g2 = MSWActiveEvent.new(grainDrought, "low", after, D, { intensity = 1, duration = 1 })
guardModel:addEvent(g2)
check("subsequent same-id event after expiry is allowed",
      guardModel:hasActiveEvent("grainDrought", after + 1))

-- ===========================================================================
-- ===========================================================================
print("\n[8b] mutual exclusion by subtype: mirrors never overlap")

-- The pair as the real config declares it: same subtype, opposite directions.
local exGlut  = {}
for k, v in pairs(grainDrought) do exGlut[k] = v end
exGlut.id, exGlut.type, exGlut.subtype = "grainBumper", "lose", "grain"
exGlut.severities = grainBumper.severities

local exDrought = {}
for k, v in pairs(grainDrought) do exDrought[k] = v end
exDrought.subtype = "grain"

local exModel = MSWPriceModel.new(function() return 1 end, log)
math.randomseed(909)
local running = MSWActiveEvent.new(exDrought, "medium", 0, D,
                                   { intensity = 1, duration = 1 })
exModel:addEvent(running)

local mid = math.floor(running.durationDays / 2)
local past = running.durationDays + 1

check("the active event carries its subtype", running.subtype == "grain")

local hit = exModel:findActiveBySubtype("grain", mid)
check("a mirror is blocked while its opposite runs", hit ~= nil)
check("the blocker is named, so a log line can say which",
      hit ~= nil and hit.eventId == "grainDrought",
      hit and hit.eventId or "nil")
check("an unrelated subtype is not blocked",
      exModel:findActiveBySubtype("ethanol", mid) == nil)
check("the pair is free again once the first expires",
      exModel:findActiveBySubtype("grain", past) == nil)

-- Subtype defaults to the event id, so an unpaired event still blocks itself and
-- nothing else. This is what keeps the old self-overlap behaviour intact.
local soloModel = MSWPriceModel.new(function() return 1 end, log)
math.randomseed(910)
local solo = MSWActiveEvent.new(grainDrought, "medium", 0, D,
                                { intensity = 1, duration = 1 })
soloModel:addEvent(solo)
check("an event with no subtype falls back to its id",
      solo.subtype == "grainDrought")
check("it still blocks itself",
      soloModel:findActiveBySubtype("grainDrought", 1) ~= nil)
check("and blocks nothing else",
      soloModel:findActiveBySubtype("rootDrought", 1) == nil)

-- End to end through the scheduler: with the glut running, the drought's roll
-- must never fire, using exactly the predicate MarketShockwaves installs.
local exSched = MSWEventScheduler.new({
    events = { exDrought },
    severityChances = { low = 0.6, medium = 0.3, high = 0.1 },
}, log)
local function firesWithMirrorRunning(mirrorActive)
    math.randomseed(24680)
    local model = MSWPriceModel.new(function() return 1 end, log)
    if mirrorActive then
        model:addEvent(MSWActiveEvent.new(exGlut, "medium", 0, D,
                                          { intensity = 1, duration = 1 }))
    end
    local n = 0
    for _ = 1, 2000 do
        for m = 1, 12 do
            local fired = exSched:rollForDay(m, 1, 1.7, function(def)
                return model:findActiveBySubtype(def.subtype or def.id, 0) ~= nil
            end)
            n = n + #fired
        end
    end
    return n
end
check("drought never fires while its mirror glut is active",
      firesWithMirrorRunning(true) == 0)
check("drought fires normally when the glut is not active",
      firesWithMirrorRunning(false) > 0)

print("\n[9] input shock: substitution lifts muck, but only weakly")

local inputShock = {
    id = "inputShock", type = "lose", baseWeight = 1.0,
    affects = { "FERTILIZER", "LIQUIDFERTILIZER", "LIME", "SEEDS" },
    chains = {
        FERTILIZER = { { to = "HERBICIDE",    tier = 1, lagMonths = 0.5,  passThrough = 0.65 },
                       { to = "MANURE",       tier = 1, lagMonths = 0.75, passThrough = 0.35 },
                       { to = "LIQUIDMANURE", tier = 1, lagMonths = 0.75, passThrough = 0.35 },
                       { to = "DIGESTATE",    tier = 1, lagMonths = 0.75, passThrough = 0.35 } },
        SEEDS      = { { to = "RICESAPLINGS", tier = 1, lagMonths = 0.5,  passThrough = 0.60 } },
    },
    severities = {
        high = severity{ priceFactorMin = 1.32, priceFactorMax = 1.32,
            durationMonthsMin = 8, durationMonthsMax = 8,
            peakPosMin = 0.25, peakPosMax = 0.25, riseExpMin = 0.7, riseExpMax = 0.7,
            hold = 0.75, correctionMonths = 1.0, jitter = 0.0,
            rippleDepth = 1, rippleScale = 1.00 },
    },
    monthShare = {},
}
for m = 1, 12 do inputShock.monthShare[m] = (m <= 5 or m == 12) and 1/6 or 0 end

math.randomseed(808)
local ish = MSWActiveEvent.new(inputShock, "high", 0, D, { intensity = 1, duration = 1 })
local function pk(p)
    local best, day = 1.0, 0
    for d = 0, ish.durationDays do
        local f = ish:getFactorFor(p, d)
        if f > best then best, day = f, d end
    end
    return best, day
end
local vFert   = pk("FERTILIZER")
local vHerb   = pk("HERBICIDE")
local vMan, dMan = pk("MANURE")
local vLiq    = pk("LIQUIDMANURE")
local vFertAtMan = ish:getFactorFor("FERTILIZER", dMan)

print(("  HI: fertiliser %+.1f%%  herbicide %+.1f%%  manure %+.1f%%  slurry %+.1f%%")
    :format((vFert-1)*100, (vHerb-1)*100, (vMan-1)*100, (vLiq-1)*100))

check("manure rises (substitution demand)", vMan > 1.0,
      ("manure %+.2f%%"):format((vMan-1)*100))
check("liquid manure rises too", vLiq > 1.0)
check("digestate rises with the other substitutes",
      pk("DIGESTATE") > 1.0)
check("all three substitutes move together",
      math.abs(pk("DIGESTATE") - vMan) < 1e-9 and math.abs(vLiq - vMan) < 1e-9)
check("muck bump is much weaker than the fertiliser hit",
      (vMan - 1) < 0.5 * (vFert - 1),
      ("manure %+.1f%% vs fertiliser %+.1f%%"):format((vMan-1)*100, (vFert-1)*100))
check("muck is weaker than herbicide (0.35 vs 0.65 pass-through)",
      (vMan - 1) < (vHerb - 1))
check("the pain still dominates when muck peaks",
      (vFertAtMan - 1) > (vMan - 1),
      ("fertiliser %+.1f%% vs manure %+.1f%%"):format((vFertAtMan-1)*100, (vMan-1)*100))

-- ===========================================================================
print("\n[10] forage: damped in every drought, compounding when they overlap")

math.randomseed(4242)
local fEv = MSWActiveEvent.new(grainDrought, "high", 0, D, { intensity = 1, duration = 1 })
local function peakOf(e, name)
    local best = 1.0
    for d = 0, e.durationDays do
        local f = e:getFactorFor(name, d)
        if f > best then best = f end
    end
    return best
end
local vWheat = peakOf(fEv, "WHEAT")
local vStraw = peakOf(fEv, "STRAW")
local vGrass = peakOf(fEv, "GRASS_WINDROW")
local vHay   = peakOf(fEv, "DRYGRASS_WINDROW")
print(("  HI drought: wheat %+.1f%%  straw %+.1f%%  grass %+.1f%%  hay %+.1f%%")
    :format((vWheat-1)*100, (vStraw-1)*100, (vGrass-1)*100, (vHay-1)*100))

check("grass is reached", vGrass > 1.0)
check("hay is reached", vHay > 1.0)
check("forage is damped well below the crop", vGrass < 1 + (vWheat - 1) * 0.6,
      ("grass %+.1f%% vs wheat %+.1f%%"):format((vGrass-1)*100, (vWheat-1)*100))
check("forage is damped below straw (0.45 vs 0.80)", vGrass < vStraw)

-- reached at EVERY severity (tier 1, so even LOW gets it)
for _, cls in ipairs({ "low", "medium", "high" }) do
    local e = MSWActiveEvent.new(grainDrought, cls, 0, D, { intensity = 1, duration = 1 })
    check(("forage reached at %s severity"):format(cls),
          e.reach["GRASS_WINDROW"] ~= nil and e.reach["DRYGRASS_WINDROW"] ~= nil)
end

-- two overlapping droughts compound on forage, which is the whole point
local rootLike = {
    id = "rootDrought", type = "win", baseWeight = 1.0,
    affects = { "POTATO" },
    chains = { POTATO = {
        { to = "GRASS_WINDROW",    tier = 1, lagMonths = 0.25, passThrough = 0.45 },
        { to = "DRYGRASS_WINDROW", tier = 1, lagMonths = 0.5,  passThrough = 0.45 } } },
    severities = grainDrought.severities,
    monthShare = grainDrought.monthShare,
}
local fModel = MSWPriceModel.new(function(n)
    return ({ GRASS_WINDROW = 1, DRYGRASS_WINDROW = 2 })[n]
end, log)
math.randomseed(8080)
local dA = MSWActiveEvent.new(grainDrought, "high", 0, D, { intensity = 1, duration = 1 })
local dB = MSWActiveEvent.new(rootLike,     "high", 0, D, { intensity = 1, duration = 1 })
fModel:addEvent(dA); fModel:addEvent(dB)
local probe = math.floor(math.min(dA.durationDays, dB.durationDays) * 0.45)
fModel:rebuild(probe)
local both = fModel:getModifier(1)
local justA = dA:getFactorFor("GRASS_WINDROW", probe)
print(("  overlapping droughts: one gives %+.1f%%, both give %+.1f%% on grass")
    :format((justA-1)*100, (both-1)*100))
check("two droughts compound on forage", both > justA + 0.02,
      ("%.4f vs %.4f"):format(both, justA))
check("different drought ids are allowed to overlap",
      fModel:hasActiveEvent("grainDrought", probe)
      and fModel:hasActiveEvent("rootDrought", probe))

-- ===========================================================================
print("\n[11] jitter noise quality (guards against the sawtooth regression)")
do
    -- A real seed from a savegame; large enough to have overflowed 2^53 in the
    -- original implementation.
    local seed = 1081859968

    -- 1) consecutive days must not step by a constant (that was the bug)
    local steps, prev = {}, nil
    for d = 0, 200 do
        local n = MSWRandom.signedNoise(seed, d)
        if prev then steps[#steps + 1] = n - prev end
        prev = n
    end
    local sum = 0
    for _, v in ipairs(steps) do sum = sum + v end
    local mean = sum / #steps
    local sd = 0
    for _, v in ipairs(steps) do sd = sd + (v - mean) ^ 2 end
    sd = math.sqrt(sd / #steps)
    print(("  consecutive-day step deviation: %.3f"):format(sd))
    check("jitter is not a constant-step ramp", sd > 0.4,
          ("step sd %.4f - an affine hash gives ~0"):format(sd))

    -- 2) roughly uniform across [-1, 1]
    local buckets = {}
    for i = 1, 10 do buckets[i] = 0 end
    local N = 0
    for sOff = 1, 40 do
        for d = 1, 500 do
            local n = MSWRandom.signedNoise(seed + sOff * 7919, d)
            local b = math.min(10, math.max(1, math.floor((n + 1) / 2 * 10) + 1))
            buckets[b] = buckets[b] + 1
            N = N + 1
        end
    end
    local worst = 0
    for i = 1, 10 do worst = math.max(worst, math.abs(buckets[i] / N - 0.1)) end
    print(("  worst decile deviation from uniform: %.1f%%"):format(worst * 100))
    check("jitter is roughly uniform", worst < 0.03,
          ("worst decile off by %.1f%%"):format(worst * 100))

    -- 3) stays in range, and different seeds give different streams
    local lo, hi = 1, -1
    for d = 1, 5000 do
        local n = MSWRandom.signedNoise(seed, d)
        lo = math.min(lo, n); hi = math.max(hi, n)
    end
    check("jitter stays within [-1, 1]", lo >= -1.0001 and hi <= 1.0001,
          ("range %.3f..%.3f"):format(lo, hi))
    check("different seeds give different noise",
          MSWRandom.signedNoise(111, 5) ~= MSWRandom.signedNoise(222, 5))

    -- 4) reproducible, which the ripple lag and save/reload both depend on
    check("noise is reproducible for the same inputs",
          MSWRandom.signedNoise(seed, 42) == MSWRandom.signedNoise(seed, 42))
end


-- ---------------------------------------------------------------------------
print("\n[12] commodity markers track the curve as days pass")
-- Regression test for markers going stale during an event.
--
-- The modifier table is rebuilt every day, but originally the markers were only
-- refreshed at the instant an event fired. Whatever was written then (at the
-- time: nothing, because the curve started at exactly 1.0) stayed on screen for
-- the whole event, and was never cleared afterwards. The daily tick must
-- refresh too.
do
    load("game/PriceDisplayAdapter.lua")

    -- A fill type manager holding just the products this event touches.
    local titles = { [1] = "Diesel", [2] = "Silage" }
    local byName = { DIESEL = 1, SILAGE = 2 }
    local fts = {
        [1] = { title = titles[1] },
        [2] = { title = titles[2] },
    }
    g_fillTypeManager = {
        getFillTypeByIndex = function(_, idx) return fts[idx] end,
    }

    local winter = {
        id = "harshWinter", type = "neutral", baseWeight = 1.0,
        affects = { "DIESEL" },
        chains = { DIESEL = { { to = "SILAGE", tier = 1,
                                lagMonths = 1.0, passThrough = 0.60 } } },
        severities = { low = severity{
            priceFactorMin = 1.15, priceFactorMax = 1.20,
            durationMonthsMin = 1, durationMonthsMax = 2,
            peakPosMin = 0.20, peakPosMax = 0.45,
            riseExpMin = 0.6, riseExpMax = 1.0,
            hold = 0.55, correctionMonths = 0.4, jitter = 0.015,
            rippleDepth = 1, rippleScale = 0.55 } },
    }
    winter.getSeverity = function(self, c) return self.severities[c] end

    -- A long season, so the curve has day-by-day resolution to observe.
    local DPM = 12
    local function freshModel()
        local m = MSWPriceModel.new(function(n) return byName[n] end, log)
        m:addEvent(MSWActiveEvent.new(winter, "low", 0, DPM,
                                      { intensity = 1.0, duration = 1.0 }))
        return m
    end
    local function resetTitles()
        for i, t in pairs(titles) do fts[i].title = t end
    end
    local function isMarked(idx) return fts[idx].title ~= titles[idx] end

    -- (a) prices move on the firing day itself, so a marker is due at once
    local m0 = freshModel()
    m0:rebuild(0)
    check("the price already moves on the day the event fires",
          m0:getModifier(1) > 1.01,
          ("got %.4f"):format(m0:getModifier(1)))

    -- (b) THE BUG: refresh only at event-fire time -> the marker goes stale
    resetTitles()
    local buggy = freshModel()
    local disp = PriceDisplayAdapter.new(buggy, nil, log)
    buggy:rebuild(0)
    disp:refresh()                      -- the one refresh the old code did
    local atFire = fts[1].title
    buggy:rebuild(9)                    -- prices move on, nothing refreshes
    local truth = titles[1] .. disp:formatMarker(buggy:getModifier(1))
    check("without a daily refresh the marker is stale mid-event (the bug)",
          fts[1].title == atFire and fts[1].title ~= truth,
          ("shows %q, should show %q"):format(fts[1].title, truth))
    buggy:rebuild(60)                   -- event long over
    check("without a daily refresh the marker outlives the event (the bug)",
          isMarked(1))

    -- (c) THE FIX: refresh on every daily rebuild -> marker tracks the curve
    resetTitles()
    local fixed = freshModel()
    local disp2 = PriceDisplayAdapter.new(fixed, nil, log)
    local markedDays, peakTitle = 0, nil
    for d = 0, 25 do
        fixed:rebuild(d)
        disp2:refresh()                 -- what the daily tick now does
        if isMarked(1) then
            markedDays = markedDays + 1
            if d == 9 then peakTitle = fts[1].title end
        end
    end
    check("with a daily refresh the marker appears while the event runs",
          markedDays > 10, ("marked on %d of 26 days"):format(markedDays))
    check("the marker carries the percentage",
          peakTitle ~= nil and peakTitle:match("^Diesel%s+%[%+%d+%%%]$") ~= nil,
          ("title was %q"):format(tostring(peakTitle)))
    print(("  peak-day title: %s"):format(tostring(peakTitle)))

    -- (d) the title is handed back intact once the event is over
    fixed:rebuild(60)
    disp2:refresh()
    check("titles are restored after the event expires",
          fts[1].title == titles[1] and fts[2].title == titles[2],
          ("got %q / %q"):format(fts[1].title, fts[2].title))

    -- (e) Bind the contract to the real file. The checks above simulate the
    --     daily tick by hand, so on their own they would still pass if someone
    --     deleted the refresh from update(). update() is the only path that
    --     runs as days pass, so assert the call is actually there.
    local f = assert(io.open(ROOT .. "MarketShockwaves.lua", "r"))
    local src = f:read("*a"); f:close()
    local body = src:match(
        "function MarketShockwaves:update%(dt%)(.-)\nfunction MarketShockwaves:")
    check("update() is still parseable for this check", body ~= nil)
    check("update() refreshes the markers as days pass",
          body ~= nil and body:match("display:refresh%(%)") ~= nil,
          "no display:refresh() in update() - markers will never appear")
    check("that refresh is gated on the day, not run every frame",
          body ~= nil and body:match("lastMarkedDay") ~= nil,
          "refresh() walks every affected fill type; it must not run per frame")

    g_fillTypeManager = nil
end

-- ---------------------------------------------------------------------------
print("\n[13] short seasons: chains fire and the news moves the market at once")
-- Most players run 1 or 2 days per month, where a short event is a handful of
-- whole days. Two things used to go wrong there: a one-month chain lag was most
-- (or all) of a short event, so downstream products never moved; and a day's
-- price was read at the day's first instant, so the firing day was always flat.
do
    local winter = {
        id = "harshWinter", type = "neutral", baseWeight = 1.0,
        affects = { "DIESEL", "ELECTRICCHARGE", "METHANE" },
        chains = { METHANE = {
            { to = "SILAGE", tier = 1, lagMonths = 1.0, passThrough = 0.60 } } },
        severities = { low = severity{
            priceFactorMin = 1.15, priceFactorMax = 1.20,
            durationMonthsMin = 1, durationMonthsMax = 2,
            peakPosMin = 0.20, peakPosMax = 0.45,
            riseExpMin = 0.6, riseExpMax = 1.0,
            hold = 0.55, correctionMonths = 0.4, jitter = 0.015,
            rippleDepth = 1, rippleScale = 0.55 } },
    }
    local S = { intensity = 1.0, duration = 1.0 }
    local SHARE = MSWActiveEvent.MAX_HOP_LAG_SHARE

    -- (a) a cold snap at 1 and 2 days per month, many rolls
    for _, dpm in ipairs({ 1, 2 }) do
        local silageDead, flatFiringDay, lagTooLong = 0, 0, 0
        for _ = 1, 200 do
            local ev = MSWActiveEvent.new(winter, "low", 0, dpm, S)
            local best = 0
            for d = 0, ev.durationDays do
                best = math.max(best, math.abs(ev:getFactorFor("SILAGE", d) - 1))
            end
            if best < 0.01 then silageDead = silageDead + 1 end
            if math.abs(ev:getFactorFor("DIESEL", 0) - 1) < 0.01 then
                flatFiringDay = flatFiringDay + 1
            end
            if ev.reach.SILAGE.lagDays > SHARE * ev.durationDays + 1e-9 then
                lagTooLong = lagTooLong + 1
            end
        end
        check(("%d day/month: silage moves in every cold snap"):format(dpm),
              silageDead == 0, ("dead in %d of 200"):format(silageDead))
        check(("%d day/month: diesel moves on the day of the news"):format(dpm),
              flatFiringDay == 0, ("flat in %d of 200"):format(flatFiringDay))
        check(("%d day/month: a month of lag never exceeds its share of the event"):format(dpm),
              lagTooLong == 0, ("too long in %d of 200"):format(lagTooLong))
    end

    -- (b) the cap shortens lags, it never reorders them
    local ev1 = MSWActiveEvent.new(grainDrought, "high", 0, 1, S)
    local r = ev1.reach
    check("short event: flour < bread < cake lag order is kept",
          r.FLOUR.lagDays > 0 and r.BREAD.lagDays > r.FLOUR.lagDays
          and r.CAKE.lagDays > r.BREAD.lagDays,
          ("lags %.2f / %.2f / %.2f"):format(r.FLOUR.lagDays, r.BREAD.lagDays, r.CAKE.lagDays))

    -- (c) long events at long seasons are exactly as configured
    local ev12 = MSWActiveEvent.new(grainDrought, "high", 0, 12, S)
    check("12 days/month drought: flour still lags by exactly one month",
          math.abs(ev12.reach.FLOUR.lagDays - 12) < 1e-9,
          ("lag %.2f days"):format(ev12.reach.FLOUR.lagDays))

    -- (d) when the cap binds, lag depends only on the event's own (saved)
    --     duration - so a reload reproduces it even if the player changed
    --     days-per-month in between
    local sev = winter.severities.low
    local a = MSWActiveEvent.buildReach(winter, sev, 1,  nil, 2).SILAGE.lagDays
    local b = MSWActiveEvent.buildReach(winter, sev, 12, nil, 2).SILAGE.lagDays
    check("capped lag is the same whatever days-per-month says at reload",
          math.abs(a - b) < 1e-9, ("%.3f vs %.3f"):format(a, b))

    -- (e) the same drought traces the same month-by-month profile at 1 and at
    --     12 days per month (midpoint rolls, noise off, month averages)
    local realRange = MSWRandom.range
    MSWRandom.range = function(lo, hi) return (lo + hi) / 2 end
    local function monthly(dpm)
        local ev = MSWActiveEvent.new(grainDrought, "high", 0, dpm, S)
        ev.jitter = 0
        local out = {}
        for m = 1, math.ceil(ev.durationDays / dpm) do
            local sum = 0
            for d = (m - 1) * dpm, m * dpm - 1 do
                sum = sum + (ev:getFactorFor("WHEAT", d) - 1) * 100
            end
            out[m] = sum / dpm
        end
        return out
    end
    local short, long = monthly(1), monthly(12)
    MSWRandom.range = realRange
    local worst = 0
    for m = 1, math.min(#short, #long) do
        worst = math.max(worst, math.abs(short[m] - long[m]))
    end
    print(("  worst month-average gap, 1 vs 12 days/month: %.1f points"):format(worst))
    check("same event length in months at both season lengths", #short == #long,
          ("%d vs %d months"):format(#short, #long))
    check("wheat follows the same monthly profile at 1 and 12 days/month",
          worst < 3.0, ("worst gap %.1f points"):format(worst))
end

print(("\n===== %d passed, %d failed =====\n"):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
