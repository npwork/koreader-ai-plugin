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

        it("falls back to the requested word", function()
            local text = Format.result({ definition = "d" }, { word = "fox" })
            assert.are.equal("fox", text:match("^[^\n]+"))
        end)

        it("returns nothing for a non-result", function()
            assert.are.equal("", Format.result(nil))
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
