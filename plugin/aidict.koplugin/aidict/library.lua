--[[--
The book library: ask the gateway what it has, download what this device does
not, and move or delete what the server moved or deleted.

Everything that touches the world is injected — `transport` for HTTP, `fs`
for the filesystem, `json` for decoding — so the whole sync is exercised in
`spec/` against a table of fake files.

    fs.size(path)        -> bytes, or nil when there is no such file
    fs.mkdir(path)       -> ok            (one level; "already there" is ok)
    fs.rename(from, to)  -> ok, err
    fs.remove(path)
    fs.rmdir(path)       -> ok, err       (fails on a folder that is not empty)

It happens in two halves, because the first runs in a forked subprocess.
`sync` fetches the manifest, plans, and downloads — the slow part, which the
reader must be able to give up on. `settle` then runs back in KOReader itself
and does the moves and deletes: they go through KOReader's own history,
collections and book settings, and a child process's changes to those would
be lost with it, or overwritten later by the parent's copy in memory.
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
Fetch the manifest, work out what to do, and do the downloads.

The moves are planned before anything downloads, so a book the server moved
is never fetched again at its new path; they come back in the report, for
`settle` to carry out where KOReader's bookkeeping lives.

@param dir     string  where books go; the manifest's folders are mirrored under it
@param opts    table   {
    on_progress = function(done, total, path),
    index = { [relative path] = { size, etag } }  what earlier syncs placed,
}
@treturn table report {
    downloaded, have, failed = { {path, reason}, … }, bytes, dropped, total,
    moves = { {from, to, entry}, … }, deletes = { path, … },
    listed = { {path, size, etag}, … }  the manifest, for the next index,
    unusable = { path, … }  rows the manifest named that this device dropped,
}
@treturn table err    { code, message } when the manifest never arrived
--]]--
function Library:sync(dir, opts)
    opts = opts or {}
    local entries, dropped, named = self:manifest()
    -- Same pair `Manifest.parse` returns, so with no entries the second
    -- value is the failure rather than a count.
    if not entries then return nil, dropped end

    dir = tostring(dir or ""):gsub("/+$", "")
    local plan = Plan.build(entries, function(path)
        return self.fs.size(dir .. "/" .. path)
    end, opts.index, named)

    -- Without the URLs: the report crosses a pipe out of the subprocess, and
    -- a presigned link is no use to the next sync anyway.
    local listed, usable = {}, {}
    for _, entry in ipairs(entries) do
        listed[#listed + 1] = { path = entry.path, size = entry.size, etag = entry.etag }
        usable[entry.path] = true
    end
    -- Rows this device dropped: still the server's books, so what the
    -- plugin placed at those paths stays its own to move or delete later.
    local unusable = {}
    for path in pairs(named or {}) do
        if not usable[path] then unusable[#unusable + 1] = path end
    end
    table.sort(unusable)

    local report = {
        downloaded = 0,
        have = plan.have,
        failed = {},
        bytes = 0,
        dropped = dropped,
        total = #plan.downloads,
        moves = plan.moves,
        deletes = plan.deletes,
        listed = listed,
        unusable = unusable,
    }

    for position, entry in ipairs(plan.downloads) do
        if opts.on_progress then opts.on_progress(position, report.total, entry.path) end
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

--[[--
Remove the folders a move or a delete left empty, from the deepest up.

Never `dir` itself: the reader picked that folder, and an empty library is
still where the next sync puts books. A folder that is not empty refuses the
`rmdir`, which is exactly the check wanted — the owner's own files, or a
sidecar KOReader kept, keep their folder.
--]]--
function Library:_prune(dir, folders)
    local tried = {}
    local order = {}
    for folder in pairs(folders) do order[#order + 1] = folder end
    table.sort(order, function(a, b) return #a > #b end)

    for _, folder in ipairs(order) do
        while folder and folder ~= "" and not tried[folder] do
            tried[folder] = true
            if not self.fs.rmdir(dir .. "/" .. folder) then break end
            folder = parent_of(folder)
        end
    end
end

--[[--
Carry out the moves and deletes `sync` planned, and work out the next index.

Runs in KOReader rather than the subprocess, with the two acts that touch its
bookkeeping injected:

    ops.relocate(from, to) -> ok, reason   absolute paths; the parent exists
    ops.discard(path)      -> ok, reason

A `reason` of "open" means the book is the one being read: it stays where it
is, and the next sync tries again once it is closed.

@param report table  from `sync`
@param dir    string the same books folder
@param ops    table  { relocate, discard, index = the index `sync` was given }
@treturn table { moved = n, deleted = n,
                 deferred = { {action, from, to}, … },         the open book
                 failed = { {action, from, to, reason}, … },
                 index = { [relative path] = { size, etag } } }
--]]--
function Library:settle(report, dir, ops)
    assert(type(ops) == "table" and type(ops.relocate) == "function"
        and type(ops.discard) == "function", "settle needs relocate and discard")
    dir = tostring(dir or ""):gsub("/+$", "")
    local previous = ops.index or {}
    local result = { moved = 0, deleted = 0, deferred = {}, failed = {}, index = {} }
    local emptied = {}

    -- A move or delete that did not happen keeps its old path in the index,
    -- so the next sync still knows the file is the plugin's to move or
    -- delete; without that it would look like the owner's, and stay for ever.
    local function hold(action, from, to, reason, record)
        result.index[from] = previous[from] or record
        local left = { action = action, from = from, to = to, reason = reason }
        if reason == "open" then
            result.deferred[#result.deferred + 1] = left
        else
            result.failed[#result.failed + 1] = left
        end
    end

    for _, move in ipairs(report.moves or {}) do
        local target = dir .. "/" .. move.to
        local parent = parent_of(target)
        if parent then self:_ensure_dir(parent) end
        local ok, reason = ops.relocate(dir .. "/" .. move.from, target)
        if ok then
            result.moved = result.moved + 1
            emptied[parent_of(move.from) or ""] = true
        else
            hold("move", move.from, move.to, reason,
                { size = move.entry.size, etag = move.entry.etag })
        end
    end

    for _, path in ipairs(report.deletes or {}) do
        local ok, reason = ops.discard(dir .. "/" .. path)
        if ok then
            result.deleted = result.deleted + 1
            emptied[parent_of(path) or ""] = true
        else
            hold("delete", path, nil, reason, { size = self.fs.size(dir .. "/" .. path) })
        end
    end

    -- Checked on disk rather than added up from the report: what is at its
    -- path with the right size now is what this plugin can vouch for, which
    -- covers what was already here, what downloaded and what moved, and
    -- leaves out a download that failed. It also takes in, on the first sync
    -- that keeps an index, the books earlier syncs placed before there was
    -- one.
    for _, entry in ipairs(report.listed or {}) do
        if self.fs.size(dir .. "/" .. entry.path) == entry.size then
            result.index[entry.path] = { size = entry.size, etag = entry.etag }
        end
    end

    -- Still the plugin's own, for a later sync to move or delete: a book
    -- whose row this device dropped, and — when the manifest named nothing,
    -- so nothing was deleted — every book already placed.
    local keep = report.unusable or {}
    if #(report.listed or {}) == 0 and #keep == 0 then
        keep = {}
        for path in pairs(previous) do keep[#keep + 1] = path end
    end
    for _, path in ipairs(keep) do
        local record = previous[path]
        if type(record) == "table" and not result.index[path]
                and self.fs.size(dir .. "/" .. path) == record.size then
            result.index[path] = record
        end
    end

    emptied[""] = nil
    self:_prune(dir, emptied)
    return result
end

return Library
