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
end)
