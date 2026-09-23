local Plan = require("aidict.plan")

local function entry(path, size, etag)
    return { path = path, size = size, etag = etag, url = "https://r2.test/" .. path }
end

--- A device holding `files` (path -> bytes) and nothing else.
local function holding(files)
    return function(path) return files[path] end
end

describe("plan", function()
    it("downloads what the device has never seen", function()
        local plan = Plan.build({ entry("A.epub", 10) }, holding({}))

        assert.are.equal(1, #plan.downloads)
        assert.are.equal("A.epub", plan.downloads[1].path)
        assert.are.equal(10, plan.bytes)
        assert.are.equal(0, plan.have)
    end)

    it("leaves alone what is already here, byte for byte", function()
        local plan = Plan.build({ entry("A.epub", 10) }, holding({ ["A.epub"] = 10 }))

        assert.are.equal(0, #plan.downloads)
        assert.are.equal(1, plan.have)
        assert.are.equal(0, plan.bytes)
    end)

    it("re-downloads a file the last sync left half-written", function()
        -- The whole reason this compares sizes instead of asking whether the
        -- file exists: a Kindle that lost Wi-Fi leaves one that does.
        local plan = Plan.build({ entry("A.epub", 10) }, holding({ ["A.epub"] = 4 }))

        assert.are.equal(1, #plan.downloads)
        assert.are.equal(10, plan.bytes)
    end)

    it("re-downloads a book that changed on the server", function()
        local plan = Plan.build({ entry("A.epub", 20) }, holding({ ["A.epub"] = 10 }))
        assert.are.equal(1, #plan.downloads)
    end)

    it("sums only what it will actually fetch", function()
        local plan = Plan.build(
            { entry("A.epub", 10), entry("B.epub", 100), entry("C.epub", 1000) },
            holding({ ["B.epub"] = 100 }))

        assert.are.equal(2, #plan.downloads)
        assert.are.equal(1, plan.have)
        assert.are.equal(1010, plan.bytes)
    end)

    it("has nothing to do with an empty library", function()
        local plan = Plan.build({}, holding({}))
        assert.are.same({ downloads = {}, moves = {}, deletes = {}, have = 0, bytes = 0 }, plan)
    end)

    describe("against what earlier syncs placed", function()
        --- What the plugin put down before: path -> { size, etag }.
        local function placed(records)
            local index = {}
            for path, record in pairs(records) do
                index[path] = { size = record[1], etag = record[2] }
            end
            return index
        end

        local function move_pairs(plan)
            local pairs_ = {}
            for _, move in ipairs(plan.moves) do
                pairs_[#pairs_ + 1] = move.from .. " -> " .. move.to
            end
            table.sort(pairs_)
            return pairs_
        end

        it("moves a book the server moved, by its etag", function()
            local plan = Plan.build(
                { entry("English/Business/x.epub", 10, "e1") },
                holding({ ["English/Fiction/x.epub"] = 10 }),
                placed({ ["English/Fiction/x.epub"] = { 10, "e1" } }))

            assert.are.same({ "English/Fiction/x.epub -> English/Business/x.epub" }, move_pairs(plan))
            assert.are.equal("e1", plan.moves[1].entry.etag)
            assert.are.equal(0, #plan.downloads)
            assert.are.equal(0, #plan.deletes)
            assert.are.equal(0, plan.bytes)
        end)

        -- A store may hand a copied object a new etag; the name and the size
        -- together are still the same book.
        it("moves a book by its name when the etag changed", function()
            local plan = Plan.build(
                { entry("Business/x.epub", 10, "new") },
                holding({ ["Fiction/x.epub"] = 10 }),
                placed({ ["Fiction/x.epub"] = { 10, "old" } }))

            assert.are.same({ "Fiction/x.epub -> Business/x.epub" }, move_pairs(plan))
        end)

        it("moves a renamed book, which only the etag can recognise", function()
            local plan = Plan.build(
                { entry("Fiction/Solaris (1961).epub", 10, "e1") },
                holding({ ["Fiction/Solaris.epub"] = 10 }),
                placed({ ["Fiction/Solaris.epub"] = { 10, "e1" } }))

            assert.are.same({ "Fiction/Solaris.epub -> Fiction/Solaris (1961).epub" }, move_pairs(plan))
        end)

        it("moves a whole folder book by book", function()
            local plan = Plan.build(
                {
                    entry("Archive/Lem/Solaris.epub", 10, "e1"),
                    entry("Archive/Lem/Eden.epub", 20, "e2"),
                    entry("Archive/Lem/Fiasco.epub", 30, "e3"),
                },
                holding({ ["Lem/Solaris.epub"] = 10, ["Lem/Eden.epub"] = 20, ["Lem/Fiasco.epub"] = 30 }),
                placed({
                    ["Lem/Solaris.epub"] = { 10, "e1" },
                    ["Lem/Eden.epub"] = { 20, "e2" },
                    ["Lem/Fiasco.epub"] = { 30, "e3" },
                }))

            assert.are.same({
                "Lem/Eden.epub -> Archive/Lem/Eden.epub",
                "Lem/Fiasco.epub -> Archive/Lem/Fiasco.epub",
                "Lem/Solaris.epub -> Archive/Lem/Solaris.epub",
            }, move_pairs(plan))
            assert.are.equal(0, #plan.downloads)
            assert.are.equal(0, #plan.deletes)
        end)

        it("deletes what it placed and the server no longer lists", function()
            local plan = Plan.build(
                { entry("A.epub", 10, "a") },
                holding({ ["A.epub"] = 10, ["Gone.epub"] = 20 }),
                placed({ ["A.epub"] = { 10, "a" }, ["Gone.epub"] = { 20, "g" } }))

            assert.are.same({ "Gone.epub" }, plan.deletes)
            assert.are.equal(1, plan.have)
        end)

        it("never touches a file the owner put there by hand", function()
            -- Not in the index, so neither a thing to delete nor a book to
            -- move — even with the very name the manifest now wants.
            local plan = Plan.build(
                { entry("Business/x.epub", 10, "e1") },
                holding({ ["Fiction/x.epub"] = 10, ["Mine.pdf"] = 5 }),
                placed({}))

            assert.are.equal(0, #plan.moves)
            assert.are.equal(0, #plan.deletes)
            assert.are.equal(1, #plan.downloads)
        end)

        it("leaves a placed path alone once the owner replaced what is there", function()
            local plan = Plan.build(
                {},
                holding({ ["Gone.epub"] = 99 }),
                placed({ ["Gone.epub"] = { 20, "g" } }))

            assert.are.same({}, plan.deletes)
        end)

        it("forgets a placed book that is no longer on the device", function()
            local plan = Plan.build(
                { entry("Business/x.epub", 10, "e1") },
                holding({}),
                placed({ ["Fiction/x.epub"] = { 10, "e1" }, ["Gone.epub"] = { 20, "g" } }))

            assert.are.equal(0, #plan.moves)
            assert.are.equal(0, #plan.deletes)
            assert.are.equal(1, #plan.downloads)
        end)

        it("downloads on the first run, with nothing placed to move", function()
            local plan = Plan.build(
                { entry("Business/x.epub", 10, "e1"), entry("A.epub", 5, "a") },
                holding({ ["A.epub"] = 5, ["Fiction/x.epub"] = 10 }),
                nil)

            assert.are.equal(1, plan.have)
            assert.are.equal(1, #plan.downloads)
            assert.are.equal(0, #plan.moves)
            assert.are.equal(0, #plan.deletes)
        end)

        it("does not move a book whose size says it is another one", function()
            local plan = Plan.build(
                { entry("Business/x.epub", 12, "e2") },
                holding({ ["Fiction/x.epub"] = 10 }),
                placed({ ["Fiction/x.epub"] = { 10, "e1" } }))

            assert.are.equal(0, #plan.moves)
            assert.are.equal(1, #plan.downloads)
            assert.are.same({ "Fiction/x.epub" }, plan.deletes)
        end)

        it("tells two books of the same name apart by their sizes", function()
            local plan = Plan.build(
                { entry("C/Notes.epub", 20, "n1"), entry("D/Notes.epub", 10, "n2") },
                holding({ ["A/Notes.epub"] = 10, ["B/Notes.epub"] = 20 }),
                placed({ ["A/Notes.epub"] = { 10, "x" }, ["B/Notes.epub"] = { 20, "y" } }))

            assert.are.same({ "A/Notes.epub -> D/Notes.epub", "B/Notes.epub -> C/Notes.epub" },
                move_pairs(plan))
        end)

        it("prefers the etag to the name when both would match", function()
            -- Same name, same size: only the etag says which one moved. The
            -- first entry must not take by name the file the second is.
            local plan = Plan.build(
                { entry("Archive/Notes.epub", 10, "n2") },
                holding({ ["A/Notes.epub"] = 10, ["B/Notes.epub"] = 10 }),
                placed({ ["A/Notes.epub"] = { 10, "n1" }, ["B/Notes.epub"] = { 10, "n2" } }))

            assert.are.same({ "B/Notes.epub -> Archive/Notes.epub" }, move_pairs(plan))
            assert.are.same({ "A/Notes.epub" }, plan.deletes)
        end)

        it("gives each placed file to one book only", function()
            local plan = Plan.build(
                { entry("C/x.epub", 10, "e1"), entry("D/x.epub", 10, "e1") },
                holding({ ["A/x.epub"] = 10 }),
                placed({ ["A/x.epub"] = { 10, "e1" } }))

            assert.are.equal(1, #plan.moves)
            assert.are.equal(1, #plan.downloads)
        end)

        it("does not move a book that is still listed where it is", function()
            local plan = Plan.build(
                { entry("A/x.epub", 10, "e1"), entry("B/x.epub", 10, "e1") },
                holding({ ["A/x.epub"] = 10 }),
                placed({ ["A/x.epub"] = { 10, "e1" } }))

            assert.are.equal(0, #plan.moves)
            assert.are.equal(1, plan.have)
            assert.are.equal("B/x.epub", plan.downloads[1].path)
        end)
    end)
end)
