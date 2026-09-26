local Config = require("aidict.config")

local Settings = {}
Settings.__index = Settings

function Settings.new(store)
    return setmetatable({ store = store }, Settings)
end

-- Falls back to the default when unset or invalid.
function Settings:get(key)
    local default = Config.DEFAULTS[key]
    if default == nil then return nil end
    local value = self.store:readSetting(key)
    if value == nil then return default end
    local ok = Config.validate(key, value)
    if not ok then return default end
    return value
end

function Settings:set(key, value)
    local ok, reason = Config.validate(key, value)
    if not ok then return false, reason end
    self.store:saveSetting(key, value)
    return true
end

function Settings:reset(key)
    if Config.DEFAULTS[key] == nil then return false, "unknown setting: " .. tostring(key) end
    self.store:saveSetting(key, nil)
    return true
end

function Settings:all()
    local all = {}
    for key in pairs(Config.DEFAULTS) do
        all[key] = self:get(key)
    end
    return all
end

-- The endpoint is the one setting with no usable default.
function Settings:is_configured()
    return Config.validate("endpoint", self:get("endpoint")) == true
end

function Settings:flush()
    if self.store.flush then self.store:flush() end
end

return Settings
