--[[--
What to do: the manifest against what is already on the device, and against
what the plugin put there before.

The whole decision lives here, in a function that takes a `size_of` rather
than touching the filesystem — so "new", "half-downloaded", "already have
it", "moved on the server" and "gone from the server" are assertions rather
than trips to a Kindle.
--]]--

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

--[[--
@param entries  table    from `manifest.parse`
@param size_of  function (relative path) -> bytes on the device, or nil
@param index    table    { [relative path] = { size, etag } } — what the plugin
                         placed on earlier syncs; nil or empty the first time
@treturn table  {
    downloads = { entry, … },
    moves     = { { from = old path, to = entry.path, entry = entry }, … },
    deletes   = { old path, … },
    have = n, bytes = n,
}
--]]--
function Plan.build(entries, size_of, index)
    entries = entries or {}
    index = index or {}
    local plan = { downloads = {}, moves = {}, deletes = {}, have = 0, bytes = 0 }

    local listed = {}
    for _, entry in ipairs(entries) do listed[entry.path] = true end

    -- Only what this plugin placed is ever moved or deleted, and only while
    -- it is still the file it placed: a path the owner has since filled with
    -- something else of another size is the owner's now, and drops out of
    -- the index rather than being thrown away. Sorted, so two runs over the
    -- same device pick the same candidate.
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
        -- Size, not existence. A download the Kindle lost Wi-Fi halfway
        -- through leaves a file that exists and is wrong, and "it is already
        -- there" would keep it wrong for ever.
        if size_of(entry.path) == entry.size then
            plan.have = plan.have + 1
        else
            wanted[#wanted + 1] = entry
        end
    end

    -- A book the server moved is found where the plugin left it, rather than
    -- fetched again at its new path: moving it keeps the reading position,
    -- the highlights and the history that a fresh download would lose.
    --
    -- The etag is the stronger evidence, so every book gets its chance at an
    -- etag match before any is matched by name — otherwise the first of two
    -- `Notes.epub` could take by name the file the second is the same bytes
    -- as. A name match covers a store that hands a moved object a new etag;
    -- the size check keeps it from pairing two different books that happen
    -- to share a file name.
    local claimed, moved = {}, {}
    local function claim(entry, matches)
        for _, candidate in ipairs(candidates) do
            if not claimed[candidate.path] and candidate.size == entry.size
                    and matches(candidate) then
                claimed[candidate.path] = true
                moved[entry] = candidate.path
                return
            end
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
            claim(entry, function(candidate) return basename(candidate.path) == name end)
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

    -- Whatever the plugin placed that the server no longer lists, and that
    -- no book moved out of, has been deleted there.
    for _, candidate in ipairs(candidates) do
        if not claimed[candidate.path] then
            plan.deletes[#plan.deletes + 1] = candidate.path
        end
    end

    return plan
end

return Plan
