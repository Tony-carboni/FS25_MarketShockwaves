--[[
    Diagnostics — verbose logging for test builds.

    Deliberately kept in ONE file so it can be removed cleanly once testing is
    done: delete this file, its <sourceFile> line in modDesc.xml, and the
    MSWDiag.* call sites (all of which are guarded by `if MSWDiag ~= nil then`).

    Everything here only READS state and writes to the log. It must never change
    behaviour, so every probe is pcall-guarded and failures are reported rather
    than raised.

    Volume is high, but never per-frame: dumps happen at startup, on a new day,
    and when an event starts or ends. Because that is far too much for normal
    play, MSWDiag.enabled defaults to FALSE - mswDump turns it on for the length
    of one call, and mswDebug toggles it for a session.
]]

MSWDiag = {}

-- OFF by default: integration is verified, and the automatic dumps produced
-- thousands of log lines per session. mswDump still works at any time (it
-- enables this for the duration of the call), and mswDebug toggles it back on
-- for a session when something needs watching.
MSWDiag.enabled = false

local function line(log, s) log:info(s) end

function MSWDiag.section(log, title)
    if not MSWDiag.enabled then return end
    line(log, "")
    line(log, "================ " .. title .. " ================")
end

--- Sorted "k=v" dump of a table's scalar fields. Depth 1 only.
local function scalarFields(t, limit)
    local out = {}
    if type(t) ~= "table" then return out end
    local ok = pcall(function()
        for k, v in pairs(t) do
            local tv = type(v)
            if tv == "number" or tv == "boolean" or tv == "string" then
                local sv = tostring(v)
                -- Truncate rather than skip: a 40-char cut previously hid
                -- savegameDirectory, which is exactly the kind of long string
                -- worth seeing.
                if #sv > 120 then sv = sv:sub(1, 117) .. "..." end
                out[#out + 1] = ("%s=%s"):format(tostring(k), sv)
            end
        end
    end)
    if not ok then return { "<error reading table>" } end
    table.sort(out)
    if limit and #out > limit then
        local trimmed = {}
        for i = 1, limit do trimmed[i] = out[i] end
        trimmed[#trimmed + 1] = ("... (%d more)"):format(#out - limit)
        return trimmed
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Environment / calendar
-- ---------------------------------------------------------------------------

--- Dump everything that might carry the date, so the real field names are
--- recoverable from a single log even if every candidate accessor missed.
function MSWDiag.dumpEnvironment(log)
    if not MSWDiag.enabled then return end
    MSWDiag.section(log, "ENVIRONMENT DUMP")

    if g_currentMission == nil then
        line(log, "g_currentMission is nil")
        return
    end

    local env = g_currentMission.environment
    if env == nil then
        line(log, "g_currentMission.environment is nil")
    else
        line(log, "environment scalar fields:")
        for _, s in ipairs(scalarFields(env, 80)) do line(log, "   " .. s) end

        -- Nested tables that plausibly hold the calendar in newer builds.
        for _, sub in ipairs({ "weather", "daylight", "calendar", "timeInfo" }) do
            if type(env[sub]) == "table" then
                line(log, ("environment.%s scalar fields:"):format(sub))
                for _, s in ipairs(scalarFields(env[sub], 30)) do line(log, "   " .. s) end
            end
        end

        -- Method names, which is how newer APIs tend to expose this.
        local methods = {}
        pcall(function()
            for k, v in pairs(env) do
                if type(v) == "function" then methods[#methods + 1] = tostring(k) end
            end
        end)
        table.sort(methods)
        line(log, "environment methods: " .. table.concat(methods, ", "))
    end

    local mi = g_currentMission.missionInfo
    if type(mi) == "table" then
        line(log, "missionInfo scalar fields:")
        for _, s in ipairs(scalarFields(mi, 60)) do line(log, "   " .. s) end
    end
end

--- What the adapter actually returns, alongside the raw values it read.
function MSWDiag.dumpCalendar(log, calendar)
    if not MSWDiag.enabled then return end
    line(log, ("calendar reads: day=%s month=%s daysPerMonth=%s")
        :format(tostring(calendar:getDay()), tostring(calendar:getMonth()),
                tostring(calendar:getDaysPerMonth())))
    line(log, ("calendar accessors: period=%s daysPerPeriod=%s day=%s")
        :format(calendar.periodAccessor and calendar.periodAccessor.name or "NONE",
                calendar.daysPerPeriodAccessor and calendar.daysPerPeriodAccessor.name or "NONE",
                calendar.dayAccessor and calendar.dayAccessor.name or "NONE"))
end

-- ---------------------------------------------------------------------------
-- Config
-- ---------------------------------------------------------------------------

function MSWDiag.dumpConfig(log, config)
    if not MSWDiag.enabled then return end
    MSWDiag.section(log, "CONFIG DUMP")
    line(log, ("eventsPerYear=%.2f  severity low/med/high=%.2f/%.2f/%.2f  events=%d")
        :format(config.eventsPerYear, config.severityChances.low,
                config.severityChances.medium, config.severityChances.high,
                #config.events))

    local MONTHS = { "Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec" }
    for _, def in ipairs(config.events) do
        line(log, ("-- %s [%s] baseWeight=%.2f"):format(def.id, def.type, def.baseWeight))
        line(log, ("     affects (%d): %s"):format(#def.affects, table.concat(def.affects, " ")))
        if def.opposite ~= nil and #def.opposite > 0 then
            line(log, ("     opposite (%d, x%.2f): %s"):format(#def.opposite,
                def.oppositeScale or 0.5, table.concat(def.opposite, " ")))
        end

        local shares = {}
        for m = 1, 12 do
            if (def.monthShare[m] or 0) > 0 then
                shares[#shares + 1] = ("%s=%.0f%%"):format(MONTHS[m], def.monthShare[m] * 100)
            end
        end
        line(log, "     season: " .. table.concat(shares, " "))

        local nchains = 0
        for from, hops in pairs(def.chains) do
            for _, h in ipairs(hops) do
                nchains = nchains + 1
                line(log, ("     chain %s -> %s  tier=%d lag=%.2fmo pass=%.2f")
                    :format(from, h.to, h.tier, h.lagMonths, h.passThrough))
            end
        end
        if nchains == 0 then line(log, "     chains: none") end

        for _, cls in ipairs({ "low", "medium", "high" }) do
            local sv = def.severities[cls]
            if sv == nil then
                line(log, ("     severity %-6s MISSING"):format(cls))
            else
                line(log, ("     severity %-6s factor=%.3f..%.3f dur=%.1f..%.1fmo "
                        .. "peakPos=%.2f..%.2f rise=%.1f..%.1f hold=%.2f corr=%.1fmo "
                        .. "jitter=%.3f depth=%d scale=%.2f")
                    :format(cls, sv.priceFactorMin, sv.priceFactorMax,
                            sv.durationMonthsMin, sv.durationMonthsMax,
                            sv.peakPosMin, sv.peakPosMax, sv.riseExpMin, sv.riseExpMax,
                            sv.hold, sv.correctionMonths, sv.jitter,
                            sv.rippleDepth, sv.rippleScale))
            end
        end
    end
end

--- Resolve every product named anywhere in the config. Anything reported
--- MISSING is a name that does not exist on this install (typo, or a product
--- from a DLC/mod that is not loaded) and will silently never move.
function MSWDiag.dumpFillTypeResolution(log, economy, config)
    if not MSWDiag.enabled then return end
    MSWDiag.section(log, "FILL TYPE RESOLUTION")

    local seen, names = {}, {}
    local function note(n)
        if n ~= nil and not seen[n] then seen[n] = true; names[#names + 1] = n end
    end
    for _, def in ipairs(config.events) do
        for _, p in ipairs(def.affects) do note(p) end
        for _, hops in pairs(def.chains) do
            for _, h in ipairs(hops) do note(h.to) end
        end
    end
    table.sort(names)

    local okCount, missing = 0, {}
    for _, n in ipairs(names) do
        local idx = economy:getFillTypeIndex(n)
        if idx ~= nil then
            okCount = okCount + 1
            line(log, ("   %-24s index=%d"):format(n, idx))
        else
            missing[#missing + 1] = n
            line(log, ("   %-24s *** MISSING ***"):format(n))
        end
    end
    line(log, ("resolved %d/%d products"):format(okCount, #names))
    if #missing > 0 then
        log:warn("unresolved products (these will never move): "
            .. table.concat(missing, ", "))
    end
end

-- ---------------------------------------------------------------------------
-- Runtime
-- ---------------------------------------------------------------------------

--- Everything about one rolled instance, including its flattened reach map.
function MSWDiag.dumpEventInstance(log, ev)
    if not MSWDiag.enabled then return end
    line(log, ("   instance: peakFactor=%.4f durationMonths=%.2f durationDays=%d "
            .. "peakPos=%.3f riseExp=%.3f hold=%.2f correctionDays=%.1f jitter=%.3f seed=%d")
        :format(ev.peakFactor, ev.durationMonths, ev.durationDays, ev.peakPos,
                ev.riseExp, ev.hold, ev.correctionDays, ev.jitter, ev.seed))
    line(log, "   reach map (product: lagDays, passThrough):")
    for _, p in ipairs(ev:getProducts()) do
        local r = ev.reach[p]
        line(log, ("     %-24s lag=%6.2f  pass=%.3f"):format(p, r.lagDays, r.passThrough))
    end
end

--- Per-event trigger odds for today, and what the roll did.
function MSWDiag.dumpDailyRoll(log, scheduler, month, daysPerMonth, eventsPerYear,
                               blockedFn, firedList)
    if not MSWDiag.enabled then return end
    local firedIds = {}
    for _, f in ipairs(firedList or {}) do firedIds[f.def.id] = f.severity end

    line(log, ("daily roll: month=%d daysPerMonth=%d eventsPerYear=%.2f")
        :format(month, daysPerMonth, eventsPerYear))
    for _, def in ipairs(scheduler.config.events) do
        local blocked = blockedFn ~= nil and blockedFn(def.id) or false
        local p = scheduler:dailyProbability(def, month, daysPerMonth, eventsPerYear)
        local status = "-"
        if blocked then status = "BLOCKED (already active)"
        elseif firedIds[def.id] then status = "*** FIRED (" .. firedIds[def.id] .. ") ***"
        elseif p <= 0 then status = "out of season" end
        line(log, ("   %-26s p/day=%.5f  %s"):format(def.id, p, status))
    end
end

--- Active events plus the live modifier for every product they touch.
function MSWDiag.dumpState(log, priceModel, day)
    if not MSWDiag.enabled then return end
    local active = priceModel:getActiveEvents()
    line(log, ("state on day %d: %d active event(s)"):format(day, #active))
    for _, ev in ipairs(active) do
        local elapsed = ev:elapsed(day)
        line(log, ("   %s [%s] day %d/%d (%.0f%%)  peak=%.3f")
            :format(ev.eventId, ev.severity, elapsed, ev.durationDays,
                    100 * elapsed / math.max(ev.durationDays, 1), ev.peakFactor))
        for _, p in ipairs(ev:getProducts()) do
            local f = ev:getFactorFor(p, day)
            if math.abs(f - 1.0) > 0.0005 then
                line(log, ("      %-24s %+7.2f%%"):format(p, (f - 1) * 100))
            end
        end
    end

    -- Combined (stacked) modifiers actually being applied.
    local mods = priceModel.modifiers or {}
    local n = 0
    for _ in pairs(mods) do n = n + 1 end
    line(log, ("combined modifier table: %d fill type(s) affected"):format(n))
end

--- Base vs modified price for a handful of products, straight through the hook.
--- This is the end-to-end check: if these two columns are identical while events
--- are active, the hook is not reaching the price the player sees.
function MSWDiag.dumpPriceProbe(log, economy, products)
    if not MSWDiag.enabled then return end
    if g_currentMission == nil or g_fillTypeManager == nil then return end
    MSWDiag.section(log, "PRICE PROBE")

    for _, name in ipairs(products) do
        local idx = economy:getFillTypeIndex(name)
        if idx == nil then
            line(log, ("   %-22s unresolved"):format(name))
        else
            local mod = economy:getModifier(idx)
            local base
            pcall(function()
                local ft = g_fillTypeManager:getFillTypeByIndex(idx)
                base = ft and ft.pricePerLiter
            end)
            line(log, ("   %-22s basePricePerLiter=%s  modifier=%.4f  => %s")
                :format(name, tostring(base), mod,
                        base and string.format("%.4f", base * mod) or "?"))
        end
    end
end

--- Probe the prices GUI.
---
--- Recolouring the price-table arrows, or adding a column, means hooking the
--- frame that draws them. We do not know its class name or row structure on this
--- build, so rather than guess we enumerate every global that looks like a
--- prices/menu frame and dump its methods. The output of this is what makes a
--- proper GUI hook possible in the next round instead of guesswork.
function MSWDiag.dumpPriceGui(log)
    if not MSWDiag.enabled then return end
    MSWDiag.section(log, "PRICES GUI PROBE")

    -- 1) Whatever screen is open right now. Run this from mswDump WITH the
    --    prices menu open: at load time the frame does not exist yet, which is
    --    why an earlier probe found nothing.
    local screenName = "unknown"
    pcall(function()
        screenName = g_gui.currentGuiName
                     or (g_gui.currentGui and g_gui.currentGui.name) or "none"
    end)
    line(log, "current screen: " .. tostring(screenName))

    -- 2) The open GUI's element tree: the frame drawing the rows lives in here.
    pcall(function()
        local cur = g_gui and g_gui.currentGui
        local target = cur and cur.target
        if target == nil then
            line(log, "no current GUI target (menu closed?)")
            return
        end
        line(log, "current GUI target fields:")
        for _, f in ipairs(scalarFields(target, 40)) do line(log, "   " .. f) end

        local methods = {}
        for k, v in pairs(target) do
            if type(v) == "function" then methods[#methods + 1] = tostring(k) end
        end
        table.sort(methods)
        line(log, "current GUI target methods: " .. table.concat(methods, ", "))

        -- Sub-tables named like frames/pages, which is where the prices list sits.
        for k, v in pairs(target) do
            if type(v) == "table" then
                local kn = tostring(k):lower()
                if kn:find("frame") or kn:find("page") or kn:find("price") then
                    local subm = {}
                    for mk, mv in pairs(v) do
                        if type(mv) == "function" then subm[#subm + 1] = tostring(mk) end
                    end
                    table.sort(subm)
                    line(log, ("   target.%s methods: %s")
                        :format(tostring(k), table.concat(subm, ", ")))
                end
            end
        end
    end)

    -- 3) The in-game menu's registered pages, reachable even when closed.
    pcall(function()
        local menu = g_gui and g_gui.guis and g_gui.guis["InGameMenu"]
        local target = menu and menu.target
        if target == nil then
            line(log, "InGameMenu not registered / has no target")
            return
        end
        local names = {}
        for k, v in pairs(target) do
            if type(v) == "table" then
                local kn = tostring(k):lower()
                if kn:find("page") or kn:find("frame") or kn:find("price")
                   or kn:find("statistic") then
                    names[#names + 1] = tostring(k)
                end
            end
        end
        table.sort(names)
        line(log, ("InGameMenu page/frame members (%d): %s")
            :format(#names, table.concat(names, ", ")))

        -- Methods on anything that looks like the prices page.
        for _, n in ipairs(names) do
            if n:lower():find("price") then
                local sub, subm = target[n], {}
                for mk, mv in pairs(sub) do
                    if type(mv) == "function" then subm[#subm + 1] = tostring(mk) end
                end
                table.sort(subm)
                line(log, ("   %s methods: %s"):format(n, table.concat(subm, ", ")))
                line(log, ("   %s fields:"):format(n))
                for _, f in ipairs(scalarFields(sub, 30)) do line(log, "      " .. f) end
            end
        end
    end)

    -- 4) Any global class whose name ends in Frame, excluding our own.
    pcall(function()
        local frames = {}
        for k, v in pairs(getfenv(0)) do
            if type(k) == "string" and type(v) == "table"
               and k:sub(-5) == "Frame" and k:sub(1, 3) ~= "MSW" then
                frames[#frames + 1] = k
            end
        end
        table.sort(frames)
        line(log, ("global *Frame classes (%d): %s")
            :format(#frames, table.concat(frames, ", ")))

        for _, k in ipairs(frames) do
            if k:lower():find("price") or k:lower():find("statistic") then
                local m = {}
                for mk, mv in pairs(getfenv(0)[k]) do
                    if type(mv) == "function" then m[#m + 1] = tostring(mk) end
                end
                table.sort(m)
                line(log, ("   %s methods: %s"):format(k, table.concat(m, ", ")))
            end
        end
    end)

    -- 4b) WALK THE METATABLE CHAIN. The previous probe reported only 7 methods on
    --     the menu target, because pairs() sees instance fields only - every real
    --     method is inherited. The row-population and draw hooks we need live on
    --     the class, so the chain has to be walked explicitly. The global is
    --     called InGameMenu, which a search for names ending in "Frame" missed.
    pcall(function()
        local function collectMethods(t, depth, seen, out)
            if type(t) ~= "table" or depth > 6 or seen[t] then return end
            seen[t] = true
            for k, v in pairs(t) do
                if type(v) == "function" and type(k) == "string" then out[k] = true end
            end
            local mt = getmetatable(t)
            if type(mt) == "table" then
                collectMethods(mt, depth + 1, seen, out)
                collectMethods(mt.__index, depth + 1, seen, out)
            end
        end

        local function dumpAll(label, t)
            if type(t) ~= "table" then
                line(log, label .. ": not a table")
                return
            end
            local out = {}
            collectMethods(t, 0, {}, out)
            local names = {}
            for k in pairs(out) do names[#names + 1] = k end
            table.sort(names)
            line(log, ("%s: %d method(s)"):format(label, #names))

            -- Everything, so nothing relevant is filtered out by a guess.
            local buf = {}
            for _, n in ipairs(names) do
                buf[#buf + 1] = n
                if #buf == 12 then
                    line(log, "    " .. table.concat(buf, ", "))
                    buf = {}
                end
            end
            if #buf > 0 then line(log, "    " .. table.concat(buf, ", ")) end
        end

        dumpAll("InGameMenu class (global)", getfenv(0)["InGameMenu"])

        local menu = g_gui and g_gui.guis and g_gui.guis["InGameMenu"]
        if menu ~= nil then
            dumpAll("InGameMenu instance + inherited", menu.target)
        end

        -- The list element itself, and its own class chain.
        local target = menu and menu.target
        if target ~= nil and target.priceList ~= nil then
            dumpAll("target.priceList + inherited", target.priceList)
            line(log, "target.priceList fields:")
            for _, f in ipairs(scalarFields(target.priceList, 40)) do
                line(log, "   " .. f)
            end
        end

        -- Any global whose name mentions the price table or graph.
        local hits = {}
        for k, v in pairs(getfenv(0)) do
            if type(k) == "string" and type(v) == "table" then
                local kl = k:lower()
                if (kl:find("price") or kl:find("graph") or kl:find("chart")
                    or kl:find("bar") and kl:find("elem")) and k:sub(1, 3) ~= "MSW" then
                    hits[#hits + 1] = k
                end
            end
        end
        table.sort(hits)
        line(log, ("globals mentioning price/graph/chart (%d): %s")
            :format(#hits, table.concat(hits, ", ")))
        for _, k in ipairs(hits) do
            dumpAll("   " .. k, getfenv(0)[k])
        end
    end)

    -- 5) The price fields the up/down arrows most likely compare. If the arrow
    --    is drawn from pricePerLiter vs previousHourPrice, recolouring it may be
    --    a matter of touching these rather than hooking any GUI at all.
    pcall(function()
        local idx = g_fillTypeManager:getFillTypeIndexByName("WHEAT")
        local ft = idx and g_fillTypeManager:getFillTypeByIndex(idx)
        if ft == nil then return end
        line(log, ("WHEAT price fields: pricePerLiter=%s startPricePerLiter=%s "
                .. "previousHourPrice=%s title=%s")
            :format(tostring(ft.pricePerLiter), tostring(ft.startPricePerLiter),
                    tostring(ft.previousHourPrice), tostring(ft.title)))
    end)
end

--- Resolve a live object's class name.
---
--- Frame classes are NOT enumerable: pairs(getfenv(0)) returns only this mod's
--- own environment, which is why an earlier probe reported zero "*Frame"
--- globals. Direct lookup by name does resolve through the metatable chain
--- though, so identity-test a candidate list instead of scanning.
local function classNameOf(obj, candidates)
    if type(obj) ~= "table" then return nil end
    local mt = getmetatable(obj)
    local index = type(mt) == "table" and mt.__index or nil
    for _, name in ipairs(candidates) do
        local ok, class = pcall(function() return getfenv(0)[name] end)
        if ok and type(class) == "table" then
            if class == index or class == mt or class == obj then return name end
            local cmt = getmetatable(class)
            if type(cmt) == "table" and cmt.__index == index then
                return name .. " (via superclass)"
            end
        end
    end
    return nil
end

-- Names to identity-test against. Cheap, and the list costs nothing if wrong.
local FRAME_CANDIDATES = {
    "InGameMenuSettingsFrame", "InGameMenuGameSettingsFrame",
    "SettingsFrame", "GameSettingsFrame", "InGameMenuGeneralSettingsFrame",
    "TabbedMenuFrameElement", "MessageDialog", "ScreenElement",
}

--- Recursive GUI element tree: exactly what a new row has to be modelled on.
---
--- Prints typeName, id/name and profile per node, because those three are all
--- that cloning an existing row needs - no class names, no internal APIs.
local function dumpElementTree(log, element, depth, maxDepth, counter)
    if type(element) ~= "table" or depth > maxDepth then return end
    if counter.n >= counter.limit then return end
    counter.n = counter.n + 1

    local parts = {}
    local function add(k)
        local v = element[k]
        if v ~= nil and v ~= "" then parts[#parts + 1] = ("%s=%s"):format(k, tostring(v)) end
    end
    add("typeName"); add("id"); add("name"); add("profile")

    -- The text on an option row is how a row is recognised without its id.
    pcall(function()
        if type(element.text) == "string" and element.text ~= "" then
            parts[#parts + 1] = ("text=%q"):format(element.text:sub(1, 40))
        end
        if type(element.texts) == "table" then
            parts[#parts + 1] = ("#texts=%d"):format(#element.texts)
        end
        if type(element.elements) == "table" then
            parts[#parts + 1] = ("#children=%d"):format(#element.elements)
        end
    end)

    line(log, ("%s%s"):format(("  "):rep(depth), table.concat(parts, "  ")))

    if type(element.elements) == "table" then
        for _, child in ipairs(element.elements) do
            dumpElementTree(log, child, depth + 1, maxDepth, counter)
        end
    end
end

--- Probe the SETTINGS frame, so mod settings can be added to ESC -> Settings.
---
--- Adding rows to the settings page is a well-trodden path, but it needs the
--- live element tree on this build: the plan is to clone an existing option row
--- rather than construct one, and to wrap onFrameOpen on the page INSTANCE
--- rather than on a class, so no internal name has to be guessed at all.
function MSWDiag.dumpSettingsGui(log)
    if not MSWDiag.enabled then return end
    MSWDiag.section(log, "SETTINGS GUI PROBE")

    local menu = g_gui and g_gui.guis and g_gui.guis["InGameMenu"]
    local target = menu and menu.target
    if type(target) ~= "table" then
        line(log, "InGameMenu has no target - is a savegame loaded?")
        return
    end

    for _, pageName in ipairs({ "pageSettings", "pageSettingsMobile" }) do
        local page = target[pageName]
        if type(page) ~= "table" then
            line(log, ("target.%s: absent"):format(pageName))
        else
            line(log, ("---- target.%s ----"):format(pageName))
            line(log, ("   class: %s")
                :format(classNameOf(page, FRAME_CANDIDATES) or "not in candidate list"))

            -- Whether the instance carries its own onFrameOpen matters: if it
            -- is inherited, wrapping the instance shadows it, which is exactly
            -- what we want and is invisible to every other mod.
            local ownOpen = rawget(page, "onFrameOpen")
            line(log, ("   onFrameOpen: %s (own=%s)")
                :format(type(page.onFrameOpen), tostring(ownOpen ~= nil)))
            line(log, ("   updateGeneralSettings=%s  onFrameClose=%s")
                :format(type(page.updateGeneralSettings), type(page.onFrameClose)))

            line(log, ("   scalar fields:"))
            for _, f in ipairs(scalarFields(page, 40)) do line(log, "      " .. f) end

            -- Named sub-tables: the control containers, plus every existing
            -- option control we could clone.
            local subs = {}
            pcall(function()
                for k, v in pairs(page) do
                    if type(v) == "table" and type(k) == "string" then
                        subs[#subs + 1] = ("%s(%s)")
                            :format(k, tostring(v.typeName or "table"))
                    end
                end
            end)
            table.sort(subs)
            line(log, ("   sub-tables (%d): %s"):format(#subs, table.concat(subs, ", ")))

            -- Depth 9, not 7: at 7 the tree stopped at the option rows and cut
            -- off their children, which is exactly the level a cloned row has
            -- to be understood at.
            line(log, "   element tree:")
            dumpElementTree(log, page, 2, 9, { n = 0, limit = 1200 })
        end
    end

    -- Control element classes a new row would be built from. Lookup, not
    -- enumeration - see classNameOf above for why.
    local wanted = { "MultiTextOptionElement", "CheckedOptionElement",
                     "BinaryOptionElement", "TextInputElement",
                     "SliderElement", "OptionToggleElement",
                     "BitmapElement", "TextElement", "ButtonElement" }
    local present = {}
    for _, k in ipairs(wanted) do
        local ok, v = pcall(function() return getfenv(0)[k] end)
        if ok and type(v) == "table" then present[#present + 1] = k end
    end
    line(log, ("control element classes resolvable: %s")
        :format(#present > 0 and table.concat(present, ", ") or "none of the expected"))
end

--- Run the settings probe automatically the first time the page is opened.
---
--- Wraps onFrameOpen on the page INSTANCE, which shadows the inherited method
--- and touches no shared class - the same technique the real settings rows will
--- use. It also proves the hook point works before anything depends on it.
function MSWDiag.armSettingsProbe(log)
    local menu = g_gui and g_gui.guis and g_gui.guis["InGameMenu"]
    local page = menu and menu.target and menu.target.pageSettings
    if type(page) ~= "table" or type(page.onFrameOpen) ~= "function" then
        log:info("settings probe: pageSettings.onFrameOpen unavailable, not armed")
        return false
    end

    local original = page.onFrameOpen
    local fired = false
    page.onFrameOpen = function(self, ...)
        local result = original(self, ...)
        if not fired then
            fired = true
            -- Force the probe on for this one call regardless of the debug
            -- toggle: this is the one dump worth having unprompted.
            local was = MSWDiag.enabled
            MSWDiag.enabled = true
            pcall(MSWDiag.dumpSettingsGui, log)
            MSWDiag.enabled = was
        end
        return result
    end

    log:info("settings probe armed on pageSettings.onFrameOpen")
    return true
end

--- One-time note of what is loaded alongside us.
function MSWDiag.dumpMods(log)
    if not MSWDiag.enabled then return end
    MSWDiag.section(log, "LOADED MODS")
    if g_modManager == nil or g_modManager.getActiveMods == nil then
        line(log, "g_modManager.getActiveMods unavailable")
        return
    end
    local ok, mods = pcall(function() return g_modManager:getActiveMods() end)
    if not ok or type(mods) ~= "table" then
        line(log, "could not read active mods")
        return
    end
    for _, mod in pairs(mods) do
        local name = (type(mod) == "table" and (mod.modName or mod.title)) or tostring(mod)
        local ver = (type(mod) == "table" and mod.version) or "?"
        line(log, ("   %s  (v%s)"):format(tostring(name), tostring(ver)))
    end
end
