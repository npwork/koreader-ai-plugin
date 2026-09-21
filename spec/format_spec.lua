local Format = require("aidict.format")

describe("format", function()
    describe("result", function()
        it("leads with the word in bold and its part of speech in italic", function()
            local text = Format.result({
                word = "fox", part_of_speech = "noun", definition = "A wild animal.",
            })
            assert.is_truthy(text:find("<b>fox</b>", 1, true))
            assert.is_truthy(text:find("<i>noun</i>", 1, true))
            -- The headword comes before everything it heads.
            assert.is_true(text:find("<b>fox</b>", 1, true) < text:find("A wild animal.", 1, true))
        end)

        it("files the entry under the headword, not the form that was tapped", function()
            local text = Format.result({
                lemma = "strap", word = "strapped", part_of_speech = "verb",
                definition = "To fasten with straps.",
            })
            assert.is_truthy(text:find("<b>strap</b>", 1, true))
            -- And says where the reader came from, or the entry looks like a
            -- different word than the one they touched.
            assert.is_truthy(text:find("as “strapped”", 1, true))
        end)

        it("says nothing about the tapped form when it is the headword", function()
            local text = Format.result({
                lemma = "fell", word = "fell", definition = "An upland moor.",
            })
            assert.is_nil(text:find("as “", 1, true))
        end)

        it("still leads with the word when the gateway sent no headword", function()
            local text = Format.result({ word = "fox", definition = "A wild animal." })
            assert.is_truthy(text:find("<b>fox</b>", 1, true))
            assert.is_nil(text:find("as “", 1, true))
        end)

        it("puts the pronunciation on the headword's line, where a dictionary does", function()
            local text = Format.result({
                lemma = "themselves", word = "themselves",
                pronunciation = "/ðəmˈsɛlvz/", definition = "Reflexive pronoun.",
            })
            local head = text:find("<b>themselves</b>", 1, true)
            local pron = text:find("/ðəmˈsɛlvz/", 1, true)
            assert.is_truthy(pron)
            -- Same line: the pronunciation follows the headword before the
            -- heading div closes.
            assert.is_true(pron > head)
            assert.is_true(pron < text:find("</div>", head, true))
        end)

        it("puts the etymology last and quieter, after the examples", function()
            local text = Format.result({
                word = "want", definition = "A lack.",
                examples = { "For want of bread." },
                etymology = "From Old Norse vanta, to lack.",
            })
            local etym = text:find("From Old Norse", 1, true)
            assert.is_truthy(etym)
            assert.is_true(etym > text:find("</ol>", 1, true))
        end)

        it("says nothing where the gateway had nothing to say", function()
            -- Both are allowed to come back empty: a wrong pronunciation
            -- teaches the reader to say the word wrongly.
            local text = Format.result({
                word = "fox", definition = "A wild animal.",
                pronunciation = "", etymology = "",
            })
            assert.is_nil(text:find("<i></i>", 1, true))
            assert.is_nil(text:find("<span", 1, true))
        end)

        it("numbers the examples, so one of them can be referred to", function()
            local text = Format.result({
                word = "fox",
                definition = "A wild animal.",
                examples = { "The fox ran.", "Sly as a fox." },
            })
            assert.is_truthy(text:find("A wild animal.", 1, true))
            assert.is_truthy(text:find("<ol", 1, true))
            assert.is_truthy(text:find(">The fox ran.</li>", 1, true))
            assert.is_truthy(text:find(">Sly as a fox.</li>", 1, true))
        end)

        it("escapes what the model wrote, rather than letting it be markup", function()
            -- A definition may legitimately contain these — explaining "gt",
            -- quoting code, naming AT&T. Unescaped, the first swallows the rest.
            local text = Format.result({
                word = "gt",
                definition = "Short for <greater than> in code & markup.",
                examples = { "a < b" },
            })
            assert.is_truthy(text:find("&lt;greater than&gt;", 1, true))
            assert.is_truthy(text:find("code &amp; markup", 1, true))
            assert.is_truthy(text:find("a &lt; b", 1, true))
            -- And the entry still closes properly around it.
            assert.is_truthy(text:find("</ol>", 1, true))
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

        it("shows the gateway's own time beside the round trip", function()
            -- The point of the whole thing: five seconds of radio and five of
            -- model look identical on the screen and want opposite fixes.
            local text = Format.result({
                definition = "d", model = "gpt-test", elapsed_ms = 5000, server_ms = 1800,
            })
            assert.is_truthy(text:find("5.0s total · 1.8s server", 1, true))
        end)

        it("keeps the footer to the time when the model is unknown", function()
            local text = Format.result({ definition = "d", elapsed_ms = 120 })
            assert.is_truthy(text:find(">120ms</div>", 1, true))
        end)

        it("has no footer at all when there is nothing to put in it", function()
            local text = Format.result({ definition = "d" })
            assert.is_nil(text:find("—", 1, true))
        end)

        it("falls back to the requested word", function()
            local text = Format.result({ definition = "d" }, { word = "fox" })
            assert.is_truthy(text:find("<b>fox</b>", 1, true))
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
        it("reports both measurements, and does not invent a third", function()
            -- The gap between them is not one thing — radio, DNS, handshake,
            -- Cloudflare, two clocks — so it is left unnamed rather than
            -- called "network".
            assert.are.equal("5.0s total · 1.8s server", Format.timing(5000, 1800))
        end)

        it("is just the round trip when the gateway did not say", function()
            -- An older gateway, or an answer that came from somewhere else.
            assert.are.equal("5.0s", Format.timing(5000, nil))
            assert.are.equal("5.0s", Format.timing(5000, "not a number"))
        end)

        it("reports a server slower than the round trip rather than hiding it", function()
            -- Two clocks on two machines can disagree by a little. Showing both
            -- says so; a subtraction would have had to pretend otherwise.
            assert.are.equal("1.7s total · 1.8s server", Format.timing(1700, 1800))
        end)

        it("has nothing to say without a round trip to describe", function()
            assert.are.equal("", Format.timing(nil, 1800))
        end)

        it("reads numbers that arrived as strings", function()
            -- Both survive a trip through the subprocess as JSON.
            assert.are.equal("5.0s total · 1.8s server", Format.timing("5000", "1800"))
        end)
    end)

    describe("title", function()
        it("titles the window with the headword, not the tapped form", function()
            assert.are.equal("strap",
                Format.title({ lemma = "strap", word = "strapped" }, "strapped"))
        end)

        it("uses what it has when the gateway sent no headword", function()
            assert.are.equal("fox", Format.title({ word = "fox" }, "fox"))
            assert.are.equal("fox", Format.title({}, "fox"))
            assert.are.equal("fox", Format.title(nil, "fox"))
        end)
    end)

    describe("escape", function()
        it("makes model text safe to put inside markup", function()
            assert.are.equal("a &amp;lt; b", Format.escape("a &lt; b"))
            assert.are.equal("&lt;b&gt;", Format.escape("<b>"))
            assert.are.equal("", Format.escape(nil))
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
