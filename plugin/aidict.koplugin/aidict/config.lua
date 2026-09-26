local Config = {}

Config.DEFAULTS = {
    -- The plugin POSTs to <endpoint>/define. Empty on purpose: the address is baked into the
    -- package at build time, so the public repository never carries it.
    endpoint = "",
    -- Empty means the gateway is open to this device.
    api_key = "",
    -- Seconds.
    block_timeout = 10,
    total_timeout = 30,
    context_chars = 1000,
    -- 0 disables the cache.
    cache_size = 200,
    -- Seconds; 0 means never expires.
    cache_ttl = 30 * 24 * 60 * 60,

    -- Not documents/: the Kindle's framework indexes it, and an EPUB there becomes a native
    -- library entry that opens badly.
    library_dir = "/mnt/us/AI_Books",

    -- The newest vocab.db lookup the server acknowledged, epoch ms. Losing it only makes the
    -- next upload longer: the server ignores lookups it already has.
    vocab_uploaded_through = 0,

    channel = "stable",
    repo_url = "https://npwork.github.io/koreader-ai-plugin",
}

-- Written in at package time from build secrets; the reader cannot see or change them.
-- An empty value means the package was built without it.
Config.BAKED = {
    library_endpoint = "",
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
    vocab_uploaded_through = function(value)
        if type(value) ~= "number" or value < 0 then
            return false, "vocab_uploaded_through must be a time in milliseconds"
        end
        return true
    end,
    library_dir = function(value)
        if type(value) ~= "string" or value:sub(1, 1) ~= "/" then
            return false, "library_dir must be an absolute path"
        end
        return true
    end,
}

function Config.validate(key, value)
    local validator = Config.VALIDATORS[key]
    if not validator then
        return false, "unknown setting: " .. tostring(key)
    end
    return validator(value)
end

return Config
