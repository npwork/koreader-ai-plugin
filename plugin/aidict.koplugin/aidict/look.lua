--[[--
A book's look, as the defaults every new book opens with.

KOReader keeps font, size, margins and spacing per book: the bottom menu
changes the open book only, and a new book starts from the defaults. Each
default is one global setting, `<prefix>_<option name>` (`copt_font_size`),
written one at a time by long-pressing a value in that menu. This builds the
whole set from the book that is open, so one tap does what a long-press on
every row would.

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

return Look
