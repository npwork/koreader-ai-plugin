--[[--
`main.lua` itself: the buttons it registers, what happens when they are
pressed, and what it shows afterwards.

KOReader is stubbed (see spec/support/koreader.lua), so this runs anywhere the
unit suite does — but it exercises the real plugin file, including the parts
the emulator would otherwise be the only way to reach.
--]]--

local helpers = require("support.helpers")
local koreader = require("support.koreader")

local ANSWER = helpers.body({
    word = "fox",
    definition = "A wild animal of the dog family.",
    translation = "лиса",
    examples = { "The fox ran." },
    model = "spec-model",
})

describe("the KOReader layer", function()
    local kor, reader, plugin

    local function build(opts)
        opts = opts or {}
        -- The shipped package carries no endpoint; it is baked in at build
        -- time. Give the reader one unless the spec is about not having it.
        local settings = {}
        if not opts.no_endpoint then settings.endpoint = helpers.ENDPOINT end
        for key, value in pairs(opts.settings or {}) do settings[key] = value end

        kor = koreader.install({
            responses = opts.responses or { { status = 200, body = ANSWER } },
            online = opts.online,
            settings = settings,
        })
        local selected_text = opts.selected_text or { text = "fox", pos0 = "p1", pos1 = "p2" }
        if opts.no_selection then selected_text = nil end

        local sentence = opts.sentence or "The quick brown fox jumps over the lazy dog."
        if opts.no_sentence then sentence = nil end

        local paragraph_html = opts.paragraph_html
        if paragraph_html == nil and not opts.no_paragraph then
            paragraph_html = "<p>The quick brown fox jumps over the lazy dog. " ..
                "It had been doing so all afternoon, to nobody's surprise.</p>"
        end

        reader = koreader.reader({
            sentence = sentence,
            paragraph_html = paragraph_html,
            selected_text = selected_text,
            doc_props = opts.doc_props,
        })

        local document = reader.document
        if opts.no_document then document = nil end

        plugin = kor.plugin_class:new({ ui = reader.ui, document = document })
        return plugin
    end

    local function last_shown()
        return kor.shown[#kor.shown]
    end

    local function tap_dict_button()
        local spec = reader.dict_buttons["aidict_explain"]
        local popup = {
            word = "fox",
            highlight = reader.ui.highlight,
            onClose = function(this) this.closed = true end,
        }
        spec.callback(popup)
        return popup
    end

    local function tap_highlight_button()
        local builder = reader.highlight_buttons["13_aidict_explain"]
        local button = builder(reader.ui.highlight)
        button.callback()
        return button
    end

    after_each(function()
        koreader.uninstall()
    end)

    describe("registration", function()
        it("adds a button to the dictionary popup", function()
            build()
            local spec = reader.dict_buttons["aidict_explain"]
            assert.is_table(spec)
            assert.are.equal("AI", spec.text)
            assert.are.equal("Explain with AI", spec.menu_text)
            assert.is_function(spec.callback)
        end)

        it("adds an entry to the highlight dialog, sorted after the built-ins", function()
            build()
            local builder = reader.highlight_buttons["13_aidict_explain"]
            assert.is_function(builder)
            assert.are.equal("Explain with AI", builder(reader.ui.highlight).text)
        end)

        it("registers itself in the main menu", function()
            build()
            assert.are.equal(plugin, reader.registered_plugin)

            local items = {}
            plugin:addToMainMenu(items)
            assert.is_table(items.aidict)
            assert.are.equal("AI dictionary", items.aidict.text)
            assert.is_true(#items.aidict.sub_item_table > 5)
        end)

        it("stays out of the highlight dialog when no document is open", function()
            build({ no_document = true })
            assert.is_nil(reader.highlight_buttons["13_aidict_explain"])
            assert.is_table(reader.dict_buttons["aidict_explain"])
        end)
    end)

    describe("pressing the dictionary button", function()
        it("closes the popup, asks the gateway and shows the answer", function()
            build()
            local popup = tap_dict_button()

            assert.is_true(popup.closed)
            assert.are.equal(1, kor.transport.calls)

            local shown = last_shown()
            assert.are.equal("TextViewer", shown.widget_kind)
            assert.are.equal("fox", shown.title)
            assert.is_truthy(shown.text:find("A wild animal of the dog family.", 1, true))
        end)

        it("sends the whole paragraph as context, stripped of its markup", function()
            build()
            tap_dict_button()

            local sent = helpers.json.decode(kor.transport.requests[1].body)
            assert.are.equal("fox", sent.word)
            assert.is_truthy(sent.context:find("fox", 1, true))
            -- The second sentence is only in the paragraph, not in the sentence.
            assert.is_truthy(sent.context:find("all afternoon", 1, true))
            assert.is_nil(sent.context:find("<p>", 1, true))
        end)

        it("sends the sentence too, so the right occurrence is known", function()
            build()
            tap_dict_button()

            local sent = helpers.json.decode(kor.transport.requests[1].body)
            assert.are.equal("The quick brown fox jumps over the lazy dog.", sent.sentence)
        end)

        it("falls back to the sentence when there is no paragraph", function()
            build({ no_paragraph = true })
            tap_dict_button()

            local sent = helpers.json.decode(kor.transport.requests[1].body)
            assert.is_truthy(sent.context:find("fox", 1, true))
            assert.is_nil(sent.context:find("all afternoon", 1, true))
        end)

        it("sends the book it was reading", function()
            build()
            tap_dict_button()

            local sent = helpers.json.decode(kor.transport.requests[1].body)
            assert.are.equal("Aesop's Fables", sent.title)
            assert.are.equal("Aesop", sent.author)
            assert.are.equal("en", sent.source_lang)
        end)

        it("serves the second tap from the cache without a request", function()
            build()
            tap_dict_button()
            tap_dict_button()

            assert.are.equal(1, kor.transport.calls)
            assert.is_truthy(last_shown().text:find("cached", 1, true))
        end)

        it("shows the gateway's error instead of an answer", function()
            build({ responses = { { status = 500, body = helpers.body({ error = "model is down" }) } } })
            tap_dict_button()

            local shown = last_shown()
            assert.are.equal("InfoMessage", shown.widget_kind)
            assert.are.equal("Model is down.", shown.text)
        end)

        it("says so when the request times out", function()
            build({ responses = { { err = "timeout" } } })
            tap_dict_button()
            assert.is_truthy(last_shown().text:find("in time", 1, true))
        end)

        it("shows nothing when the reader dismisses the wait", function()
            build()
            kor.dismiss_next = true
            tap_dict_button()
            assert.are.equal(0, #kor.shown)
        end)

        it("asks to be configured when no endpoint was baked in or set", function()
            build({ no_endpoint = true })
            tap_dict_button()

            assert.are.equal(0, kor.transport.calls)
            assert.are.equal("InfoMessage", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("endpoint", 1, true))
        end)

        it("shows how long the round trip took", function()
            build()
            kor.request_ms = 1500
            tap_dict_button()

            assert.is_truthy(last_shown().text:find("1.5s", 1, true))
        end)

        it("shows milliseconds when it was quick", function()
            build()
            kor.request_ms = 120
            tap_dict_button()

            assert.is_truthy(last_shown().text:find("120ms", 1, true))
        end)

        it("names the word in the progress message", function()
            build()
            tap_dict_button()
            assert.is_truthy(kor.last_progress_message:find("fox", 1, true))
        end)
    end)

    -- The reader sees one number; the log is where a slow lookup gets taken
    -- apart into radio, gateway and model.
    describe("what it writes to the log", function()
        local TIMED_ANSWER = helpers.body({
            word = "fox",
            definition = "A wild animal of the dog family.",
            examples = { "The fox ran." },
            model = "spec-model",
            timing = { total_ms = 900, upstream_ms = 850 },
        })

        it("records where the time went, not just how much", function()
            build({ responses = { { status = 200, body = TIMED_ANSWER } } })
            kor.request_ms = 1500
            tap_dict_button()

            local line = kor.info_lines[#kor.info_lines]
            assert.is_truthy(line:find("fox", 1, true))
            assert.is_truthy(line:find("1500ms", 1, true))
            assert.is_truthy(line:find("gateway 900ms", 1, true))
            assert.is_truthy(line:find("model 850ms", 1, true))
            assert.is_truthy(line:find("spec-model", 1, true))
        end)

        it("logs a question mark rather than crashing on a gateway that sends no timing", function()
            build()
            kor.request_ms = 1500
            tap_dict_button()

            local line = kor.info_lines[#kor.info_lines]
            assert.is_truthy(line:find("1500ms", 1, true))
            assert.is_truthy(line:find("gateway ?ms", 1, true))
        end)

        it("names the request id, so the device log and Axiom can be lined up", function()
            build()
            tap_dict_button()

            local sent = kor.transport.requests[1].headers["X-Request-Id"]
            assert.is_truthy(sent)
            assert.is_truthy(sent:match("^aidict%-%x+%-%x+$"))
            assert.is_truthy(kor.info_lines[#kor.info_lines]:find(sent, 1, true))
        end)

        it("names it on a failure too", function()
            build({ responses = { { err = "timeout" } } })
            tap_dict_button()

            local sent = kor.transport.requests[1].headers["X-Request-Id"]
            assert.is_truthy(kor.warn_lines[#kor.warn_lines]:find(sent, 1, true))
        end)

        it("gives each lookup its own", function()
            build({ responses = {
                { status = 200, body = ANSWER },
                { status = 200, body = ANSWER },
            } })
            plugin:explain("fox", "a sentence about a fox", "a sentence about a fox")
            plugin:explain("dog", "a sentence about a dog", "a sentence about a dog")

            assert.are_not.equal(kor.transport.requests[1].headers["X-Request-Id"],
                                 kor.transport.requests[2].headers["X-Request-Id"])
        end)

        it("records the error code when the gateway refuses", function()
            build({ responses = { { status = 429, body = "" } } })
            tap_dict_button()

            local line = kor.warn_lines[#kor.warn_lines]
            assert.is_truthy(line:find("fox", 1, true))
            assert.is_truthy(line:find("rate_limited", 1, true))
        end)

        it("records a lookup the reader dismissed, without calling it a failure", function()
            build()
            kor.dismiss_next = true
            tap_dict_button()

            assert.is_truthy(kor.info_lines[#kor.info_lines]:find("dismissed", 1, true))
            assert.are.equal(0, #kor.warn_lines)
        end)

        it("says how long a failure took, so a timeout is not just an error", function()
            build({ responses = { { err = "timeout" } } })
            kor.request_ms = 30000
            tap_dict_button()

            local line = kor.warn_lines[#kor.warn_lines]
            assert.is_truthy(line:find("30000ms", 1, true))
            assert.is_truthy(line:find("timeout", 1, true))
        end)

        it("records an answer served from the cache, so the log accounts for every tap", function()
            build()
            tap_dict_button()
            tap_dict_button()

            assert.are.equal(1, kor.transport.calls)
            assert.is_truthy(kor.info_lines[#kor.info_lines]:find("from cache", 1, true))
        end)

        it("says why it refused to ask when there is no Wi-Fi", function()
            build({ online = false })
            plugin:explain("fox", "a sentence with fox in it", "a sentence with fox in it")

            assert.are.equal(0, kor.transport.calls)
            assert.is_truthy(kor.warn_lines[#kor.warn_lines]:find("offline", 1, true))
        end)

        it("says why it refused to ask with no endpoint", function()
            build({ no_endpoint = true })
            tap_dict_button()

            assert.are.equal(0, kor.transport.calls)
            assert.is_truthy(kor.warn_lines[#kor.warn_lines]:find("no endpoint", 1, true))
        end)
    end)

    describe("pressing the highlight button", function()
        it("looks up the selected text", function()
            build({ selected_text = { text = " fox\n", pos0 = "p1", pos1 = "p2" } })
            tap_highlight_button()

            assert.are.equal(1, kor.transport.calls)
            assert.are.equal("fox", helpers.json.decode(kor.transport.requests[1].body).word)
            assert.are.equal("TextViewer", last_shown().widget_kind)
        end)

        it("does nothing without a selection", function()
            build({ no_selection = true })
            tap_highlight_button()
            assert.are.equal(0, kor.transport.calls)
            assert.are.equal(0, #kor.shown)
        end)

        it("still sends the paragraph when the document gives no sentence", function()
            build({ no_sentence = true, selected_text = { text = "fox", pos0 = "p1", pos1 = "p2" } })
            tap_highlight_button()

            local sent = helpers.json.decode(kor.transport.requests[1].body)
            assert.is_truthy(sent.context:find("all afternoon", 1, true))
        end)

        it("sends no context when the document gives neither", function()
            build({
                no_sentence = true,
                no_paragraph = true,
                selected_text = { text = "fox jumps", pos0 = "p1", pos1 = "p2" },
            })
            tap_highlight_button()

            assert.are.equal(1, kor.transport.calls)
            local sent = helpers.json.decode(kor.transport.requests[1].body)
            assert.are.equal("fox jumps", sent.word)
            -- The selection is all there is, so it is not sent back as its own context.
            assert.is_nil(sent.context)
        end)
    end)

    describe("being offline", function()
        it("does not offer the button at all", function()
            build({ online = false })

            local spec = reader.dict_buttons["aidict_explain"]
            assert.is_false(spec.show_func())

            local button = reader.highlight_buttons["13_aidict_explain"](reader.ui.highlight)
            assert.is_false(button.show_in_highlight_dialog_func())
        end)

        it("offers it once Wi-Fi is up", function()
            build()

            assert.is_true(reader.dict_buttons["aidict_explain"].show_func())
            local button = reader.highlight_buttons["13_aidict_explain"](reader.ui.highlight)
            assert.is_true(button.show_in_highlight_dialog_func())
        end)

        it("asks nothing and says why, if it is reached anyway", function()
            build({ online = false })
            tap_dict_button()

            assert.are.equal(0, kor.transport.calls)
            assert.are.equal("InfoMessage", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("Wi%-Fi"))
        end)

        it("still shows an answer it already has", function()
            build()
            tap_dict_button()
            local saved = kor.store.data["cache_entries"]
            koreader.uninstall()

            build({ online = false, settings = { cache_entries = saved } })
            tap_dict_button()

            assert.are.equal(0, kor.transport.calls)
            assert.are.equal("TextViewer", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("cached", 1, true))
        end)
    end)

    describe("the cache on disk", function()
        it("is written after a successful lookup", function()
            build()
            tap_dict_button()

            local saved = kor.store.data["cache_entries"]
            assert.is_table(saved)
            assert.are.equal(1, #saved)
            assert.are.equal("A wild animal of the dog family.", saved[1].value.definition)
        end)

        it("is read back by the next reader session", function()
            build()
            tap_dict_button()
            local saved = kor.store.data["cache_entries"]
            koreader.uninstall()

            build({ settings = { cache_entries = saved } })
            tap_dict_button()

            assert.are.equal(0, kor.transport.calls)
            assert.is_truthy(last_shown().text:find("cached", 1, true))
        end)

        it("is emptied by the menu item", function()
            build()
            tap_dict_button()

            local items = {}
            plugin:addToMainMenu(items)
            for _, item in ipairs(items.aidict.sub_item_table) do
                local label = item.text_func and item.text_func() or item.text
                if label:find("Clear cache") then item.callback() end
            end

            assert.are.same({}, kor.store.data["cache_entries"])
            assert.are.equal("Cached answers cleared.", last_shown().text)
        end)
    end)

    describe("the settings menu", function()
        local function menu_item(matcher)
            local items = {}
            plugin:addToMainMenu(items)
            for _, item in ipairs(items.aidict.sub_item_table) do
                local label = item.text_func and item.text_func() or item.text
                if label:find(matcher) then return item, label end
            end
        end

        it("shows the endpoint it will use", function()
            build({ settings = { endpoint = "https://gw.test/ai" } })
            local _, label = menu_item("Endpoint")
            assert.are.equal("Endpoint: https://gw.test/ai", label)
        end)

        it("hides whether a key is set behind 'set' or 'none'", function()
            build()
            local _, label = menu_item("API key")
            assert.are.equal("API key: none", label)

            koreader.uninstall()
            build({ settings = { api_key = "s3cret" } })
            local _, with_key = menu_item("API key")
            assert.are.equal("API key: set", with_key)
        end)

        it("saves a valid endpoint and rebuilds the client with it", function()
            build()
            menu_item("Endpoint").callback()

            local dialog = last_shown()
            dialog.input = "https://other.test/ai"
            dialog.buttons[1][2].callback()

            assert.are.equal("https://other.test/ai", kor.store.data.endpoint)

            tap_dict_button()
            assert.are.equal("https://other.test/ai/define", kor.transport.requests[1].url)
        end)

        it("refuses a bad endpoint and keeps the old one", function()
            build()
            menu_item("Endpoint").callback()

            local dialog = last_shown()
            dialog.input = "not-a-url"
            dialog.buttons[1][2].callback()

            assert.are.equal(helpers.ENDPOINT, kor.store.data.endpoint)
            assert.are.equal("InfoMessage", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("URL", 1, true))
        end)

        it("toggles the update channel", function()
            build()
            menu_item("Update channel").callback()
            assert.are.equal("dev", kor.store.data.channel)
        end)
    end)

    describe("the update check", function()
        it("points at the channel's version manifest", function()
            build({
                responses = { { status = 200, body = helpers.body({
                    channel = "stable",
                    packages = { ["koreader-aidict"] = { version = { 9, 9, 9 }, version_string = "9.9.9" } },
                }) } },
                settings = { repo_url = "https://repo.test/kpm" },
            })
            plugin:checkForUpdates()

            assert.are.equal("https://repo.test/kpm/stable/version.json", kor.transport.requests[1].url)
            assert.is_truthy(last_shown().text:find("9.9.9", 1, true))
            assert.is_truthy(last_shown().text:find("kpm upgrade koreader%-aidict"))
        end)

        it("says when there is nothing newer", function()
            build({
                responses = { { status = 200, body = helpers.body({
                    channel = "stable",
                    packages = { ["koreader-aidict"] = { version = { 0, 0, 1 }, version_string = "0.0.1" } },
                }) } },
            })
            plugin:checkForUpdates()
            assert.is_truthy(last_shown().text:find("newest", 1, true))
        end)

        it("reports a repository that cannot be reached", function()
            build({ responses = { { err = "host not found" } } })
            plugin:checkForUpdates()
            assert.are.equal("InfoMessage", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("Host not found", 1, true))
        end)
    end)
end)
