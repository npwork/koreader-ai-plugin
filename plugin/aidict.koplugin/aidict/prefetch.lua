local Prefetch = {}
Prefetch.__index = Prefetch

-- Only ever logged.
Prefetch.SKIP = {
    NOT_CONFIGURED = "no endpoint",
    OFFLINE = "offline",
    NO_WORD = "nothing to look up",
    CACHED = "already cached",
    IN_FLIGHT = "already in flight",
    BUSY = "too many in flight",
}

function Prefetch.new(opts)
    opts = opts or {}
    assert(opts.settings, "Prefetch needs settings")
    return setmetatable({
        settings = opts.settings,
        -- Each prefetch forks a process on a device with very little memory.
        max_in_flight = opts.max_in_flight or 2,
        flying = {},
        count = 0,
    }, Prefetch)
end

-- Settings are checked first: in the log they explain every word at once.
function Prefetch:wanted(key, opts)
    opts = opts or {}
    if not self.settings:is_configured() then
        return false, Prefetch.SKIP.NOT_CONFIGURED
    end
    if opts.offline then
        return false, Prefetch.SKIP.OFFLINE
    end
    if type(key) ~= "string" or key == "" then
        return false, Prefetch.SKIP.NO_WORD
    end
    if opts.cached then
        return false, Prefetch.SKIP.CACHED
    end
    if self.flying[key] then
        return false, Prefetch.SKIP.IN_FLIGHT
    end
    if self.count >= self.max_in_flight then
        return false, Prefetch.SKIP.BUSY
    end
    return true
end

-- Repeats are ignored.
function Prefetch:began(key)
    if type(key) ~= "string" or key == "" or self.flying[key] then return false end
    self.flying[key] = true
    self.count = self.count + 1
    return true
end

function Prefetch:ended(key)
    if not self.flying[key] then return false end
    self.flying[key] = nil
    self.count = self.count - 1
    return true
end

function Prefetch:pending()
    return self.count
end

function Prefetch:is_pending(key)
    return self.flying[key] == true
end

function Prefetch:clear()
    self.flying = {}
    self.count = 0
end

return Prefetch
