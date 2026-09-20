--[[--
Defaults and validation rules for every setting the plugin knows about.

Pure Lua: no KOReader modules are required from here, so the whole table is
testable under plain busted.
--]]--

local Config = {}

Config.DEFAULTS = {
    -- Gateway endpoint. The plugin POSTs to <endpoint>/define.
    -- Empty on purpose: the real address is baked into the package at build
    -- time (`kpmrepo.py package --endpoint …`, from a CI secret), and can be
    -- set or changed on the device from the plugin's menu. Nothing here
    -- commits the address to a public repository.
    endpoint = "",
    -- Optional bearer token; empty means the gateway is open to this device.
    api_key = "",
    -- Language the explanation should be written in. "auto" keeps the
    -- book's language.
    target_lang = "ru",
    -- Seconds. Block timeout and total timeout for the HTTP call.
    block_timeout = 10,
    total_timeout = 30,
    -- How many characters of surrounding text to send with the word.
    context_chars = 320,
    -- Answers kept on the device. 0 disables the cache.
    cache_size = 200,
    -- Seconds an answer stays fresh. 0 means "never expires".
    cache_ttl = 30 * 24 * 60 * 60,
    -- Update channel used by the update check and by `kpm`.
    channel = "stable",
    -- Root of the KPM repository, without the channel.
    repo_url = "https://npwork.github.io/koreader-ai-plugin",
}

Config.CHANNELS = { stable = true, dev = true }

local function is_http_url(value)
    return type(value) == "string" and value:match("^https?://[^%s]+$") ~= nil
end

--- Validators return `true` or `false, reason`.
Config.VALIDATORS = {
    endpoint = function(value)
        if not is_http_url(value) then
            return false, "endpoint must be an http:// or https:// URL"
        end
        return true
    end,
    api_key = function(value)
        if type(value) ~= "string" then
            return false, "api_key must be a string"
        end
        return true
    end,
    target_lang = function(value)
        if type(value) ~= "string" or not value:match("^[%a][%a%-_]*$") then
            return false, "target_lang must be a language code"
        end
        return true
    end,
    block_timeout = function(value)
        if type(value) ~= "number" or value <= 0 or value > 120 then
            return false, "block_timeout must be between 1 and 120 seconds"
        end
        return true
    end,
    total_timeout = function(value)
        if type(value) ~= "number" or value <= 0 or value > 300 then
            return false, "total_timeout must be between 1 and 300 seconds"
        end
        return true
    end,
    context_chars = function(value)
        if type(value) ~= "number" or value < 0 or value > 4000 then
            return false, "context_chars must be between 0 and 4000"
        end
        return true
    end,
    cache_size = function(value)
        if type(value) ~= "number" or value < 0 or value > 5000 then
            return false, "cache_size must be between 0 and 5000"
        end
        return true
    end,
    cache_ttl = function(value)
        if type(value) ~= "number" or value < 0 then
            return false, "cache_ttl must not be negative"
        end
        return true
    end,
    repo_url = function(value)
        if not is_http_url(value) then
            return false, "repo_url must be an http:// or https:// URL"
        end
        return true
    end,
    channel = function(value)
        if not Config.CHANNELS[value] then
            return false, "channel must be 'stable' or 'dev'"
        end
        return true
    end,
}

--- Validate a single key/value pair.
-- @treturn bool ok
-- @treturn string reason when not ok
function Config.validate(key, value)
    local validator = Config.VALIDATORS[key]
    if not validator then
        return false, "unknown setting: " .. tostring(key)
    end
    return validator(value)
end

return Config
