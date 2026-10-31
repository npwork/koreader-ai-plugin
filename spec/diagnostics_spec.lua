local Diagnostics = require("aidict.diagnostics")

local function read(path, cursor) return Diagnostics.read(path, cursor, "") end

describe("diagnostics", function()
    local path
    local function write(text)
        local file = assert(io.open(path, "wb"))
        file:write(text)
        file:close()
    end
    before_each(function() path = os.tmpname() end)
    after_each(function() os.remove(path) end)

    it("retries the same lines until acknowledged and sends only appended complete lines", function()
        write("first\nsecond\npartial")
        local upload, cursor = read(path)
        assert.are.same({ { offset = 0, text = "first" }, { offset = 6, text = "second" } }, upload.lines)
        assert.are.same(upload, read(path))
        assert.is_nil(read(path, cursor))
        write("first\nsecond\npartial done\n")
        local appended = read(path, cursor)
        assert.are.same({ { offset = 13, text = "partial done" } }, appended.lines)
    end)

    it("starts again after truncation or replacement", function()
        write("original\n")
        local _, cursor = read(path)
        write("new\n")
        assert.are.equal(0, read(path, cursor).lines[1].offset)
        write("replacement that is longer\n")
        assert.are.equal(0, read(path, cursor).lines[1].offset)
    end)

    it("bounds reads and preserves original byte offsets through redaction", function()
        write(string.rep("x\n", Diagnostics.MAX))
        local upload, cursor = read(path)
        assert.are.equal(1024, cursor.offset)
        assert.are.equal(512, #upload.lines)
        local text = Diagnostics.redact("Bearer abc https://x.test/?token=secret&key=other a.b%c", { "a.b%c" })
        assert.is_nil(text:find("secret", 1, true))
        assert.is_nil(text:find("other", 1, true))
        assert.is_nil(text:find("abc", 1, true))
        assert.is_nil(text:find("a.b%c", 1, true))
    end)

    it("detects replacement even when the startup prefix is identical", function()
        local prefix = string.rep("header\n", 50)
        write(prefix .. "old failure\n")
        local _, cursor = read(path)
        write(prefix .. "different failure\n")
        assert.are.equal(0, read(path, cursor).lines[1].offset)
    end)

    it("replaces oversized lines with an acknowledged omission marker", function()
        write(string.rep("x", Diagnostics.MAX + 1))
        local upload, cursor = read(path)
        assert.are.equal("[oversized diagnostic line omitted]", upload.lines[1].text)
        assert.are.equal(Diagnostics.MAX, cursor.offset)
        assert.is_true(cursor.skipping)
    end)

    it("continues beyond an oversized line without uploading fragments", function()
        write(string.rep("x", Diagnostics.MAX + 100) .. "\nnext failure\n")
        local first, cursor = read(path)
        assert.is_table(first)
        local second, next_cursor = read(path, cursor)
        assert.are.equal("next failure", second.lines[#second.lines].text)
        assert.is_nil(read(path, next_cursor))
    end)

    it("skips the old backlog in one read and keeps new stack trace lines", function()
        local old = "09/30/26-23:59:59 INFO old failure\n" .. string.rep("old detail\n", 2000)
        local recent = "10/01/26-00:00:00 ERROR new failure"
        write(old .. recent .. "\nstack traceback:\nframe\n")
        local upload, cursor = Diagnostics.read(path)
        assert.are.equal(recent, upload.lines[1].text)
        assert.are.equal(#old, upload.lines[1].offset)
        assert.are.equal("frame", upload.lines[3].text)
        assert.is_nil(Diagnostics.read(path, cursor))
        write(old .. recent .. "\nstack traceback:\nframe\nappended frame\n")
        assert.are.equal("appended frame", Diagnostics.read(path, cursor).lines[1].text)
    end)

    it("advances past an entirely old log without uploading it", function()
        write("startup header\n [*] Current time: 09/30/26-12:00:00\nold detail\n")
        local upload, cursor = Diagnostics.read(path)
        assert.is_nil(upload)
        assert.is_table(cursor)
        assert.are.equal(0, cursor.remaining)
        assert.is_false(cursor.eligible)
    end)

    it("resets date context after replacement and recognizes startup timestamps", function()
        write("10/02/26-12:00:00 INFO new\n")
        local _, cursor = Diagnostics.read(path)
        write("header\n [*] Current time: 09/30/26-12:00:00\nold detail\n")
        assert.is_nil(Diagnostics.read(path, cursor))
        write("header\n [*] Current time: 10/01/26-00:00:00\nnew detail\n")
        local upload = Diagnostics.read(path)
        assert.are.equal("new detail", upload.lines[2].text)
    end)

    it("redacts credentials from other plugins and earlier key rotations", function()
        for _, text in ipairs({
            'request {"userkey":"private-value","ok":true}',
            "x-auth-key: private-value",
            "Authorization: Basic private-value",
            "Cookie: session=private-value",
            "password=private-value",
            'request {"api_key":"private-value"}',
            "GET https://user:private-value@example.test/path",
            "BEARER private-value",
        }) do
            assert.is_nil(Diagnostics.redact(text):find("private-value", 1, true), text)
        end
        assert.are.equal("request failed: timeout", Diagnostics.redact("request failed: timeout"))
    end)
end)
