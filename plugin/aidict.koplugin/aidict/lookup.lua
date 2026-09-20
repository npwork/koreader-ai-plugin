--[[--
Wires settings, cache and API client together.

This is the whole behaviour of the plugin minus the widgets: `main.lua` hands
it a word and gets back either something to show or an error to report.
--]]--

local ApiClient = require("aidict.apiclient")
local Cache = require("aidict.cache")
local Context = require("aidict.context")

local Lookup = {}
Lookup.__index = Lookup

--[[--
@param opts table
  settings  Settings  required
  transport func      required, see apiclient.lua
  json      table     required, encode/decode pair
  now       func      optional clock, defaults to os.time
--]]--
function Lookup.new(opts)
    opts = opts or {}
    assert(opts.settings, "Lookup needs settings")
    local self = setmetatable({
        settings = opts.settings,
        transport = opts.transport,
        json = opts.json,
        now = opts.now or os.time,
    }, Lookup)
    self:reload()
    return self
end

--- Rebuild the client and resize the cache after a settings change.
function Lookup:reload()
    local s = self.settings
    self.client = ApiClient.new({
        endpoint = s:get("endpoint"),
        api_key = s:get("api_key"),
        block_timeout = s:get("block_timeout"),
        total_timeout = s:get("total_timeout"),
        transport = self.transport,
        json = self.json,
    })

    local max_entries = s:get("cache_size")
    local ttl = s:get("cache_ttl")
    if self.cache then
        local kept = self.cache:dump()
        self.cache = Cache.new({ max_entries = max_entries, ttl = ttl, now = self.now })
        self.cache:restore(kept)
    else
        self.cache = Cache.new({ max_entries = max_entries, ttl = ttl, now = self.now })
    end
end

--- Context snippet for a word, sized by the `context_chars` setting.
function Lookup:build_context(before, word, after)
    return Context.build(before, word, after, self.settings:get("context_chars"))
end

--[[--
@param request table { word, context, title, author, source_lang }
@param opts    table { skip_cache = bool }
@treturn table  result
@treturn table  err
@treturn bool   whether the result came from the cache
--]]--
function Lookup:define(request, opts)
    request = request or {}
    opts = opts or {}

    local word = Context.cleanup(request.word)
    if word == "" then
        return nil, { code = ApiClient.ERRORS.INVALID_REQUEST, message = "no word to look up" }, false
    end

    local target_lang = self.settings:get("target_lang")
    local context = Context.cleanup(request.context)
    local key = Cache.key(word, context, target_lang)

    if not opts.skip_cache then
        local hit = self.cache:get(key)
        if hit then return hit, nil, true end
    end

    local result, err = self.client:define({
        word = word,
        context = context,
        sentence = Context.cleanup(request.sentence),
        target_lang = target_lang,
        source_lang = request.source_lang,
        title = request.title,
        author = request.author,
    })
    if not result then
        return nil, err, false
    end

    self.cache:set(key, result)
    return result, nil, false
end

--- Cache key for a request, so the callers below agree on one.
function Lookup:key_for(request)
    request = request or {}
    return Cache.key(Context.cleanup(request.word),
                     Context.cleanup(request.context),
                     self.settings:get("target_lang"))
end

--- Cached answer for a request, without touching the network.
function Lookup:peek(request)
    local word = Context.cleanup(request and request.word)
    if word == "" then return nil end
    return self.cache:get(self:key_for(request))
end

--[[--
The network half on its own, in a shape that survives being serialised out of
`Trapper:dismissableRunInSubprocess`: one plain table, never a nil.
--]]--
function Lookup:fetch(request)
    request = request or {}
    local word = Context.cleanup(request.word)
    if word == "" then
        return { ok = false, err = { code = ApiClient.ERRORS.INVALID_REQUEST, message = "no word to look up" } }
    end
    local result, err = self.client:define({
        word = word,
        context = Context.cleanup(request.context),
        sentence = Context.cleanup(request.sentence),
        target_lang = self.settings:get("target_lang"),
        source_lang = request.source_lang,
        title = request.title,
        author = request.author,
    })
    if not result then
        return { ok = false, err = err }
    end
    return { ok = true, result = result }
end

--- Store an answer that `fetch` brought back in another process.
function Lookup:remember(request, result)
    if type(result) ~= "table" then return end
    local word = Context.cleanup(request and request.word)
    if word == "" then return end
    self.cache:set(self:key_for(request), result)
end

function Lookup:clear_cache()
    self.cache:clear()
end

function Lookup:dump_cache()
    return self.cache:dump()
end

function Lookup:restore_cache(items)
    self.cache:restore(items)
end

return Lookup
