local Cache = require("aidict.cache")
local helpers = require("support.helpers")

describe("cache", function()
    local clock

    before_each(function()
        clock = helpers.clock(1000)
    end)

    it("returns what was stored", function()
        local cache = Cache.new({ max_entries = 4, now = clock.now })
        cache:set("k", { definition = "a word" })
        assert.are.same({ definition = "a word" }, cache:get("k"))
    end)

    it("misses on an unknown key", function()
        local cache = Cache.new({ now = clock.now })
        assert.is_nil(cache:get("nope"))
    end)

    it("expires entries once the ttl has passed", function()
        local cache = Cache.new({ ttl = 60, now = clock.now })
        cache:set("k", "v")
        clock.advance(59)
        assert.are.equal("v", cache:get("k"))
        clock.advance(1)
        assert.is_nil(cache:get("k"))
        assert.are.equal(0, cache:count())
    end)

    it("never expires when the ttl is zero", function()
        local cache = Cache.new({ ttl = 0, now = clock.now })
        cache:set("k", "v")
        clock.advance(10 * 365 * 24 * 3600)
        assert.are.equal("v", cache:get("k"))
    end)

    it("evicts the least recently used entry", function()
        local cache = Cache.new({ max_entries = 2, now = clock.now })
        cache:set("a", 1)
        cache:set("b", 2)
        cache:get("a")          -- 'b' is now the oldest
        cache:set("c", 3)
        assert.are.equal(1, cache:get("a"))
        assert.is_nil(cache:get("b"))
        assert.are.equal(3, cache:get("c"))
    end)

    it("does not grow past max_entries", function()
        local cache = Cache.new({ max_entries = 3, now = clock.now })
        for i = 1, 10 do cache:set("k" .. i, i) end
        assert.are.equal(3, cache:count())
    end)

    it("stores nothing when the cache is disabled", function()
        local cache = Cache.new({ max_entries = 0, now = clock.now })
        cache:set("k", "v")
        assert.is_nil(cache:get("k"))
        assert.are.equal(0, cache:count())
    end)

    it("overwrites without duplicating the key", function()
        local cache = Cache.new({ max_entries = 5, now = clock.now })
        cache:set("k", 1)
        cache:set("k", 2)
        assert.are.equal(2, cache:get("k"))
        assert.are.equal(1, cache:count())
    end)

    it("clears everything", function()
        local cache = Cache.new({ now = clock.now })
        cache:set("a", 1)
        cache:clear()
        assert.are.equal(0, cache:count())
        assert.is_nil(cache:get("a"))
    end)

    it("prunes stale entries and keeps the fresh ones", function()
        local cache = Cache.new({ ttl = 100, now = clock.now })
        cache:set("old", 1)
        clock.advance(90)
        cache:set("new", 2)
        clock.advance(20)       -- 'old' is 110s, 'new' is 20s
        assert.are.equal(1, cache:prune())
        assert.are.equal(1, cache:count())
        assert.are.equal(2, cache:get("new"))
    end)

    -- The same word in another paragraph is a different question.
    describe("key", function()
        it("ignores case and surrounding whitespace", function()
            assert.are.equal(Cache.key("Fox", " a sentence "), Cache.key("fox", "a sentence"))
        end)

        it("ignores how the passage was wrapped", function()
            assert.are.equal(Cache.key("fox", "a  sentence"), Cache.key("fox", "a sentence"))
        end)

        it("separates different words", function()
            assert.are_not.equal(Cache.key("fox", ""), Cache.key("dog", ""))
        end)

        it("separates the same word in a different passage", function()
            assert.are_not.equal(
                Cache.key("bank", "he sat on the river bank"),
                Cache.key("bank", "she went to the bank for a loan"))
        end)

        it("separates a word looked up with and without a passage", function()
            assert.are_not.equal(Cache.key("fox", ""), Cache.key("fox", "the quick brown fox"))
        end)

        it("does not let one field bleed into the next", function()
            assert.are_not.equal(Cache.key("a", "b"), Cache.key("ab", ""))
        end)

        it("tolerates nils", function()
            assert.are.equal(Cache.key("fox", nil), Cache.key("fox", ""))
        end)
    end)

    describe("dump and restore", function()
        it("round-trips entries", function()
            local cache = Cache.new({ max_entries = 5, ttl = 100, now = clock.now })
            cache:set("a", { definition = "one" })
            cache:set("b", { definition = "two" })

            local restored = Cache.new({ max_entries = 5, ttl = 100, now = clock.now })
            restored:restore(cache:dump())

            assert.are.equal(2, restored:count())
            assert.are.same({ definition = "one" }, restored:get("a"))
        end)

        it("drops entries that went stale while it was saved", function()
            local cache = Cache.new({ max_entries = 5, ttl = 100, now = clock.now })
            cache:set("a", 1)
            local saved = cache:dump()

            clock.advance(200)
            local restored = Cache.new({ max_entries = 5, ttl = 100, now = clock.now })
            restored:restore(saved)
            assert.are.equal(0, restored:count())
        end)

        it("honours a smaller max_entries on restore", function()
            local cache = Cache.new({ max_entries = 10, now = clock.now })
            for i = 1, 6 do cache:set("k" .. i, i) end

            local restored = Cache.new({ max_entries = 2, now = clock.now })
            restored:restore(cache:dump())
            assert.are.equal(2, restored:count())
            assert.are.equal(6, restored:get("k6"))
        end)

        it("shrugs off junk", function()
            local cache = Cache.new({ now = clock.now })
            assert.has_no.errors(function() cache:restore("not a table") end)
            assert.has_no.errors(function() cache:restore({ "bare string", {} }) end)
            assert.are.equal(0, cache:count())
        end)
    end)
end)
