--[[
    MarketShockwaves — entry point.

    Wires the pieces together and hooks the game lifecycle:

      Mission00.load                  -> construct
      Mission00.loadMission00Finished -> resolve calendar, install price hooks
      FSBaseMission.update            -> detect a new day, roll events
      FSBaseMission.saveSavegame      -> persist active events + settings
      FSBaseMission.delete            -> tear down

    Console commands (dev console: enable it in game.xml, then press ~):
      mswStatus                       show settings, calendar and active events
      mswTrigger <eventId> [severity] force an event immediately
      mswPrice <PRODUCT>              show the current modifier for a product
      mswClear                        remove all active events
      mswSet <setting> <value>        any setting; mswSettings lists them
      mswSettings                     show every setting with its current value
      mswReset                        restore all settings to defaults
      mswDebug                        toggle verbose logging
      mswHooks                        check our price hooks are still installed
      mswDump                         write a full diagnostic dump to log.txt
      mswNotify <id> [severity]       preview an event message without starting it
      mswMarkers on|off               toggle the [+13%] commodity markers
      mswWelcome                      show the welcome message again
      mswForecasts                    show open forecasts and what this map offers
      mswForecast [id] [variant] [70|80|90]   announce a forecast now
      mswForecastSkip                 bring open forecasts to their pre-move
      mswVerdict [outcome]            decide the oldest open forecast now

    The forecast commands exist for testing. Nothing a player needs is behind a
    console command: forecasts arrive, resolve and are listed in the menu on
    their own.
]]

MarketShockwaves = {}
local MarketShockwaves_mt = Class(MarketShockwaves)

local SAVEGAME_KEY = "marketShockwaves"

-- Bumped on every test build that gets zipped. Logged unconditionally, because
-- a stale install once cost a full round trip of diagnosis: the log looked like
-- a code bug when the game was simply running yesterday's files.
local BUILD = "b24"

-- msw_welcome_p1 .. pN in the l10n file.
local WELCOME_PARAGRAPHS = 5

-- Forecast outcomes a tester may force with mswVerdict.
local OUTCOME_NAMES = { asForecast = true, stronger = true, milder = true,
                        wrongReason = true, backfire = true }

function MarketShockwaves.new(modDirectory, modName)
    local self = setmetatable({}, MarketShockwaves_mt)

    self.modDirectory = modDirectory
    self.modName = modName

    self.log = MSWLogger.new(false)
    self.log:info(("Market Shockwaves loading (%s) build=%s")
        :format(tostring(modName), BUILD))

    self.settings = MSWSettingsAdapter.new(self.log)
    self.calendar = CalendarAdapter.new(self.log)
    self.notifier = MSWNotificationAdapter.new(self.log)

    self.config = MSWEventDef.loadAll(
        Utils.getFilename("config/events.xml", modDirectory), self.log)
    self.scheduler = MSWEventScheduler.new(self.config, self.log)

    self.priceModel = MSWPriceModel.new(function(name)
        return self.economy and self.economy:getFillTypeIndex(name) or nil
    end, self.log)

    self.economy = EconomyAdapter.new(self.priceModel, self.log)
    self.display = PriceDisplayAdapter.new(self.priceModel, self.economy, self.log)

    -- Forecasts. Their outcome events are added to self.config, so restoring a
    -- savegame finds them like any other event.
    self.forecastConfig = MSWForecastDef.loadAll(
        Utils.getFilename("config/forecasts.xml", modDirectory), self.config, self.log)
    self.cropCalendar = MSWCropCalendarAdapter.new(self.log)
    self.forecasts = MSWForecastEngine.new(self.forecastConfig, self.config,
        function(cropName) return self.cropCalendar:get(cropName) end, self.log)
    -- An open forecast moves prices only in its pre-move; the price model
    -- treats it as one more source and stacks it by the usual rule.
    self.priceModel:setExtraSources(function() return self.forecasts:getOpen() end)

    -- Every message shown, for the hub's History tab.
    self.history = MSWHistory.new()

    -- The menu only moves numbers in the adapter; the side effects live here,
    -- so the same path serves the menu, mswSet and mswReset alike.
    self.menu = MSWSettingsMenu.new(self.settings, self.log, function()
        self:applySettingSideEffects()
    end)

    self.lastRolledDay = nil
    self.lastEventDay = nil     -- day the most recent event STARTED (cooldown)
    self.pendingLoadFile = nil
    self.welcomeShown = false   -- per savegame; see showWelcome
    return self
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function MarketShockwaves:onMissionLoaded(mission)
    self.calendar:resolve()
    self.economy:install()

    local dpm = self.calendar:getDaysPerMonth()
    self.log:info(("calendar: day=%d month=%d daysPerMonth=%d")
        :format(self.calendar:getDay(), self.calendar:getMonth(), dpm))

    -- Verbose test-build diagnostics (see scripts/lib/Diagnostics.lua).
    if MSWDiag ~= nil then
        MSWDiag.dumpMods(self.log)
        MSWDiag.dumpEnvironment(self.log)
        MSWDiag.dumpCalendar(self.log, self.calendar)
        MSWDiag.dumpConfig(self.log, self.config)
        MSWDiag.dumpFillTypeResolution(self.log, self.economy, self.config)
        MSWDiag.dumpPriceGui(self.log)
    end

    -- The crop calendar belongs to the map, so anything worked out before this
    -- point is discarded.
    self.cropCalendar:reset()
    self.forecasts:resetTiming()

    self:restorePendingSave(dpm)
    self.priceModel:invalidate()
    self.priceModel:rebuild(self.calendar:getDay())
    self.display:refresh()
end

--- Log which forecasts this map offers, and when. One block per load: it is
--- what shows, from a log alone, that the map's calendar was read correctly.
function MarketShockwaves:logForecastTimings()
    local available = self.forecasts:getAvailable()
    self.log:info(("forecasts: %d of %d variant(s) offered on this map")
        :format(#available, self:countForecastVariants()))
    for _, entry in ipairs(available) do
        local months = {}
        for month = 1, 12 do
            if entry.timing.arrive[month] then months[#months + 1] = tostring(month) end
        end
        self.log:info(("  %s/%s: message in month %s, verdict in month %s, effect %s month(s)")
            :format(entry.def.id, entry.variant.id,
                    entry.timing.numArrive == 12 and "any" or table.concat(months, "/"),
                    tostring(entry.timing.verdictMonth or "lead+" .. tostring(entry.timing.leadFrom(1))),
                    tostring(entry.timing.durationMonths)))
    end
end

function MarketShockwaves:countForecastVariants()
    local n = 0
    for _, def in ipairs(self.forecastConfig.forecasts) do n = n + #def.variants end
    return n
end

function MarketShockwaves:onStartMission(mission)
    self.lastRolledDay = self.calendar:getDay()

    -- Other mods load and patch at different times, so check our price hooks
    -- survived, and note any price-related neighbours for diagnosis.
    self.economy:verifyHooks()
    self.economy:logPriceModNeighbours(self.modName)
    self:applySettingSideEffects()

    -- The ESC menu does not exist until a savegame is loaded, which is why this
    -- is here and not at load time. The mod's own page carries the settings; the
    -- rows on the GAME SETTINGS page are only the fallback for a game version
    -- where that page cannot be added.
    self.hub = MSWHubFrame ~= nil and MSWHubFrame.install(self, self.modDirectory) or nil
    if self.hub == nil then
        self.log:warn("hub page unavailable; settings stay under GAME SETTINGS")
        self.menu:install()
    end

    if MSWDiag ~= nil then
        MSWDiag.dumpPriceProbe(self.log, self.economy, self.diagProbeProducts())
        MSWDiag.dumpState(self.log, self.priceModel, self.calendar:getDay())
        -- Dumps the settings page the first time it is opened, so the probe no
        -- longer depends on the console being used while that page is up.
        MSWDiag.armSettingsProbe(self.log)
    end

    pcall(function() self:logForecastTimings() end)

    self.log:info("ready — type mswStatus in the console for state, "
               .. "mswTrigger grainDrought high to force an event")

    -- Here rather than at load time: onStartMission fires once the player is
    -- actually in the game, and the message is queued like any other, so it
    -- inherits the notifier's rules about open menus and sleeping.
    if not self.welcomeShown then
        self:showWelcome()
        self.welcomeShown = true
        self:record({ kind = "info", titleKey = "msw_welcome_title", textKey = "msw_welcome" })
    end
end

-- ---------------------------------------------------------------------------
-- Messages and their history
-- ---------------------------------------------------------------------------

--- Add an entry to the history, stamped with today's date.
function MarketShockwaves:record(entry)
    entry.day   = entry.day or self.calendar:getDay()
    entry.month = entry.month or self.calendar:getMonth()
    entry.year  = entry.year or self.calendar:getYear()
    return self.history:add(entry)
end

--- Show a message and keep it in the history.
--- @param entry table history entry; titleKey, textKey and argKey give the text
--- @param opts table|nil { silent = true } to record without a dialog
function MarketShockwaves:tell(entry, opts)
    self:record(entry)
    if opts ~= nil and opts.silent then return end
    self.notifier:notify(MSWHistory.resolveText(g_i18n, entry.titleKey),
                         MSWHistory.resolveText(g_i18n, entry.textKey, entry.argKey),
                         { patient = entry.kind ~= "event" })
end

--- Queue the introduction. Shown automatically once per savegame (the flag is
--- stored with the rest of our state), and on demand via mswWelcome.
function MarketShockwaves:showWelcome()
    local function text(key, fallback)
        if g_i18n ~= nil and g_i18n:hasText(key) then return g_i18n:getText(key) end
        return fallback
    end
    local paragraphs = {}
    for i = 1, WELCOME_PARAGRAPHS do
        local para = text(("msw_welcome_p%d"):format(i), nil)
        if para ~= nil and para ~= "" then paragraphs[#paragraphs + 1] = para end
    end
    if #paragraphs == 0 then
        paragraphs[1] = "Market events will now move prices. Read the news, "
                     .. "watch the price table, and decide when to sell."
    end
    self.notifier:notify(text("msw_welcome_title", "Market Shockwaves"),
                         table.concat(paragraphs, "\n\n"),
                         { patient = true })
end

function MarketShockwaves:update(dt)
    -- Drain queued event messages. Deliberately outside the g_server guard and
    -- ahead of everything else: dialogs must only ever open from here, never
    -- from the code path that fires an event, or the input context breaks while
    -- the player is asleep. See NotificationAdapter.
    self.notifier:update()

    -- Only the authority rolls events (harmless in SP; correct for future MP).
    if g_server == nil then return end

    local day = self.calendar:getDay()
    if self.lastRolledDay == nil then
        self.lastRolledDay = day
        return
    end

    if day > self.lastRolledDay then
        -- Catch up one day at a time, each with its OWN day number. Rolling the
        -- same day repeatedly would inflate the event rate and prune against the
        -- wrong date, so the day is advanced properly rather than looped over.
        local MAX_CATCHUP = 30
        local from = self.lastRolledDay + 1
        if day - self.lastRolledDay > MAX_CATCHUP then
            -- A huge jump means a reload or a very long skip; roll only the most
            -- recent days rather than a month of accumulated chances.
            self.log:info(("day jumped %d -> %d; rolling only the last %d day(s)")
                :format(self.lastRolledDay, day, MAX_CATCHUP))
            from = day - MAX_CATCHUP + 1
        end
        for d = from, day do
            self:onNewDay(d)
        end
        self.lastRolledDay = day
    elseif day < self.lastRolledDay then
        -- Loading an earlier save; resync without rolling.
        self.log:info(("day moved backwards %d -> %d (save loaded); resyncing")
            :format(self.lastRolledDay, day))
        self.lastRolledDay = day
    end

    self.priceModel:rebuild(day)

    -- Markers have to be refreshed as the days pass, not just when an event
    -- fires: the modifier table is rebuilt every day, and without this the
    -- marker written at the firing instant would sit there, stale, for the whole
    -- event and never be cleared when it ends.
    --
    -- Gated on the day, because update() runs EVERY FRAME while the modifier
    -- table only changes once a day, and refresh() walks every affected fill
    -- type.
    if self.lastMarkedDay ~= day then
        self.lastMarkedDay = day
        self.display:refresh()
    end
end

--- Days of enforced quiet remaining after the last event started.
--- 0 means an event may fire today.
function MarketShockwaves:getCooldownRemaining(day, daysPerMonth)
    if self.lastEventDay == nil then return 0 end
    local months = self.settings:get("minMonthsBetweenEvents") or 0
    if months <= 0 then return 0 end
    local cooldownDays = months * daysPerMonth
    local since = day - self.lastEventDay
    if since >= cooldownDays then return 0 end
    return cooldownDays - since
end

function MarketShockwaves:onNewDay(day)
    local expired = self.priceModel:pruneExpired(day)
    for _, ev in ipairs(expired) do
        self.log:info(("event ended: %s [%s] after %d days")
            :format(ev.eventId, ev.severity, ev.durationDays))
    end

    local dpm = self.calendar:getDaysPerMonth()
    local month = self.calendar:getMonth()

    -- MASTER SWITCH: nothing new starts while the mod is switched off. Events
    -- already running still expire above, so turning it off winds the market
    -- down rather than freezing it mid-event.
    local fired = {}
    if not self.settings:isOn("enabled") then
        self.log:debug("mod disabled in settings; not rolling today")
        return self:afterNewDay(day, dpm, month, fired, nil)
    end

    -- FORECASTS run beside the random events, on their own clock: verdicts
    -- that fall due today, then perhaps a new forecast. Guarded, so a fault in
    -- this newer part can never stop the random events below.
    local okForecasts, errForecasts = pcall(function()
        self:stepForecasts(day, dpm, month)
    end)
    if not okForecasts then
        self.log:warn("forecast step failed: " .. tostring(errForecasts))
    end

    -- CONCURRENCY CEILING: events are designed to stack, so this is the rail
    -- that stops an unlucky run compounding indefinitely. An event a forecast
    -- started does not count: it runs for a year, and would otherwise hold one
    -- of the few slots the whole time.
    local active = self:countRandomEvents()
    local maxConcurrent = self.settings:get("maxConcurrentEvents")
    if active >= maxConcurrent then
        self.log:debug(("%d event(s) active, at the limit of %d; not rolling today")
            :format(active, maxConcurrent))
        return self:afterNewDay(day, dpm, month, fired, nil)
    end

    -- COOLDOWN: a minimum quiet period after any event starts, so the player is
    -- never hit with back-to-back announcements. Applies to the random roll only
    -- - mswTrigger deliberately bypasses it, as it does the season check.
    local cooldown = self:getCooldownRemaining(day, dpm)
    local blocked = nil
    if cooldown > 0 then
        self.log:debug(("cooldown: %.1f day(s) of quiet left; not rolling today")
            :format(cooldown))
    else
        blocked = function(def)
            -- Mutual exclusion by subtype. Covers self-overlap (subtype defaults
            -- to the event id) AND mirrored pairs: an ethanol boom can never
            -- start while its glut is still running. Alternating is fine, so the
            -- moment one expires the other becomes eligible again.
            if self.priceModel:findActiveBySubtype(def.subtype or def.id, day) then
                return true
            end
            -- the settings menu's per-category switches
            if not self.settings:isCategoryEnabled(def.category) then return true end
            return false
        end
        fired = self.scheduler:rollForDay(
            month, dpm, self.settings:get("eventsPerYear"), blocked)

        -- Only ONE event may start per day. Even without a cooldown, two
        -- announcements in one day is exactly the pile-up this guards against.
        if #fired > 1 then
            self.log:debug(("%d events rolled today; starting one and discarding "
                .. "the rest"):format(#fired))
            fired = { fired[1] }
        end
    end

    return self:afterNewDay(day, dpm, month, fired, blocked)
end

--- Shared tail for onNewDay: start whatever fired, then log. Split out so the
--- early returns above (mod disabled, concurrency limit) still refresh state.
function MarketShockwaves:afterNewDay(day, dpm, month, fired, blocked)
    for _, f in ipairs(fired) do
        self:fireEvent(f.def, f.severity, day, dpm)
    end

    self.priceModel:rebuild(day)
    self.display:setEnabled(self.settings:isOn("showMarkers"))
    self.display:refresh()

    if MSWDiag ~= nil then
        MSWDiag.section(self.log, ("NEW DAY %d"):format(day))
        MSWDiag.dumpCalendar(self.log, self.calendar)
        MSWDiag.dumpDailyRoll(self.log, self.scheduler, month, dpm,
                              self.settings:get("eventsPerYear"), blocked, fired)
        MSWDiag.dumpState(self.log, self.priceModel, day)
        MSWDiag.dumpPriceProbe(self.log, self.economy, self.diagProbeProducts())
    end
end

--- A spread of products to probe: one per event family, so a single probe block
--- shows whether each kind of event is reaching prices.
function MarketShockwaves.diagProbeProducts()
    return { "WHEAT", "FLOUR", "BREAD", "POTATO", "SUGAR", "MILK", "CHEESE",
             "OLIVE_OIL", "TOMATO", "LETTUCE", "DIESEL", "FERTILIZER",
             "PREFABWALL", "WOOD", "GRASS_WINDROW", "STRAW", "MAIZE" }
end

--- Running events the random scheduler started (not a forecast's verdict).
function MarketShockwaves:countRandomEvents()
    local n = 0
    for _, ev in ipairs(self.priceModel:getActiveEvents()) do
        if ev.forecastId == nil then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Forecasts
-- ---------------------------------------------------------------------------

--- One day of the forecast clock.
function MarketShockwaves:stepForecasts(day, dpm, month)
    for _, verdict in ipairs(self.forecasts:collectDue(day)) do
        self:deliverVerdict(verdict, day, dpm)
    end

    if not self.settings:isOn("forecasts") then return end

    self.forecasts:setFrequency(self.settings:get("forecastsPerYear"))
    local entry = self.forecasts:rollStart(day, month, dpm, function(def, variant)
        return self:isForecastBlocked(variant, day)
    end)
    if entry ~= nil then
        self:openForecast(entry.def, entry.variant, entry.timing, day, month, dpm)
    end
end

--- A forecast cannot be announced while an event of its own family is still
--- running: its verdict would have nothing it is allowed to start.
function MarketShockwaves:isForecastBlocked(variant, day)
    local eventDef = MSWEventDef.findById(self.config, variant.event)
    if eventDef == nil then return true end
    return self.priceModel:findActiveBySubtype(eventDef.subtype or eventDef.id, day) ~= nil
end

--- Announce a forecast.
function MarketShockwaves:openForecast(def, variant, timing, day, month, dpm, confidence)
    local forecast = self.forecasts:start(def, variant, timing, day, month, dpm, {
        confidence = confidence,
        intensity = self.settings:get("intensity"),
        dayInMonth = self.calendar:getDayInMonth(),
    })
    self.priceModel:invalidate()

    self.log:info(("forecast opened: %s/%s confidence=%d verdict on day %d (in %d days), "
        .. "pre-move %d day(s) of %+.1f%%")
        :format(def.id, variant.id, forecast.confidence, forecast.verdictDay,
                forecast.verdictDay - day, forecast.premoveDays,
                forecast.premoveDeviation * 100))

    -- The first forecast of a savegame is preceded by a short explanation of
    -- what a forecast is. Queued first, so it is read first.
    if not self.forecasts.tipShown then
        self.forecasts.tipShown = true
        self:tell({ kind = "info", titleKey = "msw_fc_tip_title", textKey = "msw_fc_tip" })
    end

    local titleKey, textKey = MSWForecastDef.messageKeys(def.id, variant.id, "open")
    self:tell({
        kind = "forecast", titleKey = titleKey, textKey = textKey,
        argKey = MSWForecastDef.confidenceKey(forecast.confidence),
        ref = ("%s@%d"):format(def.id, day), status = "open",
    })
    return forecast
end

--- A forecast's verdict: start the event(s) it resolved to and tell the player.
--- From here on it is an ordinary event.
function MarketShockwaves:deliverVerdict(verdict, day, dpm)
    local forecast = verdict.forecast
    local ref = ("%s@%d"):format(forecast.forecastId, forecast.startDay)
    self.priceModel:invalidate()

    self.log:info(("forecast verdict: %s/%s (confidence %d) -> %s")
        :format(forecast.forecastId, forecast.variantId, forecast.confidence or 0,
                verdict.outcome))

    local mainEventId
    for _, item in ipairs(verdict.events) do
        local def = MSWEventDef.findById(self.config, item.eventId)
        if def == nil then
            self.log:warn(("forecast verdict: event '%s' is not defined"):format(tostring(item.eventId)))
        else
            local ev = self:fireEvent(def, item.severity, day, dpm, {
                silent = true, fromForecast = true,
                durationMonths = item.durationMonths,
                titleKey = item.titleKey, textKey = item.textKey,
                forecastId = item.forecastId,
            })
            if ev ~= nil and item.companion then
                -- A companion is a normal event with its own news item; it is
                -- listed, but the verdict message is the one shown on screen.
                local titleKey, textKey = MSWMarketView.newsKeys(def.id, item.severity)
                self:tell({ kind = "event", titleKey = titleKey, textKey = textKey,
                            eventId = def.id, eventStartDay = day }, { silent = true })
            elseif ev ~= nil then
                mainEventId = def.id
            end
        end
    end

    self.history:setStatus("forecast", ref, verdict.outcome)
    self:tell({ kind = "verdict", titleKey = verdict.titleKey, textKey = verdict.textKey,
                ref = ref, status = verdict.outcome,
                eventId = mainEventId, eventStartDay = day })
end

--- Start an event now.
--- @param opts table|nil for an event started by a forecast's verdict:
---        silent        no message of its own (the verdict message covers it)
---        fromForecast  does not start the quiet period between random events
---        durationMonths, titleKey, textKey, forecastId  see MSWActiveEvent.new
function MarketShockwaves:fireEvent(def, severityClass, day, daysPerMonth, opts)
    opts = opts or {}
    if def.severities[severityClass] == nil then
        self.log:warn(("event '%s' has no '%s' severity"):format(def.id, severityClass))
        return nil
    end

    -- Mutual-exclusion guard, enforced here as well so EVERY path obeys it -
    -- scheduler, console, future MP sync. Subtype defaults to the event id, so
    -- this covers both an event overlapping itself and a mirrored pair
    -- overlapping each other.
    local conflict = self.priceModel:findActiveBySubtype(def.subtype or def.id, day)
    if conflict ~= nil then
        if conflict.eventId == def.id then
            self.log:info(("event '%s' is already active — not starting another "
                .. "(same event never overlaps itself)"):format(def.id))
        else
            self.log:info(("event '%s' cannot start: '%s' is running and they "
                .. "share subtype '%s' — mirrored events never overlap")
                :format(def.id, conflict.eventId, def.subtype or def.id))
        end
        return nil
    end

    local ev = MSWActiveEvent.new(def, severityClass, day, daysPerMonth,
                                  self.settings:getInstanceScalers(), opts)
    self.priceModel:addEvent(ev)
    -- Starts the quiet period, whether this came from the scheduler or console.
    -- A verdict does not: it was announced months ago, and must not also
    -- silence the random events around it.
    if not opts.fromForecast then self.lastEventDay = day end
    self.priceModel:rebuild(day)
    self.display:refresh()

    self.log:info(("event fired: %s [%s] peak=%.2f duration=%.1f months (%d days), %d products")
        :format(def.id, severityClass, ev.peakFactor, ev.durationMonths,
                ev.durationDays, #ev:getProducts()))
    if MSWDiag ~= nil then
        MSWDiag.section(self.log, ("EVENT FIRED: %s [%s]"):format(def.id, severityClass))
        MSWDiag.dumpEventInstance(self.log, ev)
    end

    if not opts.silent then self:announce(def, severityClass, day) end
    return ev
end

--- Show the player the flavour message and keep it in the history.
--- @param day number|nil the day the event started; nil for a preview
---        (mswNotify), which is shown but not recorded
function MarketShockwaves:announce(def, severityClass, day)
    local titleKey, textKey = MSWMarketView.newsKeys(def.id, severityClass)
    if day == nil then
        self.notifier:notify(MSWHistory.resolveText(g_i18n, titleKey),
                             MSWHistory.resolveText(g_i18n, textKey))
        return
    end
    self:tell({ kind = "event", titleKey = titleKey, textKey = textKey,
                eventId = def.id, eventStartDay = day })
end

-- ---------------------------------------------------------------------------
-- Persistence
-- ---------------------------------------------------------------------------

--- Where our state lives: a self-contained file inside the savegame folder.
--- Writing our own file rather than riding the mission's XML means we do not
--- depend on that structure, and an old or missing file simply means "no events".
function MarketShockwaves:getStatePath()
    local mi = g_currentMission and g_currentMission.missionInfo
    if mi == nil then return nil end

    -- Preferred: the directory the game itself reports.
    local dir = mi.savegameDirectory
    if type(dir) == "string" and dir ~= "" then
        return dir .. "/marketShockwaves.xml"
    end

    -- Fallback: rebuild it from the savegame index.
    local idx = mi.savegameIndex
    if type(idx) == "number" and getUserProfileAppPath ~= nil then
        local ok, base = pcall(getUserProfileAppPath)
        if ok and type(base) == "string" then
            return ("%ssavegame%d/marketShockwaves.xml"):format(base, idx)
        end
    end
    return nil
end

function MarketShockwaves:save()
    local path = self:getStatePath()
    if path == nil then
        self.log:warn("save: could not resolve the savegame path; state not saved")
        return
    end

    local ok, err = pcall(function()
        local xml = createXMLFile("mswState", path, SAVEGAME_KEY)
        if xml == nil or xml == 0 then error("createXMLFile returned nothing") end

        self.settings:saveToXML(xml, SAVEGAME_KEY .. ".settings")
        setXMLFloat(xml, SAVEGAME_KEY .. "#lastRolledDay", self.lastRolledDay or 0)
        if self.lastEventDay ~= nil then
            setXMLFloat(xml, SAVEGAME_KEY .. "#lastEventDay", self.lastEventDay)
        end
        -- Stored so a change to the player's days-per-month setting between
        -- sessions can be detected rather than silently rescaling durations.
        setXMLFloat(xml, SAVEGAME_KEY .. "#daysPerMonth",
                    self.calendar:getDaysPerMonth())
        -- So the introduction is shown once per savegame, not once per load.
        -- Guarded: a missing engine function here must not cost the player
        -- their saved events.
        if setXMLBool ~= nil then
            setXMLBool(xml, SAVEGAME_KEY .. "#welcomeShown", self.welcomeShown == true)
        end

        local i = 0
        for _, ev in ipairs(self.priceModel:getActiveEvents()) do
            ev:saveToXML(xml, ("%s.activeEvents.event(%d)"):format(SAVEGAME_KEY, i))
            i = i + 1
        end

        -- Each in its own pcall: a fault in the newer parts must not cost the
        -- player their running events, which are already written above.
        local okF, errF = pcall(function()
            self.forecasts:saveToXML(xml, SAVEGAME_KEY .. ".forecasts")
        end)
        if not okF then self.log:warn("save: forecasts not saved: " .. tostring(errF)) end
        local okH, errH = pcall(function()
            self.history:saveToXML(xml, SAVEGAME_KEY .. ".history")
        end)
        if not okH then self.log:warn("save: history not saved: " .. tostring(errH)) end

        saveXMLFile(xml)
        delete(xml)
        self.log:info(("saved %d active event(s) to %s"):format(i, path))
    end)
    if not ok then self.log:warn("save failed: " .. tostring(err)) end
end

--- Restore settings and any events that were still running.
--- Called after the calendar resolves, so durations convert correctly.
function MarketShockwaves:restorePendingSave(daysPerMonth)
    local path = self:getStatePath()
    if path == nil then
        self.log:warn("restore: could not resolve the savegame path")
        return
    end
    if fileExists == nil or not fileExists(path) then
        self.log:info("restore: no saved state (new savegame or first run with the mod)")
        return
    end

    local ok, err = pcall(function()
        local xml = loadXMLFile("mswState", path)
        if xml == nil or xml == 0 then error("loadXMLFile returned nothing") end

        self.settings:loadFromXML(xml, SAVEGAME_KEY .. ".settings")
        self.lastRolledDay = getXMLFloat(xml, SAVEGAME_KEY .. "#lastRolledDay")
        self.lastEventDay = getXMLFloat(xml, SAVEGAME_KEY .. "#lastEventDay")
        -- Absent in saves made before the welcome existed, which reads as
        -- "not shown yet" - so an existing playthrough sees it once too.
        self.welcomeShown = getXMLBool ~= nil
            and getXMLBool(xml, SAVEGAME_KEY .. "#welcomeShown") == true

        local savedDpm = getXMLFloat(xml, SAVEGAME_KEY .. "#daysPerMonth")
        if savedDpm ~= nil and savedDpm > 0 and savedDpm ~= daysPerMonth then
            self.log:warn(("restore: days-per-month changed %d -> %d since the last "
                .. "save; running events keep their original length in days")
                :format(savedDpm, daysPerMonth))
        end

        local restored, dropped = 0, 0
        local i = 0
        while true do
            local key = ("%s.activeEvents.event(%d)"):format(SAVEGAME_KEY, i)
            if not hasXMLProperty(xml, key) then break end

            local id = getXMLString(xml, key .. "#eventId")
            local def = id and MSWEventDef.findById(self.config, id) or nil
            if def == nil then
                -- The event was removed or renamed in config since the save.
                self.log:warn(("restore: event '%s' is no longer in the config; "
                    .. "dropping it"):format(tostring(id)))
                dropped = dropped + 1
            else
                local ev = MSWActiveEvent.loadFromXML(xml, key, def,
                                                      savedDpm or daysPerMonth,
                                                      self.settings:get("supplyChainDepth"))
                if ev == nil then
                    dropped = dropped + 1
                else
                    self.priceModel:addEvent(ev)
                    restored = restored + 1
                end
            end
            i = i + 1
        end

        local okF, errF = pcall(function()
            self.forecasts:loadFromXML(xml, SAVEGAME_KEY .. ".forecasts")
        end)
        if not okF then self.log:warn("restore: forecasts not restored: " .. tostring(errF)) end
        local okH, errH = pcall(function()
            self.history:loadFromXML(xml, SAVEGAME_KEY .. ".history")
        end)
        if not okH then self.log:warn("restore: history not restored: " .. tostring(errH)) end

        delete(xml)
        self.log:info(("restore: %d event(s) restored, %d dropped; %d open forecast(s), "
            .. "%d history entr(ies)")
            :format(restored, dropped, #self.forecasts:getOpen(), self.history:count()))

        -- A savegame from before the history existed: list what is running
        -- now, so the tab is not empty while the market is plainly moving.
        if self.history:count() == 0 then
            for _, ev in ipairs(self.priceModel:getActiveEvents()) do
                local titleKey, textKey = MSWMarketView.newsKeys(ev.eventId, ev.severity)
                self.history:add({
                    kind = "event", titleKey = ev.titleKey or titleKey,
                    textKey = ev.textKey or textKey, eventId = ev.eventId,
                    eventStartDay = ev.startDay, day = ev.startDay,
                })
            end
        end

        -- Expire anything that finished while the game was closed.
        local expired = self.priceModel:pruneExpired(self.calendar:getDay())
        if #expired > 0 then
            self.log:info(("restore: %d event(s) had already finished")
                :format(#expired))
        end
    end)
    if not ok then
        self.log:warn("restore failed (starting with no active events): " .. tostring(err))
    end
end

function MarketShockwaves:delete()
    if self.display ~= nil then self.display:restoreAll() end
    self.log:info("unloading")
end

function MarketShockwaves:draw() end
function MarketShockwaves:mouseEvent() end
function MarketShockwaves:toggleSettings() end

-- ---------------------------------------------------------------------------
-- Console commands
-- ---------------------------------------------------------------------------

function MarketShockwaves:consoleStatus()
    local day = self.calendar:getDay()
    local out = {
        "--- Market Shockwaves ---",
        ("calendar: day=%d  month=%d  daysPerMonth=%d")
            :format(day, self.calendar:getMonth(), self.calendar:getDaysPerMonth()),
        ("settings: eventsPerYear=%.2f  intensity=%.2f  duration=%.2f")
            :format(self.settings:get("eventsPerYear"),
                    self.settings:get("intensity"),
                    self.settings:get("duration")),
        ("events loaded: %d   active: %d")
            :format(#self.config.events, #self.priceModel:getActiveEvents()),
        ("cooldown: %.1f day(s) of quiet remaining (min %.1f month(s) between events)")
            :format(self:getCooldownRemaining(day, self.calendar:getDaysPerMonth()),
                    self.settings:get("minMonthsBetweenEvents")),
    }
    for _, line in ipairs(self.priceModel:describe()) do out[#out + 1] = line end

    local marks = self.display:describe()
    if #marks > 0 then
        out[#out + 1] = "marked commodities:"
        for _, m in ipairs(marks) do out[#out + 1] = m end
    end

    out[#out + 1] = "available ids:"
    for _, def in ipairs(self.config.events) do
        out[#out + 1] = "  " .. def.id
    end
    return table.concat(out, "\n")
end

function MarketShockwaves:consoleTrigger(eventId, severity)
    if eventId == nil then
        return "usage: mswTrigger <eventId> [low|medium|high]"
    end
    local def = MSWEventDef.findById(self.config, eventId)
    if def == nil then
        return ("unknown event '%s' — use mswStatus to list ids"):format(eventId)
    end
    severity = severity or "medium"
    -- The console bypasses the season window and the cooldown deliberately, but
    -- NOT mutual exclusion: a boom stacked on its own glut is the nonsense the
    -- rule exists to prevent, and forcing it would produce a state the scheduler
    -- can never reach.
    local conflict = self.priceModel:findActiveBySubtype(def.subtype or def.id,
                                                         self.calendar:getDay())
    if conflict ~= nil then
        if conflict.eventId == def.id then
            return ("'%s' is already active — the same event never runs twice at "
                .. "once. Use mswClear first if you want a fresh one."):format(def.id)
        end
        return ("'%s' cannot run while '%s' is active — they are mirrors of the "
            .. "same market (subtype '%s') and never overlap. Use mswClear first.")
            :format(def.id, conflict.eventId, def.subtype or def.id)
    end
    local ev = self:fireEvent(def, severity, self.calendar:getDay(),
                              self.calendar:getDaysPerMonth())
    if ev == nil then return "failed to fire" end
    return ("fired %s [%s]: peak %.1f%%, %d days, products: %s")
        :format(def.id, severity, (ev.peakFactor - 1) * 100, ev.durationDays,
                table.concat(ev:getProducts(), " "))
end

function MarketShockwaves:consolePrice(productName)
    if productName == nil then return "usage: mswPrice <PRODUCT>  e.g. mswPrice WHEAT" end
    productName = productName:upper()
    local idx = self.economy:getFillTypeIndex(productName)
    if idx == nil then return ("unknown product '%s'"):format(productName) end
    self.priceModel:rebuild(self.calendar:getDay())
    local m = self.priceModel:getModifier(idx)
    return ("%s (index %d): modifier %.4f  (%+.2f%%)")
        :format(productName, idx, m, (m - 1) * 100)
end

function MarketShockwaves:consoleClear()
    self.priceModel:clearEvents()
    self.forecasts:clear()
    self.priceModel:invalidate()
    self.display:restoreAll()
    return "cleared all active events and open forecasts"
end

-- ---- forecast test commands ------------------------------------------------

function MarketShockwaves:consoleForecasts()
    local day = self.calendar:getDay()
    local dpm = self.calendar:getDaysPerMonth()
    local out = { "--- Market Shockwaves forecasts ---",
                  ("forecasts %s, %s per year; cooldown %.1f day(s) left")
                      :format(self.settings:isOn("forecasts") and "ON" or "OFF",
                              tostring(self.settings:get("forecastsPerYear")),
                              self.forecasts:getCooldownRemaining(day, dpm)) }
    out[#out + 1] = "open:"
    for _, f in ipairs(self.forecasts:getOpen()) do
        out[#out + 1] = ("  %s/%s confidence=%d opened day %d, verdict day %d (%d to go), "
            .. "pre-move %d day(s)%s")
            :format(f.forecastId, f.variantId, f.confidence or 0, f.startDay, f.verdictDay,
                    f.verdictDay - day, f.premoveDays or 0,
                    f:isInPremove(day) and " - IN PRE-MOVE" or "")
    end
    if #self.forecasts:getOpen() == 0 then out[#out + 1] = "  (none)" end
    out[#out + 1] = "offered on this map (id/variant):"
    for _, entry in ipairs(self.forecasts:getAvailable()) do
        out[#out + 1] = ("  %s/%s"):format(entry.def.id, entry.variant.id)
    end
    return table.concat(out, "\n")
end

function MarketShockwaves:consoleForecast(forecastId, variantId, confidence)
    local available = self.forecasts:getAvailable()
    if #available == 0 then return "no forecast can be offered on this map" end

    local pick
    for _, entry in ipairs(available) do
        if (forecastId == nil or entry.def.id == forecastId)
           and (variantId == nil or entry.variant.id == variantId) then
            pick = entry
            break
        end
    end
    if pick == nil then
        return "no such forecast on this map — run mswForecasts for the list"
    end
    if self.forecasts:isOpen(pick.def.id) then
        return ("'%s' is already open — use mswVerdict or mswClear first"):format(pick.def.id)
    end
    local day = self.calendar:getDay()
    if self:isForecastBlocked(pick.variant, day) then
        return ("'%s' cannot open while its own event is still running — mswClear first")
            :format(pick.def.id)
    end
    local level = tonumber(confidence)
    if level ~= 70 and level ~= 80 and level ~= 90 then level = nil end
    local forecast = self:openForecast(pick.def, pick.variant, pick.timing, day,
                                       self.calendar:getMonth(),
                                       self.calendar:getDaysPerMonth(), level)
    self.display:refresh()
    return ("opened %s/%s: confidence %d, verdict on day %d (%d days from now)")
        :format(pick.def.id, pick.variant.id, forecast.confidence, forecast.verdictDay,
                forecast.verdictDay - day)
end

--- Move every open forecast so its pre-move starts today. The verdict then
--- arrives on its own once the pre-move has played out.
function MarketShockwaves:consoleForecastSkip()
    local day = self.calendar:getDay()
    local n = 0
    for _, f in ipairs(self.forecasts:getOpen()) do
        f.verdictDay = day + math.max(1, f.premoveDays or 1)
        n = n + 1
    end
    if n == 0 then return "no open forecast" end
    self.priceModel:invalidate()
    self.priceModel:rebuild(day)
    self.display:refresh()
    return ("%d forecast(s) moved to their pre-move; the verdict follows when it ends"):format(n)
end

--- Decide the oldest open forecast now, optionally with a chosen outcome.
function MarketShockwaves:consoleVerdict(outcome)
    local open = self.forecasts:getOpen()
    if #open == 0 then return "no open forecast" end
    if outcome ~= nil and not OUTCOME_NAMES[outcome] then
        return "outcome must be one of: asForecast stronger milder wrongReason backfire"
    end
    local forecast = table.remove(open, 1)
    local verdict = self.forecasts:buildVerdict(forecast, outcome and { outcome = outcome } or nil)
    if verdict == nil then return "that forecast is no longer in the config" end
    local day = self.calendar:getDay()
    self:deliverVerdict(verdict, day, self.calendar:getDaysPerMonth())
    self.priceModel:rebuild(day)
    self.display:refresh()
    return ("verdict for %s/%s: %s"):format(forecast.forecastId, forecast.variantId,
                                            verdict.outcome)
end

function MarketShockwaves:consoleSet(name, value)
    if name == nil or value == nil then
        return "usage: mswSet <setting> <value>  —  run mswSettings for the list"
    end
    if self.settings:set(name, value) then
        self:applySettingSideEffects()
        return ("%s = %s"):format(name, tostring(self.settings:get(name)))
    end
    return "invalid setting or value"
end

--- Settings that take effect outside the daily roll loop.
---
--- Shared by the in-game menu, mswSet and mswReset, so a value changed by any
--- route behaves identically. Everything else (frequency, cooldown, intensity,
--- duration, chain depth, categories) is read at roll time and needs nothing
--- here.
function MarketShockwaves:applySettingSideEffects()
    self.economy:setEnabled(self.settings:isOn("enabled"))
    self.display:setEnabled(self.settings:isOn("showMarkers"))
    self.display:refresh()
end

function MarketShockwaves:consoleHooks()
    local intact = self.economy:verifyHooks()
    self.economy:logPriceModNeighbours(self.modName)
    if intact then
        return "price hooks intact — no other mod has replaced them"
    end
    return "hooks had been replaced by another mod; reinstalled (see log for detail)"
end

function MarketShockwaves:consoleNotify(eventId, severity)
    eventId = eventId or "grainDrought"
    severity = severity or "medium"
    local def = MSWEventDef.findById(self.config, eventId)
    if def == nil then return ("unknown event '%s'"):format(eventId) end
    self:announce(def, severity)
    return ("showed the %s [%s] message (no event started)"):format(eventId, severity)
end

function MarketShockwaves:consoleDump()
    if MSWDiag == nil then return "diagnostics module not loaded" end
    -- An explicit request always produces output, even with verbose logging off.
    local wasEnabled = MSWDiag.enabled
    MSWDiag.enabled = true
    local day = self.calendar:getDay()
    -- First line of every dump, so which files the game is actually running is
    -- never in doubt when reading a log after the fact.
    self.log:info(("mswDump: build=%s"):format(BUILD))
    MSWDiag.dumpMods(self.log)
    MSWDiag.dumpEnvironment(self.log)
    MSWDiag.dumpCalendar(self.log, self.calendar)
    MSWDiag.dumpConfig(self.log, self.config)
    MSWDiag.dumpFillTypeResolution(self.log, self.economy, self.config)
    -- Run this with the Prices menu OPEN: the frame does not exist at load time,
    -- which is why probing only at startup found nothing useful.
    MSWDiag.dumpPriceGui(self.log)
    MSWDiag.dumpSettingsGui(self.log)
    self.priceModel:rebuild(day)
    MSWDiag.dumpState(self.log, self.priceModel, day)
    MSWDiag.dumpPriceProbe(self.log, self.economy, self.diagProbeProducts())
    MSWDiag.enabled = wasEnabled
    return "full diagnostic dump written to log.txt"
end

function MarketShockwaves:consoleWelcome()
    self:showWelcome()
    return "welcome message queued — it opens once no menu is in the way"
end

function MarketShockwaves:consoleMarkers(onOff)
    if onOff == nil then
        return ("markers are %s — use: mswMarkers on|off")
            :format(self.display.enabled and "ON" or "OFF")
    end
    local want = (onOff == "on" or onOff == "1" or onOff == "true")
    self.display:setEnabled(want)
    if want then self.display:refresh() end
    return "commodity markers " .. (want and "ON" or "OFF")
end

--- Every setting with its value, default and range.
function MarketShockwaves:consoleSettings()
    local out = { "--- Market Shockwaves settings ---" }
    for _, name in ipairs(MSWSettingsAdapter.getAllNames()) do
        local lim = MSWSettingsAdapter.getLimits(name)
        local isBool = lim[1] == 0 and lim[2] == 1 and lim[3]
        local v = self.settings:get(name)
        if isBool then
            out[#out + 1] = ("  %-24s %s"):format(name, v >= 0.5 and "on" or "off")
        else
            out[#out + 1] = ("  %-24s %-8s (default %s, range %s..%s)")
                :format(name, tostring(v),
                        tostring(MSWSettingsAdapter.getDefault(name)),
                        tostring(lim[1]), tostring(lim[2]))
        end
    end
    out[#out + 1] = "categories map to config/events.xml: "
        .. "crops greenhouse trade biofuel winter supplies"
    return table.concat(out, "\n")
end

function MarketShockwaves:consoleReset()
    self.settings:resetToDefaults()
    self:applySettingSideEffects()
    -- Reopening the settings page picks the new values up; refresh now so the
    -- menu is already correct if it happens to be open.
    if self.menu ~= nil then pcall(function() self.menu:refresh() end) end
    return "all settings restored to defaults"
end

function MarketShockwaves:consoleDebug()
    self.log.debugEnabled = not self.log.debugEnabled
    if MSWDiag ~= nil then MSWDiag.enabled = self.log.debugEnabled end
    return ("debug logging %s (verbose per-day diagnostics %s)")
        :format(self.log.debugEnabled and "ON" or "OFF",
                self.log.debugEnabled and "ON" or "OFF")
end

-- ---------------------------------------------------------------------------
-- Bootstrap
-- ---------------------------------------------------------------------------

local modDirectory = g_currentModDirectory
local modName      = g_currentModName
local instance     = nil

local function onLoad(mission)
    instance = MarketShockwaves.new(modDirectory, modName)
    getfenv(0)["g_MarketShockwaves"] = instance

    addConsoleCommand("mswStatus",  "Market Shockwaves: show state",            "consoleStatus",  instance)
    addConsoleCommand("mswTrigger", "Market Shockwaves: force an event",        "consoleTrigger", instance)
    addConsoleCommand("mswPrice",   "Market Shockwaves: show price modifier",   "consolePrice",   instance)
    addConsoleCommand("mswClear",   "Market Shockwaves: clear active events",   "consoleClear",   instance)
    addConsoleCommand("mswSet",     "Market Shockwaves: change a setting",      "consoleSet",     instance)
    addConsoleCommand("mswDebug",   "Market Shockwaves: toggle debug logging",  "consoleDebug",   instance)
    addConsoleCommand("mswHooks",   "Market Shockwaves: check price hooks",     "consoleHooks",   instance)
    addConsoleCommand("mswDump",    "Market Shockwaves: full diagnostic dump",  "consoleDump",    instance)
    addConsoleCommand("mswNotify",  "Market Shockwaves: preview an event message", "consoleNotify", instance)
    addConsoleCommand("mswMarkers", "Market Shockwaves: toggle price markers",  "consoleMarkers", instance)
    addConsoleCommand("mswSettings","Market Shockwaves: list all settings",     "consoleSettings",instance)
    addConsoleCommand("mswReset",   "Market Shockwaves: reset settings",        "consoleReset",   instance)
    addConsoleCommand("mswWelcome", "Market Shockwaves: show the welcome message again", "consoleWelcome", instance)
    addConsoleCommand("mswForecasts", "Market Shockwaves: list forecasts", "consoleForecasts", instance)
    addConsoleCommand("mswForecast", "Market Shockwaves: announce a forecast now", "consoleForecast", instance)
    addConsoleCommand("mswForecastSkip", "Market Shockwaves: bring open forecasts to their pre-move", "consoleForecastSkip", instance)
    addConsoleCommand("mswVerdict", "Market Shockwaves: decide the oldest open forecast now", "consoleVerdict", instance)
end

local function onLoadFinished(mission)
    if instance then instance:onMissionLoaded(mission) end
end

local function onStartMission(mission)
    if instance then instance:onStartMission(mission) end
end

local function onUpdate(mission, dt)
    if instance then instance:update(dt) end
end

local function onSave(mission)
    if instance then instance:save() end
end

local function onDelete(mission)
    if instance then
        instance:delete()
        instance = nil
        getfenv(0)["g_MarketShockwaves"] = nil
    end
end

Mission00.load                  = Utils.prependedFunction(Mission00.load,                 onLoad)
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished,  onLoadFinished)
Mission00.onStartMission        = Utils.appendedFunction(Mission00.onStartMission,         onStartMission)
FSBaseMission.update            = Utils.appendedFunction(FSBaseMission.update,             onUpdate)
FSBaseMission.saveSavegame      = Utils.appendedFunction(FSBaseMission.saveSavegame,       onSave)
FSBaseMission.delete            = Utils.appendedFunction(FSBaseMission.delete,             onDelete)
