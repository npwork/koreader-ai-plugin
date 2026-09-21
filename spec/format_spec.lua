local Format = require("aidict.format")

describe("format", function()
    describe("result", function()
        it("leads with the word and its part of speech", function()
            local text = Format.result({
                word = "fox", part_of_speech = "noun", definition = "A wild animal.",
            })
            assert.are.equal("fox  (noun)", text:match("^[^\n]+"))
        end)

        it("includes the definition and the examples", function()
            local text = Format.result({
                word = "fox",
                definition = "A wild animal.",
                examples = { "The fox ran.", "Sly as a fox." },
            })
            assert.is_truthy(text:find("A wild animal.", 1, true))
            assert.is_truthy(text:find("• The fox ran.", 1, true))
            assert.is_truthy(text:find("• Sly as a fox.", 1, true))
        end)

        it("does not show the translation yet, though it is fetched", function()
            local text = Format.result({
                word = "fox",
                definition = "A wild animal.",
                translation = "лиса",
            })
            assert.is_nil(text:find("лиса", 1, true))
        end)

        it("leaves out what the gateway did not send", function()
            local text = Format.result({ word = "fox", definition = "A wild animal." })
            assert.is_nil(text:find("•", 1, true))
            assert.is_nil(text:find("—", 1, true))
        end)

        it("marks a cached answer in the footer", function()
            local text = Format.result({ definition = "d", model = "gpt-test" }, { cached = true })
            assert.is_truthy(text:find("gpt%-test · cached"))
        end)

        it("shows the round trip in the footer when it was not cached", function()
            local text = Format.result({ definition = "d", model = "gpt-test", elapsed_ms = 1500 })
            assert.is_truthy(text:find("gpt%-test · 1%.5s"))
        end)

        it("says cached rather than how long the original ask took", function()
            -- A cached answer took no time now; showing the old number would lie.
            local text = Format.result(
                { definition = "d", model = "gpt-test", elapsed_ms = 1500 }, { cached = true })
            assert.is_truthy(text:find("cached", 1, true))
            assert.is_nil(text:find("1.5s", 1, true))
        end)

        it("splits the wait into the gateway's share and the network's", function()
            -- The point of the whole thing: five seconds of radio and five of
            -- model look identical on the screen and want opposite fixes.
            local text = Format.result({
                definition = "d", model = "gpt-test", elapsed_ms = 5000, server_ms = 1800,
            })
            assert.is_truthy(text:find("5.0s (1.8s server, 3.2s network)", 1, true))
        end)

        it("keeps the footer to the time when the model is unknown", function()
            local text = Format.result({ definition = "d", elapsed_ms = 120 })
            assert.is_truthy(text:find("— 120ms", 1, true))
        end)

        it("has no footer at all when there is nothing to put in it", function()
            local text = Format.result({ definition = "d" })
            assert.is_nil(text:find("—", 1, true))
        end)

        it("falls back to the requested word", function()
            local text = Format.result({ definition = "d" }, { word = "fox" })
            assert.are.equal("fox", text:match("^[^\n]+"))
        end)

        it("returns nothing for a non-result", function()
            assert.are.equal("", Format.result(nil))
        end)
    end)

    describe("duration", function()
        it("stays in milliseconds below a second", function()
            assert.are.equal("120ms", Format.duration(120))
            assert.are.equal("0ms", Format.duration(0))
            assert.are.equal("999ms", Format.duration(999))
        end)

        it("rounds to the nearest millisecond", function()
            assert.are.equal("121ms", Format.duration(120.6))
        end)

        it("switches to seconds at one second", function()
            assert.are.equal("1.0s", Format.duration(1000))
            assert.are.equal("12.3s", Format.duration(12345))
        end)

        it("says nothing about a time it was not given", function()
            assert.are.equal("", Format.duration(nil))
            assert.are.equal("", Format.duration("a while"))
        end)

        it("reads a number that arrived as a string", function()
            -- Timings survive a trip through the subprocess, so be forgiving.
            assert.are.equal("250ms", Format.duration("250"))
        end)
    end)

    describe("timing", function()
        it("names the gateway's share and what is left over", function()
            assert.are.equal("5.0s (1.8s server, 3.2s network)",
                Format.timing(5000, 1800))
        end)

        it("is just the total when the gateway did not say", function()
            -- An older gateway, or an answer that came from somewhere else.
            assert.are.equal("5.0s", Format.timing(5000, nil))
            assert.are.equal("5.0s", Format.timing(5000, "not a number"))
        end)

        it("drops the split rather than reporting no network at all", function()
            -- Two clocks on two machines; the subtraction can land at or under
            -- zero, and "0ms network" is not a finding.
            assert.are.equal("1.8s", Format.timing(1800, 1800))
            assert.are.equal("1.7s", Format.timing(1700, 1800))
        end)

        it("has nothing to say without a round trip to describe", function()
            assert.are.equal("", Format.timing(nil, 1800))
        end)

        it("reads numbers that arrived as strings", function()
            -- Both survive a trip through the subprocess as JSON.
            assert.are.equal("5.0s (1.8s server, 3.2s network)",
                Format.timing("5000", "1800"))
        end)
    end)

    describe("error", function()
        it("turns an error table into a sentence", function()
            assert.are.equal("The gateway did not answer in time.",
                Format.error({ code = "timeout", message = "the gateway did not answer in time" }))
        end)

        it("has something to say about anything", function()
            assert.are.equal("Lookup failed.", Format.error(nil))
        end)
    end)
end)
