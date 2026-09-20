local Reqid = require("aidict.reqid")

-- The gateway keeps a client-sent id only if it matches this; anything else it
-- replaces, and the two sides stop agreeing.
local GATEWAY_ACCEPTS = "^[A-Za-z0-9%._%-]+$"

describe("request id", function()
    it("is something the gateway will keep", function()
        local id = Reqid.generate(1758387834, function() return 0x9c41f2 end)
        assert.is_truthy(id:match(GATEWAY_ACCEPTS))
        assert.is_true(#id <= 64)
    end)

    it("is readable off a log on a device with no scrollback", function()
        assert.are.equal("aidict-68ce5f3a-9c41f2",
            Reqid.generate(0x68ce5f3a, function() return 0x9c41f2 end))
    end)

    it("changes when the clock does", function()
        local fixed = function() return 1 end
        assert.are_not.equal(Reqid.generate(100, fixed), Reqid.generate(101, fixed))
    end)

    it("changes within the same second", function()
        local n = 0
        local counter = function() n = n + 1 return n end
        assert.are_not.equal(Reqid.generate(100, counter), Reqid.generate(100, counter))
    end)

    it("stays the same length whatever it is given", function()
        local wide = Reqid.generate(2 ^ 40, function() return 2 ^ 30 end)
        local narrow = Reqid.generate(0, function() return 0 end)
        assert.are.equal(#narrow, #wide)
        assert.is_truthy(wide:match(GATEWAY_ACCEPTS))
    end)

    it("is actually random with the real math.random, not a fixed zero", function()
        -- The bug this pins: math.random() with no arguments answers a
        -- fraction below 1, so flooring it made every id end in 000000.
        math.randomseed(12345)
        local seen = {}
        for _ = 1, 50 do seen[Reqid.generate(100, math.random)] = true end

        local distinct = 0
        for _ in pairs(seen) do distinct = distinct + 1 end
        assert.is_true(distinct > 40)
    end)

    it("copes with a source that ignores the range and answers a fraction", function()
        local a = Reqid.generate(100, function() return 0.5 end)
        assert.are_not.equal("aidict-00000064-000000", a)
    end)

    it("still produces one without a random source", function()
        local id = Reqid.generate(100, nil)
        assert.is_truthy(id:match(GATEWAY_ACCEPTS))
    end)
end)
