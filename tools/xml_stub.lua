--[[
    Engine stubs shared by the offline tools: Class(), and a small XML reader
    and in-memory XML store standing in for the engine's XML functions, so the
    mod's own loaders can read the real config files outside the game.

    Globals defined: Class, parseXML(path), memoryXML(), and the engine's
    loadXMLFile / getXML* / setXML* / hasXMLProperty / delete / fileExists.
]]

-- ---- minimal engine stubs -------------------------------------------------
function Class(base)
    local c = {}
    c.__index = c
    if base then setmetatable(c, { __index = base }) end
    return c
end

-- ---- a small XML reader, standing in for the engine's ----------------------
local ENTITIES = { ["&amp;"] = "&", ["&lt;"] = "<", ["&gt;"] = ">",
                   ["&quot;"] = '"', ["&apos;"] = "'" }
local function decode(s) return (s:gsub("&%a+;", ENTITIES)) end

function parseXML(path)
    local f = assert(io.open(path, "rb"), "cannot open " .. path)
    local s = f:read("a"); f:close()
    s = s:gsub("<%?.-%?>", ""):gsub("<!%-%-.-%-%->", ""):gsub("<!%[CDATA%[(.-)%]%]>", "%1")
    local root, stack = nil, {}
    local pos = 1
    while true do
        local a, b, closing, name, attrs, selfClosing = s:find("<(/?)([%w_:]+)(.-)(/?)>", pos)
        if a == nil then break end
        local between = s:sub(pos, a - 1)
        if #stack > 0 then stack[#stack].text = stack[#stack].text .. between end
        if closing == "/" then
            table.remove(stack)
        else
            local node = { name = name, attrs = {}, children = {}, text = "" }
            for k, v in attrs:gmatch('([%w_:]+)%s*=%s*"([^"]*)"') do node.attrs[k] = decode(v) end
            if #stack > 0 then table.insert(stack[#stack].children, node) else root = node end
            if selfClosing ~= "/" then stack[#stack + 1] = node end
        end
        pos = b + 1
    end
    return { tree = root }
end

--- Resolve "a.b(2).c" to a node, and split off "#attr".
local function resolve(handle, key)
    local path, attr = key:match("^([^#]*)#?(.*)$")
    if attr == "" then attr = nil end
    local node
    for segment in path:gmatch("[^%.]+") do
        local name, index = segment:match("^([%w_:]+)%((%d+)%)$")
        if name == nil then name, index = segment, 0 end
        index = tonumber(index)
        if node == nil then
            if handle.tree == nil or handle.tree.name ~= name then return nil end
            node = handle.tree
        else
            local found, n = nil, 0
            for _, child in ipairs(node.children) do
                if child.name == name then
                    if n == index then found = child break end
                    n = n + 1
                end
            end
            if found == nil then return nil end
            node = found
        end
    end
    return node, attr
end

-- A handle is either a parsed file (tree) or an in-memory store (values),
-- which is what saving writes into.
function loadXMLFile(_, path) return parseXML(path) end
function delete() end
function fileExists(path) local f = io.open(path, "rb"); if f then f:close() return true end return false end

local function readValue(handle, key)
    if handle.values ~= nil then return handle.values[key] end
    local node, attr = resolve(handle, key)
    if node == nil then return nil end
    if attr ~= nil then return node.attrs[attr] end
    local trimmed = decode(node.text):gsub("^%s+", ""):gsub("%s+$", "")
    return trimmed
end
function getXMLString(handle, key) local v = readValue(handle, key); return v ~= nil and tostring(v) or nil end
function getXMLFloat(handle, key) return tonumber(readValue(handle, key)) end
function getXMLInt(handle, key) local v = tonumber(readValue(handle, key)); return v and math.floor(v) or nil end
function getXMLBool(handle, key) local v = readValue(handle, key); if v == nil then return nil end return tostring(v) == "true" end
function setXMLFloat(handle, key, v) handle.values[key] = v end
function setXMLString(handle, key, v) handle.values[key] = v end
function hasXMLProperty(handle, key)
    if handle.values ~= nil then
        local prefix = key .. "#"
        for k in pairs(handle.values) do
            if k:sub(1, #prefix) == prefix then return true end
        end
        return false
    end
    return resolve(handle, key) ~= nil
end
function memoryXML() return { values = {} } end
