local Look = require("aidict.look")

-- The shape of KOReader's ui/data/creoptions.lua: tabs, each with a list of
-- options, and the prefix every default is saved under.
local function creoptions()
    return {
        prefix = "copt",
        { options = { { name = "rotation_mode" }, { name = "visible_pages" } } },
        { options = { { name = "h_page_margins" }, { name = "t_page_margin" }, { name = "b_page_margin" } } },
        { options = { { name = "line_spacing" } } },
        { options = { { name = "font_size" }, { name = "font_fine_tune" }, { name = "word_spacing" } } },
    }
end

local function as_map(list)
    local map = {}
    for _, entry in ipairs(list) do map[entry.key] = entry.value end
    return map
end

describe("a book's look as defaults", function()
    it("turns every option the book has a value for into its default", function()
        local defaults = Look.defaults(creoptions(), {
            visible_pages = 1,
            h_page_margins = { 20, 20 },
            t_page_margin = 15,
            b_page_margin = 15,
            line_spacing = 100,
            font_size = 22,
            word_spacing = { 95, 75 },
        }, "Literata")

        assert.are.same({
            copt_visible_pages = 1,
            copt_h_page_margins = { 20, 20 },
            copt_t_page_margin = 15,
            copt_b_page_margin = 15,
            copt_line_spacing = 100,
            copt_font_size = 22,
            copt_word_spacing = { 95, 75 },
            cre_font = "Literata",
        }, as_map(defaults))
    end)

    it("keeps the bottom menu's order, with the font last", function()
        local defaults = Look.defaults(creoptions(), { t_page_margin = 15, font_size = 22 }, "Literata")
        local keys = {}
        for _, entry in ipairs(defaults) do keys[#keys + 1] = entry.key end
        assert.are.same({ "copt_t_page_margin", "copt_font_size", "cre_font" }, keys)
    end)

    it("leaves out how the Kindle is held and the size stepper", function()
        local map = as_map(Look.defaults(creoptions(), { rotation_mode = 0, font_fine_tune = 1, font_size = 22 }))
        assert.is_nil(map.copt_rotation_mode)
        assert.is_nil(map.copt_font_fine_tune)
        assert.are.equal(22, map.copt_font_size)
    end)

    it("skips what the book has no value for rather than writing nil", function()
        assert.are.same({}, Look.defaults(creoptions(), {}))
    end)

    it("uses the prefix it is given, so a PDF's options land under kopt", function()
        local map = as_map(Look.defaults({ prefix = "kopt", { options = { { name = "page_margin" } } } },
            { page_margin = 0.1 }))
        assert.are.same({ kopt_page_margin = 0.1 }, map)
    end)

    it("copies margins, so changing the book later leaves the default alone", function()
        local margins = { 20, 20 }
        local map = as_map(Look.defaults(creoptions(), { h_page_margins = margins }))
        margins[1] = 40
        assert.are.same({ 20, 20 }, map.copt_h_page_margins)
    end)
end)

describe("one look for every book", function()
    it("gives every key a book keeps its look under the default to open with, the font included", function()
        local defaults = { copt_h_page_margins = { 20, 20 }, copt_font_size = 22, cre_font = "Bookerly" }
        local look = Look.book_look(creoptions(), function(key) return defaults[key] end)
        assert.are.same({
            { key = "copt_visible_pages" },
            { key = "copt_h_page_margins", value = { 20, 20 } },
            { key = "copt_t_page_margin" },
            { key = "copt_b_page_margin" },
            { key = "copt_line_spacing" },
            { key = "copt_font_size", value = 22 },
            { key = "copt_word_spacing" },
            { key = "font_face", value = "Bookerly" },
        }, look)
        look[2].value[1] = 5
        assert.are.same({ 20, 20 }, defaults.copt_h_page_margins)
    end)

    it("gives only what changed since it last looked, and remembers it", function()
        local seen = {}
        Look.changed(seen, { { key = "copt_font_size", value = 22 }, { key = "copt_h_page_margins", value = { 20, 20 } } })

        local margins = { 20, 20 }
        local changed = Look.changed(seen, {
            { key = "copt_font_size", value = 26 },
            { key = "copt_h_page_margins", value = margins },
        })
        assert.are.same({ { key = "copt_font_size", value = 26 } }, changed)

        margins[1] = 40
        assert.are.same({ { key = "copt_h_page_margins", value = { 40, 20 } } },
            Look.changed(seen, { { key = "copt_font_size", value = 26 }, { key = "copt_h_page_margins", value = margins } }))
    end)
end)
