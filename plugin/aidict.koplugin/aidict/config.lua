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
    -- Seconds. Block timeout and total timeout for the HTTP call.
    block_timeout = 10,
    total_timeout = 30,
    -- How many characters of the surrounding paragraph to send with the word.
    -- A paragraph is what lets the other side tell which sense is meant.
    context_chars = 1000,
    -- Answers kept on the device. 0 disables the cache.
    cache_size = 200,
    -- Seconds an answer stays fresh. 0 means "never expires".
    cache_ttl = 30 * 24 * 60 * 60,
    -- Update channel used by the update check and by `kpm`.
    -- Look a word up when the dictionary opens, rather than when AI is
    -- pressed, so the answer is waiting by the time it is wanted. On, because
    -- the gateway takes seconds: pressing AI and watching a spinner is most
    -- of what the feature costs, and this is the only thing that removes it.
    -- The price is a request per dictionary lookup rather than per AI press,
    -- and most lookups never reach the button — turn it off in the menu if
    -- that ever matters more than the wait.
    prefetch = true,

    -- Where synced books land: its own folder beside Audible, Documents and
    -- Screenshots, named to sort above them so it is the first thing in the
    -- file browser. The sync creates it, and `documents/` is deliberately not
    -- it — that is the one folder the Kindle's own framework indexes, and an
    -- EPUB in there becomes an entry in the native library that opens badly.
    library_dir = "/mnt/us/AI Books",
    -- The library mount's address. Empty means "derive it from `endpoint`" —
    -- both mounts sit on the same gateway, so one baked-in address covers
    -- both and the repository still carries none.
    library_endpoint = "",

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
    prefetch = function(value)
        if type(value) ~= "boolean" then
            return false, "prefetch must be true or false"
        end
        return true
    end,
    api_key = function(value)
        if type(value) ~= "string" then
            return false, "api_key must be a string"
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
    library_dir = function(value)
        if type(value) ~= "string" or value:sub(1, 1) ~= "/" then
            return false, "library_dir must be an absolute path"
        end
        return true
    end,
    library_endpoint = function(value)
        if type(value) ~= "string" then
            return false, "library_endpoint must be a string"
        end
        if value ~= "" and not is_http_url(value) then
            return false, "library_endpoint must be empty or an http:// or https:// URL"
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
