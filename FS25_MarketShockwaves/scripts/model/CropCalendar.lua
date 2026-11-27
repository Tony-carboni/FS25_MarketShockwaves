--[[
    CropCalendar — when a crop is sown and when it is harvested.

    Forecasts are about planting decisions, so they have to know the calendar:
    a forecast that arrives after sowing has closed, or pays out before the crop
    can be harvested, changes nothing the player can act on.

    Maps change the calendar, so the months are NOT written in the config. Each
    crop's own data file carries a twelve-period growth table: which periods
    allow planting, and how a plant moves from one growth stage to the next in
    each period. This module walks that table from sowing to the harvest-ready
    stage. It is pure logic; the game layer (CropCalendarAdapter) reads the file
    and hands the table over.

    PERIODS AND MONTHS. Period 1 is early spring, which is March. Everything
    this module returns is in calendar months (1 = January).

    WHEN A GROWTH STEP APPLIES. A period's step takes effect at the END of that
    period: a plant that turns harvest-ready in early summer is harvestable from
    mid summer. Checked against the base game, whose in-game calendar shows
    wheat sown September-October and harvested July-August, exactly what this
    walk gives for the base wheat table.
]]

MSWCropCalendar = {}

MSWCropCalendar.PERIOD_NAMES = {
    "EARLY_SPRING", "MID_SPRING", "LATE_SPRING",
    "EARLY_SUMMER", "MID_SUMMER", "LATE_SUMMER",
    "EARLY_AUTUMN", "MID_AUTUMN", "LATE_AUTUMN",
    "EARLY_WINTER", "MID_WINTER", "LATE_WINTER",
}

--- Used when a map's calendar cannot be read, or seasonal growth is off (crops
--- can then be sown at any time, so there is no calendar to follow). These are
--- the base game's months, as given by walking its own crop files.
MSWCropCalendar.BASE = {
    WHEAT     = { sowFirst = 9,  sow = { 9, 10 }, harvestFirst = 7,  harvest = { 7, 8 } },
    BARLEY    = { sowFirst = 9,  sow = { 9, 10 }, harvestFirst = 6,  harvest = { 6, 7 } },
    OAT       = { sowFirst = 3,  sow = { 3, 4 },  harvestFirst = 7,  harvest = { 7, 8 } },
    CANOLA    = { sowFirst = 8,  sow = { 8, 9 },  harvestFirst = 7,  harvest = { 7, 8 } },
    SUNFLOWER = { sowFirst = 3,  sow = { 3, 4 },  harvestFirst = 10, harvest = { 10, 11 } },
    MAIZE     = { sowFirst = 4,  sow = { 4, 5 },  harvestFirst = 10, harvest = { 10, 11 } },
    SOYBEAN   = { sowFirst = 4,  sow = { 4, 5 },  harvestFirst = 10, harvest = { 10, 11 } },
    POTATO    = { sowFirst = 3,  sow = { 3, 4 },  harvestFirst = 8,  harvest = { 8, 9 } },
    SUGARBEET = { sowFirst = 3,  sow = { 3, 4 },  harvestFirst = 10, harvest = { 10, 11 } },
    SUGARCANE = { sowFirst = 3,  sow = { 3, 4 },  harvestFirst = 10, harvest = { 10, 11 } },
}

--- Period (1 = early spring) to calendar month (1 = January).
function MSWCropCalendar.periodToMonth(period)
    return (period + 1) % 12 + 1
end

--- Whole months from month `a` forward to month `b`: 0 when they are the same.
function MSWCropCalendar.monthsUntil(a, b)
    return (b - a) % 12
end

--- Walk a growth table.
---
--- @param t table {
---     sownState     = "invisible",            the stage a freshly sown plant is in
---     harvestStates = { harvestReady = true }, stages that can be harvested
---     periods       = { [1..12] = { plantingAllowed = bool,
---                                   updates = { { from = "a", to = "b" }, ... } } } }
--- @return table|nil { sowFirst, sow = {months}, harvestFirst, harvest = {months} }
---         nil when the table gives no usable sowing window or never reaches
---         harvest - the caller then falls back to the base calendar.
function MSWCropCalendar.fromGrowthTable(t)
    if type(t) ~= "table" or type(t.periods) ~= "table" or t.sownState == nil
       or type(t.harvestStates) ~= "table" then
        return nil
    end

    local sowPeriods, count = {}, 0
    for p = 1, 12 do
        local period = t.periods[p]
        if type(period) ~= "table" then return nil end
        if period.plantingAllowed then
            sowPeriods[p] = true
            count = count + 1
        end
    end
    -- Sowable never, or all year: neither gives a window to plan around.
    if count == 0 or count == 12 then return nil end

    -- The window opens at the first sowing period that follows a closed one.
    local firstSow
    for p = 1, 12 do
        local previous = (p - 2) % 12 + 1
        if sowPeriods[p] and not sowPeriods[previous] then firstSow = p break end
    end
    if firstSow == nil then return nil end

    local harvestSet, harvestFirst = {}, nil
    local sow = {}
    for offset = 0, 11 do
        local p0 = (firstSow - 1 + offset) % 12 + 1
        if not sowPeriods[p0] then break end        -- end of this sowing window
        sow[#sow + 1] = MSWCropCalendar.periodToMonth(p0)

        local state = t.sownState
        for step = 0, 23 do
            local p = (p0 - 1 + step) % 12 + 1
            if step > 0 and t.harvestStates[state] then
                local month = MSWCropCalendar.periodToMonth(p)
                harvestSet[month] = true
                if offset == 0 and harvestFirst == nil then harvestFirst = month end
            end
            -- This period's step, applied at its end. One step per period: the
            -- rows are alternatives for different stages, not a sequence.
            for _, update in ipairs(t.periods[p].updates or {}) do
                if update.from == state then
                    state = update.to
                    break
                end
            end
        end
    end
    if harvestFirst == nil then return nil end

    -- Harvest months in season order, starting from the first.
    local harvest = {}
    for offset = 0, 11 do
        local month = (harvestFirst - 1 + offset) % 12 + 1
        if harvestSet[month] then harvest[#harvest + 1] = month end
    end

    return {
        sowFirst = MSWCropCalendar.periodToMonth(firstSow), sow = sow,
        harvestFirst = harvestFirst, harvest = harvest,
    }
end
