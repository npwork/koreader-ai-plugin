--[[--
Typed access to the plugin's settings.

Takes any LuaSettings-shaped store — `readSetting`, `saveSetting`, `flush` —
so the tests can pass a table and KOReader can pass the real thing.
--]]--

local Config = require("aidict.config")

local Settings = {}
Settings.__index = Settings

function Settings.new(store)
    return setmetatable({ store = store }, Settings)
end

--- Current value, falling back to the default when unset or invalid.
function Settings:get(key)
    local default = Config.DEFAULTS[key]
    if default == nil then return nil end
    local value = self.store:readSetting(key)
    if value == nil then return default end
    local ok = Config.validate(key, value)
    if not ok then return default end
    return value
end

--- @treturn bool ok
--- @treturn string reason when rejected
function Settings:set(key, value)
    local ok, reason = Config.validate(key, value)
    if not ok then return false, reason end
    self.store:saveSetting(key, value)
    return true
end

--- Reset a key back to its default.
function Settings:reset(key)
    if Config.DEFAULTS[key] == nil then return false, "unknown setting: " .. tostring(key) end
    self.store:saveSetting(key, nil)
    return true
end

--- Every setting, defaults filled in.
function Settings:all()
    local all = {}
    for key in pairs(Config.DEFAULTS) do
        all[key] = self:get(key)
    end
    return all
end

--- The endpoint is the one setting without a sensible universal default, so
--- "configured" means: it still parses as a URL.
function Settings:is_configured()
    return Config.validate("endpoint", self:get("endpoint")) == true
end

function Settings:flush()
    if self.store.flush then self.store:flush() end
end

return Settings
