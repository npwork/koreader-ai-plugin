-- KOReader keeps the look per book (sidecar `copt_*` and `font_face`), falling back to globals of
-- the same key (`cre_font` for the font). The plugin makes it global: defaults overwrite a book's own.

local Look = {}

-- Margins and word spacing are tables; copied so a later change to the book cannot reach the saved default.
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

-- `font_fine_tune` KOReader itself refuses to make a default; `rotation_mode` is how the Kindle is held.
local SKIP = {
    font_fine_tune = true,
    rotation_mode = true,
}

function Look.defaults(options, configurable, font_face)
    local out = {}
    local prefix = options.prefix .. "_"
    for _, tab in ipairs(options) do
        for _, option in ipairs(tab.options or {}) do
            local name = option.name
            local value = configurable[name]
            if name and not SKIP[name] and value ~= nil then
                out[#out + 1] = { key = prefix .. name, value = copy(value) }
            end
        end
    end
    -- The font is not one of the bottom menu's options: ReaderFont keeps it,
    -- and its default is `cre_font`, which a long-press in the font list sets.
    if font_face then
        out[#out + 1] = { key = "cre_font", value = font_face }
    end
    return out
end

-- Only crengine books: a PDF's `kopt` options (crop, zoom, contrast) belong to that one scan.
function Look.is_global(options)
    return type(options) == "table" and options.prefix == "copt"
end

-- Without its own copt_block_rendering_mode, a book already read opens in legacy mode 0
-- (ReaderTypeset:onReadSettings); a new one gets web mode 3.
local NEW_BOOK = { block_rendering_mode = 3 }

-- The default is written in rather than the key dropped, since KOReader does not always fall back
-- (see NEW_BOOK). A nil value means drop the key.
function Look.book_look(options, default)
    local out = {}
    local prefix = options.prefix .. "_"
    for _, tab in ipairs(options) do
        for _, option in ipairs(tab.options or {}) do
            if option.name and not SKIP[option.name] then
                local key = prefix .. option.name
                local value = default(key)
                if value == nil then value = NEW_BOOK[option.name] end
                out[#out + 1] = { key = key, value = copy(value) }
            end
        end
    end
    out[#out + 1] = { key = "font_face", value = copy(default("cre_font")) }
    return out
end

local function same(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return a == b end
    for k, v in pairs(a) do
        if not same(v, b[k]) then return false end
    end
    for k in pairs(b) do
        if a[k] == nil then return false end
    end
    return true
end

-- Updates `seen` in place.
function Look.changed(seen, current)
    local out = {}
    for _, entry in ipairs(current) do
        if not same(seen[entry.key], entry.value) then
            out[#out + 1] = entry
            seen[entry.key] = copy(entry.value)
        end
    end
    return out
end

return Look
