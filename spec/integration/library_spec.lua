--[[--
The book sync over a real socket, writing real files.

`spec/library_spec.lua` proves the decisions; this proves the plumbing —
`ltn12.sink.file` streaming a body to disk through the same
`http_transport.lua` that runs on the Kindle, and the `.part` rename that
keeps a half-arrived book from looking like a finished one.
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
    }
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
end)
