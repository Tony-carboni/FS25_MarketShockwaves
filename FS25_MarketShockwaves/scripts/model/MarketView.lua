--[[
    MarketView — what the hub's Market tab shows, as plain data.

    Pure logic: it reads the price model and returns tables, so the menu page
    only has to draw them and the whole thing is testable outside the game.

    Two lists:

      events    what is in the news right now, newest first
      products  what is actually moving today, largest change first, each with
                the events behind it

    NO SPOILERS. The view carries only what the player has already been told
    (the news item) and what they can already see at a selling point (today's
    price change). It deliberately has no remaining duration, no peak and no
    list of products an event has yet to reach - a ripple that has not arrived
    is not shown until it does.
]]

MSWMarketView = {}

--- A product is listed once it has moved this far. The same threshold the
--- commodity markers use, so the list and the markers always agree.
MSWMarketView.MIN_ABS_CHANGE = 0.01

--- l10n keys of the news item an event was announced with.
function MSWMarketView.newsKeys(eventId, severity)
    local base = ("msw_%s_%s"):format(tostring(eventId), tostring(severity))
    return base .. "_title", base .. "_text"
end

--- @param priceModel table MSWPriceModel
--- @param day number current game day
--- @param openForecasts table|nil array of MSWActiveForecast. One in its
---        pre-move is already moving prices, so its products are listed, with
---        the forecast named as the cause.
--- @return table { events = {...}, products = {...} }
function MSWMarketView.build(priceModel, day, openForecasts)
    local view = { events = {}, products = {} }
    if priceModel == nil or day == nil then return view end

    local byProduct = {}   -- name -> { name=, factors={}, eventIds={}, forecastTitleKeys={} }

    for _, ev in ipairs(priceModel:getActiveEvents()) do
        if not ev:isExpired(day) then
            local titleKey, textKey = MSWMarketView.newsKeys(ev.eventId, ev.severity)
            -- An event a forecast started was announced with the verdict
            -- message, so that is its news item.
            if ev.titleKey ~= nil then titleKey = ev.titleKey end
            if ev.textKey ~= nil then textKey = ev.textKey end
            local entry = {
                eventId = ev.eventId, severity = ev.severity, type = ev.type,
                startDay = ev.startDay, titleKey = titleKey, textKey = textKey,
                moving = 0,
            }
            view.events[#view.events + 1] = entry

            for _, name in ipairs(ev:getProducts()) do
                -- Only products this game actually has: a map without olives
                -- should not list olive oil.
                if priceModel:getIndexFor(name) ~= nil then
                    local factor = ev:getFactorFor(name, day)
                    if factor ~= 1.0 then
                        local p = byProduct[name]
                        if p == nil then
                            p = { name = name, factors = {}, eventIds = {},
                                  forecastTitleKeys = {} }
                            byProduct[name] = p
                        end
                        p.factors[#p.factors + 1] = factor
                        if math.abs(factor - 1.0) >= MSWMarketView.MIN_ABS_CHANGE then
                            p.eventIds[#p.eventIds + 1] = ev.eventId
                            entry.moving = entry.moving + 1
                        end
                    end
                end
            end
        end
    end

    for _, forecast in ipairs(openForecasts or {}) do
        local titleKey = MSWForecastDef.messageKeys(forecast.forecastId,
                                                    forecast.variantId, "open")
        for _, name in ipairs(forecast:getProducts()) do
            if priceModel:getIndexFor(name) ~= nil then
                local factor = forecast:getFactorFor(name, day)
                if factor ~= 1.0 then
                    local p = byProduct[name]
                    if p == nil then
                        p = { name = name, factors = {}, eventIds = {},
                              forecastTitleKeys = {} }
                        byProduct[name] = p
                    end
                    p.factors[#p.factors + 1] = factor
                    if math.abs(factor - 1.0) >= MSWMarketView.MIN_ABS_CHANGE then
                        p.forecastTitleKeys[#p.forecastTitleKeys + 1] = titleKey
                    end
                end
            end
        end
    end

    -- Newest news first; ties broken by id so the order never flickers.
    table.sort(view.events, function(a, b)
        if a.startDay ~= b.startDay then return a.startDay > b.startDay end
        return a.eventId < b.eventId
    end)

    for _, p in pairs(byProduct) do
        -- The same combination the price hook applies, so the number shown is
        -- the number paid.
        local factor = MSWPriceModel.combineFactors(p.factors)
        if math.abs(factor - 1.0) >= MSWMarketView.MIN_ABS_CHANGE then
            view.products[#view.products + 1] = {
                name = p.name, factor = factor, eventIds = p.eventIds,
                forecastTitleKeys = p.forecastTitleKeys,
            }
        end
    end

    table.sort(view.products, function(a, b)
        local da, db = math.abs(a.factor - 1.0), math.abs(b.factor - 1.0)
        if da ~= db then return da > db end
        return a.name < b.name
    end)

    return view
end

--- "+13%" / "-8%", rounded like the commodity markers.
function MSWMarketView.formatChange(factor)
    local pct = (factor - 1.0) * 100
    local rounded = pct >= 0 and math.floor(pct + 0.5) or -math.floor(-pct + 0.5)
    return ("%+d%%"):format(rounded)
end
