local Page = require("aidict.page")
local Prefetch = require("aidict.prefetch")

local ANSWER = { word = "fox", definition = "A wild animal of the dog family.", model = "m" }

describe("the AI page", function()
    describe("when the popup opens", function()
        it("shows an answer already in the cache, and says so", function()
            local state = Page.opening({ cached = ANSWER })
            assert.are.equal("answer", state.kind)
            assert.are.equal("cached", state.source)
        end)

        it("does not call an answer cached when it was asked for this lookup", function()
            local state = Page.opening({ cached = ANSWER, fresh = true })
            assert.are.equal("answer", state.kind)
            assert.is_nil(state.source)
        end)

        it("says it is asking while the request is out", function()
            assert.are.equal("asking", Page.opening({ wanted = true }).kind)
        end)

        it("says it is asking when the request went out before the popup", function()
            assert.are.equal("asking", Page.opening({ why = Prefetch.SKIP.IN_FLIGHT }).kind)
        end)

        it("says it is busy when too many words are already in the air", function()
            assert.are.equal("busy", Page.opening({ why = Prefetch.SKIP.BUSY }).kind)
        end)

        it("is not there at all offline or unconfigured", function()
            assert.is_nil(Page.opening({ why = Prefetch.SKIP.OFFLINE }))
            assert.is_nil(Page.opening({ why = Prefetch.SKIP.NOT_CONFIGURED }))
            assert.is_nil(Page.opening({ why = Prefetch.SKIP.NO_WORD }))
        end)
    end)

    describe("when the request comes back", function()
        it("carries the answer", function()
            local state = Page.landed({ ok = true, result = ANSWER })
            assert.are.equal("answer", state.kind)
            assert.are.equal(ANSWER, state.result)
        end)

        it("carries the error", function()
            local state = Page.landed({ ok = false, err = { message = "model is down" } })
            assert.are.equal("failed", state.kind)
            assert.are.equal("model is down", state.err.message)
        end)

        it("fails when there was nothing to read at all", function()
            assert.are.equal("failed", Page.landed(nil).kind)
        end)
    end)

    describe("as a dictionary result", function()
        it("is an HTML entry named AI, marked as the plugin's own", function()
            local entry = Page.entry("fox", { kind = "asking" })
            assert.are.equal("AI", entry.dict)
            assert.are.equal("fox", entry.word)
            assert.is_true(entry.is_html)
            assert.is_true(entry.aidict)
        end)

        it("names the word it is asking about", function()
            local entry = Page.entry("fox", { kind = "asking" })
            assert.is_truthy(entry.definition:find("Asking AI about “fox”", 1, true))
        end)

        it("is the entry itself once it has an answer", function()
            local entry = Page.entry("fox", { kind = "answer", result = ANSWER, source = "cached" })
            assert.is_truthy(entry.definition:find("A wild animal of the dog family.", 1, true))
            assert.is_truthy(entry.definition:find("cached", 1, true))
        end)

        it("does not repeat the word the popup already heads it with", function()
            local entry = Page.entry("fox", { kind = "answer", result = ANSWER })
            assert.is_nil(entry.definition:find("<b>fox</b>", 1, true))
        end)

        it("is headed by the dictionary form once it has an answer", function()
            local read = { word = "reading", lemma = "read", definition = "To look at and interpret." }
            local entry = Page.entry("reading", { kind = "answer", result = read })
            -- The popup's header, which said "reading" over an entry that said
            -- "read" again.
            assert.are.equal("read", entry.word)
            assert.is_nil(entry.definition:find("<b>read</b>", 1, true))
            assert.is_truthy(entry.definition:find("as “reading”", 1, true))
        end)

        it("is headed by the tapped word until then", function()
            assert.are.equal("reading", Page.entry("reading", { kind = "asking" }).word)
            assert.are.equal("reading", Page.entry("reading", { kind = "failed" }).word)
        end)

        it("says what went wrong", function()
            local entry = Page.entry("fox", { kind = "failed", err = { message = "model is down" } })
            assert.is_truthy(entry.definition:find("Model is down.", 1, true))
        end)

        it("says the lookup failed when nothing says why", function()
            local entry = Page.entry("fox", { kind = "failed" })
            assert.is_truthy(entry.definition:find("The lookup failed.", 1, true))
        end)

        it("tells the reader to try again when it was too busy to ask", function()
            local entry = Page.entry("fox", { kind = "busy" })
            assert.is_truthy(entry.definition:find("again", 1, true))
        end)

        it("escapes the word, which came from the book", function()
            local entry = Page.entry("<b>", { kind = "asking" })
            assert.is_nil(entry.definition:find("<b>", 1, true))
        end)
    end)

    describe("finding it among the others", function()
        it("finds it wherever it is", function()
            local results = { { dict = "Oxford" }, Page.entry("fox", { kind = "asking" }) }
            assert.are.equal(2, Page.index_in(results))
        end)

        it("wants KOReader's query line only when it is not the page on top", function()
            local ai = Page.entry("fox", { kind = "asking" })
            assert.is_false(Page.wants_query_line({ ai, { dict = "Oxford" } }))
            assert.is_true(Page.wants_query_line({ { dict = "Oxford" }, ai }))
            assert.is_true(Page.wants_query_line({ { dict = "Oxford" } }))
        end)

        it("finds nothing in a popup it is not in", function()
            assert.is_nil(Page.index_in({ { dict = "Oxford" } }))
            assert.is_nil(Page.index_in(nil))
        end)
    end)
end)
