--[[--
The update check.

Installing is `kpm`'s job — this only answers "is there something newer on
the channel I follow?", by reading the `version.json` that
`scripts/kpmrepo.py` writes next to each channel's manifest.

Pure Lua: the transport and the JSON codec are injected, exactly as in
`apiclient.lua`.
--]]--

local Version = require("aidict.version")

local Updater = {}
Updater.__index = Updater

Updater.PACKAGE_ID = "koreader-aidict"

--- Parse "1.2.3" into `{1, 2, 3}`; nil when it is not a version.
function Updater.parse(text)
    if type(text) ~= "string" then return nil end
    local major, minor, patch = text:match("^(%d+)%.(%d+)%.(%d+)$")
    if not major then return nil end
    return { tonumber(major), tonumber(minor), tonumber(patch) }
end

--- -1 when a < b, 0 when equal, 1 when a > b.
function Updater.compare(a, b)
    for i = 1, 3 do
        local left = tonumber(a and a[i]) or 0
        local right = tonumber(b and b[i]) or 0
        if left < right then return -1 end
        if left > right then return 1 end
    end
    return 0
end

function Updater.new(opts)
    opts = opts or {}
    assert(type(opts.transport) == "function", "Updater needs a transport function")
    assert(type(opts.json) == "table", "Updater needs a json codec")
    return setmetatable({
        transport = opts.transport,
        json = opts.json,
        package_id = opts.package_id or Updater.PACKAGE_ID,
        current = opts.current or Updater.parse(Version.string),
        block_timeout = opts.block_timeout or 10,
        total_timeout = opts.total_timeout or 20,
    }, Updater)
end

function Updater.url_for(repo_url, channel)
    return (tostring(repo_url or ""):gsub("/+$", "")) .. "/" .. tostring(channel or "stable") .. "/version.json"
end

--[[--
@string repo_url  root of the KPM repository
@string channel   "stable" or "dev"
@treturn table    { available, current, latest, url, sha256, channel }
@treturn table    err { code, message }
--]]--
function Updater:check(repo_url, channel)
    local url = Updater.url_for(repo_url, channel)
    local response, transport_err = self.transport({
        url = url,
        method = "GET",
        headers = { ["Accept"] = "application/json" },
        block_timeout = self.block_timeout,
        total_timeout = self.total_timeout,
    })

    if not response then
        return nil, { code = "network", message = tostring(transport_err or "network unreachable") }
    end
    local status = tonumber(response.status) or 0
    if status < 200 or status >= 300 then
        return nil, { code = "http_error", message = "the repository answered HTTP " .. status, status = status }
    end

    local ok, manifest = pcall(self.json.decode, response.body or "")
    if not ok or type(manifest) ~= "table" or type(manifest.packages) ~= "table" then
        return nil, { code = "bad_response", message = "the repository sent no usable version manifest" }
    end

    local entry = manifest.packages[self.package_id]
    if type(entry) ~= "table" or type(entry.version) ~= "table" then
        return nil, { code = "not_published", message = "this channel does not carry " .. self.package_id }
    end

    local latest = { tonumber(entry.version[1]), tonumber(entry.version[2]), tonumber(entry.version[3]) }
    local function to_string(triple)
        return table.concat({ triple[1] or 0, triple[2] or 0, triple[3] or 0 }, ".")
    end

    return {
        available = Updater.compare(latest, self.current) > 0,
        current = to_string(self.current),
        latest = entry.version_string or to_string(latest),
        url = entry.url,
        sha256 = entry.sha256,
        channel = manifest.channel or channel,
    }
end

return Updater
