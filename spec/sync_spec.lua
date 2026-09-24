local Sync = require("aidict.sync")

local function step(title, ...)
    local answer, n = { ... }, select("#", ...)
    local ran = { count = 0 }
    return {
        title = title,
        run = function()
            ran.count = ran.count + 1
            return unpack(answer, 1, n)
        end,
    }, ran
end

describe("one sync", function()
    it("says what each step did, under its title, in order", function()
        local outcome = Sync.run({ (step("Library", "Nothing new.")), (step("Settings", "Changed 2: a, b.", 2)) })
        assert.are.equal("Library\nNothing new.\n\nSettings\nChanged 2: a, b.", outcome.text)
        assert.are.equal(2, outcome.changed)
        assert.is_false(outcome.empty)
    end)

    it("stops at a dismissed step, keeping what came before", function()
        local after, ran = step("Kindle lookups", "Sent 1.")
        local outcome = Sync.run({ step("Library", "Nothing new."), step("Settings", nil), after })
        assert.are.equal("Library\nNothing new.", outcome.text)
        assert.are.equal(0, ran.count)
    end)

    it("says a step that asked to stop, then stops", function()
        local after, ran = step("Kindle lookups", "Sent 1.")
        local outcome = Sync.run({ step("Settings", "Changed 1: a.", 1, true), after })
        assert.are.equal("Settings\nChanged 1: a.", outcome.text)
        assert.are.equal(1, outcome.changed)
        assert.are.equal(0, ran.count)
    end)

    it("leaves out a step with nothing to say, and goes on", function()
        local outcome = Sync.run({ (step("Kindle lookups", false)), (step("Library", "Nothing new.")) })
        assert.are.equal("Library\nNothing new.", outcome.text)
    end)

    it("is empty when the first step was dismissed", function()
        assert.is_true(Sync.run({ (step("Library", nil)) }).empty)
    end)
end)
