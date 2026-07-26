--[[ Logger — prefixed logging with an optional debug level. ]]

MSWLogger = {}
local MSWLogger_mt = Class(MSWLogger)

local PREFIX = "[MSW] "

function MSWLogger.new(debugEnabled)
    local self = setmetatable({}, MSWLogger_mt)
    self.debugEnabled = debugEnabled and true or false
    return self
end

function MSWLogger:info(msg)  print(PREFIX .. tostring(msg)) end
function MSWLogger:warn(msg)  print(PREFIX .. "WARNING: " .. tostring(msg)) end
function MSWLogger:error(msg) print(PREFIX .. "ERROR: " .. tostring(msg)) end

function MSWLogger:debug(msg)
    if self.debugEnabled then print(PREFIX .. "debug: " .. tostring(msg)) end
end

function MSWLogger:setDebug(enabled) self.debugEnabled = enabled and true or false end
