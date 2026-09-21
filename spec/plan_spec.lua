local Plan = require("aidict.plan")

local function entry(path, size)
    return { path = path, size = size, url = "https://r2.test/" .. path }
end

--- A device holding `files` (path -> bytes) and nothing else.
local function holding(files)
    return function(path) return files[path] end
end

describe("plan", function()
    it("downloads what the device has never seen", function()
        local plan = Plan.build({ entry("A.epub", 10) }, holding({}))

        assert.are.equal(1, #plan.downloads)
        assert.are.equal("A.epub", plan.downloads[1].path)
        assert.are.equal(10, plan.bytes)
        assert.are.equal(0, plan.have)
    end)

    it("leaves alone what is already here, byte for byte", function()
        local plan = Plan.build({ entry("A.epub", 10) }, holding({ ["A.epub"] = 10 }))

        assert.are.equal(0, #plan.downloads)
        assert.are.equal(1, plan.have)
        assert.are.equal(0, plan.bytes)
    end)

    it("re-downloads a file the last sync left half-written", function()
        -- The whole reason this compares sizes instead of asking whether the
        -- file exists: a Kindle that lost Wi-Fi leaves one that does.
        local plan = Plan.build({ entry("A.epub", 10) }, holding({ ["A.epub"] = 4 }))

        assert.are.equal(1, #plan.downloads)
        assert.are.equal(10, plan.bytes)
    end)

    it("re-downloads a book that changed on the server", function()
        local plan = Plan.build({ entry("A.epub", 20) }, holding({ ["A.epub"] = 10 }))
        assert.are.equal(1, #plan.downloads)
    end)

    it("sums only what it will actually fetch", function()
        local plan = Plan.build(
            { entry("A.epub", 10), entry("B.epub", 100), entry("C.epub", 1000) },
            holding({ ["B.epub"] = 100 }))

        assert.are.equal(2, #plan.downloads)
        assert.are.equal(1, plan.have)
        assert.are.equal(1010, plan.bytes)
    end)

    it("has nothing to do with an empty library", function()
        local plan = Plan.build({}, holding({}))
        assert.are.same({ downloads = {}, have = 0, bytes = 0 }, plan)
    end)
end)
