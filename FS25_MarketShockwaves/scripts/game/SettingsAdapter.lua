--[[
    SettingsAdapter — the player-facing settings.

    Fifteen settings, matching the in-game menu:

      MASTER
        enabled                 turn the whole mod off without uninstalling,
                                keeping savegame state intact

      FREQUENCY
        eventsPerYear           average total events/year (0 = none)
        minMonthsBetweenEvents  minimum months between event STARTS; 2 leaves one
                                whole month silent
        maxConcurrentEvents     hard ceiling on simultaneous events, the companion
                                rail to the cooldown

      MAGNITUDE
        intensity               0..2 multiplier on price swing and jitter
        duration                0..2 multiplier on how long events last

      SCOPE
        supplyChainDepth        0 = raw products only, 1..3 = how far a ripple may
                                travel up the processing chain

      PRESENTATION
        showMarkers             the [+60%] suffix on commodity names. It also
                                shows in the shop and HUD, hence the opt-out.

      CATEGORIES  (seven on/off switches, matching config/events.xml)
        catCrops catGreenhouse catTrade catBiofuel catWinter catSupplies
        catConsumer

    Values are held here and persisted with the savegame. Every consumer reads
    through this adapter, so the in-game menu only has to move these numbers -
    it never touches the simulation.
]]

MSWSettingsAdapter = {}
local MSWSettingsAdapter_mt = Class(MSWSettingsAdapter)

local DEFAULTS = {
    enabled = 1,                    -- boolean settings are 0/1 so one code path
                                    -- covers every value the menu can hand back

    eventsPerYear = 2.0,
    -- Minimum months between event STARTS. 2 leaves one whole month silent:
    --   April  event fires
    --   May    nothing can fire
    --   June   events may fire again
    -- 1 would be a no-op, since consecutive months are already permitted.
    minMonthsBetweenEvents = 2.0,
    -- Ceiling on simultaneous events. Events are designed to stack and compound,
    -- so this is the rail that stops an unlucky run piling up indefinitely.
    maxConcurrentEvents = 3,

    intensity = 1.0,
    duration  = 1.0,

    -- 0 = raw products only (no ripple at all), 1..3 = highest chain tier a
    -- ripple may reach. 3 is the full graph, which is what the severities
    -- themselves already scale within.
    supplyChainDepth = 3,

    showMarkers = 1,

    -- Forecasts (speculation). Off stops NEW forecasts; one already announced
    -- still gets its verdict.
    forecasts = 1,

    catCrops = 1, catGreenhouse = 1, catTrade = 1,
    catBiofuel = 1, catWinter = 1, catSupplies = 1,
    catConsumer = 1,
}

-- Per-setting bounds. Anything absent is treated as a 0..2 multiplier.
local LIMITS = {
    enabled                = { 0, 1,  true },
    showMarkers            = { 0, 1,  true },
    forecasts              = { 0, 1,  true },
    catCrops               = { 0, 1,  true },
    catGreenhouse          = { 0, 1,  true },
    catTrade               = { 0, 1,  true },
    catBiofuel             = { 0, 1,  true },
    catWinter              = { 0, 1,  true },
    catSupplies            = { 0, 1,  true },
    catConsumer            = { 0, 1,  true },
    eventsPerYear          = { 0, 50, false },
    minMonthsBetweenEvents = { 0, 12, false },
    maxConcurrentEvents    = { 1, 10, true },
    supplyChainDepth       = { 0, 3,  true },
    intensity              = { 0, 2,  false },
    duration               = { 0, 2,  false },
}

-- config category -> setting name
local CATEGORY_SETTING = {
    crops = "catCrops", greenhouse = "catGreenhouse", trade = "catTrade",
    biofuel = "catBiofuel", winter = "catWinter", supplies = "catSupplies",
    consumer = "catConsumer",
}

function MSWSettingsAdapter.new(logger)
    local self = setmetatable({}, MSWSettingsAdapter_mt)
    self.log = logger
    self.values = {}
    for k, v in pairs(DEFAULTS) do self.values[k] = v end
    return self
end

function MSWSettingsAdapter:get(name)
    local v = self.values[name]
    if v == nil then return DEFAULTS[name] end
    return v
end

function MSWSettingsAdapter:set(name, value)
    if DEFAULTS[name] == nil then
        self.log:warn("SettingsAdapter: unknown setting " .. tostring(name))
        return false
    end

    -- Accept the words the menu and console both produce.
    if type(value) == "boolean" then
        value = value and 1 or 0
    elseif type(value) == "string" then
        local lower = value:lower()
        if lower == "on" or lower == "true" or lower == "yes" then value = 1
        elseif lower == "off" or lower == "false" or lower == "no" then value = 0
        else value = tonumber(value) end
    end
    if type(value) ~= "number" then return false end

    local lim = LIMITS[name] or { 0, 2, false }
    if value < lim[1] then value = lim[1] end
    if value > lim[2] then value = lim[2] end
    if lim[3] then value = math.floor(value + 0.5) end

    self.values[name] = value
    self.log:info(("setting %s = %s"):format(name, tostring(value)))
    return true
end

--- Boolean read for the 0/1 settings.
function MSWSettingsAdapter:isOn(name)
    return (self:get(name) or 0) >= 0.5
end

--- Is this event's category switched on? Unknown categories stay enabled, so a
--- new category added to the config is never silently suppressed.
function MSWSettingsAdapter:isCategoryEnabled(category)
    local key = CATEGORY_SETTING[category]
    if key == nil then return true end
    return self:isOn(key)
end

--- Every category name the menu should offer, with its setting key.
function MSWSettingsAdapter.getCategories()
    return {
        { category = "crops",      setting = "catCrops" },
        { category = "greenhouse", setting = "catGreenhouse" },
        { category = "trade",      setting = "catTrade" },
        { category = "biofuel",    setting = "catBiofuel" },
        { category = "winter",     setting = "catWinter" },
        { category = "supplies",   setting = "catSupplies" },
        { category = "consumer",   setting = "catConsumer" },
    }
end

--- Ordered menu specification.
---
--- The in-game settings page is built entirely from this, so adding or reordering
--- a row means editing this table and nothing else. Each entry gives:
---   name     the setting key
---   kind     "bool" or "choice"
---   values   for "choice": the discrete steps the control cycles through.
---            FS settings rows are option pickers, not free-text fields, so
---            continuous settings are exposed as sensible steps.
---   labels   optional display text per value; otherwise values are formatted
---   fmt      "percent" renders 1.0 as "100%"
---
--- Label and tooltip l10n keys follow msw_setting_<name> and
--- msw_tooltip_<name>, so the description panel is filled automatically.
local MENU_SPEC = {
    { name = "enabled",                kind = "bool" },

    { name = "eventsPerYear",          kind = "choice",
      values = { 0, 0.5, 1, 1.5, 1.7, 2, 2.5, 3, 4, 5, 8, 10 } },

    { name = "minMonthsBetweenEvents", kind = "choice",
      values = { 0, 1, 2, 3, 4, 6, 8, 12 } },

    { name = "maxConcurrentEvents",    kind = "choice",
      values = { 1, 2, 3, 4, 5, 8 } },

    { name = "intensity",              kind = "choice", fmt = "percent",
      values = { 0, 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0 } },

    { name = "duration",               kind = "choice", fmt = "percent",
      values = { 0.25, 0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0 } },

    { name = "supplyChainDepth",       kind = "choice",
      values = { 0, 1, 2, 3 },
      labels = { "msw_depth_raw", "msw_depth_first",
                 "msw_depth_most", "msw_depth_full" } },

    { name = "showMarkers",            kind = "bool" },

    { name = "forecasts",              kind = "bool" },

    -- Event categories, matching the category attribute in events.xml.
    { name = "catCrops",      kind = "bool" },
    { name = "catGreenhouse", kind = "bool" },
    { name = "catTrade",      kind = "bool" },
    { name = "catBiofuel",    kind = "bool" },
    { name = "catWinter",     kind = "bool" },
    { name = "catSupplies",   kind = "bool" },
    { name = "catConsumer",   kind = "bool" },
}

--- The menu rows, in display order.
function MSWSettingsAdapter.getMenuSpec() return MENU_SPEC end

--- l10n key for a setting's label and for its description panel.
function MSWSettingsAdapter.getLabelKey(name)   return "msw_setting_" .. name end
function MSWSettingsAdapter.getTooltipKey(name) return "msw_tooltip_" .. name end

--- Display strings for a choice row, ready for the control.
function MSWSettingsAdapter.getChoiceTexts(entry)
    local out = {}
    for i, v in ipairs(entry.values or {}) do
        if entry.labels ~= nil and entry.labels[i] ~= nil then
            out[i] = entry.labels[i]        -- an l10n key; resolved by the caller
        elseif entry.fmt == "percent" then
            out[i] = ("%d%%"):format(math.floor(v * 100 + 0.5))
        elseif v == math.floor(v) then
            out[i] = tostring(math.floor(v))
        else
            out[i] = tostring(v)
        end
    end
    return out
end

--- Index (1-based) of the step closest to the current value, for setting the
--- control's initial state.
function MSWSettingsAdapter:getChoiceIndex(entry)
    local current = self:get(entry.name)
    local best, bestDiff = 1, math.huge
    for i, v in ipairs(entry.values or {}) do
        local d = math.abs(v - current)
        if d < bestDiff then best, bestDiff = i, d end
    end
    return best
end

--- Names of every setting, for persistence and for building the menu.
function MSWSettingsAdapter.getAllNames()
    local names = {}
    for k in pairs(DEFAULTS) do names[#names + 1] = k end
    table.sort(names)
    return names
end

function MSWSettingsAdapter.getDefault(name) return DEFAULTS[name] end
function MSWSettingsAdapter.getLimits(name) return LIMITS[name] or { 0, 2, false } end

--- Bundle used when rolling an event instance.
function MSWSettingsAdapter:getInstanceScalers()
    return {
        intensity = self:get("intensity"),
        duration = self:get("duration"),
        supplyChainDepth = self:get("supplyChainDepth"),
    }
end

function MSWSettingsAdapter:saveToXML(xmlFile, key)
    for _, name in ipairs(MSWSettingsAdapter.getAllNames()) do
        setXMLFloat(xmlFile, key .. "#" .. name, self:get(name))
    end
end

function MSWSettingsAdapter:loadFromXML(xmlFile, key)
    for _, name in ipairs(MSWSettingsAdapter.getAllNames()) do
        local v = getXMLFloat(xmlFile, key .. "#" .. name)
        -- Route through set() so an out-of-range value in an old or hand-edited
        -- savegame is clamped rather than trusted.
        if v ~= nil then self:set(name, v) end
    end
end

--- Restore every setting to its shipped default (menu "reset" / console use).
function MSWSettingsAdapter:resetToDefaults()
    for k, v in pairs(DEFAULTS) do self.values[k] = v end
    self.log:info("settings reset to defaults")
end
