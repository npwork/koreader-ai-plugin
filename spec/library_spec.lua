local Library = require("aidict.library")
local helpers = require("support.helpers")

local BOOKS = "/mnt/us/books"

local function entry(path, size, etag)
    return {
        path = path,
        size = size,
        etag = etag or ("e-" .. path),
        url = "https://r2.test/books/" .. path .. "?sig=x",
    }
end

local function manifest_body(entries)
    return helpers.body({ version = 1, generated_at = "2026-09-21T11:00:00Z", files = entries })
end

--[[--
A transport for the downloads, holding the manifest the spec serves: the
library's answer to Sync carries it, and `library` below hands it over.

A download "arrives" by putting its size into the fake filesystem, which is
what the real one does through `ltn12.sink.file`. `bytes` says how much
actually landed, so a truncated transfer is one number.
--]]--
local function transport(fs, manifest, downloads)
    local tr = { requests = {}, downloads = downloads or {}, sizes = {}, manifest = manifest }
    -- What each URL is supposed to deliver, read off the manifest being
    -- served: a download arrives whole unless a spec says otherwise.
    if type(manifest.body) == "string" then
        local ok, decoded = pcall(helpers.json.decode, manifest.body)
        if ok and type(decoded) == "table" and type(decoded.files) == "table" then
            for _, file in ipairs(decoded.files) do tr.sizes[file.url] = file.size end
        end
    end

    tr.fn = function(request)
        tr.requests[#tr.requests + 1] = request
        local answer = tr.downloads[request.url] or {}
        if answer.err then return nil, answer.err end
        local status = answer.status or 200
        if status >= 200 and status < 300 then
            fs.files[request.download_to] = answer.bytes or tr.sizes[request.url]
        end
        return { status = status, body = "", headers = {} }
    end
    return tr
end

--- A library whose `sync` is handed the manifest `tr` serves, as the answer to Sync would.
local function library(tr, fs)
    local lib = Library.new({ transport = tr.fn, fs = fs })
    local sync = lib.sync
    lib.sync = function(self, dir, opts)
        local ok, decoded = pcall(helpers.json.decode, tr.manifest.body or "")
        return sync(self, dir, ok and decoded or nil, opts)
    end
    return lib
end

describe("library", function()
    describe("finding the mount", function()
        it("uses the address it is given", function()
            assert.are.equal("https://gw.test/koreader-library",
                Library.endpoint_from("https://gw.test/koreader-library"))
        end)

        it("keeps a baked-in key at the end, where a query has to be", function()
            assert.are.equal("https://gw.test/koreader-library?token=abc",
                Library.endpoint_from("https://gw.test/koreader-library?token=abc"))
        end)

        it("ignores a trailing slash", function()
            assert.are.equal("https://gw.test/koreader-library",
                Library.endpoint_from("https://gw.test/koreader-library/"))
            assert.are.equal("https://gw.test/koreader-library?token=abc",
                Library.endpoint_from("https://gw.test/koreader-library/?token=abc"))
        end)

        -- The dictionary's address is no longer a route to the library's: one
        -- is a Worker and the other is the gateway. Handing it this one used
        -- to yield https://koreader-library, which failed at the fetch.
        it("will not take the dictionary's address for the library's", function()
            assert.are.equal("https://koreader-ai.test",
                Library.endpoint_from("https://koreader-ai.test"))
        end)

        it("has nowhere to go without an address", function()
            assert.is_nil(Library.endpoint_from(""))
            assert.is_nil(Library.endpoint_from(nil))
            assert.is_nil(Library.endpoint_from("not a url"))
            assert.is_nil(Library.endpoint_from("ftp://gw.test/koreader-library"))
        end)
    end)

    describe("syncing", function()
        it("downloads what is missing and leaves the rest alone", function()
            local fs = helpers.filesystem({ [BOOKS .. "/B.epub"] = 100 })
            local tr = transport(fs, {
                status = 200,
                body = manifest_body({ entry("A.epub", 10), entry("B.epub", 100) }),
            })

            local report = library(tr, fs):sync(BOOKS)

            assert.are.equal(1, report.downloaded)
            assert.are.equal(1, report.have)
            assert.are.equal(10, report.bytes)
            assert.are.equal(10, fs.files[BOOKS .. "/A.epub"])
        end)

        it("mirrors the shelves, creating every folder on the way", function()
            local fs = helpers.filesystem()
            local tr = transport(fs, {
                status = 200,
                body = manifest_body({ entry("Фантастика/Лем/Солярис.epub", 7) }),
            })

            local report = library(tr, fs):sync(BOOKS)

            assert.are.equal(1, report.downloaded)
            assert.are.equal(7, fs.files[BOOKS .. "/Фантастика/Лем/Солярис.epub"])
            assert.is_true(fs.dirs[BOOKS .. "/Фантастика/Лем"])
            assert.is_true(fs.dirs[BOOKS .. "/Фантастика"])
        end)

        it("sends no key with a download: the URL is already signed", function()
            -- An Authorization header beside a signed query is how a
            -- signature stops matching.
            local fs = helpers.filesystem()
            local tr = transport(fs, { status = 200, body = manifest_body({ entry("A.epub", 10) }) })

            library(tr, fs):sync(BOOKS)

            assert.is_nil(tr.requests[1].headers["Authorization"])
            assert.are.equal("https://r2.test/books/A.epub?sig=x", tr.requests[1].url)
        end)

        it("writes to .part and only then puts the book in place", function()
            local fs = helpers.filesystem()
            local tr = transport(fs, { status = 200, body = manifest_body({ entry("A.epub", 10) }) })

            library(tr, fs):sync(BOOKS)

            assert.are.equal(BOOKS .. "/A.epub.part", tr.requests[1].download_to)
            assert.is_nil(fs.files[BOOKS .. "/A.epub.part"])
            assert.are.equal(10, fs.files[BOOKS .. "/A.epub"])
        end)

        it("throws away a truncated download instead of leaving half a book", function()
            local fs = helpers.filesystem()
            local tr = transport(fs,
                { status = 200, body = manifest_body({ entry("A.epub", 10) }) },
                { ["https://r2.test/books/A.epub?sig=x"] = { status = 200, bytes = 4 } })

            local report = library(tr, fs):sync(BOOKS)

            assert.are.equal(0, report.downloaded)
            assert.are.equal(1, #report.failed)
            assert.are.equal("A.epub", report.failed[1].path)
            assert.is_nil(fs.files[BOOKS .. "/A.epub"])
            assert.is_nil(fs.files[BOOKS .. "/A.epub.part"])
        end)

        it("says an expired link is expired, not 403", function()
            local fs = helpers.filesystem()
            local tr = transport(fs,
                { status = 200, body = manifest_body({ entry("A.epub", 10) }) },
                { ["https://r2.test/books/A.epub?sig=x"] = { status = 403 } })

            local report = library(tr, fs):sync(BOOKS)

            assert.is_truthy(report.failed[1].reason:find("expired"))
        end)

        it("keeps going after one book fails", function()
            local fs = helpers.filesystem()
            local tr = transport(fs,
                { status = 200, body = manifest_body({ entry("A.epub", 10), entry("B.epub", 20) }) },
                { ["https://r2.test/books/A.epub?sig=x"] = { err = "connection reset" } })

            local report = library(tr, fs):sync(BOOKS)

            assert.are.equal(1, report.downloaded)
            assert.are.equal(1, #report.failed)
            assert.are.equal(20, fs.files[BOOKS .. "/B.epub"])
        end)

        it("reports progress a book at a time", function()
            local fs = helpers.filesystem()
            local tr = transport(fs, {
                status = 200,
                body = manifest_body({ entry("A.epub", 10), entry("B.epub", 20) }),
            })

            local seen = {}
            library(tr, fs):sync(BOOKS, {
                on_progress = function(done, total, path)
                    seen[#seen + 1] = done .. "/" .. total .. " " .. path
                end,
            })

            assert.are.same({ "1/2 A.epub", "2/2 B.epub" }, seen)
        end)

        it("refuses a manifest that is not one", function()
            local fs = helpers.filesystem()
            local report, err = library(transport(fs, { status = 200, body = "" }), fs):sync(BOOKS)

            assert.is_nil(report)
            assert.are.equal("bad_response", err.code)
        end)

        it("tolerates a trailing slash on the books folder", function()
            local fs = helpers.filesystem()
            local tr = transport(fs, { status = 200, body = manifest_body({ entry("A.epub", 10) }) })

            library(tr, fs):sync(BOOKS .. "/")

            assert.are.equal(10, fs.files[BOOKS .. "/A.epub"])
        end)
    end)

    --[[--
    The moves and deletes, planned in `sync` and carried out by `settle`.

    `relocate` and `discard` stand in for KOReader's own move and delete;
    here they move and remove entries in the fake filesystem, and refuse the
    one path a spec calls open.
    --]]--
    describe("mirroring moves and deletes", function()
        local function ops(fs, index, open)
            local calls = {}
            return {
                index = index,
                calls = calls,
                relocate = function(from, to)
                    calls[#calls + 1] = "relocate " .. from .. " -> " .. to
                    if from == open then return false, "open" end
                    return fs.rename(from, to)
                end,
                discard = function(path)
                    calls[#calls + 1] = "discard " .. path
                    if path == open then return false, "open" end
                    if fs.files[path] == nil then return false, "no such file" end
                    fs.remove(path)
                    return true
                end,
            }
        end

        local function served(fs, entries)
            return transport(fs, { status = 200, body = manifest_body(entries) })
        end

        it("plans a move instead of downloading the book again", function()
            local fs = helpers.filesystem({ [BOOKS .. "/Fiction/x.epub"] = 10 })
            local tr = served(fs, { entry("Business/x.epub", 10, "e1") })

            local report = library(tr, fs):sync(BOOKS, {
                index = { ["Fiction/x.epub"] = { size = 10, etag = "e1" } },
            })

            assert.are.equal(0, #tr.requests)
            assert.are.equal(0, report.total)
            assert.are.equal(1, #report.moves)
            assert.are.equal("Fiction/x.epub", report.moves[1].from)
            assert.are.equal("Business/x.epub", report.moves[1].to)
            -- The move is settle's, not the subprocess's.
            assert.are.equal(10, fs.files[BOOKS .. "/Fiction/x.epub"])
        end)

        it("reports the manifest without its links", function()
            local fs = helpers.filesystem()
            local report = library(served(fs, { entry("A.epub", 10, "a") }), fs):sync(BOOKS)

            assert.are.same({ { path = "A.epub", size = 10, etag = "a" } }, report.listed)
        end)

        it("moves the book, into folders made for it, and drops the folder it left", function()
            local fs = helpers.filesystem({ [BOOKS .. "/English/Fiction/x.epub"] = 10 })
            local index = { ["English/Fiction/x.epub"] = { size = 10, etag = "e1" } }
            local lib = library(served(fs, { entry("English/Business/x.epub", 10, "e1") }), fs)

            local report = lib:sync(BOOKS, { index = index })
            local settled = lib:settle(report, BOOKS, ops(fs, index))

            assert.are.equal(1, settled.moved)
            assert.are.equal(10, fs.files[BOOKS .. "/English/Business/x.epub"])
            assert.is_nil(fs.files[BOOKS .. "/English/Fiction/x.epub"])
            assert.is_true(fs.dirs[BOOKS .. "/English/Business"])
            assert.are.same({ BOOKS .. "/English/Fiction" }, fs.rmdirs)
            assert.are.same({ ["English/Business/x.epub"] = { size = 10, etag = "e1" } }, settled.index)
        end)

        it("hands relocate and discard absolute paths", function()
            local fs = helpers.filesystem({ [BOOKS .. "/A/x.epub"] = 10, [BOOKS .. "/Gone.epub"] = 5 })
            local index = { ["A/x.epub"] = { size = 10, etag = "e1" }, ["Gone.epub"] = { size = 5 } }
            local lib = library(served(fs, { entry("B/x.epub", 10, "e1") }), fs)
            local o = ops(fs, index)

            lib:settle(lib:sync(BOOKS, { index = index }), BOOKS, o)

            assert.are.same({
                "relocate " .. BOOKS .. "/A/x.epub -> " .. BOOKS .. "/B/x.epub",
                "discard " .. BOOKS .. "/Gone.epub",
            }, o.calls)
        end)

        it("deletes what the server deleted, and forgets it", function()
            local fs = helpers.filesystem({
                [BOOKS .. "/Old/Gone.epub"] = 20,
                [BOOKS .. "/A.epub"] = 10,
            })
            local index = { ["Old/Gone.epub"] = { size = 20, etag = "g" }, ["A.epub"] = { size = 10, etag = "a" } }
            local lib = library(served(fs, { entry("A.epub", 10, "a") }), fs)

            local settled = lib:settle(lib:sync(BOOKS, { index = index }), BOOKS, ops(fs, index))

            assert.are.equal(1, settled.deleted)
            assert.is_nil(fs.files[BOOKS .. "/Old/Gone.epub"])
            assert.are.same({ BOOKS .. "/Old" }, fs.rmdirs)
            assert.are.same({ ["A.epub"] = { size = 10, etag = "a" } }, settled.index)
        end)

        it("keeps, and still owns, a book whose row this device dropped", function()
            local fs = helpers.filesystem({ [BOOKS .. "/A.epub"] = 10, [BOOKS .. "/Odd.epub"] = 20 })
            local index = { ["A.epub"] = { size = 10, etag = "a" }, ["Odd.epub"] = { size = 20, etag = "o" } }
            local odd = entry("Odd.epub", 20, "o")
            odd.url = "ftp://nope/Odd.epub"
            local lib = library(served(fs, { entry("A.epub", 10, "a"), odd }), fs)

            local report = lib:sync(BOOKS, { index = index })
            local settled = lib:settle(report, BOOKS, ops(fs, index))

            assert.are.equal(1, report.dropped)
            assert.are.same({}, report.deletes)
            assert.are.equal(20, fs.files[BOOKS .. "/Odd.epub"])
            assert.are.same(index, settled.index)
        end)

        it("deletes nothing when the server lists nothing", function()
            -- A gateway pointed at the wrong bucket, not an owner who deleted
            -- every book: keep the books, and keep owning them.
            local fs = helpers.filesystem({ [BOOKS .. "/A.epub"] = 10 })
            local index = { ["A.epub"] = { size = 10, etag = "a" } }
            local lib = library(served(fs, {}), fs)

            local report = lib:sync(BOOKS, { index = index })
            local settled = lib:settle(report, BOOKS, ops(fs, index))

            assert.are.same({}, report.deletes)
            assert.are.equal(10, fs.files[BOOKS .. "/A.epub"])
            assert.are.equal(0, settled.deleted)
            assert.are.same(index, settled.index)
        end)

        it("never touches what the owner put in the folder", function()
            local fs = helpers.filesystem({
                [BOOKS .. "/Mine/notes.pdf"] = 3,
                [BOOKS .. "/Mine/Gone.epub"] = 20,
                [BOOKS .. "/A.epub"] = 10,
            })
            local index = { ["Mine/Gone.epub"] = { size = 20, etag = "g" } }
            local lib = library(served(fs, { entry("A.epub", 10, "a") }), fs)

            local settled = lib:settle(lib:sync(BOOKS, { index = index }), BOOKS, ops(fs, index))

            assert.are.equal(1, settled.deleted)
            assert.are.equal(3, fs.files[BOOKS .. "/Mine/notes.pdf"])
            -- Its folder is not empty, so it stays.
            assert.are.same({}, fs.rmdirs)
            assert.are.same({ ["A.epub"] = { size = 10, etag = "a" } }, settled.index)
        end)

        it("removes every folder a whole-folder move emptied, but never the library itself", function()
            local fs = helpers.filesystem({
                [BOOKS .. "/Lem/Novels/Solaris.epub"] = 10,
                [BOOKS .. "/Lem/Novels/Eden.epub"] = 20,
            })
            local index = {
                ["Lem/Novels/Solaris.epub"] = { size = 10, etag = "s" },
                ["Lem/Novels/Eden.epub"] = { size = 20, etag = "e" },
            }
            local lib = library(served(fs, {
                entry("Archive/Solaris.epub", 10, "s"),
                entry("Archive/Eden.epub", 20, "e"),
            }), fs)

            local settled = lib:settle(lib:sync(BOOKS, { index = index }), BOOKS, ops(fs, index))

            assert.are.equal(2, settled.moved)
            assert.are.same({ BOOKS .. "/Lem/Novels", BOOKS .. "/Lem" }, fs.rmdirs)
        end)

        it("does not try to remove the library when a book at its top is deleted", function()
            local fs = helpers.filesystem({ [BOOKS .. "/Gone.epub"] = 20, [BOOKS .. "/A.epub"] = 10 })
            local index = { ["Gone.epub"] = { size = 20 } }
            local lib = library(served(fs, { entry("A.epub", 10, "a") }), fs)

            local settled = lib:settle(lib:sync(BOOKS, { index = index }), BOOKS, ops(fs, index))

            assert.are.equal(1, settled.deleted)
            assert.are.same({}, fs.rmdirs)
        end)

        it("leaves the open book where it is, and keeps it for the next sync", function()
            local fs = helpers.filesystem({ [BOOKS .. "/Fiction/x.epub"] = 10 })
            local index = { ["Fiction/x.epub"] = { size = 10, etag = "e1" } }
            local lib = library(served(fs, { entry("Business/x.epub", 10, "e1") }), fs)

            local settled = lib:settle(lib:sync(BOOKS, { index = index }), BOOKS,
                ops(fs, index, BOOKS .. "/Fiction/x.epub"))

            assert.are.equal(0, settled.moved)
            assert.are.same({ { action = "move", from = "Fiction/x.epub", to = "Business/x.epub", reason = "open" } },
                settled.deferred)
            assert.are.same({}, settled.failed)
            assert.are.equal(10, fs.files[BOOKS .. "/Fiction/x.epub"])
            assert.are.same({}, fs.rmdirs)
            assert.are.same({ ["Fiction/x.epub"] = { size = 10, etag = "e1" } }, settled.index)

            -- Closed now: the next sync finds it where it was left, and moves it.
            local again = library(served(fs, { entry("Business/x.epub", 10, "e1") }), fs)
            local next_settled = again:settle(again:sync(BOOKS, { index = settled.index }), BOOKS,
                ops(fs, settled.index))
            assert.are.equal(1, next_settled.moved)
            assert.are.equal(10, fs.files[BOOKS .. "/Business/x.epub"])
        end)

        it("keeps the open book the server deleted until it is closed", function()
            local fs = helpers.filesystem({ [BOOKS .. "/Gone.epub"] = 20, [BOOKS .. "/A.epub"] = 10 })
            local index = { ["Gone.epub"] = { size = 20, etag = "g" } }
            local lib = library(served(fs, { entry("A.epub", 10, "a") }), fs)

            local settled = lib:settle(lib:sync(BOOKS, { index = index }), BOOKS,
                ops(fs, index, BOOKS .. "/Gone.epub"))

            assert.are.equal(0, settled.deleted)
            assert.are.equal("delete", settled.deferred[1].action)
            assert.are.same({ size = 20, etag = "g" }, settled.index["Gone.epub"])
        end)

        it("counts a move that failed apart from the open book, and tries it again next time", function()
            local fs = helpers.filesystem({ [BOOKS .. "/A/x.epub"] = 10 })
            local index = { ["A/x.epub"] = { size = 10, etag = "e1" } }
            local lib = library(served(fs, { entry("B/x.epub", 10, "e1") }), fs)
            local o = ops(fs, index)
            o.relocate = function() return false, "read-only file system" end

            local settled = lib:settle(lib:sync(BOOKS, { index = index }), BOOKS, o)

            assert.are.same({}, settled.deferred)
            assert.are.equal("read-only file system", settled.failed[1].reason)
            assert.are.same(index, settled.index)
        end)

        it("indexes what is here, what arrived and what moved — not what failed", function()
            local fs = helpers.filesystem({ [BOOKS .. "/Have.epub"] = 1, [BOOKS .. "/Old/M.epub"] = 2 })
            local index = { ["Old/M.epub"] = { size = 2, etag = "m" } }
            local tr = transport(fs,
                { status = 200, body = manifest_body({
                    entry("Have.epub", 1, "h"),
                    entry("New/M.epub", 2, "m"),
                    entry("Got.epub", 3, "g"),
                    entry("Lost.epub", 4, "l"),
                }) },
                { ["https://r2.test/books/Lost.epub?sig=x"] = { err = "connection reset" } })
            local lib = library(tr, fs)

            local settled = lib:settle(lib:sync(BOOKS, { index = index }), BOOKS, ops(fs, index))

            assert.are.same({
                ["Have.epub"] = { size = 1, etag = "h" },
                ["New/M.epub"] = { size = 2, etag = "m" },
                ["Got.epub"] = { size = 3, etag = "g" },
            }, settled.index)
        end)

        it("adopts, on the first run, the books earlier syncs left without an index", function()
            local fs = helpers.filesystem({ [BOOKS .. "/A.epub"] = 10 })
            local lib = library(served(fs, { entry("A.epub", 10, "a") }), fs)

            local settled = lib:settle(lib:sync(BOOKS, { index = nil }), BOOKS, ops(fs, nil))

            assert.are.same({ ["A.epub"] = { size = 10, etag = "a" } }, settled.index)
        end)
    end)
end)
