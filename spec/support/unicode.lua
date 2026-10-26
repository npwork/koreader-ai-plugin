local Unicode = {}

local codes = { ["é"] = 0xE9, ["É"] = 0xC9, ["ï"] = 0xEF, ["Ï"] = 0xCF,
    ["\204\129"] = 0x301, ["“"] = 0x201C, ["”"] = 0x201D, ["—"] = 0x2014, ["🤖"] = 0x1F916 }

function Unicode.codepoint(char)
    return codes[char] or char:byte()
end

function Unicode.category(code)
    if code == 0x301 then return 6 end
    if code >= 65 and code <= 90 or code >= 97 and code <= 122
        or code == 0xE9 or code == 0xC9 or code == 0xEF or code == 0xCF then return 1 end
    return 0
end

function Unicode.lowercase(text)
    return (text:lower():gsub("É", "é"):gsub("Ï", "ï"):gsub("e\204\129", "é"))
end

function Unicode.character(text, at)
    for char, code in pairs(codes) do
        if text:sub(at, at + #char - 1) == char then
            local category = Unicode.category(code)
            return #char, category >= 1 and category <= 8, true
        end
    end
    local char = text:sub(at, at)
    return 1, char:match("^%a$") ~= nil, char:byte() < 128
end

function Unicode.count(text)
    local at, count = 1, 0
    while at <= #text do
        local size, _, valid = Unicode.character(text, at)
        if not valid then return count, false end
        at, count = at + size, count + 1
    end
    return count, true
end

Unicode.options = {
    lower = Unicode.lowercase,
    character = Unicode.character,
}

return Unicode
