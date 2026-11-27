--[[
    HubFrame — the mod's own page in the ESC menu.

    A hub rather than a settings page: one place to see what the market is doing
    and to change how the mod behaves. Sub-tabs across the top:

        MARKET     what is in the news, and which prices are moving today
        FORECASTS  what has been announced and is still undecided
        HISTORY    every message the mod has shown, newest first
        SETTINGS   every setting (moved here from GAME SETTINGS)

    The first three share one shape: a list on the left and, on the right, the
    text behind the selected row. They are driven by the LISTS table below, so
    the data-source and selection code is written once.

    HOW IT GETS INTO THE MENU. The ESC menu is a TabbedMenu. A page is a
    TabbedMenuFrameElement loaded from its own layout, added to the menu's
    paging element, registered, and given a tab icon; the tab list is then
    rebuilt. That sequence is the one other mods' ESC pages use on this game
    version, and each call is checked for before it is made, so a game patch
    that renames one fails with a log line instead of a broken menu.

    IF IT FAILS, NOTHING ELSE DOES. install() returns false without touching the
    menu unless every piece it needs is present, and the caller then falls back
    to the settings rows in GAME SETTINGS. All drawing code runs under pcall for
    the same reason: a mistake here must cost this page, never the ESC menu.

    NO SPOILERS. Nothing here shows how long an event has left, how big it will
    get, or how a forecast will turn out before its verdict.

    The data shown comes from MSWMarketView, MSWForecastEngine and MSWHistory
    (pure logic, tested offline); this file only draws it.
]]

MSWHubFrame = {}

local PAGE_NAME = "pageMarketShockwaves"
local GUI_NAME  = "MSWHubFrame"

MSWHubFrame.TAB = { MARKET = 1, FORECASTS = 2, HISTORY = 3, SETTINGS = 4 }
local TAB_COUNT = 4

-- List sections on the Market tab.
local SECTION_EVENTS, SECTION_PRODUCTS = 1, 2

-- The three list tabs: which controls belong to each.
local LISTS = {
    [MSWHubFrame.TAB.MARKET] = {
        list = "marketList", empty = "marketEmptyText",
        title = "detailTitle", body = "detailText",
    },
    [MSWHubFrame.TAB.FORECASTS] = {
        list = "forecastList", empty = "forecastEmptyText",
        title = "forecastDetailTitle", body = "forecastDetailText",
    },
    [MSWHubFrame.TAB.HISTORY] = {
        list = "historyList", empty = "historyEmptyText",
        title = "historyDetailTitle", body = "historyDetailText",
    },
}

-- Only defined inside the game: the offline tests load the pure-logic modules
-- and never this class.
local MSWHubFrame_mt = Class(MSWHubFrame, TabbedMenuFrameElement)

local function text(key, fallback)
    if key ~= nil and g_i18n ~= nil and g_i18n:hasText(key) then
        return g_i18n:getText(key)
    end
    return fallback or key or ""
end

--- @param mod table the MarketShockwaves instance (settings, price model, ...)
function MSWHubFrame.new(mod)
    local self = MSWHubFrame:superClass().new(nil, MSWHubFrame_mt)
    self.mod = mod
    self.log = mod.log
    self.hasCustomMenuButtons = true
    self.tabState = MSWHubFrame.TAB.MARKET
    self.view = { events = {}, products = {} }
    self.forecastRows = {}
    self.historyRows = {}
    self.settingsBuilt = false
    return self
end

function MSWHubFrame:initialize()
    self.backButtonInfo = { inputAction = InputAction.MENU_BACK }
    self:setMenuButtonInfo({ self.backButtonInfo })
end

--- Run a drawing step without letting an error escape into the menu.
function MSWHubFrame:guard(what, fn)
    local ok, err = pcall(fn)
    if not ok then
        self.log:warn(("HubFrame: %s failed: %s"):format(what, tostring(err)))
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function MSWHubFrame:onGuiSetupFinished()
    MSWHubFrame:superClass().onGuiSetupFinished(self)

    for _, controls in pairs(LISTS) do
        self:guard("list setup " .. controls.list, function()
            local list = self[controls.list]
            if list ~= nil then
                list:setDataSource(self)
                list:setDelegate(self)
            end
        end)
    end

    -- The tab buttons draw as selected when their index is the current tab.
    self:guard("tab setup", function()
        for index, tab in ipairs(self.subCategoryTabs or {}) do
            local isSelected = function() return index == self:getCurrentTab() end
            tab.getIsSelected = isSelected
            local background = tab.getDescendantByName ~= nil
                               and tab:getDescendantByName("background") or nil
            if background ~= nil then background.getIsSelected = isSelected end
        end
    end)
end

function MSWHubFrame:onFrameOpen()
    MSWHubFrame:superClass().onFrameOpen(self)

    self:guard("tab layout", function()
        local texts = {}
        for index, tab in ipairs(self.subCategoryTabs or {}) do
            tab:setVisible(true)
            texts[index] = tostring(index)
        end
        if self.subCategoryBox ~= nil then self.subCategoryBox:invalidateLayout() end
        if self.subCategoryPaging ~= nil then
            self.subCategoryPaging:setTexts(texts)
            if self.subCategoryBox ~= nil and self.subCategoryBox.maxFlowSize ~= nil
               and g_pixelSizeScaledX ~= nil then
                self.subCategoryPaging:setSize(self.subCategoryBox.maxFlowSize
                                               + 140 * g_pixelSizeScaledX)
            end
            self.subCategoryPaging:setState(self.tabState, false)
        end
    end)

    self:guard("settings rows", function() self:ensureSettingsRows() end)
    self:guard("tab pages", function() self:showTab(self.tabState) end)
end

function MSWHubFrame:onFrameClose()
    MSWHubFrame:superClass().onFrameClose(self)
end

-- ---------------------------------------------------------------------------
-- Sub-tabs
-- ---------------------------------------------------------------------------

function MSWHubFrame:getCurrentTab()
    return self.tabState or MSWHubFrame.TAB.MARKET
end

--- Show one tab's page and hide the others.
function MSWHubFrame:showTab(index)
    if type(index) ~= "number" or index < 1 or index > TAB_COUNT then
        index = MSWHubFrame.TAB.MARKET
    end
    self.tabState = index

    for i, page in pairs(self.subCategoryPages or {}) do
        page:setVisible(i == index)
    end
    if self.subCategoryPaging ~= nil and self.subCategoryPaging.getState ~= nil
       and self.subCategoryPaging:getState() ~= index then
        self.subCategoryPaging:setState(index, false)
    end

    if index == MSWHubFrame.TAB.SETTINGS then
        if self.mod.menu ~= nil then self.mod.menu:refresh() end
        if self.settingsLayout ~= nil and FocusManager ~= nil then
            pcall(function() FocusManager:setFocus(self.settingsLayout) end)
        end
    else
        self:guard("tab data", function() self:reloadTab(index) end)
        local list = self[LISTS[index].list]
        if list ~= nil and FocusManager ~= nil then
            pcall(function() FocusManager:setFocus(list) end)
        end
    end
    self:setMenuButtonInfoDirty()
end

function MSWHubFrame:onClickMarketTab()
    self:guard("market tab", function() self:showTab(MSWHubFrame.TAB.MARKET) end)
end

function MSWHubFrame:onClickForecastsTab()
    self:guard("forecasts tab", function() self:showTab(MSWHubFrame.TAB.FORECASTS) end)
end

function MSWHubFrame:onClickHistoryTab()
    self:guard("history tab", function() self:showTab(MSWHubFrame.TAB.HISTORY) end)
end

function MSWHubFrame:onClickSettingsTab()
    self:guard("settings tab", function() self:showTab(MSWHubFrame.TAB.SETTINGS) end)
end

--- The paging control is what the shoulder buttons / Q and E drive.
function MSWHubFrame:onTabPagingChanged(state)
    self:guard("tab paging", function() self:showTab(state) end)
end

-- ---------------------------------------------------------------------------
-- Settings tab
-- ---------------------------------------------------------------------------

function MSWHubFrame:ensureSettingsRows()
    if self.settingsBuilt then return end
    self.settingsBuilt = true     -- one attempt; do not retry on every open

    if self.mod.menu == nil or self.settingsLayout == nil then
        self.log:warn("HubFrame: no settings layout, settings stay console-only")
        return
    end
    if self.mod.menu:buildInto(self.settingsLayout) then
        self.mod.menu:refresh()
    end
end

-- ---------------------------------------------------------------------------
-- Loading the list tabs
-- ---------------------------------------------------------------------------

function MSWHubFrame:today()
    return self.mod.calendar ~= nil and self.mod.calendar:getDay() or nil
end

--- Fill a list tab with today's data and show its empty text if there is none.
function MSWHubFrame:reloadTab(index)
    local controls = LISTS[index]
    if controls == nil then return end
    local day = self:today()
    local isEmpty

    if index == MSWHubFrame.TAB.MARKET then
        local open = self.mod.forecasts ~= nil and self.mod.forecasts:getOpen() or nil
        self.mod.priceModel:rebuild(day)
        self.view = MSWMarketView.build(self.mod.priceModel, day, open)
        isEmpty = #self.view.events == 0 and #self.view.products == 0
    elseif index == MSWHubFrame.TAB.FORECASTS then
        self.forecastRows = {}
        for _, forecast in ipairs(self.mod.forecasts ~= nil and self.mod.forecasts:getOpen() or {}) do
            self.forecastRows[#self.forecastRows + 1] = forecast
        end
        -- Newest first.
        table.sort(self.forecastRows, function(a, b) return a.startDay > b.startDay end)
        isEmpty = #self.forecastRows == 0
    else
        self.historyRows = self.mod.history ~= nil and self.mod.history:getNewestFirst() or {}
        isEmpty = #self.historyRows == 0
    end

    local empty, list = self[controls.empty], self[controls.list]
    if empty ~= nil then empty:setVisible(isEmpty) end
    if list ~= nil then
        list:setVisible(not isEmpty)
        list:reloadData()
    end
    if isEmpty then self:showDetail(index, nil, nil) end
end

--- Kept for callers that refresh the Market tab by name.
function MSWHubFrame:reloadMarket()
    self:reloadTab(MSWHubFrame.TAB.MARKET)
end

function MSWHubFrame:showDetail(index, title, body)
    local controls = LISTS[index]
    if controls == nil then return end
    local titleElement, bodyElement = self[controls.title], self[controls.body]
    if titleElement ~= nil then titleElement:setText(title or "") end
    if bodyElement ~= nil then bodyElement:setText(body or "") end
end

--- Which tab a list control belongs to.
function MSWHubFrame:tabOfList(list)
    for index, controls in pairs(LISTS) do
        if self[controls.list] == list then return index end
    end
    return MSWHubFrame.TAB.MARKET
end

-- ---------------------------------------------------------------------------
-- What the rows say
-- ---------------------------------------------------------------------------

--- A product's name as the game shows it, without our own [+13%] marker.
function MSWHubFrame:productTitle(name)
    local idx = self.mod.priceModel:getIndexFor(name)
    local display = self.mod.display
    if idx ~= nil and display ~= nil and display.originalTitles ~= nil
       and display.originalTitles[idx] ~= nil then
        return display.originalTitles[idx]
    end
    if idx ~= nil and g_fillTypeManager ~= nil then
        local ok, ft = pcall(function() return g_fillTypeManager:getFillTypeByIndex(idx) end)
        if ok and type(ft) == "table" and type(ft.title) == "string" then
            return ft.title
        end
    end
    return name
end

function MSWHubFrame:eventTitle(eventId)
    for _, e in ipairs(self.view.events) do
        if e.eventId == eventId then return text(e.titleKey, eventId) end
    end
    return eventId
end

--- "Mar, year 2", or "" for an entry from before dates were recorded.
function MSWHubFrame:dateLabel(month, year)
    if month == nil or year == nil then return "" end
    return text("msw_hub_date", "%s, year %d")
        :format(text(("msw_month_%d"):format(month), tostring(month)), year)
end

--- Is the event behind a history entry still running?
function MSWHubFrame:isEventRunning(eventId, startDay)
    local day = self:today()
    if eventId == nil or startDay == nil or day == nil then return false end
    for _, ev in ipairs(self.mod.priceModel:getActiveEvents()) do
        if ev.eventId == eventId and ev.startDay == startDay and not ev:isExpired(day) then
            return true
        end
    end
    return false
end

--- A word for where an entry stands. Never a number.
function MSWHubFrame:historyStatus(entry)
    if entry.kind == "forecast" then
        return text("msw_hub_status_" .. tostring(entry.status or "open"), "")
    end
    if entry.kind == "event" or entry.kind == "verdict" then
        if entry.eventId == nil then return "" end
        if self:isEventRunning(entry.eventId, entry.eventStartDay) then
            return text("msw_hub_status_running", "Running")
        end
        return text("msw_hub_status_ended", "Ended")
    end
    return ""
end

function MSWHubFrame:forecastTitle(forecast)
    local titleKey = MSWForecastDef.messageKeys(forecast.forecastId, forecast.variantId, "open")
    return text(titleKey, forecast.forecastId)
end

--- The history entry a forecast was announced with (for its date).
function MSWHubFrame:forecastEntry(forecast)
    local ref = ("%s@%d"):format(forecast.forecastId, forecast.startDay)
    for _, entry in ipairs(self.mod.history ~= nil and self.mod.history.entries or {}) do
        if entry.kind == "forecast" and entry.ref == ref then return entry end
    end
    return nil
end

-- ---- SmoothList data source ----------------------------------------------

function MSWHubFrame:getNumberOfSections(list)
    if self:tabOfList(list) == MSWHubFrame.TAB.MARKET then return 2 end
    return 1
end

function MSWHubFrame:getNumberOfItemsInSection(list, section)
    local tab = self:tabOfList(list)
    if tab == MSWHubFrame.TAB.FORECASTS then return #self.forecastRows end
    if tab == MSWHubFrame.TAB.HISTORY then return #self.historyRows end
    if section == SECTION_EVENTS then return #self.view.events end
    return #self.view.products
end

function MSWHubFrame:getTitleForSectionHeader(list, section)
    if self:tabOfList(list) ~= MSWHubFrame.TAB.MARKET then return nil end
    if section == SECTION_EVENTS then
        return text("msw_hub_section_news", "In the news")
    end
    return text("msw_hub_section_prices", "Prices on the move")
end

function MSWHubFrame:populateCellForItemInSection(list, section, index, cell)
    local tab = self:tabOfList(list)
    local nameCell, changeCell = cell:getAttribute("name"), cell:getAttribute("change")
    local function set(element, value)
        if element ~= nil then element:setText(value or "") end
    end

    if tab == MSWHubFrame.TAB.FORECASTS then
        local forecast = self.forecastRows[index]
        if forecast == nil then return end
        set(nameCell, self:forecastTitle(forecast))
        -- The pre-move is the visible sign that a verdict is close.
        local close = forecast:isInPremove(self:today() or 0)
        set(changeCell, close and text("msw_hub_status_close", "Verdict close")
                               or text("msw_hub_status_open", "Open"))
    elseif tab == MSWHubFrame.TAB.HISTORY then
        local entry = self.historyRows[index]
        if entry == nil then return end
        set(cell:getAttribute("date"), self:dateLabel(entry.month, entry.year))
        set(cell:getAttribute("kind"), text("msw_hub_kind_" .. tostring(entry.kind), ""))
        set(nameCell, MSWHistory.resolveText(g_i18n, entry.titleKey))
        set(changeCell, self:historyStatus(entry))
    elseif section == SECTION_EVENTS then
        local e = self.view.events[index]
        if e == nil then return end
        set(nameCell, text(e.titleKey, e.eventId))
        set(changeCell, "")
    else
        local p = self.view.products[index]
        if p == nil then return end
        set(nameCell, self:productTitle(p.name))
        set(changeCell, MSWMarketView.formatChange(p.factor))
    end
end

-- ---- SmoothList delegate ---------------------------------------------------

function MSWHubFrame:onListSelectionChanged(list, section, index)
    self:guard("selection", function()
        local tab = self:tabOfList(list)

        if tab == MSWHubFrame.TAB.FORECASTS then
            local forecast = self.forecastRows[index]
            if forecast == nil then return end
            local _, textKey = MSWForecastDef.messageKeys(forecast.forecastId,
                                                          forecast.variantId, "open")
            local body = MSWHistory.resolveText(g_i18n, textKey,
                MSWForecastDef.confidenceKey(forecast.confidence or 70))
            local entry = self:forecastEntry(forecast)
            local date = entry ~= nil and self:dateLabel(entry.month, entry.year) or ""
            if date ~= "" then
                body = text("msw_hub_announced", "Announced: %s"):format(date) .. "\n\n" .. body
            end
            self:showDetail(tab, self:forecastTitle(forecast), body)
            return
        end

        if tab == MSWHubFrame.TAB.HISTORY then
            local entry = self.historyRows[index]
            if entry == nil then return end
            self:showDetail(tab, MSWHistory.resolveText(g_i18n, entry.titleKey),
                            MSWHistory.resolveText(g_i18n, entry.textKey, entry.argKey))
            return
        end

        if section == SECTION_EVENTS then
            local e = self.view.events[index]
            if e ~= nil then
                self:showDetail(tab, text(e.titleKey, e.eventId), text(e.textKey, ""))
            end
        else
            local p = self.view.products[index]
            if p ~= nil then
                local titles = {}
                for _, id in ipairs(p.eventIds) do titles[#titles + 1] = self:eventTitle(id) end
                for _, key in ipairs(p.forecastTitleKeys or {}) do
                    titles[#titles + 1] = text("msw_hub_moved_by_forecast", "Forecast: %s")
                        :format(text(key, key))
                end
                self:showDetail(tab,
                    ("%s  %s"):format(self:productTitle(p.name), MSWMarketView.formatChange(p.factor)),
                    text("msw_hub_moved_by", "Moved by:") .. "\n" .. table.concat(titles, "\n"))
            end
        end
    end)
end

-- ---------------------------------------------------------------------------
-- Installing the page into the ESC menu
-- ---------------------------------------------------------------------------

local REQUIRED_MENU_METHODS = {
    "registerPage", "addPageTab", "rebuildTabList", "exposeControlsAsFields",
}
local REQUIRED_PAGING_METHODS = {
    "addElement", "updateAbsolutePosition", "updatePageMapping",
}

--- Move `item` to `position` in an array, if it is in there.
local function moveTo(array, matches, position)
    if type(array) ~= "table" then return end
    for i = 1, #array do
        if matches(array[i]) then
            local entry = table.remove(array, i)
            table.insert(array, math.min(position, #array + 1), entry)
            return
        end
    end
end

--- Create the page and add it to the ESC menu.
--- @param mod table the MarketShockwaves instance
--- @param modDirectory string
--- @return table|nil the frame, or nil if the menu was left untouched
function MSWHubFrame.install(mod, modDirectory)
    local log = mod.log
    if g_gui == nil or InGameMenu == nil or TabbedMenuFrameElement == nil then
        log:warn("HubFrame: GUI classes unavailable, hub not installed")
        return nil
    end

    local menu = g_gui.screenControllers ~= nil and g_gui.screenControllers[InGameMenu] or nil
    if type(menu) ~= "table" or type(menu.pagingElement) ~= "table" then
        log:warn("HubFrame: ESC menu controller not found, hub not installed")
        return nil
    end
    for _, m in ipairs(REQUIRED_MENU_METHODS) do
        if type(menu[m]) ~= "function" then
            log:warn(("HubFrame: InGameMenu.%s missing, hub not installed"):format(m))
            return nil
        end
    end
    for _, m in ipairs(REQUIRED_PAGING_METHODS) do
        if type(menu.pagingElement[m]) ~= "function" then
            log:warn(("HubFrame: pagingElement.%s missing, hub not installed"):format(m))
            return nil
        end
    end
    if menu[PAGE_NAME] ~= nil then
        log:info("HubFrame: already installed")
        return menu[PAGE_NAME]
    end

    -- Build the frame first. If the layout does not load, or loads without the
    -- controls the code relies on, stop before the menu is touched.
    local frame = MSWHubFrame.new(mod)
    local okLoad, errLoad = pcall(function()
        g_gui:loadGui(modDirectory .. "gui/MSWHubFrame.xml", GUI_NAME, frame, true)
    end)
    if not okLoad then
        log:warn("HubFrame: layout failed to load: " .. tostring(errLoad))
        return nil
    end
    for _, id in ipairs({ "marketList", "settingsLayout", "subCategoryPages" }) do
        if frame[id] == nil then
            log:warn(("HubFrame: layout loaded without '%s', hub not installed"):format(id))
            return nil
        end
    end
    -- The newer tabs are not required: without them the page still works.
    for _, id in ipairs({ "forecastList", "historyList" }) do
        if frame[id] == nil then
            log:warn(("HubFrame: layout loaded without '%s'; that tab will be empty"):format(id))
        end
    end

    local ok, err = pcall(function()
        -- Directly above the settings page when it can be found, else last.
        local position = #menu.pagingElement.elements + 1
        for i, child in ipairs(menu.pagingElement.elements) do
            if child == menu.pageSettings then position = i break end
        end

        if type(menu.controlIDs) == "table" then menu.controlIDs[PAGE_NAME] = nil end
        menu[PAGE_NAME] = frame
        menu.pagingElement:addElement(frame)
        menu:exposeControlsAsFields(PAGE_NAME)

        moveTo(menu.pagingElement.elements, function(e) return e == frame end, position)
        moveTo(menu.pagingElement.pages, function(p) return p.element == frame end, position)

        menu.pagingElement:updateAbsolutePosition()
        menu.pagingElement:updatePageMapping()

        menu:registerPage(frame, position, function() return true end)
        menu:addPageTab(frame, Utils.getFilename("gui/menuIcon.dds", modDirectory),
                        GuiUtils.getUVs({ 0, 0, 1024, 1024 }))

        moveTo(menu.pageFrames, function(f) return f == frame end, position)
        menu:rebuildTabList()

        frame:initialize()
    end)
    if not ok then
        log:error("HubFrame: adding the page to the ESC menu failed: " .. tostring(err))
        return nil
    end

    log:info("HubFrame: Market Shockwaves page added to the ESC menu")
    return frame
end
