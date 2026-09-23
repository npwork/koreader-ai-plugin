--[[--
The book sync over a real socket, writing real files.

`spec/library_spec.lua` proves the decisions; this proves the plumbing —
`ltn12.sink.file` streaming a body to disk through the same
`http_transport.lua` that runs on the Kindle, the `.part` rename that keeps a
half-arrived book from looking like a finished one, and a move and a delete
that leave no empty folder behind.
--]]--

local gateway = require("support.gateway")
local helpers = require("support.helpers")

local PORT = tonumber(os.getenv("AIDICT_TEST_PORT") or "8732") + 1

--- The filesystem, for a machine that is not a Kindle: no lfs in the suite,
--- so size comes from a seek and mkdir from the shell.
local function filesystem()
    return {
        size = function(path)
            local file = io.open(path, "rb")
            if not file then return nil end
            local size = file:seek("end")
            file:close()
            return size
        end,
        mkdir = function(path) os.execute("mkdir -p '" .. path .. "' 2>/dev/null") end,
        rename = function(from, to) return os.rename(from, to) end,
        remove = function(path) os.remove(path) end,
        -- Lua 5.1 hands back the exit status; `rmdir` itself is what refuses
        -- a folder that is not empty.
        rmdir = function(path)
            local status = os.execute("rmdir '" .. path .. "' 2>/dev/null")
            return status == 0 or status == true
        end,
    }
end

local function exists(path)
    return os.execute("test -e '" .. path .. "'") == 0
end

local function put(path, text)
    os.execute("mkdir -p \"$(dirname '" .. path .. "')\"")
    local file = io.open(path, "wb")
    file:write(text)
    file:close()
end

local function contents(path)
    local file = io.open(path, "rb")
    if not file then return nil end
    local text = file:read("*a")
    file:close()
    return text
end

describe("library sync, end to end", function()
    local server, Library, transport, dir

    setup(function()
        server = gateway.start(PORT)
        -- Required after the stubs are in place: the transport requires
        -- `logger` at load time.
        Library = require("aidict.library")
        transport = require("aidict.http_transport")
    end)

    teardown(function()
        if server then server.stop() end
    end)

    before_each(function()
        dir = os.tmpname()
        os.remove(dir)
        os.execute("mkdir -p '" .. dir .. "'")
    end)

    after_each(function()
        os.execute("rm -rf '" .. dir .. "'")
    end)

    local function library()
        return Library.new({
            endpoint = server.url("/koreader-library"),
            transport = transport,
            json = helpers.json,
            fs = filesystem(),
        })
    end

    it("downloads the books into their shelves and leaves nothing half-written", function()
        local report = library():sync(dir)

        assert.are.equal(2, report.downloaded)
        assert.are.equal("SOLARIS", contents(dir .. "/Lem/Solaris.epub"):sub(1, 7))
        assert.are.equal("FICCIONES", contents(dir .. "/Borges/Ficciones.epub"))

        -- The third book's manifest size does not match what arrives, so it
        -- is thrown away rather than becoming a truncated file the reader
        -- opens to find empty.
        assert.are.equal(1, #report.failed)
        assert.are.equal("Broken/Half.epub", report.failed[1].path)
        assert.is_nil(contents(dir .. "/Broken/Half.epub"))
        assert.is_nil(contents(dir .. "/Broken/Half.epub.part"))
    end)

    it("does it all again for nothing when the books are already there", function()
        library():sync(dir)
        local report = library():sync(dir)

        assert.are.equal(0, report.downloaded)
        assert.are.equal(2, report.have)
    end)

    it("replaces a book the last run left half-written", function()
        os.execute("mkdir -p '" .. dir .. "/Borges'")
        local file = io.open(dir .. "/Borges/Ficciones.epub", "wb")
        file:write("FIC")
        file:close()

        local report = library():sync(dir)

        assert.are.equal(2, report.downloaded)
        assert.are.equal("FICCIONES", contents(dir .. "/Borges/Ficciones.epub"))
    end)

    it("moves a book the server moved and deletes one it dropped, on disk", function()
        -- An earlier sync put Ficciones under Old/ and a book the gateway no
        -- longer lists under Gone/; the owner's own file sits beside it.
        put(dir .. "/Old/Ficciones.epub", "FICCIONES")
        put(dir .. "/Gone/Dropped.epub", "DROPPED")
        put(dir .. "/Gone/mine.txt", "MINE")
        local index = {
            ["Old/Ficciones.epub"] = { size = 9, etag = "etag-1" },
            ["Gone/Dropped.epub"] = { size = 7, etag = "etag-9" },
        }

        local lib = library()
        local report = lib:sync(dir, { index = index })
        local settled = lib:settle(report, dir, {
            index = index,
            relocate = function(from, to) return os.rename(from, to) end,
            discard = function(path) return os.remove(path) end,
        })

        -- Solaris arrives; Ficciones is moved, not fetched again.
        assert.are.equal(1, report.downloaded)
        assert.are.equal(1, settled.moved)
        assert.are.equal(1, settled.deleted)
        assert.are.equal("FICCIONES", contents(dir .. "/Borges/Ficciones.epub"))
        assert.is_false(exists(dir .. "/Old"))
        assert.is_false(exists(dir .. "/Gone/Dropped.epub"))
        assert.are.equal("MINE", contents(dir .. "/Gone/mine.txt"))
        assert.is_true(exists(dir))
        assert.are.same({
            ["Lem/Solaris.epub"] = { size = 70, etag = "etag-0" },
            ["Borges/Ficciones.epub"] = { size = 9, etag = "etag-1" },
        }, settled.index)
    end)
end)
