--[[
    SettingsMenu — the mod's rows inside ESC -> Settings -> GAME SETTINGS.

    Built entirely by CLONING the game's own rows rather than constructing GUI
    elements, so the rows inherit the current build's look, spacing, focus
    behaviour and tooltip wiring for free. Nothing here builds a widget from
    scratch and nothing patches a shared class.

    Verified against a live probe (see MSWDiag.dumpSettingsGui) rather than
    assumed:

      g_gui.guis.InGameMenu.target.pageSettings   class InGameMenuSettingsFrame
        .gameSettingsLayout    ScrollingLayout, the GAME SETTINGS tab, whose
                               children are alternating option rows and
                               "sectionHeader" Text elements
        rows                   Bitmap  profile=fs25_multiTextOptionContainer
        headers                Text    profile=fs25_settingsSectionHeader
                                       name=sectionHeader

    GAME SETTINGS is the right tab: these are savegame-scoped economy settings,
    living next to SEASONS and CROPS AND GROWTH, not client preferences like
    units or volume.

    Two deliberate simplifications:

      * Every row is a MultiTextOption, booleans included (Off/On). One code
        path covers all fifteen settings, and it matches how most of the game's
        own rows are built.
      * onFrameOpen is wrapped on the page INSTANCE, not on
        InGameMenuSettingsFrame. The instance method shadows the class one, so
        no other mod touching that class can collide with us.

    Every step is pcall-guarded as a whole: if the layout ever changes shape,
    the rows are simply absent and the reason is in the log. A settings page
    that is missing our rows is an acceptable failure; a broken settings page
    is not.
]]

MSWSettingsMenu = {}
local MSWSettingsMenu_mt = Class(MSWSettingsMenu)

local SECTION_TITLE_KEY = "msw_settings_section"

function MSWSettingsMenu.new(settings, logger, onChanged)
    local self = setmetatable({}, MSWSettingsMenu_mt)
    self.settings = settings
    self.log = logger
    -- Called after any row changes, so the mod can apply side effects (price
    -- hooks on/off, name markers) without this file knowing about them.
    self.onChanged = onChanged
    self.rows = {}          -- [settingName] = { option=, entry=, values= }
    self.installed = false
    self.loggedRowShape = false
    return self
end

-- ---------------------------------------------------------------------------
-- Small helpers
-- ---------------------------------------------------------------------------

local function text(key, fallback)
    if key == nil then return fallback or "" end
    if g_i18n ~= nil and g_i18n:hasText(key) then return g_i18n:getText(key) end
    return fallback or key
end

--- Depth-first search for the first descendant satisfying pred.
local function findDescendant(element, pred, depth)
    depth = depth or 0
    if type(element) ~= "table" or depth > 8 then return nil end
    if depth > 0 and pred(element) then return element end
    if type(element.elements) ~= "table" then return nil end
    for _, child in ipairs(element.elements) do
        local hit = findDescendant(child, pred, depth + 1)
        if hit ~= nil then return hit end
    end
    return nil
end

--- Profiles that identify the two text elements in a settings row.
---
--- Verified from a live dump rather than guessed - the first attempt used
--- "the first Text that is not the value display", which found the TOOLTIP and
--- wrote every row's label into the description panel. The real shape is:
---
---   Bitmap             fs25_multiTextOptionContainer
---     MultiTextOption  fs25_settingsMultiTextOption
---       Text           fs25_multiTextOptionTooltip       name=ignore  <- panel
---       background / left / right
---       text                                                         <- value
---     Text             fs25_settingsMultiTextOptionTitle              <- label
---
--- So the description lives INSIDE the option and the title is its SIBLING,
--- which is the opposite of what the nesting suggests.
local TITLE_PROFILE   = "fs25_settingsMultiTextOptionTitle"
local TOOLTIP_PROFILE = "fs25_multiTextOptionTooltip"

local function isText(e) return e.typeName == "Text" end

--- Search a subtree while skipping one branch of it.
local function findOutside(element, skip, pred, depth)
    depth = depth or 0
    if type(element) ~= "table" or element == skip or depth > 8 then return nil end
    if depth > 0 and pred(element) then return element end
    if type(element.elements) ~= "table" then return nil end
    for _, child in ipairs(element.elements) do
        local hit = findOutside(child, skip, pred, depth + 1)
        if hit ~= nil then return hit end
    end
    return nil
end

--- The row's visible label. Matched by profile, falling back to "any Text that
--- is not inside the option" so a renamed profile degrades rather than breaks.
local function findTitle(box, option)
    return findDescendant(box, function(e)
               return isText(e) and e.profile == TITLE_PROFILE
           end)
        or findOutside(box, option, isText)
end

--- The element whose text appears in the right-hand description panel.
local function findTooltip(option)
    if option == nil then return nil end
    return findDescendant(option, function(e)
               return isText(e) and e.profile == TOOLTIP_PROFILE
           end)
        or findDescendant(option, function(e)
               return isText(e) and e.name ~= "text"
           end)
end

-- The base game's row, and the hub's own row which extends it.
local ROW_PROFILES = {
    fs25_multiTextOptionContainer = true,
    msw_hubSettingsRow = true,
}

local function isRowContainer(e)
    return ROW_PROFILES[e.profile] == true
end

local function isSectionHeader(e)
    return e.name == "sectionHeader" or e.profile == "fs25_settingsSectionHeader"
end

--- The display texts for one MENU_SPEC entry, l10n keys resolved.
---
--- Booleans are widened to a two-step choice here so the row-building code
--- below has exactly one shape to deal with.
local function choiceTextsFor(entry)
    if entry.kind == "bool" then
        return { text("msw_off", "Off"), text("msw_on", "On") }, { 0, 1 }
    end
    local raw = MSWSettingsAdapter.getChoiceTexts(entry)
    local out = {}
    for i, t in ipairs(raw) do
        -- getChoiceTexts returns l10n keys where the entry defined labels, and
        -- already-formatted strings otherwise.
        out[i] = (entry.labels ~= nil and entry.labels[i] ~= nil) and text(t, t) or t
    end
    return out, entry.values
end

-- ---------------------------------------------------------------------------
-- Install
-- ---------------------------------------------------------------------------

--- Wrap pageSettings.onFrameOpen so the rows are built on first open and their
--- displayed state is refreshed on every open.
function MSWSettingsMenu:install()
    if self.installed then return true end

    local menu = g_gui and g_gui.guis and g_gui.guis["InGameMenu"]
    local page = menu and menu.target and menu.target.pageSettings
    if type(page) ~= "table" or type(page.onFrameOpen) ~= "function" then
        self.log:warn("SettingsMenu: pageSettings.onFrameOpen unavailable, "
                   .. "settings are console-only (mswSet / mswSettings)")
        return false
    end

    local original = page.onFrameOpen
    local this = self
    page.onFrameOpen = function(frame, ...)
        local result = original(frame, ...)
        -- Never let a GUI problem of ours stop the settings page opening.
        local ok, err = pcall(function()
            this:onSettingsOpened(frame)
        end)
        if not ok then
            this.log:warn("SettingsMenu: " .. tostring(err))
        end
        return result
    end

    self.installed = true
    self.log:info("SettingsMenu: installed on pageSettings.onFrameOpen")
    return true
end

function MSWSettingsMenu:onSettingsOpened(frame)
    if not frame.mswRowsBuilt then
        if self:buildRows(frame) then
            frame.mswRowsBuilt = true
        else
            -- Do not retry endlessly on every open.
            frame.mswRowsBuilt = true
            self.log:warn("SettingsMenu: rows could not be built, "
                       .. "settings remain available via mswSet")
            return
        end
    end
    self:refresh()
end

-- ---------------------------------------------------------------------------
-- Row construction
-- ---------------------------------------------------------------------------

function MSWSettingsMenu:buildRows(frame)
    return self:buildRowsIn(frame.gameSettingsLayout, { where = "GAME SETTINGS", header = true })
end

--- Build the rows on the mod's own hub page.
---
--- The hub's layout carries one template row and one header, the same shapes
--- the GAME SETTINGS page has, so the cloning code below serves both. There the
--- templates are real base-game rows and must stay; here they exist only to be
--- cloned, so they are hidden afterwards. No section header either: the whole
--- page is ours, so there is nothing to tell the rows apart from.
function MSWSettingsMenu:buildInto(layout)
    return self:buildRowsIn(layout, { where = "the hub", header = false, hideTemplates = true,
                                      altProfile = "msw_hubSettingsRowAlt" })
end

--- @param layout table a layout whose children include a row to clone
--- @param opts table where (for the log), header, hideTemplates
function MSWSettingsMenu:buildRowsIn(layout, opts)
    opts = opts or {}
    if type(layout) ~= "table" or type(layout.elements) ~= "table" then
        self.log:warn(("SettingsMenu: no settings layout for %s")
            :format(tostring(opts.where or "?")))
        return false
    end

    -- Templates come from the page itself, so they always match this build.
    local rowTemplate, headerTemplate
    for _, child in ipairs(layout.elements) do
        if rowTemplate == nil and isRowContainer(child)
           and findDescendant(child, function(e) return e.typeName == "MultiTextOption" end) ~= nil then
            rowTemplate = child
        end
        if headerTemplate == nil and isSectionHeader(child) then
            headerTemplate = child
        end
    end

    if rowTemplate == nil then
        self.log:warn("SettingsMenu: no fs25_multiTextOptionContainer row to clone")
        return false
    end

    self.log:info(("SettingsMenu: cloning row template (profile=%s) and header "
                .. "template (%s)")
        :format(tostring(rowTemplate.profile),
                headerTemplate ~= nil and tostring(headerTemplate.profile) or "none"))

    -- Section header, so the block is visibly ours and not mistaken for a
    -- base-game setting.
    if headerTemplate ~= nil and opts.header ~= false then
        local header = headerTemplate:clone(layout)
        if header ~= nil then
            if header.setText ~= nil then
                header:setText(text(SECTION_TITLE_KEY, "MARKET SHOCKWAVES"))
            end
            self:clearFocus(header)
        end
    end

    local built = 0
    for _, entry in ipairs(MSWSettingsAdapter.getMenuSpec()) do
        local before = #layout.elements
        if self:buildRow(layout, rowTemplate, entry) then
            built = built + 1
            -- Band every second row, where the page asks for it.
            local box = layout.elements[#layout.elements]
            if opts.altProfile ~= nil and built % 2 == 0 and #layout.elements > before
               and box ~= nil and box.applyProfile ~= nil then
                box:applyProfile(opts.altProfile)
            end
        end
    end

    if opts.hideTemplates then
        for _, template in ipairs({ rowTemplate, headerTemplate }) do
            if template.setVisible ~= nil then template:setVisible(false) end
        end
    end

    if layout.invalidateLayout ~= nil then layout:invalidateLayout() end

    self.log:info(("SettingsMenu: added %d of %d rows to %s")
        :format(built, #MSWSettingsAdapter.getMenuSpec(), tostring(opts.where or "?")))
    return built > 0
end

function MSWSettingsMenu:buildRow(layout, template, entry)
    local box = template:clone(layout)
    if box == nil then
        self.log:warn("SettingsMenu: clone failed for " .. entry.name)
        return false
    end

    local option = findDescendant(box, function(e)
        return e.typeName == "MultiTextOption"
    end)
    if option == nil then
        self.log:warn("SettingsMenu: cloned row has no MultiTextOption for "
                   .. entry.name)
        return false
    end

    -- The clone carries the template's id and focus id. Both must go: a
    -- duplicate id confuses lookups, a duplicate focus id breaks controller
    -- navigation across the whole page.
    box.id = nil
    option.id = "msw_" .. entry.name
    self:clearFocus(box)

    -- The clone also carries the template's callback and target, which point at
    -- a real base-game handler. Overwriting BOTH is what stops our row from
    -- changing, say, the growth mode.
    option.target = self
    option.onClickCallback = function(_, state)
        self:onRowChanged(entry.name, state)
    end

    local texts, values = choiceTextsFor(entry)
    self.rows[entry.name] = { option = option, entry = entry, values = values }

    if option.setTexts ~= nil then option:setTexts(texts) end

    -- The row's TITLE is a sibling of the option; the DESCRIPTION shown in the
    -- right-hand panel is a Text INSIDE it. See the profile constants at the top
    -- for why that ordering matters.
    local title = findTitle(box, option)
    if title ~= nil and title.setText ~= nil then
        title:setText(text(MSWSettingsAdapter.getLabelKey(entry.name), entry.name))
    else
        self.log:warn("SettingsMenu: no title element in row for " .. entry.name)
    end

    -- Description for the right-hand panel. It is a real Text element that has
    -- to be written to; the element's `toolTipText` field is unused on this
    -- build (the probe reported it nil), so setting that achieved nothing.
    local tipElement = findTooltip(option)
    local tip = text(MSWSettingsAdapter.getTooltipKey(entry.name), nil)
    if tipElement ~= nil and tipElement.setText ~= nil then
        if tip ~= "" then tipElement:setText(tip) end
    else
        self.log:warn("SettingsMenu: no tooltip element in row for " .. entry.name)
    end

    -- First row logs its own structure. This is what identified the title and
    -- tooltip elements in the first place, and it is what will identify them
    -- again if a game patch reshapes the row.
    if not self.loggedRowShape then
        self.loggedRowShape = true
        self:logRowShape(box, option, title, tipElement)
    end

    return true
end

--- One-time log of a cloned row's shape: every descendant, and which of them we
--- picked as the option and the label. Cheap, and it is the difference between
--- fixing a mislabelled row in one iteration or three.
function MSWSettingsMenu:logRowShape(box, option, title, tipElement)
    local function walk(e, depth)
        if type(e) ~= "table" or depth > 5 then return end
        self.log:info(("   %s%s name=%s profile=%s%s%s%s")
            :format(("  "):rep(depth),
                    tostring(e.typeName), tostring(e.name), tostring(e.profile),
                    e == option and "   <-- OPTION" or "",
                    e == title and "   <-- TITLE" or "",
                    e == tipElement and "   <-- DESCRIPTION" or ""))
        if type(e.elements) == "table" then
            for _, c in ipairs(e.elements) do walk(c, depth + 1) end
        end
    end
    self.log:info("SettingsMenu: cloned row shape --")
    walk(box, 0)
    self.log:info(("SettingsMenu: option has setTexts=%s setState=%s "
                .. "toolTipText field=%s")
        :format(tostring(option.setTexts ~= nil), tostring(option.setState ~= nil),
                tostring(option.toolTipText)))
end

--- Give a cloned subtree fresh focus ids.
---
--- Clones copy focusId verbatim, and duplicate ids make the focus manager pick
--- the wrong element when navigating with a controller. Serving new ids is the
--- documented way out; if the API is missing we clear the ids instead, which
--- costs controller navigation on our rows but harms nothing else.
function MSWSettingsMenu:clearFocus(element)
    if type(element) ~= "table" then return end
    if FocusManager ~= nil and FocusManager.serveAutoFocusId ~= nil then
        element.focusId = FocusManager:serveAutoFocusId()
    else
        element.focusId = nil
    end
    if type(element.elements) == "table" then
        for _, child in ipairs(element.elements) do self:clearFocus(child) end
    end
    -- Register the subtree once its ids are unique.
    if element.focusId ~= nil and FocusManager ~= nil
       and FocusManager.loadElementFromCustomValues ~= nil then
        pcall(function() FocusManager:loadElementFromCustomValues(element) end)
    end
end

-- ---------------------------------------------------------------------------
-- Reading and writing
-- ---------------------------------------------------------------------------

function MSWSettingsMenu:onRowChanged(name, state)
    local row = self.rows[name]
    if row == nil then return end
    local value = row.values and row.values[state]
    if value == nil then return end

    self.settings:set(name, value)
    if self.onChanged ~= nil then self.onChanged(name, value) end
end

--- Push current values into the controls. Called on every page open, so an
--- mswSet or mswReset from the console is reflected in the menu.
function MSWSettingsMenu:refresh()
    for name, row in pairs(self.rows) do
        local index = self.settings:getChoiceIndex({
            name = name,
            values = row.values,
        })
        if row.option.setState ~= nil then
            -- false: do not fire the callback, this is a display update.
            row.option:setState(index, false)
        end
    end
end
