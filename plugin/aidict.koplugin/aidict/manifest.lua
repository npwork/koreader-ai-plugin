--[[--
The library manifest, as the gateway sends it.

One GET gives the device every file in the bucket; this turns that into a
list it can trust. Pure Lua — the caller decodes the JSON and passes the
table in, exactly as `apiclient.lua` takes its codec as an argument.
--]]--

local Manifest = {}

--[[--
Whether a path from the manifest may be joined onto the download folder.

`..` is the one that matters: a path like `../../koreader/settings.lua` would
have the sync overwrite the plugin's own installation. The gateway refuses
such a key on upload and leaves one out of the manifest if it got into the
bucket some other way — this is the same rule on this side, because a device
that trusts a server to have checked is a device that stops working the day
the server does not.
--]]--
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

--[[--
@param decoded table  the manifest, already decoded from JSON
@treturn table  entries { { path, size, etag, url }, … }
@treturn number how many entries were dropped, or an err table when the
                manifest itself was unusable
@treturn table  { [path] = true } for every row that named a path, usable or
                not — what the server still holds, even where this device
                could not take it
--]]--
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
            -- Not an error: one unusable row should not cost the reader the
            -- other two hundred books.
            dropped = dropped + 1
        end
    end

    return entries, dropped, named
end

return Manifest
