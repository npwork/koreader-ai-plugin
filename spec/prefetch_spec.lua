local Prefetch = require("aidict.prefetch")
local helpers = require("support.helpers")

local function prefetch(settings, max)
    return Prefetch.new({
        settings = settings or helpers.settings({
            endpoint = helpers.ENDPOINT, prefetch = true,
        }),
        max_in_flight = max,
    })
end

describe("prefetch", function()
    describe("whether to fetch ahead at all", function()
        it("does not once it is switched off", function()
            local p = prefetch(helpers.settings({
                endpoint = helpers.ENDPOINT, prefetch = false,
            }))
            local ok, why = p:wanted("fox\1a sentence")
            assert.is_false(ok)
            assert.are.equal(Prefetch.SKIP.DISABLED, why)
        end)

        it("fetches while it is on", function()
            assert.is_true(prefetch():wanted("fox\1a sentence"))
        end)

        it("does not without an endpoint to ask", function()
            local p = prefetch(helpers.settings({ prefetch = true }))
            local ok, why = p:wanted("fox\1a sentence")
            assert.is_false(ok)
            assert.are.equal(Prefetch.SKIP.NOT_CONFIGURED, why)
        end)

        it("does not while there is no Wi-Fi", function()
            local ok, why = prefetch():wanted("fox\1a sentence", { offline = true })
            assert.is_false(ok)
            assert.are.equal(Prefetch.SKIP.OFFLINE, why)
        end)

        it("does not for a word it could not make a key from", function()
            for _, key in ipairs({ "", nil, 42 }) do
                local ok, why = prefetch():wanted(key)
                assert.is_false(ok)
                assert.are.equal(Prefetch.SKIP.NO_WORD, why)
            end
        end)

        it("does not for an answer it already has", function()
            local ok, why = prefetch():wanted("fox\1a sentence", { cached = true })
            assert.is_false(ok)
            assert.are.equal(Prefetch.SKIP.CACHED, why)
        end)

        it("reports the settings before the state of one word", function()
            -- A log full of "already cached" hides the fact that the whole
            -- feature is off.
            local p = prefetch(helpers.settings({
                endpoint = helpers.ENDPOINT, prefetch = false,
            }))
            local _, why = p:wanted("fox\1a sentence", { cached = true, offline = true })
            assert.are.equal(Prefetch.SKIP.DISABLED, why)
        end)
    end)

    describe("what is already in the air", function()
        it("does not start the same word twice", function()
            local p = prefetch()
            p:began("fox\1a sentence")
            local ok, why = p:wanted("fox\1a sentence")
            assert.is_false(ok)
            assert.are.equal(Prefetch.SKIP.IN_FLIGHT, why)
        end)

        it("starts it again once the first one is done", function()
            local p = prefetch()
            p:began("fox\1a sentence")
            p:ended("fox\1a sentence")
            assert.is_true(p:wanted("fox\1a sentence"))
        end)

        it("treats the same word in another passage as another question", function()
            local p = prefetch()
            p:began("fox\1one passage")
            assert.is_true(p:wanted("fox\1another passage"))
        end)

        it("stops at the ceiling — a Kindle has little memory to fork into", function()
            local p = prefetch(nil, 2)
            p:began("a\1x")
            p:began("b\1x")
            local ok, why = p:wanted("c\1x")
            assert.is_false(ok)
            assert.are.equal(Prefetch.SKIP.BUSY, why)
            assert.are.equal(2, p:pending())
        end)

        it("makes room again as they finish", function()
            local p = prefetch(nil, 1)
            p:began("a\1x")
            assert.is_false(p:wanted("b\1x"))
            p:ended("a\1x")
            assert.is_true(p:wanted("b\1x"))
        end)

        it("counts each word once however often it is told", function()
            local p = prefetch()
            assert.is_true(p:began("fox\1x"))
            assert.is_false(p:began("fox\1x"))
            assert.are.equal(1, p:pending())
        end)

        it("ignores the end of something that never began", function()
            local p = prefetch()
            assert.is_false(p:ended("never\1started"))
            assert.are.equal(0, p:pending())
        end)

        it("says which words are still out", function()
            local p = prefetch()
            p:began("fox\1x")
            assert.is_true(p:is_pending("fox\1x"))
            assert.is_false(p:is_pending("dog\1x"))
        end)

        it("forgets everything when the document closes under it", function()
            local p = prefetch()
            p:began("a\1x")
            p:began("b\1x")
            p:clear()
            assert.are.equal(0, p:pending())
            assert.is_true(p:wanted("a\1x"))
        end)
    end)
end)
