local ApiClient = require("aidict.apiclient")
local Lookup = require("aidict.lookup")
local helpers = require("support.helpers")

local GOOD_BODY = helpers.body({ word = "fox", definition = "A wild animal.", model = "m" })

local function lookup(transport, settings, clock)
    return Lookup.new({
        settings = settings or helpers.settings({ endpoint = helpers.ENDPOINT }),
        transport = transport.fn,
        json = helpers.json,
        now = clock and clock.now or nil,
    })
end

describe("lookup", function()
    it("asks the gateway and returns the answer", function()
        local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
        local result, err, cached = lookup(tr):define({ word = "fox" })

        assert.is_nil(err)
        assert.is_false(cached)
        assert.are.equal("A wild animal.", result.definition)
        assert.are.equal(1, tr.calls)
    end)

    it("serves the second lookup of the same word from the cache", function()
        local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
        local l = lookup(tr)
        l:define({ word = "fox", context = "a quick fox" })
        local result, err, cached = l:define({ word = "fox", context = "a quick fox" })

        assert.is_nil(err)
        assert.is_true(cached)
        assert.are.equal("A wild animal.", result.definition)
        assert.are.equal(1, tr.calls)
    end)

    it("treats a different context as a different question", function()
        local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
        local l = lookup(tr)
        l:define({ word = "fox", context = "the animal" })
        l:define({ word = "fox", context = "to fox someone" })
        assert.are.equal(2, tr.calls)
    end)

    it("re-asks after the answer goes stale", function()
        local clock = helpers.clock(1000)
        local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
        local settings = helpers.settings({ endpoint = helpers.ENDPOINT, cache_ttl = 60 })
        local l = lookup(tr, settings, clock)

        l:define({ word = "fox" })
        clock.advance(61)
        local _, _, cached = l:define({ word = "fox" })

        assert.is_false(cached)
        assert.are.equal(2, tr.calls)
    end)

    it("skips the cache when told to", function()
        local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
        local l = lookup(tr)
        l:define({ word = "fox" })
        local _, _, cached = l:define({ word = "fox" }, { skip_cache = true })
        assert.is_false(cached)
        assert.are.equal(2, tr.calls)
    end)

    it("never asks when the cache is disabled, but never caches either", function()
        local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
        local l = lookup(tr, helpers.settings({ endpoint = helpers.ENDPOINT, cache_size = 0 }))
        l:define({ word = "fox" })
        l:define({ word = "fox" })
        assert.are.equal(2, tr.calls)
    end)

    it("does not cache a failure", function()
        local tr = helpers.transport({
            { status = 500, body = "" },
            { status = 200, body = GOOD_BODY },
        })
        local l = lookup(tr)

        local _, err = l:define({ word = "fox" })
        assert.are.equal(ApiClient.ERRORS.SERVER_ERROR, err.code)

        local result = l:define({ word = "fox" })
        assert.are.equal("A wild animal.", result.definition)
        assert.are.equal(2, tr.calls)
    end)

    it("rejects an empty word before it reaches the client", function()
        local tr = helpers.transport({})
        local _, err = lookup(tr):define({ word = "  \n " })
        assert.are.equal(ApiClient.ERRORS.INVALID_REQUEST, err.code)
        assert.are.equal(0, tr.calls)
    end)

    it("normalises the word before caching it", function()
        local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
        local l = lookup(tr)
        l:define({ word = " Fox\n" })
        local _, _, cached = l:define({ word = "fox" })
        assert.is_true(cached)
        assert.are.equal(1, tr.calls)
    end)

    it("sends the language from settings", function()
        local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
        lookup(tr, helpers.settings({ endpoint = helpers.ENDPOINT, target_lang = "de" })):define({ word = "fox" })
        assert.are.equal("de", helpers.json.decode(tr.requests[1].body).target_lang)
    end)

    it("picks up a changed endpoint after reload", function()
        local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
        local settings = helpers.settings({ endpoint = helpers.ENDPOINT })
        local l = lookup(tr, settings)

        settings:set("endpoint", "https://other.test/ai")
        l:reload()
        l:define({ word = "fox" })

        assert.are.equal("https://other.test/ai/define", tr.requests[1].url)
    end)

    it("keeps cached answers across a reload", function()
        local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
        local settings = helpers.settings({ endpoint = helpers.ENDPOINT })
        local l = lookup(tr, settings)

        l:define({ word = "fox" })
        settings:set("block_timeout", 12)
        l:reload()
        local _, _, cached = l:define({ word = "fox" })

        assert.is_true(cached)
        assert.are.equal(1, tr.calls)
    end)

    it("builds the context window from the context_chars setting", function()
        local l = lookup(helpers.transport({}),
            helpers.settings({ endpoint = helpers.ENDPOINT, context_chars = 12 }))
        local context = l:build_context("before text here", "fox", "after text here")
        assert.is_truthy(context:find("fox", 1, true))
        assert.is_true(require("aidict.context").len(context) <= 12)
    end)

    describe("the split used by the reader's subprocess", function()
        it("peek misses before anything was fetched", function()
            local l = lookup(helpers.transport({ { status = 200, body = GOOD_BODY } }))
            assert.is_nil(l:peek({ word = "fox" }))
        end)

        it("fetch returns a plain, serialisable table", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            local outcome = lookup(tr):fetch({ word = "fox" })
            assert.is_true(outcome.ok)
            assert.are.equal("A wild animal.", outcome.result.definition)
            assert.is_nil(outcome.err)
        end)

        it("fetch reports errors in the same shape", function()
            local tr = helpers.transport({ { err = "timeout" } })
            local outcome = lookup(tr):fetch({ word = "fox" })
            assert.is_false(outcome.ok)
            assert.are.equal(ApiClient.ERRORS.TIMEOUT, outcome.err.code)
            assert.is_nil(outcome.result)
        end)

        it("fetch never touches the cache", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            local l = lookup(tr)
            l:fetch({ word = "fox" })
            assert.is_nil(l:peek({ word = "fox" }))
        end)

        it("remember makes the next peek hit", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            local l = lookup(tr)
            local outcome = l:fetch({ word = "fox", context = "a quick fox" })
            l:remember({ word = "fox", context = "a quick fox" }, outcome.result)

            local hit = l:peek({ word = "Fox", context = "A quick fox" })
            assert.are.equal("A wild animal.", hit.definition)
        end)

        it("remember ignores a missing result", function()
            local l = lookup(helpers.transport({}))
            assert.has_no.errors(function() l:remember({ word = "fox" }, nil) end)
            assert.is_nil(l:peek({ word = "fox" }))
        end)
    end)

    describe("cache persistence", function()
        it("survives a dump and restore into a new instance", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            local first = lookup(tr)
            first:define({ word = "fox" })

            local second = lookup(tr)
            second:restore_cache(first:dump_cache())
            local _, _, cached = second:define({ word = "fox" })

            assert.is_true(cached)
            assert.are.equal(1, tr.calls)
        end)

        it("clears on request", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            local l = lookup(tr)
            l:define({ word = "fox" })
            l:clear_cache()
            local _, _, cached = l:define({ word = "fox" })
            assert.is_false(cached)
        end)
    end)
end)
