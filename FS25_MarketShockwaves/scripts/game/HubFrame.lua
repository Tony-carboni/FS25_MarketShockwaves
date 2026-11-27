--[[
    HubFrame — the mod's own page in the ESC menu.

    A hub rather than a settings page: one place to see what the market is doing
    and to change how the mod behaves. Sub-tabs across the top:

        MARKET     what is in the news, and which prices are moving today
        SETTINGS   every setting (moved here from GAME SETTINGS)

    More tabs are expected (forecasts, once speculation exists), which is why
    the tab handling below is table-driven rather than written for two.

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

    The data shown comes from MSWMarketView (pure logic, tested offline); this
    file only draws it.
]]

MSWHubFrame = {}

local PAGE_NAME = "pageMarketShockwaves"
local GUI_NAME  = "MSWHubFrame"

MSWHubFrame.TAB = { MARKET = 1, SETTINGS = 2 }
local TAB_COUNT = 2

-- List sections on the Market tab.
local SECTION_EVENTS, SECTION_PRODUCTS = 1, 2

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

    self:guard("list setup", function()
        self.marketList:setDataSource(self)
        self.marketList:setDelegate(self)
    end)

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
    self:guard("market data", function() self:reloadMarket() end)
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
        self:reloadMarket()
        if self.marketList ~= nil and FocusManager ~= nil then
            pcall(function() FocusManager:setFocus(self.marketList) end)
        end
    end
    self:setMenuButtonInfoDirty()
end

function MSWHubFrame:onClickMarketTab()
    self:guard("market tab", function() self:showTab(MSWHubFrame.TAB.MARKET) end)
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
-- Market tab
-- ---------------------------------------------------------------------------

function MSWHubFrame:reloadMarket()
    local day = self.mod.calendar ~= nil and self.mod.calendar:getDay() or nil
    self.mod.priceModel:rebuild(day)
    self.view = MSWMarketView.build(self.mod.priceModel, day)

    local calm = #self.view.events == 0
    if self.marketEmptyText ~= nil then self.marketEmptyText:setVisible(calm) end
    if self.marketList ~= nil then
        self.marketList:setVisible(not calm)
        self.marketList:reloadData()
    end
    if calm then self:showDetail(nil, nil) end
end

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

function MSWHubFrame:showDetail(title, body)
    if self.detailTitle ~= nil then self.detailTitle:setText(title or "") end
    if self.detailText ~= nil then self.detailText:setText(body or "") end
end

-- ---- SmoothList data source ----------------------------------------------

function MSWHubFrame:getNumberOfSections()
    return 2
end

function MSWHubFrame:getNumberOfItemsInSection(list, section)
    if section == SECTION_EVENTS then return #self.view.events end
    return #self.view.products
end

function MSWHubFrame:getTitleForSectionHeader(list, section)
    if section == SECTION_EVENTS then
        return text("msw_hub_section_news", "In the news")
    end
    return text("msw_hub_section_prices", "Prices on the move")
end

function MSWHubFrame:populateCellForItemInSection(list, section, index, cell)
    local nameCell, changeCell = cell:getAttribute("name"), cell:getAttribute("change")
    if section == SECTION_EVENTS then
        local e = self.view.events[index]
        if e == nil then return end
        if nameCell ~= nil then nameCell:setText(text(e.titleKey, e.eventId)) end
        if changeCell ~= nil then changeCell:setText("") end
    else
        local p = self.view.products[index]
        if p == nil then return end
        if nameCell ~= nil then nameCell:setText(self:productTitle(p.name)) end
        if changeCell ~= nil then changeCell:setText(MSWMarketView.formatChange(p.factor)) end
    end
end

-- ---- SmoothList delegate ---------------------------------------------------

function MSWHubFrame:onListSelectionChanged(list, section, index)
    self:guard("selection", function()
        if section == SECTION_EVENTS then
            local e = self.view.events[index]
            if e ~= nil then
                self:showDetail(text(e.titleKey, e.eventId), text(e.textKey, ""))
            end
        else
            local p = self.view.products[index]
            if p ~= nil then
                local titles = {}
                for _, id in ipairs(p.eventIds) do titles[#titles + 1] = self:eventTitle(id) end
                self:showDetail(
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
