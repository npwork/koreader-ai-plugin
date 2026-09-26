local Manifest = {}

-- `..` could make a sync overwrite the plugin itself. The gateway checks too; this side does not
-- trust it to.
function Manifest.is_safe_path(path)
    if type(path) ~= "string" then return false end
    if path == "" or #path > 1024 then return false end
    if path:sub(1, 1) == "/" or path:sub(-1) == "/" then return false end
    -- A backslash separates folders here even though S3 treats it as an
    -- ordinary character, so `a\..\b` would climb out on arrival.
    if path:find("\\", 1, true) then return false end
    if path:find("%c") then return false end
    for segment in (path .. "/"):gmatch("([^/]*)/") do
        if segment == "" or segment == "." or segment == ".." then return false end
    end
    return true
end

local function usable(entry)
    return type(entry) == "table"
        and Manifest.is_safe_path(entry.path)
        and type(entry.size) == "number" and entry.size > 0
        and type(entry.url) == "string" and entry.url:match("^https?://") ~= nil
end

-- Second value: the dropped count, or an err table when the manifest is unusable. Third: every path
-- a row named, usable or not — what the server still holds.
function Manifest.parse(decoded)
    if type(decoded) ~= "table" or type(decoded.files) ~= "table" then
        return nil, { code = "bad_response", message = "the gateway sent no file list" }
    end

    local entries, dropped, named = {}, 0, {}
    for _, entry in ipairs(decoded.files) do
        if type(entry) == "table" and type(entry.path) == "string" then
            named[entry.path] = true
        end
        if usable(entry) then
            entries[#entries + 1] = {
                path = entry.path,
                size = entry.size,
                etag = type(entry.etag) == "string" and entry.etag or nil,
                url = entry.url,
            }
        else
            -- One unusable row should not cost the reader the other books.
            dropped = dropped + 1
        end
    end

    return entries, dropped, named
end

return Manifest
