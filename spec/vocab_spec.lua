local Vocab = require("aidict.vocab")
local helpers = require("support.helpers")

--- A row as `QUERY` returns it: positional, NULLs as holes.
local function lookup(id, timestamp, over)
    local values = {
        id, "6032", "He was strapped into the seat.", timestamp,
        "strapped", "strap", "en",
        "B000FC1PJI", "A Book", "An Author",
    }
    for index, value in pairs(over or {}) do values[index] = value end
    return values
end

--- `read` over a fixed table, honouring the cursor as the SQL does.
local function reader(rows)
    local asked = {}
    return function(since)
        asked[#asked + 1] = since
        local out = {}
        for _, values in ipairs(rows) do
            if values[4] >= since then out[#out + 1] = values end
        end
        return out
    end, asked
end

local function receipt(created, existing)
    return { status = 200, body = helpers.body({ created = created, existing = existing or 0, skipped = 0 }) }
end

local function vocab(tr, opts)
    opts = opts or {}
    return Vocab.new({
        endpoint = opts.endpoint or "https://ai.test",
        api_key = opts.api_key or "key",
        transport = tr.fn,
        json = helpers.json,
        random = math.random,
    })
end

describe("vocab upload", function()
    it("sends the lookups since the cursor to <endpoint>/vocab", function()
        local tr = helpers.transport({ receipt(2) })
        local read, asked = reader({ lookup("lk-1", 1000), lookup("lk-2", 2000), lookup("lk-3", 3000) })

        local report, err = vocab(tr):upload(read, 2000)

        assert.is_nil(err)
        assert.are.same({ 2000 }, asked)
        assert.are.equal(1, #tr.requests)
        local request = tr.requests[1]
        assert.are.equal("https://ai.test/vocab", request.url)
        assert.are.equal("POST", request.method)
        assert.are.equal("Bearer key", request.headers["Authorization"])

        local body = helpers.json.decode(request.body)
        assert.is_truthy(body.request_id:match(
            "^%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x%x%x%x%x%x%x%x%x%x%x%x$"))
        assert.are.equal(2, #body.rows)
        assert.are.same({
            lookup_id = "lk-2",
            position = "6032",
            usage = "He was strapped into the seat.",
            timestamp = 2000,
            word = "strapped",
            stem = "strap",
            lang = "en",
            book_asin = "B000FC1PJI",
            book_title = "A Book",
            book_authors = "An Author",
        }, body.rows[1])

        assert.are.same({ rows = 2, created = 2, existing = 0, skipped = 0, batches = 1, cursor = 3000 }, report)
    end)

    it("keeps a token carried in the endpoint at the end of the URL", function()
        local tr = helpers.transport({ receipt(1) })
        vocab(tr, { endpoint = "https://ai.test/?token=abc" }):upload(reader({ lookup("lk-1", 1) }), 0)
        assert.are.equal("https://ai.test/vocab?token=abc", tr.requests[1].url)
    end)

    it("goes a batch at a time and advances the cursor with each", function()
        local rows = {}
        for i = 1, Vocab.BATCH * 2 + 5 do rows[i] = lookup("lk-" .. i, i * 10) end
        local tr = helpers.transport({ receipt(Vocab.BATCH), receipt(Vocab.BATCH), receipt(5) })

        local report = vocab(tr):upload(reader(rows), 0)

        assert.are.equal(3, #tr.requests)
        assert.are.equal(5, #helpers.json.decode(tr.requests[3].body).rows)
        assert.are.equal(Vocab.BATCH * 2 + 5, report.created)
        assert.are.equal((Vocab.BATCH * 2 + 5) * 10, report.cursor)
    end)

    it("stops at a failed batch, with the cursor past only what arrived", function()
        local rows = {}
        for i = 1, Vocab.BATCH + 1 do rows[i] = lookup("lk-" .. i, i) end
        local tr = helpers.transport({
            receipt(Vocab.BATCH),
            { status = 502, body = helpers.body({ error = { message = "the word inbox did not answer (TypeError)" } }) },
        })

        local report, err = vocab(tr):upload(reader(rows), 0)

        assert.are.equal("server_error", err.code)
        assert.are.equal("the word inbox did not answer (TypeError)", err.message)
        assert.are.equal(Vocab.BATCH, report.cursor)
        assert.are.equal(1, report.batches)
    end)

    it("sends nothing when there is nothing new", function()
        local tr = helpers.transport({ receipt(0) })
        local report, err = vocab(tr):upload(reader({ lookup("lk-1", 1000) }), 5000)
        assert.is_nil(err)
        assert.are.equal(0, #tr.requests)
        assert.are.equal(5000, report.cursor)
    end)

    it("counts what the server already had", function()
        local tr = helpers.transport({ receipt(1, 1) })
        local report = vocab(tr):upload(reader({ lookup("lk-1", 1000), lookup("lk-2", 2000) }), 1000)
        assert.are.equal(1, report.created)
        assert.are.equal(1, report.existing)
    end)

    it("says the key was refused", function()
        local tr = helpers.transport({ { status = 401, body = helpers.body({ error = { message = "this device's key was not accepted" } }) } })
        local _, err = vocab(tr):upload(reader({ lookup("lk-1", 1) }), 0)
        assert.are.equal("unauthorized", err.code)
        assert.are.equal("this device's key was not accepted", err.message)
    end)

    it("reports a network failure and a timeout apart", function()
        local down = helpers.transport({ { err = "connection refused" } })
        local _, err = vocab(down):upload(reader({ lookup("lk-1", 1) }), 0)
        assert.are.equal("network", err.code)

        local slow = helpers.transport({ { err = "timeout" } })
        _, err = vocab(slow):upload(reader({ lookup("lk-1", 1) }), 0)
        assert.are.equal("timeout", err.code)
    end)

    it("refuses an answer that is not a receipt", function()
        local tr = helpers.transport({ { status = 200, body = "<html>" } })
        local _, err = vocab(tr):upload(reader({ lookup("lk-1", 1) }), 0)
        assert.are.equal("bad_response", err.code)
    end)

    it("says when vocab.db cannot be read, and sends nothing", function()
        local tr = helpers.transport({ receipt(0) })
        local report, err = vocab(tr):upload(function() return nil, "no such file" end, 0)
        assert.are.equal("unreadable", err.code)
        assert.are.equal("no such file", err.message)
        assert.are.equal(0, #tr.requests)
        assert.are.equal(0, report.cursor)
    end)

    it("does not send without an endpoint", function()
        local tr = helpers.transport({ receipt(0) })
        local _, err = vocab(tr, { endpoint = "" }):upload(reader({ lookup("lk-1", 1) }), 0)
        assert.are.equal("not_configured", err.code)
        assert.are.equal(0, #tr.requests)
    end)
end)

describe("vocab pending", function()
    it("counts only what is after the cursor", function()
        local rows = { lookup("lk-1", 2000), lookup("lk-2", 3000), lookup("lk-3", 4000) }
        assert.are.equal(2, Vocab.pending(rows, 2000))
        assert.are.equal(0, Vocab.pending({ lookup("lk-1", 2000) }, 2000))
    end)

    it("counts everything the first time", function()
        assert.are.equal(2, Vocab.pending({ lookup("lk-1", 0), lookup("lk-2", 5) }, 0))
    end)

    it("is zero for nothing", function()
        assert.are.equal(0, Vocab.pending({}, 0))
    end)
end)

describe("vocab row", function()
    it("turns NULLs into empty strings", function()
        -- The driver hands a NULL back as a hole in the row.
        local holes = { "lk-1", "6032", "usage", 1000, "word" }
        holes[10] = "An Author"
        local row = Vocab.row(holes)
        assert.are.equal("", row.stem)
        assert.are.equal("", row.book_asin)
        assert.are.equal("An Author", row.book_authors)
    end)

    it("makes a number of a timestamp the driver hands back as something else", function()
        assert.are.equal(1760000000000, Vocab.row(lookup("lk-1", "1760000000000")).timestamp)
        assert.are.equal(-1, Vocab.row(lookup("lk-1", "yesterday")).timestamp)
    end)
end)
