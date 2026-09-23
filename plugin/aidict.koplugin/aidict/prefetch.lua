--[[--
Whether to start asking about a word now, and what is already in the air.

The gateway takes a second and a half to answer and the Kindle spends nearly
another on the radio. KOReader announces a lookup before it has even searched
its dictionaries, so that is when the request goes out: the AI page in the
dictionary popup says it is asking, and is filled in when the answer lands.

This module is only the decision and the bookkeeping of what is in the air.
The forking lives in `main.lua`, where KOReader does.
--]]--

local Prefetch = {}
Prefetch.__index = Prefetch

--- Why a word was not fetched ahead. Only ever logged.
Prefetch.SKIP = {
    NOT_CONFIGURED = "no endpoint",
    OFFLINE = "offline",
    NO_WORD = "nothing to look up",
    CACHED = "already cached",
    IN_FLIGHT = "already in flight",
    BUSY = "too many in flight",
}

--[[--
@param opts table
  settings       Settings required
  max_in_flight  int      how many may be in the air at once (default 2)
--]]--
function Prefetch.new(opts)
    opts = opts or {}
    assert(opts.settings, "Prefetch needs settings")
    return setmetatable({
        settings = opts.settings,
        -- A reader flicking through a page can open several dictionary
        -- entries in a few seconds. Each one forks a process on a device with
        -- very little memory, so there is a ceiling.
        max_in_flight = opts.max_in_flight or 2,
        flying = {},
        count = 0,
    }, Prefetch)
end

--[[--
Should this word be fetched now?

The order of the checks is the order of the reasons worth reading in a log:
the settings first, because they explain every word at once, then the state of
this particular one.

@param key  string cache key the answer would be stored under
@param opts table  { offline = bool, cached = bool }
@treturn bool   whether to fetch
@treturn string why not, when it is false
--]]--
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

--- Note that a fetch for this key has started. Repeats are ignored.
function Prefetch:began(key)
    if type(key) ~= "string" or key == "" or self.flying[key] then return false end
    self.flying[key] = true
    self.count = self.count + 1
    return true
end

--- Note that it has finished, however it finished.
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

--- Forget everything in the air, for when the document closes under it.
function Prefetch:clear()
    self.flying = {}
    self.count = 0
end

return Prefetch
