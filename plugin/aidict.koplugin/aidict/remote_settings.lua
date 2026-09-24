--[[--
KOReader's settings, set from the library server.

KOReader keeps its global settings in one store (`G_reader_settings`, the file
`settings.reader.lua`): plain key → value. The owner queues changes to it
through the library's MCP (`kindle_settings_set`); "Sync" fetches
the queue, writes each change into that store, and reports back what it
changed — with the value each one replaced, so it can be undone — and every
setting the store now holds, except the secrets other plugins keep there.

Takes the store, a transport and a JSON codec as arguments, like
`library.lua`, so the specs run it without KOReader.
--]]--

local Version = require("aidict.version")

local RemoteSettings = {}
RemoteSettings.__index = RemoteSettings

--- The gateway accepts nothing else, and neither do we: KOReader's keys are identifiers.
local function is_key(key)
    return type(key) == "string" and key:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil and #key <= 100
end

--[[--
A value JSON can carry both ways: a finite number, a string, a boolean, or a
table of those. Functions, userdata (a JSON null among them) and cycles are
not; neither is anything nested deeper than any real setting is.
--]]--
local function is_plain(value, depth)
    local kind = type(value)
    if kind == "string" or kind == "boolean" then return true end
    if kind == "number" then return value == value and value ~= math.huge and value ~= -math.huge end
    if kind ~= "table" or depth > 8 then return false end
    for k, v in pairs(value) do
        local key_kind = type(k)
        if key_kind ~= "string" and key_kind ~= "number" then return false end
        if not is_plain(v, depth + 1) then return false end
    end
    return true
end

--- A fresh copy without metatables: the codec's arrays carry one, and the store must not keep it.
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

--[[--
Write the queued changes into the store.

@param store   table  `readSetting`, `saveSetting`, `delSetting`
@param pending table  list of `{ key, value }` or `{ key, reset = true }`
@treturn table list of what was changed: `{ key, value | reset, previous }`
--]]--
function RemoteSettings.apply(store, pending)
    local applied = {}
    for _, change in ipairs(type(pending) == "table" and pending or {}) do
        if type(change) == "table" and is_key(change.key) then
            local previous = store:readSetting(change.key)
            local entry = { key = change.key }
            if is_plain(previous, 0) then entry.previous = copy(previous) end
            if change.reset == true then
                store:delSetting(change.key)
                entry.reset = true
                applied[#applied + 1] = entry
            elseif change.value ~= nil and is_plain(change.value, 0) then
                store:saveSetting(change.key, copy(change.value))
                entry.value = copy(change.value)
                applied[#applied + 1] = entry
            end
        end
    end
    return applied
end

--[[--
Names that hold a secret. Other plugins keep theirs in the same store —
kosync's `userkey`, the exporter's Readwise and Joplin tokens — and those stay
on the device: the report ends up in an MCP client's context.
--]]--
local SECRET = { "password", "passwd", "secret", "token", "userkey", "api_key", "apikey", "auth", "cookie", "credential" }

local function is_secret(name)
    if type(name) ~= "string" then return false end
    name = name:lower()
    for _, word in ipairs(SECRET) do
        if name:find(word, 1, true) then return true end
    end
    return false
end

--- A copy with every field named like a secret left out, at any depth.
local function without_secrets(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do
        if not is_secret(k) then out[k] = without_secrets(v) end
    end
    return out
end

--[[--
Every setting in the store that can travel as JSON, secrets left out.

@param data  table  the store's own table (`G_reader_settings.data`)
@param json  table  the codec, to drop a value it cannot encode
--]]--
function RemoteSettings.snapshot(data, json)
    local values = {}
    for key, value in pairs(type(data) == "table" and data or {}) do
        if is_key(key) and not is_secret(key) and is_plain(value, 0) then
            local kept = without_secrets(value)
            if pcall(json.encode, kept) then values[key] = kept end
        end
    end
    return values
end

function RemoteSettings.new(opts)
    opts = opts or {}
    assert(type(opts.transport) == "function", "RemoteSettings needs a transport function")
    assert(type(opts.json) == "table", "RemoteSettings needs a json codec")
    return setmetatable({
        endpoint = opts.endpoint,
        api_key = opts.api_key,
        transport = opts.transport,
        json = opts.json,
        block_timeout = opts.block_timeout or 10,
        total_timeout = opts.total_timeout or 30,
        user_agent = opts.user_agent or ("koreader-aidict/" .. Version.string),
    }, RemoteSettings)
end

--- `<endpoint>/settings`, keeping a `?token=` the address may carry at the end.
function RemoteSettings:url()
    local base, query = self.endpoint or "", ""
    local mark = base:find("?", 1, true)
    if mark then
        query = base:sub(mark)
        base = base:sub(1, mark - 1)
    end
    return (base:gsub("/+$", "")) .. "/settings" .. query
end

--- One request to the settings route, decoded; nil and `{ code, message }` when it failed.
function RemoteSettings:request(method, body)
    local headers = { ["Accept"] = "application/json", ["User-Agent"] = self.user_agent }
    if type(self.api_key) == "string" and self.api_key ~= "" then
        headers["Authorization"] = "Bearer " .. self.api_key
    end
    if body then headers["Content-Type"] = "application/json" end

    local response, transport_err = self.transport({
        url = self:url(),
        method = method,
        headers = headers,
        body = body,
        block_timeout = self.block_timeout,
        total_timeout = self.total_timeout,
    })
    if not response then
        local reason = tostring(transport_err or "network unreachable")
        if reason:lower():find("timeout") then
            return nil, { code = "timeout", message = "the gateway did not answer in time" }
        end
        return nil, { code = "network", message = reason }
    end

    local status = tonumber(response.status) or 0
    if status == 401 or status == 403 then
        return nil, { code = "unauthorized", message = "the gateway rejected this device's key" }
    end
    if status < 200 or status >= 300 then
        return nil, { code = "http_error", message = "the library answered HTTP " .. status, status = status }
    end
    local ok, decoded = pcall(self.json.decode, response.body or "")
    if not ok or type(decoded) ~= "table" then
        return nil, { code = "bad_response", message = "the library sent something that is not JSON" }
    end
    return decoded
end

--- Where changes wait while the library has not heard of them, in the plugin's own store.
RemoteSettings.OUTBOX_KEY = "settings_unreported"

--[[--
The changes to report: those still waiting from a sync whose report never
arrived, then this sync's. A change applied again because its first report was
lost keeps the value it first replaced — the second time round, the store
already holds the new value, and that is no use for undoing it.
--]]--
local function outgoing(unreported, applied)
    local first = {}
    for _, entry in ipairs(unreported) do
        if type(entry) == "table" and entry.key then first[entry.key] = entry end
    end
    local again = {}
    for _, entry in ipairs(applied) do
        local earlier = first[entry.key]
        if earlier then entry.previous = copy(earlier.previous) end
        again[entry.key] = true
    end
    local out = {}
    for _, entry in ipairs(unreported) do
        if type(entry) == "table" and entry.key and not again[entry.key] then out[#out + 1] = entry end
    end
    for _, entry in ipairs(applied) do out[#out + 1] = entry end
    return out
end

--[[--
Run a request through `offload`, which may run it in another process: the
answer crosses as JSON, the way the prefetch's does. Nil when it was cancelled.
--]]--
function RemoteSettings:offloaded(offload, fn)
    local codec = self.json
    local function task()
        local ok, encoded = pcall(codec.encode, fn())
        return ok and encoded or ""
    end
    local raw
    if offload then
        raw = offload(task)
        if raw == nil then return nil end
    else
        raw = task()
    end
    local ok, decoded = pcall(codec.decode, raw)
    return ok and type(decoded) == "table" and decoded or {}
end

local CANCELLED = { code = "cancelled", message = "the sync was cancelled" }

--[[--
Fetch the queue, apply it, report back.

The two requests go through `opts.offload`, so KOReader can run them in a
subprocess and a slow gateway never freezes the reader; the writes to the
store happen here, because a change made in a forked child dies with it.

@param store table  `readSetting`, `saveSetting`, `delSetting`, `flush`, and
                    `data`, the table holding every setting
@param opts  table  `outbox`: a store for the changes not yet reported;
                    `offload`: `function(task) → task's string | nil if cancelled`
@treturn table `{ applied = { … }, reported = bool, report_error = err|nil }`
@treturn table err when nothing could be fetched, so nothing changed
--]]--
function RemoteSettings:sync(store, opts)
    assert(type(opts) == "table" and opts.outbox, "RemoteSettings:sync needs an outbox")
    if type(self.endpoint) ~= "string" or not self.endpoint:match("^https?://") then
        return nil, { code = "not_configured", message = "the library endpoint is not set" }
    end

    local fetched = self:offloaded(opts.offload, function()
        local queue, err = self:request("GET")
        return { queue = queue, err = err }
    end)
    if not fetched then return nil, CANCELLED end
    if type(fetched.queue) ~= "table" then
        return nil, fetched.err or { code = "bad_response", message = "the library sent nothing usable" }
    end

    local applied = RemoteSettings.apply(store, fetched.queue.pending)
    if #applied > 0 and store.flush then store:flush() end

    local unreported = opts.outbox:readSetting(RemoteSettings.OUTBOX_KEY)
    local changes = outgoing(type(unreported) == "table" and unreported or {}, applied)
    if #applied > 0 then
        opts.outbox:saveSetting(RemoteSettings.OUTBOX_KEY, changes)
        if opts.outbox.flush then opts.outbox:flush() end
    end

    local report = {
        values = RemoteSettings.snapshot(store.data, self.json),
        plugin_version = Version.string,
    }
    -- Left out rather than sent empty: an empty Lua table encodes as an
    -- object, and the list it stands for would not be one.
    if #changes > 0 then report.applied = changes end

    local ok, body = pcall(self.json.encode, report)
    if not ok then
        return { applied = applied, reported = false, report_error = { code = "encode", message = tostring(body) } }
    end
    local sent = self:offloaded(opts.offload, function()
        local answer, err = self:request("POST", body)
        return { ok = answer ~= nil, err = err }
    end)
    if not sent then return { applied = applied, reported = false, report_error = CANCELLED } end
    if sent.ok and #changes > 0 then
        opts.outbox:delSetting(RemoteSettings.OUTBOX_KEY)
        if opts.outbox.flush then opts.outbox:flush() end
    end
    return { applied = applied, reported = sent.ok == true, report_error = sent.err }
end

return RemoteSettings
