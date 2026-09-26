-- Sync sends every setting with when this Kindle changed it, and applies what the library queued;
-- when both sides changed a key, the later change wins.

local Version = require("aidict.version")

local RemoteSettings = {}
RemoteSettings.__index = RemoteSettings

-- The gateway accepts nothing else.
local function is_key(key)
    return type(key) == "string" and key:match("^[A-Za-z_][A-Za-z0-9_]*$") ~= nil and #key <= 100
end

-- JSON-safe both ways: functions, userdata (a JSON null among them) and cycles are not.
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

-- Without metatables: the codec's arrays carry one, and the store must not keep it.
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

-- pending: `{ key, value }` or `{ key, reset = true }`. Returns what changed, with `previous`.
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

-- Other plugins keep secrets here too (kosync's `userkey`, Readwise tokens); they stay on the
-- device, since the report ends up in an MCP client's context.
local SECRET = { "password", "passwd", "secret", "token", "userkey", "api_key", "apikey", "auth", "cookie", "credential" }

local function is_secret(name)
    if type(name) ~= "string" then return false end
    name = name:lower()
    for _, word in ipairs(SECRET) do
        if name:find(word, 1, true) then return true end
    end
    return false
end

local function without_secrets(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do
        if not is_secret(k) then out[k] = without_secrets(v) end
    end
    return out
end

-- `data` is the store's own table (G_reader_settings.data).
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

-- Keeps a `?token=` the address may carry at the end.
function RemoteSettings:url(path)
    local base, query = self.endpoint or "", ""
    local mark = base:find("?", 1, true)
    if mark then
        query = base:sub(mark)
        base = base:sub(1, mark - 1)
    end
    return (base:gsub("/+$", "")) .. path .. query
end

-- nil and `{ code, message }` when it failed.
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

-- In the plugin's own store: changes the library has not heard of yet.
RemoteSettings.OUTBOX_KEY = "settings_unreported"

-- In the plugin's own store: the settings as last seen, and when each changed.
RemoteSettings.SEEN_KEY = "settings_seen"
RemoteSettings.CHANGED_KEY = "settings_changed_at"

-- Oldest first until reported: `{ n, at, key, source, value | removed, previous? }`, `at` in Unix
-- seconds by the Kindle's clock, source "sync", "book" or "kindle". Secrets are never logged.
RemoteSettings.LOG_KEY = "settings_log"

-- Only the newest entries are kept when reports keep failing.
RemoteSettings.LOG_KEPT = 300

-- So a report can drop exactly the entries it sent.
RemoteSettings.LOG_NEXT_KEY = "settings_log_next"

-- nil for a secret, or for what JSON cannot carry.
local function visible(key, value, json)
    return RemoteSettings.snapshot({ [key] = value }, json)[key]
end

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

-- Table keys sorted, since `pairs` walks them in no fixed order.
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

-- KOReader records no time for a change, so a stamp is the first look that saw it, not the tap.
-- The first look only records. Returns key -> Unix seconds.
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

-- Changes the plugin made on the Kindle's behalf: logged once and marked seen, so `notice` does
-- not log them again as "kindle".
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

-- The library's changes are not the Kindle's own: marked seen, unstamped, in `notice`'s form so
-- the next look does not take the difference for a change.
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

-- A change reapplied because its first report was lost keeps the value it first replaced: the
-- store already holds the new one, which is no use for undoing it.
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

-- `offload` may run fn in another process, so the answer crosses as JSON. Nil when cancelled.
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

-- Drops the log lines and stamps the library now holds.
local function delivered(outbox, sent)
    local left = outbox:readSetting(RemoteSettings.LOG_KEY)
    if type(left) == "table" then
        local rest = {}
        for _, line in ipairs(left) do
            if type(line) == "table" and (tonumber(line.n) or 0) > sent.last_logged then rest[#rest + 1] = line end
        end
        outbox:saveSetting(RemoteSettings.LOG_KEY, rest)
    end
    local changed = outbox:readSetting(RemoteSettings.CHANGED_KEY)
    if type(changed) == "table" then
        for key, at in pairs(sent.stamps) do
            if changed[key] == at then changed[key] = nil end
        end
        outbox:saveSetting(RemoteSettings.CHANGED_KEY, changed)
    end
end

-- Copies: the store's lists grow if a change is logged while this is on its way.
local function sending(outbox)
    local stamps, log = {}, {}
    for key, at in pairs(outbox:readSetting(RemoteSettings.CHANGED_KEY) or {}) do stamps[key] = at end
    for i, line in ipairs(outbox:readSetting(RemoteSettings.LOG_KEY) or {}) do log[i] = line end
    return { stamps = stamps, log = log, last_logged = #log > 0 and tonumber(log[#log].n) or 0 }
end

-- A second request (the report) goes only when something was applied or an earlier report was
-- lost. Requests go through opts.offload (a subprocess); store writes happen here, as a forked
-- child's die with it. opts.also(answer) runs in that subprocess and comes back as answer.also.
function RemoteSettings:sync(store, opts)
    assert(type(opts) == "table" and opts.outbox, "RemoteSettings:sync needs an outbox")
    if type(self.endpoint) ~= "string" or not self.endpoint:match("^https?://") then
        return nil, { code = "not_configured", message = "the library endpoint is not set" }
    end
    local outbox, now = opts.outbox, opts.now or os.time

    local clock = now()
    local changed_at = RemoteSettings.notice(store.data, outbox, self.json, clock)
    local sent = sending(outbox)
    -- `now` is this Kindle's clock, so the library can set the stamps against its own.
    local ask = { values = RemoteSettings.snapshot(store.data, self.json), now = clock }
    for key, value in pairs(opts.ask or {}) do ask[key] = value end
    -- Left out rather than sent empty: an empty Lua table encodes as a list.
    if next(changed_at) ~= nil then ask.changed_at = changed_at end
    if #sent.log > 0 then ask.log = sent.log end
    local encoded, ask_body = pcall(self.json.encode, ask)
    if not encoded then return nil, { code = "encode", message = tostring(ask_body) } end

    local fetched = self:offloaded(opts.offload, function()
        local answer, err = self:request("POST", ask_body, "/sync")
        if answer and opts.also then answer.also = opts.also(answer) end
        -- The manifest's presigned links are no use out here, and they are the bulk of the answer.
        if answer then answer.manifest = nil end
        return { plan = answer, err = err }
    end)
    if not fetched then return nil, CANCELLED end
    if type(fetched.plan) ~= "table" then
        return nil, fetched.err or { code = "bad_response", message = "the library sent nothing usable" }
    end
    -- The library keeps what it was sent as this Kindle's settings now.
    delivered(outbox, sent)

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
    -- Nothing here changed since the library was told: its copy is already right.
    if #changes == 0 then return { applied = applied, reported = true, answer = fetched.plan } end

    local report_sent = sending(outbox)
    local report = {
        values = RemoteSettings.snapshot(store.data, self.json),
        plugin_version = Version.string,
        now = now(),
        applied = changes,
    }
    if #report_sent.log > 0 then report.log = report_sent.log end

    local ok, body = pcall(self.json.encode, report)
    if not ok then
        return { applied = applied, reported = false, answer = fetched.plan,
            report_error = { code = "encode", message = tostring(body) } }
    end
    local answered = self:offloaded(opts.offload, function()
        local answer, err = self:request("POST", body, "/settings")
        return { ok = answer ~= nil, err = err }
    end)
    if not answered then
        return { applied = applied, reported = false, report_error = CANCELLED, answer = fetched.plan }
    end
    if answered.ok then
        -- The library's copy now has everything: nothing is waiting, and no change is newer than it.
        outbox:delSetting(RemoteSettings.OUTBOX_KEY)
        delivered(outbox, report_sent)
        if outbox.flush then outbox:flush() end
    end
    return { applied = applied, reported = answered.ok == true, report_error = answered.err, answer = fetched.plan }
end

return RemoteSettings
