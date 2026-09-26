-- fs: size(path) -> bytes|nil, mkdir(path) (one level; existing is ok), rename(from, to) -> ok, err,
-- remove(path), rmdir(path) -> ok, err (fails when not empty). `sync` runs in a forked subprocess;
-- `settle` runs in KOReader, since a child's changes to history and collections would be lost.

local Manifest = require("aidict.manifest")
local Plan = require("aidict.plan")
local Version = require("aidict.version")

local Library = {}
Library.__index = Library

-- A 30 MB book over a Kindle's radio needs far more room than a word lookup.
local DOWNLOAD_BLOCK_TIMEOUT = 30
local DOWNLOAD_TOTAL_TIMEOUT = 600

function Library.endpoint_from(library_endpoint)
    if type(library_endpoint) ~= "string" then return nil end
    if not library_endpoint:match("^https?://[^%s]+$") then return nil end

    -- The mount takes its key as `?token=…`, which has to stay at the end.
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
    assert(type(opts.fs) == "table", "Library needs a filesystem")
    return setmetatable({
        transport = opts.transport,
        fs = opts.fs,
        user_agent = opts.user_agent or ("koreader-aidict/" .. Version.string),
    }, Library)
end

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

-- Lands under `.part` and is renamed once whole, so a dropped download leaves nothing that looks
-- finished. No key is sent: an Authorization header beside a presigned query breaks the signature.
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
        -- A presigned URL expires; a fresh manifest is the fix.
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

-- Moves are planned before anything downloads, so a moved book is never fetched again; `settle`
-- carries them out. opts.index is { [relative path] = { size, etag } } from earlier syncs.
function Library:sync(dir, manifest, opts)
    opts = opts or {}
    local entries, dropped, named = Manifest.parse(manifest)
    -- With no entries, the second value is the failure rather than a count.
    if not entries then return nil, dropped end

    dir = tostring(dir or ""):gsub("/+$", "")
    local plan = Plan.build(entries, function(path)
        return self.fs.size(dir .. "/" .. path)
    end, opts.index, named)

    -- Without the URLs: the report crosses a pipe, and a presigned link is no use later anyway.
    local listed, usable = {}, {}
    for _, entry in ipairs(entries) do
        listed[#listed + 1] = { path = entry.path, size = entry.size, etag = entry.etag }
        usable[entry.path] = true
    end
    -- Rows this device dropped are still the server's, so what the plugin placed there stays its own.
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

-- Never `dir` itself. A non-empty folder refuses rmdir, which is the check wanted: the owner's
-- files, or a sidecar KOReader kept, keep their folder.
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

-- ops.relocate(from, to) and ops.discard(path) take absolute paths and return ok, reason; a reason
-- of "open" defers the book to the next sync. ops.index is the index `sync` was given.
function Library:settle(report, dir, ops)
    assert(type(ops) == "table" and type(ops.relocate) == "function"
        and type(ops.discard) == "function", "settle needs relocate and discard")
    dir = tostring(dir or ""):gsub("/+$", "")
    local previous = ops.index or {}
    local result = { moved = 0, deleted = 0, deferred = {}, failed = {}, index = {} }
    local emptied = {}

    -- An undone move or delete keeps its old path in the index, or the next sync would take the
    -- file for the owner's and leave it for ever.
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

    -- Checked on disk, not added up from the report: only a file at its path with the right size
    -- can be vouched for.
    for _, entry in ipairs(report.listed or {}) do
        if self.fs.size(dir .. "/" .. entry.path) == entry.size then
            result.index[entry.path] = { size = entry.size, etag = entry.etag }
        end
    end

    -- Still the plugin's own: books whose rows this device dropped, and every placed book when the
    -- manifest named nothing (so nothing was deleted).
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
