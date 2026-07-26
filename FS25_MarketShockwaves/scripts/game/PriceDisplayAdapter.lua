--[[
    PriceDisplayAdapter — marks affected commodities in the prices screen.

    APPROACH: the prices list renders each commodity's name from its fill type's
    `title`, so appending a marker there surfaces the modifier without touching
    the game's GUI code at all. Recolouring the arrows or adding a column would
    mean hooking the prices frame itself, which is far more version-fragile - see
    MSWDiag.dumpPriceGui, whose output is what we need before attempting that.

    Titles are restored the moment a product returns to baseline, and every
    original is kept so unloading leaves nothing behind.

    Caveat, deliberately accepted: `title` is also used by the shop and the HUD
    fill-level readout, so the marker appears there too. That is arguably useful
    (it flags an affected product wherever you see it) but it is why the whole
    feature sits behind a setting that can be switched off.
]]

PriceDisplayAdapter = {}
local PriceDisplayAdapter_mt = Class(PriceDisplayAdapter)

--- Only bother marking once a move is big enough to notice.
local MIN_ABS_CHANGE = 0.01   -- 1%

function PriceDisplayAdapter.new(priceModel, economy, logger)
    local self = setmetatable({}, PriceDisplayAdapter_mt)
    self.priceModel = priceModel
    self.economy = economy
    self.log = logger
    self.originalTitles = {}   -- fillTypeIndex -> original title string
    self.marked = {}           -- fillTypeIndex -> last marker applied
    self.enabled = true
    return self
end

function PriceDisplayAdapter:setEnabled(enabled)
    enabled = enabled and true or false
    if self.enabled == enabled then return end
    self.enabled = enabled
    if not enabled then self:restoreAll() end
end

local function fillTypeByIndex(idx)
    if g_fillTypeManager == nil then return nil end
    local ok, ft = pcall(function()
        return g_fillTypeManager:getFillTypeByIndex(idx)
    end)
    if ok and type(ft) == "table" then return ft end
    return nil
end

--- The suffix shown after a commodity name, e.g. "  [+13%]".
function PriceDisplayAdapter:formatMarker(modifier)
    local pct = (modifier - 1) * 100
    -- ASCII only: the menu font's unicode coverage is not guaranteed.
    return ("  [%+.0f%%]"):format(pct)
end

--- Apply or clear markers to match today's modifiers. Cheap and idempotent, so
--- it is safe to call whenever the modifier table is rebuilt.
function PriceDisplayAdapter:refresh()
    if not self.enabled or g_fillTypeManager == nil then return end

    local mods = self.priceModel.modifiers or {}

    -- 1) mark or update everything currently affected
    for idx, modifier in pairs(mods) do
        if math.abs(modifier - 1.0) >= MIN_ABS_CHANGE then
            local ft = fillTypeByIndex(idx)
            if ft ~= nil and type(ft.title) == "string" then
                if self.originalTitles[idx] == nil then
                    self.originalTitles[idx] = ft.title
                end
                local marker = self:formatMarker(modifier)
                if self.marked[idx] ~= marker then
                    ft.title = self.originalTitles[idx] .. marker
                    self.marked[idx] = marker
                end
            end
        end
    end

    -- 2) clear anything that is no longer affected
    for idx in pairs(self.marked) do
        local m = mods[idx]
        if m == nil or math.abs(m - 1.0) < MIN_ABS_CHANGE then
            self:restore(idx)
        end
    end
end

function PriceDisplayAdapter:restore(idx)
    local original = self.originalTitles[idx]
    if original == nil then return end
    local ft = fillTypeByIndex(idx)
    if ft ~= nil then ft.title = original end
    self.marked[idx] = nil
end

function PriceDisplayAdapter:restoreAll()
    for idx in pairs(self.originalTitles) do
        local ft = fillTypeByIndex(idx)
        if ft ~= nil then ft.title = self.originalTitles[idx] end
    end
    self.marked = {}
    self.log:debug("PriceDisplayAdapter: all titles restored")
end

--- Human-readable summary for the console.
function PriceDisplayAdapter:describe()
    local lines = {}
    for idx, marker in pairs(self.marked) do
        local ft = fillTypeByIndex(idx)
        lines[#lines + 1] = ("  %s%s")
            :format(ft and (self.originalTitles[idx] or ft.title) or ("index " .. idx),
                    marker)
    end
    table.sort(lines)
    return lines
end
