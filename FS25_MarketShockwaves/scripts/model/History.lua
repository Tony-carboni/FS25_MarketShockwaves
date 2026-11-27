--[[
    History — every message the mod has shown, so it can be read again.

    The hub's History tab lists these newest first. An entry stores the KEYS of
    the text, never the text itself, so a savegame opened in another language
    shows the history in that language.

    Kinds:
      event     the news item of a random event
      forecast  a forecast's opening message
      verdict   what became of a forecast
      info      the welcome message and the one-time explanation of speculation

    NO SPOILERS. An entry holds what the player was told and nothing more. A
    forecast's entry gains its outcome only when the verdict has happened.

    Pure logic; the game layer adds entries and saves the list.
]]

MSWHistory = {}
local MSWHistory_mt = Class(MSWHistory)

MSWHistory.MAX_ENTRIES = 200

local STRING_FIELDS = { "kind", "titleKey", "textKey", "argKey", "ref", "status",
                        "eventId" }
local NUMBER_FIELDS = { "day", "month", "year", "eventStartDay" }

--- Turn a text key into text.
---
--- A long message is stored one paragraph per key (`key_p1`, `key_p2`, ...),
--- so nothing depends on how line breaks survive in an XML attribute; those
--- are joined with blank lines. `argKey` names a second text put in place of
--- the `%s` in the first (the "how sure are the experts" line of a forecast).
---
--- @param i18n table anything with hasText(key) and getText(key)
--- @return string the text, or the key itself when there is none
function MSWHistory.resolveText(i18n, key, argKey)
    if key == nil then return "" end
    if i18n == nil then return key end

    local text
    if i18n:hasText(key) then
        text = i18n:getText(key)
    else
        local paragraphs = {}
        for n = 1, 20 do
            local pkey = ("%s_p%d"):format(key, n)
            if not i18n:hasText(pkey) then break end
            paragraphs[#paragraphs + 1] = i18n:getText(pkey)
        end
        if #paragraphs == 0 then return key end
        text = table.concat(paragraphs, "\n\n")
    end

    if argKey ~= nil then
        local arg = i18n:hasText(argKey) and i18n:getText(argKey) or ""
        -- A function replacement, so a "%" in the inserted text is left alone.
        text = text:gsub("%%s", function() return arg end)
    end
    return text
end

function MSWHistory.new(maxEntries)
    local self = setmetatable({}, MSWHistory_mt)
    self.maxEntries = maxEntries or MSWHistory.MAX_ENTRIES
    self.entries = {}       -- oldest first
    return self
end

--- @param entry table { kind, day, month, year, titleKey, textKey,
---        argKey         key of a text substituted into the body (%s)
---        ref            links a forecast to its verdict
---        status         forecast: "open", later the outcome
---        eventId, eventStartDay   the running event behind an entry }
function MSWHistory:add(entry)
    self.entries[#self.entries + 1] = entry
    while #self.entries > self.maxEntries do
        table.remove(self.entries, 1)
    end
    return entry
end

--- Set the status of the newest entry of `kind` with this ref.
function MSWHistory:setStatus(kind, ref, status)
    for i = #self.entries, 1, -1 do
        local entry = self.entries[i]
        if entry.kind == kind and entry.ref == ref then
            entry.status = status
            return entry
        end
    end
    return nil
end

--- Newest first, for display.
function MSWHistory:getNewestFirst()
    local out = {}
    for i = #self.entries, 1, -1 do out[#out + 1] = self.entries[i] end
    return out
end

function MSWHistory:count()
    return #self.entries
end

function MSWHistory:clear()
    self.entries = {}
end

function MSWHistory:saveToXML(xmlFile, key)
    for i, entry in ipairs(self.entries) do
        local ekey = ("%s.entry(%d)"):format(key, i - 1)
        for _, f in ipairs(STRING_FIELDS) do
            if type(entry[f]) == "string" then setXMLString(xmlFile, ekey .. "#" .. f, entry[f]) end
        end
        for _, f in ipairs(NUMBER_FIELDS) do
            if type(entry[f]) == "number" then setXMLFloat(xmlFile, ekey .. "#" .. f, entry[f]) end
        end
    end
end

function MSWHistory:loadFromXML(xmlFile, key)
    self.entries = {}
    local i = 0
    while true do
        local ekey = ("%s.entry(%d)"):format(key, i)
        if not hasXMLProperty(xmlFile, ekey) then break end
        local entry = {}
        for _, f in ipairs(STRING_FIELDS) do entry[f] = getXMLString(xmlFile, ekey .. "#" .. f) end
        for _, f in ipairs(NUMBER_FIELDS) do entry[f] = getXMLFloat(xmlFile, ekey .. "#" .. f) end
        if entry.kind ~= nil and entry.titleKey ~= nil then
            self.entries[#self.entries + 1] = entry
        end
        i = i + 1
    end
end
