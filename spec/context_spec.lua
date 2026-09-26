local Context = require("aidict.context")

describe("context", function()
    describe("cleanup", function()
        it("collapses line breaks and runs of whitespace", function()
            assert.are.equal("one two three", Context.cleanup("one\n  two\tthree"))
        end)

        it("drops soft hyphens left by reflowed text", function()
            assert.are.equal("hyphenated", Context.cleanup("hyphen\194\173ated"))
        end)

        it("trims the edges", function()
            assert.are.equal("word", Context.cleanup("   word \n"))
        end)

        it("survives a nil", function()
            assert.are.equal("", Context.cleanup(nil))
        end)
    end)

    describe("len", function()
        it("counts characters, not bytes", function()
            assert.are.equal(6, Context.len("привет"))
            assert.are.equal(12, #"привет")
        end)
    end)

    describe("truncate", function()
        it("keeps the head by default", function()
            assert.are.equal("abcde", Context.truncate("abcdefgh", 5))
        end)

        it("keeps the tail when asked", function()
            assert.are.equal("defgh", Context.truncate("abcdefgh", 5, true))
        end)

        it("never splits a multi-byte character", function()
            local cut = Context.truncate("привет", 3)
            assert.are.equal("при", cut)
            assert.are.equal(6, #cut)
        end)

        it("returns the whole string when it already fits", function()
            assert.are.equal("short", Context.truncate("short", 50))
        end)
    end)

    describe("is_single_word", function()
        it("is true for one word", function()
            assert.is_true(Context.is_single_word("  fox\n"))
        end)

        it("is false for a phrase", function()
            assert.is_false(Context.is_single_word("quick brown fox"))
        end)

        it("is false for nothing", function()
            assert.is_false(Context.is_single_word("   "))
        end)
    end)

    describe("build", function()
        it("centres the window on the word", function()
            local snippet = Context.build("the quick brown", "fox", "jumps over the lazy dog", 21)
            assert.is_truthy(snippet:find("fox", 1, true))
            assert.is_true(Context.len(snippet) <= 21)
        end)

        it("spends the whole budget on one side when the other is empty", function()
            local snippet = Context.build("", "fox", "jumps over the lazy dog", 20)
            assert.are.equal("fox jumps over the l", snippet)
        end)

        it("returns nothing when there is no surrounding text", function()
            assert.are.equal("", Context.build("", "fox", "", 100))
        end)

        it("returns nothing when the budget is zero", function()
            assert.are.equal("", Context.build("before", "fox", "after", 0))
        end)

        it("falls back to the word alone when it fills the budget", function()
            assert.are.equal("antidisestablishmentarianism",
                Context.build("a", "antidisestablishmentarianism", "b", 10))
        end)
    end)

    describe("snippet", function()
        local sentence = "The quick brown fox jumps over the lazy dog near the river bank today"

        it("returns the sentence untouched when it fits", function()
            assert.are.equal(sentence, Context.snippet(sentence, "fox", 200))
        end)

        it("keeps the word inside the window and respects the budget", function()
            local snippet = Context.snippet(sentence, "fox", 20)
            assert.is_truthy(snippet:find("fox", 1, true))
            assert.are.equal(20, Context.len(snippet))
        end)

        it("finds the word regardless of case", function()
            local snippet = Context.snippet(sentence, "FOX", 20)
            assert.is_truthy(snippet:find("fox", 1, true))
        end)

        it("falls back to the head when the word is not in the text", function()
            local snippet = Context.snippet(sentence, "aardvark", 10)
            assert.are.equal("The quick ", snippet)
        end)

        it("returns nothing when the text is only the word", function()
            assert.are.equal("", Context.snippet("fox", "fox", 200))
            assert.are.equal("", Context.snippet(" Fox ", "fox", 200))
        end)

        it("keeps a sentence that merely starts with the word", function()
            assert.are.equal("Fox hunting is banned.",
                Context.snippet("Fox hunting is banned.", "fox", 200))
        end)

        it("returns nothing without text", function()
            assert.are.equal("", Context.snippet("", "fox", 50))
        end)
    end)

    describe("sentence", function()
        local paragraph = "Halting the ongoing escalation of AI technology, corralling the " ..
            "hardware used to create ever more powerful AI models\226\128\148that is not " ..
            "something that would be easy to do in today\226\128\153s world. But it would " ..
            "take less than a war. Normality always ends."

        it("cuts the sentence holding the word out of the paragraph", function()
            assert.are.equal("But it would take less than a war.", Context.sentence(paragraph, "war"))
            assert.are.equal("Normality always ends.", Context.sentence(paragraph, "Normality"))
        end)

        it("does not end a sentence at a dash or an apostrophe", function()
            local s = Context.sentence(paragraph, "hardware")
            assert.is_truthy(s:find("^Halting"))
            assert.is_truthy(s:find("world%.$"))
        end)

        it("finds the word regardless of case", function()
            assert.are.equal("Normality always ends.", Context.sentence(paragraph, "normality"))
        end)

        it("prefers the word standing on its own to one inside a longer word", function()
            assert.are.equal("The fox ran.",
                Context.sentence("Foxes hide. The fox ran.", "fox"))
        end)

        it("settles for a longer word when that is all there is", function()
            assert.are.equal("Foxes hide.", Context.sentence("Foxes hide. It rained.", "fox"))
        end)

        it("keeps closing quotes and ends at ! ? and an ellipsis", function()
            local p = "\226\128\156Run!\226\128\157 she said. Why? Because\226\128\166 " ..
                "the fox was near."
            assert.are.equal("\226\128\156Run!\226\128\157", Context.sentence(p, "run"))
            assert.are.equal("Why?", Context.sentence(p, "why"))
            assert.are.equal("the fox was near.", Context.sentence(p, "fox"))
        end)

        it("does not split at a title or an initial", function()
            assert.are.equal("Mr. Darcy met J. Smith at noon.",
                Context.sentence("It was late. Mr. Darcy met J. Smith at noon.", "Smith"))
        end)

        it("takes a paragraph with no stop as one sentence", function()
            assert.are.equal("If you are reading this the sync works",
                Context.sentence("If you are reading this the sync works", "sync"))
        end)

        it("returns nothing when the word is not there, or there is no paragraph", function()
            assert.are.equal("", Context.sentence(paragraph, "aardvark"))
            assert.are.equal("", Context.sentence("", "fox"))
            assert.are.equal("", Context.sentence(nil, "fox"))
        end)
    end)
end)
