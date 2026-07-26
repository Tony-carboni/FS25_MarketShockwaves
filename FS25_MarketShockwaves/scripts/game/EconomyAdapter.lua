--[[
    EconomyAdapter — applies event price modifiers to what the game charges/pays.

    APPROACH: hook the price *getter*, never mutate stored data.

    We wrap SellingStation.getEffectiveFillTypePrice() and multiply its return
    value by the modifier the PriceModel computes for that fill type today. So:

      * stored fill-type/economy data is never touched -> no savegame damage,
        and uninstalling the mod restores vanilla prices instantly;
      * the base game's own monthly price curve still applies, and our event
        modifier composes on top of it (exactly the design's `factor` model);
      * prices the player sees at a sell point and the money they actually
        receive both come through this path, so display and payout can't drift
        apart.

    EconomyManager.getPricePerLiter() is also hooked so any UI that reads the
    pre-station base price shows the same movement.

    All FS25 API touchpoints for pricing live in this file.
]]

EconomyAdapter = {}
local EconomyAdapter_mt = Class(EconomyAdapter)

--- @param priceModel table  must expose :getModifier(fillTypeIndex) -> number
function EconomyAdapter.new(priceModel, logger)
    local self = setmetatable({}, EconomyAdapter_mt)
    self.priceModel = priceModel
    self.log = logger
    self.installed = false
    self.enabled = true
    return self
end

--- Resolve a fill type name (e.g. "WHEAT") to its runtime index.
--- Names come from config; indices are what the engine speaks.
function EconomyAdapter:getFillTypeIndex(name)
    if g_fillTypeManager == nil then return nil end
    -- Preferred API; fall back to a name lookup if the signature differs.
    if g_fillTypeManager.getFillTypeIndexByName ~= nil then
        local ok, idx = pcall(function()
            return g_fillTypeManager:getFillTypeIndexByName(name)
        end)
        if ok and type(idx) == "number" then return idx end
    end
    if g_fillTypeManager.getFillTypeByName ~= nil then
        local ok, ft = pcall(function()
            return g_fillTypeManager:getFillTypeByName(name)
        end)
        if ok and type(ft) == "table" and ft.index ~= nil then return ft.index end
    end
    self.log:warn(("EconomyAdapter: could not resolve fill type '%s'"):format(tostring(name)))
    return nil
end

--- Multiplier for a fill type today: 1.0 means untouched.
function EconomyAdapter:getModifier(fillTypeIndex)
    if not self.enabled or self.priceModel == nil or fillTypeIndex == nil then
        return 1.0
    end
    local ok, m = pcall(function()
        return self.priceModel:getModifier(fillTypeIndex)
    end)
    if not ok or type(m) ~= "number" or m ~= m then  -- m ~= m catches NaN
        return 1.0
    end
    -- Clamp defensively: never zero/negative, never absurd.
    if m < 0.1 then m = 0.1 end
    if m > 5.0 then m = 5.0 end
    return m
end

--- Install the hooks. Idempotent.
function EconomyAdapter:install()
    if self.installed then return end

    local adapter = self

    if SellingStation ~= nil and SellingStation.getEffectiveFillTypePrice ~= nil then
        SellingStation.getEffectiveFillTypePrice = Utils.overwrittenFunction(
            SellingStation.getEffectiveFillTypePrice,
            function(station, superFunc, fillTypeIndex, ...)
                local base = superFunc(station, fillTypeIndex, ...)
                if type(base) ~= "number" then return base end
                return base * adapter:getModifier(fillTypeIndex)
            end
        )
        -- Keep a reference so verifyHooks() can tell if another mod replaced us.
        self.stationHook = SellingStation.getEffectiveFillTypePrice
        self.log:info("EconomyAdapter: hooked SellingStation.getEffectiveFillTypePrice")
    else
        self.log:error("EconomyAdapter: SellingStation.getEffectiveFillTypePrice not found — "
                    .. "prices will NOT be modified. Report this with your game version.")
    end

    if EconomyManager ~= nil and EconomyManager.getPricePerLiter ~= nil then
        EconomyManager.getPricePerLiter = Utils.overwrittenFunction(
            EconomyManager.getPricePerLiter,
            function(manager, superFunc, fillTypeIndex, ...)
                local base = superFunc(manager, fillTypeIndex, ...)
                if type(base) ~= "number" then return base end
                return base * adapter:getModifier(fillTypeIndex)
            end
        )
        self.economyHook = EconomyManager.getPricePerLiter
        self.log:info("EconomyAdapter: hooked EconomyManager.getPricePerLiter")
    else
        self.log:warn("EconomyAdapter: EconomyManager.getPricePerLiter not found "
                   .. "(price displays may not reflect events)")
    end

    self.installed = true
end

--- Check our hooks are still in place, and reinstall if not.
---
--- MOD COMPATIBILITY. We wrap with Utils.overwrittenFunction and MULTIPLY the
--- original result, which composes safely with almost everything:
---
---   * mods that ship their own fillTypes.xml (base prices / monthly factors)
---     just change the baseline we multiply - fully compatible;
---   * mods that also *wrap* the same getter chain with us, and since both
---     multiply, load order does not matter;
---   * mods that mutate stored economy data are fine too, as we never touch it.
---
--- The one dangerous case is a mod that REPLACES the function outright
--- (plain assignment instead of a wrapper) after we install. That silently
--- discards our hook, and a silent failure is the worst kind - prices simply
--- stop moving with no error. So we compare the live function against the
--- wrapper we installed and shout if it changed.
---
--- @return boolean true if hooks are intact (or were successfully reinstalled)
function EconomyAdapter:verifyHooks()
    local intact = true

    if self.stationHook ~= nil and SellingStation ~= nil
       and SellingStation.getEffectiveFillTypePrice ~= self.stationHook then
        self.log:warn("EconomyAdapter: another mod replaced "
            .. "SellingStation.getEffectiveFillTypePrice after us. Reinstalling our "
            .. "hook on top. If prices still do not move, that mod overrides prices "
            .. "absolutely and is incompatible.")
        intact = false
    end

    if self.economyHook ~= nil and EconomyManager ~= nil
       and EconomyManager.getPricePerLiter ~= self.economyHook then
        self.log:warn("EconomyAdapter: another mod replaced "
            .. "EconomyManager.getPricePerLiter after us. Reinstalling.")
        intact = false
    end

    if not intact then
        self.installed = false
        self:install()
    end
    return intact
end

--- Log other loaded mods that look price/economy related, so a compatibility
--- report from a user names the likely culprit without guesswork.
function EconomyAdapter:logPriceModNeighbours(selfModName)
    if g_modManager == nil or g_modManager.getActiveMods == nil then return end
    local ok, mods = pcall(function() return g_modManager:getActiveMods() end)
    if not ok or type(mods) ~= "table" then return end

    local KEYWORDS = { "price", "econom", "market", "seasonal", "sell", "filltype" }
    local hits = {}
    for _, mod in pairs(mods) do
        local name = (type(mod) == "table" and (mod.modName or mod.title)) or tostring(mod)
        if name ~= selfModName then
            local lower = tostring(name):lower()
            for _, kw in ipairs(KEYWORDS) do
                if lower:find(kw, 1, true) then
                    hits[#hits + 1] = tostring(name)
                    break
                end
            end
        end
    end
    if #hits > 0 then
        self.log:info("EconomyAdapter: other price/economy mods present: "
            .. table.concat(hits, ", ")
            .. " (compatible as long as they change base prices rather than "
            .. "overriding the price getter outright)")
    end
end

--- Temporarily disable modification without removing hooks (used when the
--- player sets "events per year" to 0, and for the mswClear console command).
function EconomyAdapter:setEnabled(enabled)
    self.enabled = enabled and true or false
end
