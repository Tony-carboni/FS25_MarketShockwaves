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

    self:installPurchaseHooks()
    self.installed = true
end

-- ---------------------------------------------------------------------------
-- What the player PAYS
-- ---------------------------------------------------------------------------
--
-- The hooks above move what a selling point pays. Farm inputs are mostly not
-- sold, they are bought, and the game charges for them by three routes, each
-- seen in the game's own scripts:
--
--   * a fill trigger (the fuel pump, a filling point) charges
--     economyManager:getPricePerLiter(fillType) - already hooked above;
--   * a helper who refills a seeder, sprayer or fuel tank on the go charges
--     economyManager:getCostPerLiter(fillType);
--   * the shop charges economyManager:getBuyPrice(storeItem, ...) for a big
--     bag, pallet or tank.
--
-- The last one is by ITEM, not by fill type, so the item has to be matched to
-- what it holds: a shop item in one of the consumable categories whose fill
-- unit holds exactly one fill type. A bag of fertiliser costs more during an
-- input shock; a fertiliser spreader does not.

--- Shop categories that are a quantity of goods, not a machine.
EconomyAdapter.CONSUMABLE_CATEGORIES = {
    BIGBAGS = true, BIGBAGPALLETS = true, IBC = true, PALLETS = true,
}

local function isConsumable(storeItem)
    for _, name in ipairs(storeItem.categoryNames or {}) do
        if EconomyAdapter.CONSUMABLE_CATEGORIES[tostring(name):upper()] then return true end
    end
    return false
end

--- The one fill type a shop item holds, or nil when it is not a single-product
--- consumable. `fillTypeNames` is the list the game builds for the shop's own
--- fill-type icons.
function EconomyAdapter:getStoreItemFillType(storeItem)
    if type(storeItem) ~= "table" then return nil end
    self.storeItemFillTypes = self.storeItemFillTypes or setmetatable({}, { __mode = "k" })
    local cached = self.storeItemFillTypes[storeItem]
    if cached ~= nil then return cached ~= false and cached or nil end

    local index = nil
    pcall(function()
        if not isConsumable(storeItem) then return end
        if storeItem.specs == nil and StoreItemUtil ~= nil
           and StoreItemUtil.loadSpecsFromXML ~= nil then
            StoreItemUtil.loadSpecsFromXML(storeItem)
        end
        local spec = storeItem.specs ~= nil and storeItem.specs.fillTypes or nil
        if type(spec) ~= "table" or type(spec.fillTypeNames) ~= "string" then return end
        local only, count = nil, 0
        local seen = {}
        for name in spec.fillTypeNames:gmatch("%S+") do
            local upper = name:upper()
            if not seen[upper] then
                seen[upper] = true
                only = upper
                count = count + 1
            end
        end
        if count == 1 then index = self:getFillTypeIndex(only) end
    end)

    self.storeItemFillTypes[storeItem] = index or false
    return index
end

--- Multiplier for a shop item's price today: 1.0 for anything but a
--- single-product consumable whose product an event is moving.
function EconomyAdapter:getStoreItemModifier(storeItem)
    if not self.enabled then return 1.0 end
    local index = self:getStoreItemFillType(storeItem)
    if index == nil then return 1.0 end
    return self:getModifier(index)
end

local unpackValues = table.unpack or unpack
local function packValues(...) return { ... }, select("#", ...) end

--- Hook the two purchase routes that are not covered by getPricePerLiter.
--- Installed once: verifyHooks() may call install() again, and wrapping these
--- twice would apply the modifier twice.
function EconomyAdapter:installPurchaseHooks()
    if self.purchaseHooksInstalled then return end
    self.purchaseHooksInstalled = true
    local adapter = self

    if EconomyManager ~= nil and EconomyManager.getCostPerLiter ~= nil then
        EconomyManager.getCostPerLiter = Utils.overwrittenFunction(
            EconomyManager.getCostPerLiter,
            function(manager, superFunc, fillTypeIndex, ...)
                local base = superFunc(manager, fillTypeIndex, ...)
                if type(base) ~= "number" then return base end
                return base * adapter:getModifier(fillTypeIndex)
            end
        )
        self.log:info("EconomyAdapter: hooked EconomyManager.getCostPerLiter (helper refills)")
    else
        self.log:warn("EconomyAdapter: EconomyManager.getCostPerLiter not found "
                   .. "(helper refills will not reflect events)")
    end

    if EconomyManager ~= nil and EconomyManager.getBuyPrice ~= nil then
        EconomyManager.getBuyPrice = Utils.overwrittenFunction(
            EconomyManager.getBuyPrice,
            function(manager, superFunc, storeItem, configurations, saleItem, ...)
                -- Every return value is passed on as it came, nils included.
                local results, count = packValues(
                    superFunc(manager, storeItem, configurations, saleItem, ...))
                -- New goods only: a used-market item has its own price.
                if type(results[1]) == "number" and saleItem == nil then
                    local modifier = adapter:getStoreItemModifier(storeItem)
                    if modifier ~= 1.0 then
                        results[1] = math.floor(results[1] * modifier + 0.5)
                    end
                end
                return unpackValues(results, 1, count)
            end
        )
        self.log:info("EconomyAdapter: hooked EconomyManager.getBuyPrice "
                   .. "(big bags, pallets and tanks in the shop)")
    else
        self.log:warn("EconomyAdapter: EconomyManager.getBuyPrice not found "
                   .. "(shop prices of inputs will not reflect events)")
    end
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
