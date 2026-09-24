--[[--
KOReader's settings, set from the library server.

KOReader keeps its global settings in one store (`G_reader_settings`, the file
`settings.reader.lua`): plain key → value. The owner queues changes to it
through the library's MCP (`kindle_settings_set`); "Sync settings" fetches
the queue, writes each change into that store, and reports back what it
changed — with the value each one replaced, so it can be undone — and every
setting the store now holds.

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
Every setting in the store that can travel as JSON.

@param data  table  the store's own table (`G_reader_settings.data`)
@param json  table  the codec, to drop a value it cannot encode
--]]--
function RemoteSettings.snapshot(data, json)
    local values = {}
    for key, value in pairs(type(data) == "table" and data or {}) do
        if is_key(key) and is_plain(value, 0) and pcall(json.encode, value) then
            values[key] = value
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

--[[--
Fetch the queue, apply it, report back.

@param store table  `readSetting`, `saveSetting`, `delSetting`, `flush`, and
                    `data`, the table holding every setting
@treturn table `{ applied = { … }, reported = bool, report_error = err|nil }`
@treturn table err when nothing could be fetched, so nothing changed
--]]--
function RemoteSettings:sync(store)
    if type(self.endpoint) ~= "string" or not self.endpoint:match("^https?://") then
        return nil, { code = "not_configured", message = "the library endpoint is not set" }
    end

    local queue, err = self:request("GET")
    if not queue then return nil, err end

    local applied = RemoteSettings.apply(store, queue.pending)
    if #applied > 0 and store.flush then store:flush() end

    local report = {
        values = RemoteSettings.snapshot(store.data, self.json),
        plugin_version = Version.string,
    }
    -- Left out rather than sent empty: an empty Lua table encodes as an
    -- object, and the list it stands for would not be one.
    if #applied > 0 then report.applied = applied end

    local ok, body = pcall(self.json.encode, report)
    if not ok then
        return { applied = applied, reported = false, report_error = { code = "encode", message = tostring(body) } }
    end
    local answer, report_err = self:request("POST", body)
    return { applied = applied, reported = answer ~= nil, report_error = report_err }
end

return RemoteSettings
