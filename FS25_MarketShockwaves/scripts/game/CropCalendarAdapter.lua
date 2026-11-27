--[[
    CropCalendarAdapter — reads each crop's sowing and harvest months from the
    map that is loaded.

    Where the data comes from, all of it confirmed in the game's own scripts:

      * g_fruitTypeManager:getFruitTypeByName(name) gives the crop, or nil when
        the map does not have it;
      * the crop keeps the path of the data file it was loaded from
        (`xmlFilename`), so a map that ships its own wheat is read from ITS
        file, not the base game's;
      * that file holds the growth stages and a twelve-period growth table;
      * crop:getIsPlantableInPeriod(growthMode, period) is what the game's own
        seeders ask before letting the player sow. It is used here as the last
        word on the sowing months, and to notice when seasonal growth is off.

    MSWCropCalendar walks the table to find the harvest months. Nothing here
    needs the player to do anything, and every failure falls back to the base
    game's months with one log line saying why.
]]

MSWCropCalendarAdapter = {}
local MSWCropCalendarAdapter_mt = Class(MSWCropCalendarAdapter)

local PERIOD_INDEX = {}
for index, name in ipairs(MSWCropCalendar.PERIOD_NAMES) do PERIOD_INDEX[name] = index end

function MSWCropCalendarAdapter.new(logger)
    local self = setmetatable({}, MSWCropCalendarAdapter_mt)
    self.log = logger
    self.cache = {}     -- name -> calendar, or false when the map lacks the crop
    return self
end

function MSWCropCalendarAdapter:reset()
    self.cache = {}
end

--- Sowing periods as the game itself reports them, or nil if it cannot be asked.
local function plantablePeriods(crop)
    if type(crop.getIsPlantableInPeriod) ~= "function" then return nil end
    local mission = g_currentMission
    local growthMode = mission ~= nil and mission.missionInfo ~= nil
                       and mission.missionInfo.growthMode or nil
    if growthMode == nil then return nil end

    local periods, count = {}, 0
    for period = 1, 12 do
        local ok, plantable = pcall(crop.getIsPlantableInPeriod, crop, growthMode, period)
        if not ok then return nil end
        if plantable then
            periods[period] = true
            count = count + 1
        end
    end
    return periods, count
end

--- Read a crop file's growth stages and growth table.
local function readGrowthTable(path)
    if loadXMLFile == nil or fileExists == nil or not fileExists(path) then return nil end
    local xml = loadXMLFile("mswCropCalendar", path)
    if xml == nil or xml == 0 then return nil end

    local t = { harvestStates = {}, periods = {} }
    local i = 0
    while true do
        local key = ("foliageType.foliageLayer(0).foliageState(%d)"):format(i)
        if not hasXMLProperty(xml, key) then break end
        local name = getXMLString(xml, key .. "#name")
        if name ~= nil then
            -- A freshly sown plant is in the first stage.
            if t.sownState == nil then t.sownState = name end
            if getXMLBool(xml, key .. "#isHarvestReady") == true then
                t.harvestStates[name] = true
            end
        end
        i = i + 1
    end

    local p = 0
    while true do
        local key = ("foliageType.growth.seasonal.period(%d)"):format(p)
        if not hasXMLProperty(xml, key) then break end
        local index = PERIOD_INDEX[getXMLString(xml, key .. "#name") or ""] or (p + 1)
        local period = { plantingAllowed = getXMLBool(xml, key .. "#plantingAllowed") == true,
                         updates = {} }
        local u = 0
        while true do
            local ukey = ("%s.update(%d)"):format(key, u)
            if not hasXMLProperty(xml, ukey) then break end
            local from = getXMLString(xml, ukey .. "#startState")
            local to = getXMLString(xml, ukey .. "#endState")
            if from ~= nil and to ~= nil then
                period.updates[#period.updates + 1] = { from = from, to = to }
            end
            u = u + 1
        end
        t.periods[index] = period
        p = p + 1
    end
    delete(xml)

    for index = 1, 12 do
        if t.periods[index] == nil then return nil end
    end
    return t
end

local function describe(calendar)
    return ("sown %s, harvested %s"):format(table.concat(calendar.sow, "/"),
                                           table.concat(calendar.harvest, "/"))
end

--- @return table|nil { sowFirst, sow, harvestFirst, harvest } in calendar
---         months, or nil when this map does not have the crop
function MSWCropCalendarAdapter:get(name)
    local cached = self.cache[name]
    if cached ~= nil then return cached ~= false and cached or nil end

    local calendar, source = nil, nil
    local ok, err = pcall(function()
        local crop = g_fruitTypeManager ~= nil and g_fruitTypeManager.getFruitTypeByName ~= nil
                     and g_fruitTypeManager:getFruitTypeByName(name) or nil
        if crop == nil then
            source = "absent"
            return
        end

        local base = MSWCropCalendar.BASE[name]
        local plantable, count = plantablePeriods(crop)
        if plantable ~= nil and count == 12 then
            -- Sowable all year: seasonal growth is off, so there is no calendar.
            calendar, source = base, "base months (no sowing season on this savegame)"
            return
        end

        local growth = type(crop.xmlFilename) == "string" and readGrowthTable(crop.xmlFilename) or nil
        if growth ~= nil and plantable ~= nil and count > 0 then
            -- The game's own answer decides which periods allow sowing.
            for period = 1, 12 do
                growth.periods[period].plantingAllowed = plantable[period] == true
            end
        end
        local walked = growth ~= nil and MSWCropCalendar.fromGrowthTable(growth) or nil
        if walked ~= nil then
            calendar, source = walked, "the map's crop file"
        else
            calendar, source = base, "base months (crop file could not be read)"
        end
    end)
    if not ok then
        calendar, source = MSWCropCalendar.BASE[name], "base months (error: " .. tostring(err) .. ")"
    end

    if calendar == nil then
        self.cache[name] = false
        self.log:info(("crop calendar: %s is not on this map"):format(name))
        return nil
    end
    self.cache[name] = calendar
    self.log:info(("crop calendar: %s %s (months; from %s)")
        :format(name, describe(calendar), tostring(source)))
    return calendar
end
