local Header = require("aidict.header")

describe("tapping the lookup word below the AI bar", function()
    local popup, text, dirty, ai
    local function tap(x, y) return popup:onTap(nil, { pos = { x = x, y = y } }) end
    before_each(function()
        ai = { aidict = true, word = "swagger", aidict_translation = "важничать" }
        text = {
            text = "swagger", lang = "en",
            setText = function(this, value) this.text = value end,
            getSize = function(this) return { w = math.min(200, #this.text * 10), h = 24 } end,
            paintTo = function() end,
        }
        popup = {
            results = { ai, { word = "Oxford word" } }, dict_index = 1,
            lookup_word_text = text, lang_in = "en", lookupword = "swagger", word = "swagger",
            definition = "English definition", scroll_position = 123, taps = 0,
            onTap = function(this) this.taps = this.taps + 1; return "ordinary tap" end,
            handleEvent = function() return "child widget consumed the gesture" end,
            update = function(this)
                this.lookup_word_text:setText(this.results[this.dict_index].word)
                this.lookup_word_text.lang = this.lang_in
            end,
        }
        dirty = {}
        assert.is_true(Header.install(popup, function(_, area) dirty[#dirty + 1] = area or "initial" end))
        text:paintTo(nil, 20, 80)
    end)

    it("switches swagger to Russian and back without changing the lookup or scrolling the definition", function()
        assert.is_true(tap(25, 85))
        assert.are.equal("важничать", text.text)
        assert.are.equal("ru", text.lang)
        text:paintTo(nil, 20, 80)
        -- Still tappable over the wider Russian label.
        assert.is_true(tap(150, 85))
        assert.are.equal("swagger", text.text)
        assert.are.equal("en", text.lang)
        assert.are.equal("swagger", popup.lookupword)
        assert.are.equal("swagger", popup.word)
        assert.are.equal("swagger", ai.word)
        assert.are.equal("English definition", popup.definition)
        assert.are.equal(123, popup.scroll_position)
        assert.are.equal(0, popup.taps)
        assert.is_true(dirty[#dirty].w > #"swagger" * 10)
    end)

    it("leaves taps on the AI bar, edit button, definition and outside the popup alone", function()
        for _, pos in ipairs({ { 25, 30 }, { 300, 85 }, { 25, 200 }, { 0, 0 } }) do
            assert.are.equal("ordinary tap", tap(pos[1], pos[2]))
        end
        assert.are.equal("swagger", text.text)
        assert.are.equal(4, popup.taps)
    end)

    it("leaves a missing translation or a non-AI dictionary unchanged", function()
        ai.aidict_translation = nil
        assert.are.equal("ordinary tap", tap(25, 85))
        ai.aidict_translation = ""
        assert.are.equal("ordinary tap", tap(25, 85))
        ai.aidict_translation = "важничать"
        ai.aidict = nil
        assert.are.equal("ordinary tap", tap(25, 85))
    end)

    it("resets to English when changing dictionaries, with no state leaking into the next result", function()
        tap(25, 85)
        popup.dict_index = 2
        popup:update()
        text:paintTo(nil, 20, 80)
        assert.are.equal("ordinary tap", tap(25, 85))
        assert.are.equal("Oxford word", text.text)
        popup.dict_index = 1
        popup:update()
        text:paintTo(nil, 20, 80)
        tap(25, 85)
        assert.are.equal("важничать", text.text)
    end)

    it("uses the new painted position after the window moves", function()
        text:paintTo(nil, 200, 300)
        assert.are.equal("ordinary tap", tap(25, 85))
        assert.is_true(tap(205, 305))
    end)

    it("receives a real tap before child widgets can swallow it, leaving other gestures alone", function()
        assert.is_true(popup:handleEvent({ handler = "onGesture", args = {
            { ges = "tap", pos = { x = 25, y = 85 } },
        } }))
        assert.are.equal("важничать", text.text)
        assert.are.equal("child widget consumed the gesture", popup:handleEvent({ handler = "onGesture", args = {
            { ges = "swipe", pos = { x = 25, y = 85 } },
        } }))
        assert.are.equal("child widget consumed the gesture", popup:handleEvent({ handler = "onGesture", args = {
            { ges = "tap", pos = { x = 25, y = 200 } },
        } }))
        assert.are.equal("child widget consumed the gesture", popup:handleEvent({ handler = "onOtherEvent" }))
    end)

    it("installs only once on a popup and tolerates unsupported widgets", function()
        local handler = popup.onTap
        assert.is_false(Header.install(popup, function() error("must not install again") end))
        assert.are.equal(handler, popup.onTap)
        assert.is_false(Header.install({}, function() end))
    end)
end)
