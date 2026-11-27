--[[
    Offline tests for the in-game settings rows.

    The settings page is the one place where a mistake is visible to every
    player and awkward to diagnose from a screenshot, so the row-building logic
    is exercised here against a fake GUI tree shaped like the real one.

    The fake tree mirrors the REAL row, as dumped from a running game:

      pageSettings
        gameSettingsLayout                ScrollingLayout
          Bitmap  fs25_multiTextOptionContainer          <- row, 2 children
            MultiTextOption fs25_settingsMultiTextOption
              Text name=ignore fs25_multiTextOptionTooltip  <- DESCRIPTION panel
              background / left / right
              Text name=text                                <- value display
            Text  fs25_settingsMultiTextOptionTitle         <- the row LABEL
          Text  name=sectionHeader                       <- section header

    This fixture used to model a guessed shape - title as a direct child, no
    tooltip element - and every test passed while the shipped menu wrote all 14
    labels into the description panel. A fixture that encodes an assumption
    cannot test that assumption, so it now mirrors the dump exactly: the
    description is INSIDE the option and the title is its SIBLING, which is the
    opposite of what the nesting suggests.

    Run:  lua tools/test_settings_menu.lua
]]

function Class(base)
    local c = {}
    c.__index = c
    if base then setmetatable(c, { __index = base }) end
    return c
end

local passed, failed = 0, 0
local function check(name, cond, detail)
    if cond then
        passed = passed + 1
        print("  PASS  " .. name)
    else
        failed = failed + 1
        print("  FAIL  " .. name .. (detail and ("  — " .. detail) or ""))
    end
end
local function group(n) print("\n[" .. n .. "]") end

-- ---- engine stubs ---------------------------------------------------------

local i18nTexts = {}
g_i18n = {
    hasText = function(_, k) return i18nTexts[k] ~= nil end,
    getText = function(_, k) return i18nTexts[k] or k end,
}

local servedFocusIds = {}
FocusManager = {
    serveAutoFocusId = function()
        local id = "auto_" .. tostring(#servedFocusIds + 1)
        servedFocusIds[#servedFocusIds + 1] = id
        return id
    end,
    loadElementFromCustomValues = function() end,
}

-- A GuiElement stand-in: enough of the real contract for the code under test.
local Element = {}
Element.__index = Element

local function newElement(spec)
    local e = setmetatable({
        typeName = spec.typeName,
        name = spec.name,
        profile = spec.profile,
        id = spec.id,
        focusId = spec.focusId,
        elements = {},
        text = spec.text,
        texts = spec.texts,
        state = spec.state or 1,
    }, Element)
    for _, child in ipairs(spec.children or {}) do
        child.parent = e
        e.elements[#e.elements + 1] = child
    end
    return e
end

function Element:clone(parent)
    local copy = newElement({
        typeName = self.typeName, name = self.name, profile = self.profile,
        id = self.id, focusId = self.focusId, text = self.text,
    })
    -- A real clone carries the template's callback and target across, which is
    -- precisely the hazard the code under test has to neutralise.
    copy.onClickCallback = self.onClickCallback
    copy.target = self.target
    for _, child in ipairs(self.elements) do
        local c = child:clone()
        c.parent = copy
        copy.elements[#copy.elements + 1] = c
    end
    if parent ~= nil then
        parent.elements[#parent.elements + 1] = copy
        copy.parent = parent
    end
    return copy
end

function Element:setText(t) self.text = t end
function Element:setTexts(t) self.texts = t end
function Element:setState(i, fireCallback)
    self.state = i
    if fireCallback and self.onClickCallback ~= nil then
        if self.target ~= nil then self.onClickCallback(self.target, i, self)
        else self.onClickCallback(i, self) end
    end
end
function Element:invalidateLayout() self.layoutInvalidated = true end
function Element:setVisible(v) self.visible = v end
function Element:applyProfile(name) self.profile = name end

-- ---- the page under test --------------------------------------------------

local baseGameCalls = 0

local function buildFakePage()
    local function optionRow(id)
        return newElement({
            typeName = "Bitmap", profile = "fs25_multiTextOptionContainer",
            id = id, focusId = "template_focus",
            children = {
                newElement({
                    typeName = "MultiTextOption", id = "multiGrowthMode",
                    profile = "fs25_settingsMultiTextOption",
                    focusId = "template_focus_opt",
                    children = {
                        -- The description panel's source, inside the option.
                        newElement({ typeName = "Text", name = "ignore",
                                     profile = "fs25_multiTextOptionTooltip",
                                     text = "How crops grow over the year." }),
                        newElement({ name = "background" }),
                        newElement({ name = "left" }),
                        newElement({ name = "right" }),
                        newElement({ typeName = "Text", name = "text",
                                     profile = "fs25_multiTextOptionText",
                                     text = "Annual" }),
                    },
                }),
                -- The visible row label, a SIBLING of the option.
                newElement({ typeName = "Text",
                             profile = "fs25_settingsMultiTextOptionTitle",
                             text = "Autosave Interval" }),
            },
        })
    end

    local row = optionRow("multiGrowthModeBox")
    -- The base-game handler the template row is wired to. If a cloned row still
    -- points here, changing a mod setting would change a game setting.
    local option = row.elements[1]
    option.target = { frame = true }
    option.onClickCallback = function() baseGameCalls = baseGameCalls + 1 end

    local layout = newElement({
        typeName = "ScrollingLayout", id = "gameSettingsLayout",
        profile = "fs25_settingsLayout",
        children = {
            row,
            newElement({ typeName = "Text", name = "sectionHeader",
                         profile = "fs25_settingsSectionHeader", text = "SEASONS" }),
        },
    })

    local page = {
        gameSettingsLayout = layout,
        onFrameOpen = function() return "opened" end,
    }
    return page, layout
end

local page, layout = buildFakePage()
g_gui = { guis = { InGameMenu = { target = { pageSettings = page } } } }

-- ---- load the code under test --------------------------------------------

local log = {
    info = function() end,
    warn = function(_, m) print("    (warn) " .. tostring(m)) end,
    error = function(_, m) print("    (error) " .. tostring(m)) end,
    debug = function() end,
}

dofile("FS25_MarketShockwaves/scripts/game/SettingsAdapter.lua")
dofile("FS25_MarketShockwaves/scripts/game/SettingsMenu.lua")

local settings = MSWSettingsAdapter.new(log)
local changedNames = {}
local menu = MSWSettingsMenu.new(settings, log, function(name)
    changedNames[#changedNames + 1] = name
end)

-- ---------------------------------------------------------------------------
group("1  install wraps the page instance, not a class")

local originalOpen = page.onFrameOpen
check("install succeeds", menu:install())
check("onFrameOpen was replaced", page.onFrameOpen ~= originalOpen)
check("install is idempotent", menu:install())

local returned = page.onFrameOpen(page)
check("the original onFrameOpen still runs and its value is returned",
      returned == "opened", tostring(returned))

-- ---------------------------------------------------------------------------
group("2  a row exists for every setting in MENU_SPEC")

local spec = MSWSettingsAdapter.getMenuSpec()
local built = 0
for _ in pairs(menu.rows) do built = built + 1 end
check(("one row per spec entry (%d)"):format(#spec), built == #spec,
      ("built %d"):format(built))

for _, entry in ipairs(spec) do
    if menu.rows[entry.name] == nil then
        check("row for " .. entry.name, false)
    end
end
check("every spec entry has a row", built == #spec)

-- Rows land in the layout: 2 originals + 1 header + one per setting.
check("layout grew by header plus rows",
      #layout.elements == 2 + 1 + #spec,
      ("layout has %d children"):format(#layout.elements))
check("layout was invalidated so it re-flows", layout.layoutInvalidated == true)

-- ---------------------------------------------------------------------------
group("3  cloned rows are cut loose from the base-game handler")

local enabledRow = menu.rows.enabled
check("option element found", enabledRow ~= nil and enabledRow.option ~= nil)
check("target no longer points at the settings frame",
      enabledRow.option.target == menu)

baseGameCalls = 0
enabledRow.option:setState(1, true)
check("changing our row does not call the base-game handler",
      baseGameCalls == 0, ("called %d times"):format(baseGameCalls))

-- ---------------------------------------------------------------------------
group("4  labels, values and descriptions")

i18nTexts["msw_setting_enabled"] = "Enable Market Shockwaves"
i18nTexts["msw_tooltip_enabled"] = "Turns market events on or off."
i18nTexts["msw_settings_section"] = "MARKET SHOCKWAVES"

-- Rebuild so the l10n above is picked up.
page, layout = buildFakePage()
g_gui.guis.InGameMenu.target.pageSettings = page
menu = MSWSettingsMenu.new(settings, log, function(name)
    changedNames[#changedNames + 1] = name
end)
menu:install()
page.onFrameOpen(page)

local row = menu.rows.enabled

-- The TITLE is the sibling Text, by profile. This is the assertion that the old
-- fixture could not make, and the bug it therefore could not catch.
local titleText
for _, child in ipairs(row.option.parent.elements) do
    if child.profile == "fs25_settingsMultiTextOptionTitle" then
        titleText = child.text
    end
end
check("the row label goes to the TITLE element",
      titleText == "Enable Market Shockwaves", tostring(titleText))

-- The DESCRIPTION is the Text inside the option.
local descText
for _, child in ipairs(row.option.elements) do
    if child.profile == "fs25_multiTextOptionTooltip" then descText = child.text end
end
check("the description goes to the panel element inside the option",
      descText == "Turns market events on or off.", tostring(descText))

-- The exact defect that shipped: the label written into the description panel,
-- leaving every row titled "Autosave Interval".
check("the label is NOT written into the description panel",
      descText ~= "Enable Market Shockwaves", tostring(descText))
check("the description is NOT written into the title",
      titleText ~= "Turns market events on or off.", tostring(titleText))
check("no row keeps the template's own label",
      titleText ~= "Autosave Interval", tostring(titleText))

local header
for _, child in ipairs(layout.elements) do
    if child.name == "sectionHeader" and child.text == "MARKET SHOCKWAVES" then
        header = child
    end
end
check("a MARKET SHOCKWAVES section header was added", header ~= nil)

check("a boolean row offers exactly two choices",
      #row.option.texts == 2, ("%d"):format(#row.option.texts))

local depth = menu.rows.supplyChainDepth
check("supply chain depth offers four labelled choices",
      #depth.option.texts == 4, ("%d"):format(#depth.option.texts))

local intensity = menu.rows.intensity
check("intensity choices are rendered as percentages",
      intensity.option.texts[5] == "100%", tostring(intensity.option.texts[5]))

-- ---------------------------------------------------------------------------
group("5  a change writes through to the adapter")

-- Off is index 1, On is index 2.
row.option:setState(1, true)
check("selecting Off writes 0", settings:get("enabled") == 0,
      tostring(settings:get("enabled")))
row.option:setState(2, true)
check("selecting On writes 1", settings:get("enabled") == 1,
      tostring(settings:get("enabled")))
check("the change callback fired", #changedNames > 0)

depth.option:setState(1, true)
check("depth Off maps to 0 (raw products only)",
      settings:get("supplyChainDepth") == 0,
      tostring(settings:get("supplyChainDepth")))
depth.option:setState(4, true)
check("depth full maps to 3", settings:get("supplyChainDepth") == 3)

local perYear = menu.rows.eventsPerYear
perYear.option:setState(12, true)
check("the last events-per-year step writes 10",
      settings:get("eventsPerYear") == 10, tostring(settings:get("eventsPerYear")))

-- ---------------------------------------------------------------------------
group("6  refresh reflects values changed elsewhere")

settings:set("eventsPerYear", 1.7)
settings:set("enabled", 0)
settings:set("supplyChainDepth", 2)
menu:refresh()
check("events per year snaps to its 1.7 step", perYear.option.state == 5,
      ("state %d"):format(perYear.option.state))
check("enabled shows Off", row.option.state == 1, ("state %d"):format(row.option.state))
check("depth shows 'most processed'", depth.option.state == 3,
      ("state %d"):format(depth.option.state))

-- A value with no exact step still picks the nearest one rather than failing.
settings:set("eventsPerYear", 2.4)
menu:refresh()
check("an off-step value picks the nearest step (2.5)",
      perYear.option.state == 7, ("state %d"):format(perYear.option.state))

-- refresh must not write back through the callback
local before = #changedNames
menu:refresh()
check("refresh does not fire change callbacks", #changedNames == before)

-- ---------------------------------------------------------------------------
group("7  focus ids are made unique so controller navigation survives")

local seen, duplicates = {}, 0
local function scan(e)
    if e.focusId ~= nil then
        if seen[e.focusId] then duplicates = duplicates + 1 end
        seen[e.focusId] = true
    end
    for _, c in ipairs(e.elements or {}) do scan(c) end
end
for _, child in ipairs(layout.elements) do scan(child) end
check("no duplicate focus ids among our rows", duplicates == 0,
      ("%d duplicates"):format(duplicates))

-- ---------------------------------------------------------------------------
group("8  a malformed page degrades to console-only, never an error")

local brokenPage = { onFrameOpen = function() return "opened" end }
g_gui.guis.InGameMenu.target.pageSettings = brokenPage
local m2 = MSWSettingsMenu.new(settings, log, nil)
check("install still succeeds with no layout", m2:install())
local ok, err = pcall(function() return brokenPage.onFrameOpen(brokenPage) end)
check("opening a page with no gameSettingsLayout does not raise", ok, tostring(err))
check("no rows were invented", next(m2.rows) == nil)

g_gui.guis.InGameMenu.target.pageSettings = nil
local m3 = MSWSettingsMenu.new(settings, log, nil)
check("install reports failure when there is no settings page", m3:install() == false)

-- ---------------------------------------------------------------------------
group("9  the same rows on the mod's own hub page")

-- The hub layout holds one header and one template row, nothing else.
local hubPage, hubLayout = buildFakePage()
local hubTemplateRow, hubTemplateHeader = hubLayout.elements[1], hubLayout.elements[2]
-- The hub's template row carries the hub's own profile, not the base game's.
hubTemplateRow.profile = "msw_hubSettingsRow"
local hubSettings = MSWSettingsAdapter.new(log)
local hubChanged = {}
local hubMenu = MSWSettingsMenu.new(hubSettings, log, function(name)
    hubChanged[#hubChanged + 1] = name
end)
local hubSpec = MSWSettingsAdapter.getMenuSpec()
local callsBefore = baseGameCalls

check("buildInto succeeds on a layout with a template row", hubMenu:buildInto(hubLayout) == true)
local hubBuilt = 0
for _ in pairs(hubMenu.rows) do hubBuilt = hubBuilt + 1 end
check(("one row per setting (%d)"):format(#hubSpec), hubBuilt == #hubSpec)
check("no section header is added: only the two templates plus the rows",
      #hubLayout.elements == 2 + #hubSpec, tostring(#hubLayout.elements))
check("the templates are hidden", hubTemplateRow.visible == false and hubTemplateHeader.visible == false)
check("the layout is re-flowed", hubLayout.layoutInvalidated == true)
check("the consumer category has a row", hubMenu.rows.catConsumer ~= nil)

-- Rows are the layout's children after the two templates, in spec order.
local banded, plain = 0, 0
for i = 3, #hubLayout.elements do
    local rowProfile = hubLayout.elements[i].profile
    local expectAlt = (i - 2) % 2 == 0
    if rowProfile == "msw_hubSettingsRowAlt" and expectAlt then banded = banded + 1 end
    if rowProfile == "msw_hubSettingsRow" and not expectAlt then plain = plain + 1 end
end
check("the hub's own row profile is recognised as a template", hubBuilt == #hubSpec)
check("every second row is banded, the others are not",
      banded == math.floor(#hubSpec / 2) and plain == #hubSpec - banded,
      ("%d banded, %d plain"):format(banded, plain))

local hubRow = hubMenu.rows.eventsPerYear
hubRow.option:setState(7, true)      -- the 2.5 step
check("changing a hub row changes the setting", hubSettings:get("eventsPerYear") == 2.5,
      tostring(hubSettings:get("eventsPerYear")))
check("and reports the change", hubChanged[#hubChanged] == "eventsPerYear")
check("and never reaches the template's base-game handler", baseGameCalls == callsBefore)

hubSettings:set("eventsPerYear", 2)
hubMenu:refresh()
check("refresh shows the default rate on its step", hubRow.option.state == 6,
      tostring(hubRow.option.state))

local noLayout = MSWSettingsMenu.new(hubSettings, log, nil)
local okHub, errHub = pcall(function() return noLayout:buildInto(nil) end)
check("a missing hub layout is reported, not raised", okHub and errHub == false, tostring(errHub))

-- ---------------------------------------------------------------------------
print(("\n===== %d passed, %d failed =====\n"):format(passed, failed))
os.exit(failed == 0 and 0 or 1)
