local Plan = {}

local function basename(path)
    return path:match("([^/]*)$")
end

local function sorted_keys(map)
    local keys = {}
    for key in pairs(map) do keys[#keys + 1] = key end
    table.sort(keys)
    return keys
end

-- index: { [path] = { size, etag } } the plugin placed before; named: every path the manifest
-- named, dropped rows included (nil means only `entries`). size_of(path) -> bytes or nil.
function Plan.build(entries, size_of, index, named)
    entries = entries or {}
    index = index or {}
    local plan = { downloads = {}, moves = {}, deletes = {}, have = 0, bytes = 0 }

    -- A row this device could not use is still the server's book, not one "gone from the server".
    local listed = {}
    for path in pairs(named or {}) do listed[path] = true end
    for _, entry in ipairs(entries) do listed[entry.path] = true end

    -- FAT storage folds case: after a case-only rename the old path looks abandoned, and deleting
    -- it would delete the book. Such a path may be moved from, never deleted.
    local listed_folded = {}
    for path in pairs(listed) do listed_folded[path:lower()] = true end

    -- Only files the plugin placed, still at their recorded size, are moved or deleted; anything
    -- else is the owner's. Sorted so runs agree on the candidate.
    local candidates = {}
    for _, path in ipairs(sorted_keys(index)) do
        local record = index[path]
        if not listed[path] and type(record) == "table" then
            local size = size_of(path)
            if size ~= nil and size == record.size then
                candidates[#candidates + 1] = { path = path, size = size, etag = record.etag }
            end
        end
    end

    local wanted = {}
    for _, entry in ipairs(entries) do
        -- Size, not existence: a download cut off halfway leaves a file that exists and is wrong.
        if size_of(entry.path) == entry.size then
            plan.have = plan.have + 1
        else
            wanted[#wanted + 1] = entry
        end
    end

    -- A moved book is found and moved, keeping its reading state. Every book gets an etag match
    -- before any name match, or one `Notes.epub` could take by name the other's bytes.
    local claimed, moved = {}, {}
    -- `unique`: two candidates of one name and size are ambiguous, so neither is taken and the
    -- book downloads afresh.
    local function claim(entry, matches, unique)
        local found
        for _, candidate in ipairs(candidates) do
            if not claimed[candidate.path] and candidate.size == entry.size
                    and matches(candidate) then
                if not unique then
                    found = candidate
                    break
                end
                if found then return end
                found = candidate
            end
        end
        if found then
            claimed[found.path] = true
            moved[entry] = found.path
        end
    end

    for _, entry in ipairs(wanted) do
        if entry.etag then
            claim(entry, function(candidate) return candidate.etag == entry.etag end)
        end
    end
    for _, entry in ipairs(wanted) do
        if not moved[entry] then
            local name = basename(entry.path)
            claim(entry, function(candidate) return basename(candidate.path) == name end, true)
        end
    end

    for _, entry in ipairs(wanted) do
        if moved[entry] then
            plan.moves[#plan.moves + 1] = { from = moved[entry], to = entry.path, entry = entry }
        else
            plan.downloads[#plan.downloads + 1] = entry
            plan.bytes = plan.bytes + entry.size
        end
    end

    -- Unless the manifest named nothing: an empty library is likelier a gateway on the wrong
    -- bucket than every book deleted, and only one of those mistakes can be undone.
    local deletes = next(listed) ~= nil
    for _, candidate in ipairs(deletes and candidates or {}) do
        if not claimed[candidate.path] and not listed_folded[candidate.path:lower()] then
            plan.deletes[#plan.deletes + 1] = candidate.path
        end
    end

    return plan
end

return Plan
