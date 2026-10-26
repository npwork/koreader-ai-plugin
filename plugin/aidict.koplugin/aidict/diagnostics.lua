local Diagnostics = {}

Diagnostics.MAX = 64 * 1024
Diagnostics.KEY = "diagnostics_cursor"

function Diagnostics.read(path, cursor)
    local file = io.open(path, "rb")
    if not file then return nil end
    local size = file:seek("end")
    file:seek("set", 0)
    local prefix = file:read(math.min(size, 256)) or ""
    cursor = type(cursor) == "table" and cursor or {}
    local offset = tonumber(cursor.offset) or 0
    if offset > size or prefix:sub(1, #(cursor.prefix or "")) ~= (cursor.prefix or "") then offset = 0 end
    if offset > 0 and type(cursor.anchor) == "string" then
        file:seek("set", math.max(0, offset - #cursor.anchor))
        if file:read(#cursor.anchor) ~= cursor.anchor then offset = 0 end
    end
    file:seek("set", offset)
    local text = file:read(Diagnostics.MAX) or ""
    if #text == 0 then file:close() return nil end
    local lines, position = {}, offset
    local skipping = offset == cursor.offset and cursor.skipping == true
    if skipping then
        local through = text:find("\n", 1, true)
        local consumed = through or #text
        lines[#lines + 1] = { offset = position, text = "[oversized diagnostic line omitted]" }
        position = position + consumed
        text = text:sub(consumed + 1)
        skipping = through == nil
    end
    local complete = text:match("^(.*\n)")
    if complete then
        for line in complete:gmatch("([^\n]*)\n") do
            lines[#lines + 1] = { offset = position, text = line }
            position = position + #line + 1
            if #lines == 512 then break end
        end
    elseif #text == Diagnostics.MAX then
        lines[#lines + 1] = { offset = position, text = "[oversized diagnostic line omitted]" }
        position = position + #text
        skipping = true
    end
    if #lines == 0 then file:close() return nil end
    file:seek("set", math.max(0, position - 256))
    local anchor = file:read(math.min(position, 256)) or ""
    file:close()
    return { source = "crash.log", lines = lines },
        { offset = position, prefix = prefix, anchor = anchor, remaining = size - position, skipping = skipping }
end

function Diagnostics.redact(text, secrets)
    for _, secret in ipairs(secrets or {}) do
        if type(secret) == "string" and secret ~= "" then
            text = text:gsub(secret:gsub("(%W)", "%%%1"), "[redacted]")
        end
    end
    text = text:gsub("([Bb][Ee][Aa][Rr][Ee][Rr]%s+)[^%s\"']+", "%1[redacted]")
    text = text:gsub("([?&][%w_%-]+=)[^%s&#\"']+", "%1[redacted]")
    text = text:gsub("([%a][%w+%.%-]*://)[^/%s@]+@", "%1[redacted]@")
    local names = { "password", "passwd", "secret", "token", "userkey", "api_key", "apikey", "auth", "cookie", "credential" }
    local position = 1
    while true do
        local start, finish, name = text:find("([%w_%-]+)[\"']?%s*[:=]%s*", position)
        if not start then break end
        for _, word in ipairs(names) do
            if name:lower():find(word, 1, true) then return text:sub(1, finish) .. "[redacted]" end
        end
        position = finish + 1
    end
    return text
end

return Diagnostics
