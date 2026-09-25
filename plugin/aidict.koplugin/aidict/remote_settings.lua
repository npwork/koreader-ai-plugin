--[[--
KOReader's settings, set from the library server.

KOReader keeps its global settings in one store (`G_reader_settings`, the file
`settings.reader.lua`): plain key → value. The owner queues changes to it
through the library's MCP (`kindle_settings_set`); "Sync" sends every
setting and when this Kindle changed each, gets back what to apply, writes it
into that store, and reports back what it changed — with the value each one
replaced, so it can be undone — and every setting the store now holds, except
the secrets other plugins keep there. That report is the library's copy, so
it goes both ways; when both sides changed a key, the later change wins.

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

--- `<endpoint>/settings<path>`, keeping a `?token=` the address may carry at the end.
function RemoteSettings:url(path)
    local base, query = self.endpoint or "", ""
    local mark = base:find("?", 1, true)
    if mark then
        query = base:sub(mark)
        base = base:sub(1, mark - 1)
    end
    return (base:gsub("/+$", "")) .. "/settings" .. (path or "") .. query
end

--- One request to the settings route, decoded; nil and `{ code, message }` when it failed.
function RemoteSettings:request(method, body, path)
    local headers = { ["Accept"] = "application/json", ["User-Agent"] = self.user_agent }
    if type(self.api_key) == "string" and self.api_key ~= "" then
        headers["Authorization"] = "Bearer " .. self.api_key
    end
    if body then headers["Content-Type"] = "application/json" end

    local response, transport_err = self.transport({
        url = self:url(path),
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

--- What the settings looked like when last seen, and when each changed; in the plugin's own store.
RemoteSettings.SEEN_KEY = "settings_seen"
RemoteSettings.CHANGED_KEY = "settings_changed_at"

--[[--
Every change to a setting this Kindle saw, oldest first, until a report takes
it to the library: `{ n, at, key, source, value | removed, previous? }`, `at` in
Unix seconds by this Kindle's clock. `source` says who changed it: "sync" (the
library's queued change, applied), "book" (the look changed in an open book,
made the default), or "kindle" (anything else, seen when KOReader saved its
settings). Secrets are never logged.
--]]--
RemoteSettings.LOG_KEY = "settings_log"

--- Only the newest entries are kept when reports keep failing.
RemoteSettings.LOG_KEPT = 300

--- The number the next entry gets, so a report can drop exactly the entries it sent.
RemoteSettings.LOG_NEXT_KEY = "settings_log_next"

--- A value as the library may see it: nil for a secret, or for what JSON cannot carry.
local function visible(key, value, json)
    return RemoteSettings.snapshot({ [key] = value }, json)[key]
end

--[[--
Add one change to the log. A secret's key is left out altogether.

@param outbox table the plugin's own store
@param entry  table `{ at, key, source, value | removed = true, previous? }`
@param json   table the codec, to leave out what it cannot encode
--]]--
function RemoteSettings.log(outbox, entry, json)
    if is_secret(entry.key) then return end
    local line = { at = entry.at, key = entry.key, source = entry.source }
    if entry.removed then
        line.removed = true
    else
        line.value = visible(entry.key, entry.value, json)
    end
    if entry.previous ~= nil then line.previous = visible(entry.key, entry.previous, json) end
    local n = tonumber(outbox:readSetting(RemoteSettings.LOG_NEXT_KEY)) or 1
    line.n = n
    outbox:saveSetting(RemoteSettings.LOG_NEXT_KEY, n + 1)
    local log = outbox:readSetting(RemoteSettings.LOG_KEY)
    if type(log) ~= "table" then log = {} end
    log[#log + 1] = line
    while #log > RemoteSettings.LOG_KEPT do table.remove(log, 1) end
    outbox:saveSetting(RemoteSettings.LOG_KEY, log)
end

--[[--
A value as one string that is the same whenever the value is: a table's keys
sorted, since `pairs` walks them in no fixed order.
--]]--
local function canonical(value)
    -- Quoted, so no string can pass for the separators around it.
    if type(value) == "string" then return string.format("%q", value) end
    if type(value) ~= "table" then return type(value) .. ":" .. tostring(value) end
    local keys = {}
    for k in pairs(value) do keys[#keys + 1] = k end
    table.sort(keys, function(a, b)
        if type(a) ~= type(b) then return type(a) < type(b) end
        return a < b
    end)
    local parts = {}
    for _, k in ipairs(keys) do
        parts[#parts + 1] = canonical(k) .. "=" .. canonical(value[k])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

--[[--
Note when each of this Kindle's own settings changed: compare what the store
holds with what was seen last time, and stamp what differs with `now`.
KOReader records no time for a change, so the plugin looks whenever KOReader
saves its settings, and before every sync; a stamp is the first look that
saw the change, not the tap itself.

The first look only records. Returns the stamps, key → Unix seconds.
--]]--
function RemoteSettings.notice(data, outbox, json, now)
    local seen = outbox:readSetting(RemoteSettings.SEEN_KEY)
    local changed = outbox:readSetting(RemoteSettings.CHANGED_KEY)
    if type(changed) ~= "table" then changed = {} end

    local values = RemoteSettings.snapshot(data, json)
    local current, moved = {}, false
    for key, value in pairs(values) do
        current[key] = canonical(value)
    end
    if type(seen) == "table" then
        for key, form in pairs(current) do
            if seen[key] ~= form then
                changed[key], moved = now, true
                RemoteSettings.log(outbox, { at = now, key = key, source = "kindle", value = values[key] }, json)
            end
        end
        for key in pairs(seen) do
            if current[key] == nil then
                changed[key], moved = now, true
                RemoteSettings.log(outbox, { at = now, key = key, source = "kindle", removed = true }, json)
            end
        end
    end
    if moved or type(seen) ~= "table" then
        outbox:saveSetting(RemoteSettings.SEEN_KEY, current)
        outbox:saveSetting(RemoteSettings.CHANGED_KEY, changed)
        if outbox.flush then outbox:flush() end
    end
    return changed
end

--[[--
Changes the plugin itself made on the Kindle's behalf (`source` says how, e.g.
"book" for the open book's look kept as the default): logged once, stamped
and seen as `notice` would, so its next look finds nothing new and does not
log them a second time as "kindle". Before the first look there is nothing to
compare against, and that look takes them in with the rest.
--]]--
function RemoteSettings.adopt(outbox, entries, json, now, source)
    local seen = outbox:readSetting(RemoteSettings.SEEN_KEY)
    local changed = outbox:readSetting(RemoteSettings.CHANGED_KEY)
    if type(changed) ~= "table" then changed = {} end
    for _, entry in ipairs(entries) do
        RemoteSettings.log(outbox, { at = now, key = entry.key, source = source, value = entry.value }, json)
        if type(seen) == "table" then
            local shown = visible(entry.key, entry.value, json)
            if shown ~= nil then
                seen[entry.key] = canonical(shown)
                changed[entry.key] = now
            end
        end
    end
    if type(seen) == "table" then
        outbox:saveSetting(RemoteSettings.SEEN_KEY, seen)
        outbox:saveSetting(RemoteSettings.CHANGED_KEY, changed)
    end
end

--[[--
The library's changes are not the Kindle's own: seen as they now are, no
stamp. Seen in the form `notice` compares, the secrets left out, or the next
look would take the difference for a change.
--]]--
local function absorb(outbox, applied, json)
    if #applied == 0 then return end
    local seen = outbox:readSetting(RemoteSettings.SEEN_KEY)
    local changed = outbox:readSetting(RemoteSettings.CHANGED_KEY)
    if type(seen) ~= "table" then seen = {} end
    if type(changed) ~= "table" then changed = {} end
    for _, entry in ipairs(applied) do
        local shown
        if not entry.reset then shown = visible(entry.key, entry.value, json) end
        if shown == nil then seen[entry.key] = nil else seen[entry.key] = canonical(shown) end
        changed[entry.key] = nil
    end
    outbox:saveSetting(RemoteSettings.SEEN_KEY, seen)
    outbox:saveSetting(RemoteSettings.CHANGED_KEY, changed)
end

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
One sync, both ways.

1. Note this Kindle's own changes since the last look (`notice`).
2. Send every setting, with when each of its own changes was seen; the
   library answers with what to apply — its queued changes, less those the
   Kindle changed later itself.
3. Apply them here, and report back what changed and every setting now. The
   report is the library's copy, so the Kindle's own changes arrive with it.

The two requests go through `opts.offload`, so KOReader can run them in a
subprocess and a slow gateway never freezes the reader; the writes to the
store happen here, because a change made in a forked child dies with it.

@param store table  `readSetting`, `saveSetting`, `delSetting`, `flush`, and
                    `data`, the table holding every setting
@param opts  table  `outbox`: the plugin's own store, for the changes not yet
                    reported and the stamps; `offload`: `function(task) →
                    task's string | nil if cancelled`; `now`: Unix seconds
@treturn table `{ applied = { … }, reported = bool, report_error = err|nil }`
@treturn table err when nothing could be fetched, so nothing changed
--]]--
function RemoteSettings:sync(store, opts)
    assert(type(opts) == "table" and opts.outbox, "RemoteSettings:sync needs an outbox")
    if type(self.endpoint) ~= "string" or not self.endpoint:match("^https?://") then
        return nil, { code = "not_configured", message = "the library endpoint is not set" }
    end
    local outbox, now = opts.outbox, opts.now or os.time

    local clock = now()
    local changed_at = RemoteSettings.notice(store.data, outbox, self.json, clock)
    -- `now` is this Kindle's clock, so the library can set the stamps against its own.
    local ask = { values = RemoteSettings.snapshot(store.data, self.json), now = clock }
    -- Left out rather than sent empty: an empty Lua table encodes as a list.
    if next(changed_at) ~= nil then ask.changed_at = changed_at end
    local encoded, ask_body = pcall(self.json.encode, ask)
    if not encoded then return nil, { code = "encode", message = tostring(ask_body) } end

    local fetched = self:offloaded(opts.offload, function()
        local plan, err = self:request("POST", ask_body, "/plan")
        return { plan = plan, err = err }
    end)
    if not fetched then return nil, CANCELLED end
    if type(fetched.plan) ~= "table" then
        return nil, fetched.err or { code = "bad_response", message = "the library sent nothing usable" }
    end

    local applied = RemoteSettings.apply(store, fetched.plan.apply)
    if #applied > 0 and store.flush then store:flush() end
    absorb(outbox, applied, self.json)
    for _, entry in ipairs(applied) do
        -- A change applied again, its first report lost, finds its own value in place: nothing changed.
        local after, before
        if not entry.reset then after = canonical(visible(entry.key, entry.value, self.json)) end
        if entry.previous ~= nil then before = canonical(visible(entry.key, entry.previous, self.json)) end
        if after ~= before then
            RemoteSettings.log(outbox, {
                at = clock, key = entry.key, source = "sync",
                value = entry.value, removed = entry.reset, previous = entry.previous,
            }, self.json)
        end
    end

    local unreported = outbox:readSetting(RemoteSettings.OUTBOX_KEY)
    local changes = outgoing(type(unreported) == "table" and unreported or {}, applied)
    if #applied > 0 then outbox:saveSetting(RemoteSettings.OUTBOX_KEY, changes) end
    if outbox.flush then outbox:flush() end

    -- The stamps this report answers; one taken while it is on its way is not.
    local answered = {}
    for key, at in pairs(outbox:readSetting(RemoteSettings.CHANGED_KEY) or {}) do answered[key] = at end
    -- A copy: the store's own list grows if a change is logged while the report is on its way.
    local log = {}
    for i, line in ipairs(outbox:readSetting(RemoteSettings.LOG_KEY) or {}) do log[i] = line end
    local last_sent = #log > 0 and tonumber(log[#log].n) or 0
    local report = {
        values = RemoteSettings.snapshot(store.data, self.json),
        plugin_version = Version.string,
        now = now(),
    }
    if #changes > 0 then report.applied = changes end
    if #log > 0 then report.log = log end

    local ok, body = pcall(self.json.encode, report)
    if not ok then
        return { applied = applied, reported = false, report_error = { code = "encode", message = tostring(body) } }
    end
    local sent = self:offloaded(opts.offload, function()
        local answer, err = self:request("POST", body)
        return { ok = answer ~= nil, err = err }
    end)
    if not sent then return { applied = applied, reported = false, report_error = CANCELLED } end
    if sent.ok then
        -- The library's copy now has everything, the Kindle's own changes
        -- included: nothing is waiting, and no change is newer than it.
        outbox:delSetting(RemoteSettings.OUTBOX_KEY)
        -- Only what went: a change logged while the report was on its way stays for the next one.
        local left = outbox:readSetting(RemoteSettings.LOG_KEY)
        if type(left) == "table" then
            local rest = {}
            for _, line in ipairs(left) do
                if type(line) == "table" and (tonumber(line.n) or 0) > last_sent then rest[#rest + 1] = line end
            end
            outbox:saveSetting(RemoteSettings.LOG_KEY, rest)
        end
        local changed = outbox:readSetting(RemoteSettings.CHANGED_KEY)
        if type(changed) == "table" then
            for key, at in pairs(answered) do
                if changed[key] == at then changed[key] = nil end
            end
            outbox:saveSetting(RemoteSettings.CHANGED_KEY, changed)
        end
        if outbox.flush then outbox:flush() end
    end
    return { applied = applied, reported = sent.ok == true, report_error = sent.err }
end

return RemoteSettings
