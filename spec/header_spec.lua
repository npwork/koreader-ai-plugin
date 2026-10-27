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
        local button = { enabled = true, enableDisable = function(this, enabled) this.enabled = enabled end }
        popup.button_table = { getButtonById = function() return button end }
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

    it("shares one toggle between the heading and the translation button", function()
        assert.is_true(popup:onAidictTranslate())
        assert.are.equal("важничать", text.text)
        assert.is_true(tap(25, 85))
        assert.are.equal("swagger", text.text)
        assert.are.equal(123, popup.scroll_position)
        assert.are.equal("English definition", popup.definition)
    end)

    it("uses the small remote button's previous-page event only for available AI translations", function()
        local event = { handler = "onGotoViewRel", args = { -1 } }
        assert.is_true(popup:handleEvent(event))
        assert.are.equal("важничать", text.text)
        assert.is_true(popup:handleEvent(event))
        assert.are.equal("swagger", text.text)
        assert.are.equal("child widget consumed the gesture",
            popup:handleEvent({ handler = "onGotoViewRel", args = { 1 } }))
        popup.dict_index = 2
        assert.are.equal("child widget consumed the gesture", popup:handleEvent(event))
        popup.dict_index = 1
        ai.aidict_translation = nil
        assert.are.equal("child widget consumed the gesture", popup:handleEvent(event))
    end)

    it("updates the translation button when changing result or receiving a translation", function()
        local button = popup.button_table:getButtonById("aidict_translate")
        assert.is_true(button.enabled)
        popup.dict_index = 2
        popup:update()
        assert.is_false(button.enabled)
        popup.dict_index = 1
        ai.aidict_translation = nil
        popup:update()
        assert.is_false(button.enabled)
        ai.aidict_translation = "важничать"
        popup:update()
        assert.is_true(button.enabled)
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

describe("translation button placement", function()
    it("inserts between Next and Close and does not duplicate the button", function()
        local rows = { { { id = "prev_dict" }, { id = "next_dict" }, { id = "close" } } }
        local button = { id = "aidict_translate" }
        Header.insertButton(rows, button)
        assert.are.equal(button, rows[1][3])
        assert.are.equal("close", rows[1][4].id)
        Header.insertButton(rows, button)
        assert.are.equal(4, #rows[1])
    end)

    it("leaves room in rows that have explicit widths", function()
        local rows = { { { id = "next_dict", width = 200 }, { id = "close", width = 200 } } }
        Header.insertButton(rows, { id = "aidict_translate" })
        assert.is_true(rows[1][1].width < 200)
        assert.is_true(rows[1][3].width < 200)
    end)

    it("uses Next or a new row when a customized layout omits Close", function()
        local button = { id = "aidict_translate" }
        local rows = { { { id = "next_dict" }, { id = "other" } } }
        Header.insertButton(rows, button)
        assert.are.equal(button, rows[1][2])
        rows = {}
        Header.insertButton(rows, button)
        assert.are.same({ { button } }, rows)
    end)
end)
