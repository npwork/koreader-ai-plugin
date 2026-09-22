--[[--
The book library: ask the gateway what it has, download what this device does
not.

Everything that touches the world is injected — `transport` for HTTP, `fs`
for the filesystem, `json` for decoding — so the whole sync is exercised in
`spec/` against a table of fake files.

    fs.size(path)        -> bytes, or nil when there is no such file
    fs.mkdir(path)       -> ok            (one level; "already there" is ok)
    fs.rename(from, to)  -> ok, err
    fs.remove(path)
--]]--

local Manifest = require("aidict.manifest")
local Plan = require("aidict.plan")
local Version = require("aidict.version")

local Library = {}
Library.__index = Library

-- A book is not a definition: a 30 MB file over a Kindle's radio needs room
-- that would be an absurd wait for a word lookup, so these are the library's
-- own rather than the settings the dictionary uses.
local DOWNLOAD_BLOCK_TIMEOUT = 30
local DOWNLOAD_TOTAL_TIMEOUT = 600

--[[--
Where the library lives.

It used to be worked out from the dictionary's address by swapping the last
path segment, because both mounts sat side by side on the same gateway. They
do not any more: `/koreader-ai` moved to a Cloudflare Worker on 2026-09-22 and
the library stayed on the gateway with the books. A Worker address has no path
segment to swap, so the old rule produced `https://koreader-library` — an
address that is not one, failing at the fetch rather than here.

So it is its own setting now, baked into the package the same way the
dictionary's is. Empty means the device has not been told, and the caller says
so rather than guessing.
--]]--
function Library.endpoint_from(library_endpoint)
    if type(library_endpoint) ~= "string" then return nil end
    if not library_endpoint:match("^https?://[^%s]+$") then return nil end

    -- The query has to stay at the end: the mount takes its key as
    -- `?token=…`, so the baked-in address may carry one.
    local base, query = library_endpoint, ""
    local mark = base:find("?", 1, true)
    if mark then
        query = base:sub(mark)
        base = base:sub(1, mark - 1)
    end
    return base:gsub("/+$", "") .. query
end

function Library.new(opts)
    opts = opts or {}
    assert(type(opts.transport) == "function", "Library needs a transport function")
    assert(type(opts.json) == "table", "Library needs a json codec")
    assert(type(opts.fs) == "table", "Library needs a filesystem")
    return setmetatable({
        endpoint = opts.endpoint,
        api_key = opts.api_key,
        transport = opts.transport,
        json = opts.json,
        fs = opts.fs,
        block_timeout = opts.block_timeout or 10,
        total_timeout = opts.total_timeout or 60,
        user_agent = opts.user_agent or ("koreader-aidict/" .. Version.string),
    }, Library)
end

function Library:url_for(path)
    local base = self.endpoint or ""
    local query = ""
    local mark = base:find("?", 1, true)
    if mark then
        query = base:sub(mark)
        base = base:sub(1, mark - 1)
    end
    base = base:gsub("/+$", "")
    return base .. "/" .. tostring(path or ""):gsub("^/+", "") .. query
end

--[[--
Everything the gateway holds.

@treturn table entries from `manifest.parse`
@treturn table err     { code, message }
--]]--
function Library:manifest()
    if type(self.endpoint) ~= "string" or not self.endpoint:match("^https?://") then
        return nil, { code = "not_configured", message = "the library endpoint is not set" }
    end

    local headers = {
        ["Accept"] = "application/json",
        ["User-Agent"] = self.user_agent,
    }
    if type(self.api_key) == "string" and self.api_key ~= "" then
        headers["Authorization"] = "Bearer " .. self.api_key
    end

    local response, transport_err = self.transport({
        url = self:url_for("manifest"),
        method = "GET",
        headers = headers,
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

    return Manifest.parse(decoded)
end

--- Create `dir` and every folder above it. The manifest carries shelves, and
--- a book two folders deep must not fail because neither folder exists yet.
function Library:_ensure_dir(dir)
    local built = ""
    for segment in dir:gmatch("[^/]+") do
        built = built .. "/" .. segment
        self.fs.mkdir(built)
    end
end

local function parent_of(path)
    return path:match("^(.*)/[^/]*$")
end

--[[--
One book, into place.

It lands under `.part` first and is renamed only once it is whole. A Kindle
that loses Wi-Fi mid-download then leaves nothing the file browser will show
and nothing the next sync will mistake for a finished book.

No key is sent: the URL is presigned, and an Authorization header beside a
signed query is how a signature stops matching.
--]]--
function Library:fetch(entry, target)
    local dir = parent_of(target)
    if dir then self:_ensure_dir(dir) end

    local temporary = target .. ".part"
    local response, transport_err = self.transport({
        url = entry.url,
        method = "GET",
        headers = { ["User-Agent"] = self.user_agent },
        download_to = temporary,
        block_timeout = DOWNLOAD_BLOCK_TIMEOUT,
        total_timeout = DOWNLOAD_TOTAL_TIMEOUT,
    })

    local function fail(message)
        self.fs.remove(temporary)
        return false, message
    end

    if not response then
        return fail(tostring(transport_err or "network unreachable"))
    end
    local status = tonumber(response.status) or 0
    if status < 200 or status >= 300 then
        -- A presigned URL expires; the manifest it came from is the fix, and
        -- saying so beats "HTTP 403" on a Kindle.
        if status == 401 or status == 403 then
            return fail("the download link has expired — sync again")
        end
        return fail("the store answered HTTP " .. status)
    end

    local written = self.fs.size(temporary)
    if written ~= entry.size then
        return fail("got " .. tostring(written or 0) .. " bytes of " .. entry.size)
    end

    local renamed, rename_err = self.fs.rename(temporary, target)
    if not renamed then
        return fail(tostring(rename_err or "could not put the file in place"))
    end
    return true
end

--[[--
Fetch the manifest, work out what is missing, and get it.

@param dir     string  where books go; the manifest's folders are mirrored under it
@param opts    table   { on_progress = function(done, total, path) }
@treturn table report { downloaded, have, failed = { {path, reason}, … }, bytes, dropped }
@treturn table err    { code, message } when the manifest never arrived
--]]--
function Library:sync(dir, opts)
    opts = opts or {}
    local entries, dropped = self:manifest()
    -- Same pair `Manifest.parse` returns, so with no entries the second
    -- value is the failure rather than a count.
    if not entries then return nil, dropped end

    dir = tostring(dir or ""):gsub("/+$", "")
    local plan = Plan.build(entries, function(path)
        return self.fs.size(dir .. "/" .. path)
    end)

    local report = {
        downloaded = 0,
        have = plan.have,
        failed = {},
        bytes = 0,
        dropped = dropped,
        total = #plan.downloads,
    }

    for index, entry in ipairs(plan.downloads) do
        if opts.on_progress then opts.on_progress(index, report.total, entry.path) end
        local ok, reason = self:fetch(entry, dir .. "/" .. entry.path)
        if ok then
            report.downloaded = report.downloaded + 1
            report.bytes = report.bytes + entry.size
        else
            report.failed[#report.failed + 1] = { path = entry.path, reason = reason }
        end
    end

    return report
end

return Library
