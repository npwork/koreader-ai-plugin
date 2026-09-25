--[[--
One look for every book.

KOReader keeps font, size, margins and spacing per book: the bottom menu
changes the open book only, saved in its sidecar as `<prefix>_<option name>`
(`copt_font_size`) and `font_face`, and a book without its own value opens
with the global default, the same key in the reader's settings
(`copt_font_size`, and `cre_font` for the font).

The plugin makes the look global instead: a book opens with its own keys
dropped (`book_keys`), so it takes the defaults, and a change made in it
becomes the default (`defaults`, `changed`).

Takes KOReader's own tables rather than requiring them: `options` is the
reader's config options (`CreOptions`, or `KoptOptions` for PDFs), and
`configurable` is the open document's current values.
--]]--

local Look = {}

-- Margins and word spacing are tables. The default gets its own copy, so
-- changing this book afterwards cannot reach into it before it is saved.
local function copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for k, v in pairs(value) do out[k] = copy(v) end
    return out
end

--[[--
Options that are not part of how a book looks, or not a value at all.

`font_fine_tune` is the ⋮ button's stepper, which KOReader itself refuses to
make a default; `rotation_mode` is how the Kindle is held.
--]]--
local SKIP = {
    font_fine_tune = true,
    rotation_mode = true,
}

--[[--
The global settings to write, in the menu's order.

@param options      table  config options: `{ prefix = "copt", { options = { { name = … }, … } }, … }`
@param configurable table  option name -> the open book's value
@param font_face    string|nil the open book's font, for crengine books
@treturn table list of `{ key = …, value = … }`
--]]--
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

--[[--
Whether a document's look is made global: books read by crengine (EPUB,
FB2…), whose options are `copt`. A PDF's `kopt` options are its crop, zoom,
contrast and reflow, which belong to that one scan, so they stay its own.
--]]--
function Look.is_global(options)
    return type(options) == "table" and options.prefix == "copt"
end

--[[--
The keys a book keeps its own look under, in its sidecar.

@param options table config options, as for `defaults`
@treturn table list of keys
--]]--
function Look.book_keys(options)
    local out = {}
    local prefix = options.prefix .. "_"
    for _, tab in ipairs(options) do
        for _, option in ipairs(tab.options or {}) do
            if option.name and not SKIP[option.name] then out[#out + 1] = prefix .. option.name end
        end
    end
    out[#out + 1] = "font_face"
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

--[[--
What the reader changed in the book since `seen`, as defaults to save; and
`seen` brought up to date.

@param seen    table key -> value, the book's look as last seen
@param current table list of `{ key, value }`, from `defaults`
@treturn table list of `{ key, value }`
--]]--
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
