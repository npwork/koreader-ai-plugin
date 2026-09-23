local Manifest = require("aidict.manifest")

local function entry(overrides)
    local e = {
        path = "Lem/Solaris.epub",
        size = 4096,
        etag = "d41d8",
        url = "https://r2.test/books/Lem/Solaris.epub?sig=x",
    }
    for k, v in pairs(overrides or {}) do e[k] = v end
    return e
end

describe("manifest", function()
    describe("safe paths", function()
        it("accepts a book and the shelves around it", function()
            assert.is_true(Manifest.is_safe_path("Solaris.epub"))
            assert.is_true(Manifest.is_safe_path("Lem/Solaris.epub"))
            assert.is_true(Manifest.is_safe_path("Фантастика/Лем/Солярис.epub"))
        end)

        it("refuses anything that would climb out of the books folder", function()
            -- The one that matters: this would overwrite the plugin itself.
            assert.is_false(Manifest.is_safe_path("../../koreader/settings.lua"))
            assert.is_false(Manifest.is_safe_path("../x.epub"))
            assert.is_false(Manifest.is_safe_path("/mnt/us/x.epub"))
            assert.is_false(Manifest.is_safe_path("a\\..\\b.epub"))
        end)

        it("refuses what is not a file name", function()
            assert.is_false(Manifest.is_safe_path(""))
            assert.is_false(Manifest.is_safe_path("Lem/"))
            assert.is_false(Manifest.is_safe_path("Lem//Solaris.epub"))
            assert.is_false(Manifest.is_safe_path("./Solaris.epub"))
            assert.is_false(Manifest.is_safe_path("Sol\naris.epub"))
            assert.is_false(Manifest.is_safe_path(nil))
        end)
    end)

    describe("parsing", function()
        it("keeps path, size, etag and url", function()
            local entries = Manifest.parse({ version = 1, files = { entry() } })
            assert.are.same({
                path = "Lem/Solaris.epub",
                size = 4096,
                etag = "d41d8",
                url = "https://r2.test/books/Lem/Solaris.epub?sig=x",
            }, entries[1])
        end)

        it("drops a bad row rather than losing the whole library to it", function()
            local entries, dropped = Manifest.parse({
                files = {
                    entry(),
                    entry({ path = "../escape.epub" }),
                    entry({ size = 0 }),
                    entry({ url = "ftp://nope/x.epub" }),
                    entry({ path = "Borges/Ficciones.epub" }),
                },
            })

            assert.are.equal(2, #entries)
            assert.are.equal(3, dropped)
        end)

        it("names every path it was given, the dropped rows too", function()
            local _, _, named = Manifest.parse({
                files = {
                    entry(),
                    entry({ path = "Borges/Ficciones.epub", size = 0 }),
                    entry({ path = 42 }),
                    "not a row",
                },
            })

            assert.are.same({
                ["Lem/Solaris.epub"] = true,
                ["Borges/Ficciones.epub"] = true,
            }, named)
        end)

        it("treats a body with no file list as a failure", function()
            local entries, err = Manifest.parse({ version = 1 })
            assert.is_nil(entries)
            assert.are.equal("bad_response", err.code)

            assert.is_nil(Manifest.parse("not a table"))
        end)

        it("is empty, not broken, when the library is", function()
            local entries, dropped = Manifest.parse({ version = 1, files = {} })
            assert.are.same({}, entries)
            assert.are.equal(0, dropped)
        end)
    end)
end)
