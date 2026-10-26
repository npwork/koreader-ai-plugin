local Diagnostics = require("aidict.diagnostics")

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
        local upload, cursor = Diagnostics.read(path)
        assert.are.same({ { offset = 0, text = "first" }, { offset = 6, text = "second" } }, upload.lines)
        assert.are.same(upload, Diagnostics.read(path))
        assert.is_nil(Diagnostics.read(path, cursor))
        write("first\nsecond\npartial done\n")
        local appended = Diagnostics.read(path, cursor)
        assert.are.same({ { offset = 13, text = "partial done" } }, appended.lines)
    end)

    it("starts again after truncation or replacement", function()
        write("original\n")
        local _, cursor = Diagnostics.read(path)
        write("new\n")
        assert.are.equal(0, Diagnostics.read(path, cursor).lines[1].offset)
        write("replacement that is longer\n")
        assert.are.equal(0, Diagnostics.read(path, cursor).lines[1].offset)
    end)

    it("bounds reads and preserves original byte offsets through redaction", function()
        write(string.rep("x\n", Diagnostics.MAX))
        local upload, cursor = Diagnostics.read(path)
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
        local _, cursor = Diagnostics.read(path)
        write(prefix .. "different failure\n")
        assert.are.equal(0, Diagnostics.read(path, cursor).lines[1].offset)
    end)

    it("replaces oversized lines with an acknowledged omission marker", function()
        write(string.rep("x", Diagnostics.MAX + 1))
        local upload, cursor = Diagnostics.read(path)
        assert.are.equal("[oversized diagnostic line omitted]", upload.lines[1].text)
        assert.are.equal(Diagnostics.MAX, cursor.offset)
        assert.is_true(cursor.skipping)
    end)

    it("continues beyond an oversized line without uploading fragments", function()
        write(string.rep("x", Diagnostics.MAX + 100) .. "\nnext failure\n")
        local first, cursor = Diagnostics.read(path)
        assert.is_table(first)
        local second, next_cursor = Diagnostics.read(path, cursor)
        assert.are.equal("next failure", second.lines[#second.lines].text)
        assert.is_nil(Diagnostics.read(path, next_cursor))
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
