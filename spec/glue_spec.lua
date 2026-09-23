--[[--
`main.lua` itself: the buttons it registers, what happens when they are
pressed, and what it shows afterwards.

KOReader is stubbed (see spec/support/koreader.lua), so this runs anywhere the
unit suite does — but it exercises the real plugin file, including the parts
the emulator would otherwise be the only way to reach.
--]]--

local helpers = require("support.helpers")
local koreader = require("support.koreader")
local Config = require("aidict.config")
local Version = require("aidict.version")

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
        -- The committed package carries neither address; both are baked in
        -- at build time. The dictionary's lands in the settings, where the
        -- reader can change it; the library's is not a setting at all. Give
        -- the reader both unless the spec is about not having one.
        local settings = {}
        if not opts.no_endpoint then settings.endpoint = helpers.ENDPOINT end
        Config.BAKED.library_endpoint = opts.no_library_endpoint and "" or helpers.LIBRARY_ENDPOINT
        for key, value in pairs(opts.settings or {}) do settings[key] = value end

        kor = koreader.install({
            responses = opts.responses or { { status = 200, body = ANSWER } },
            online = opts.online,
            can_restart = opts.can_restart,
            settings = settings,
            stores = opts.stores,
        })
        local selected_text = opts.selected_text or { text = "fox", pos0 = "p1", pos1 = "p2" }
        if opts.no_selection then selected_text = nil end

        local paragraph_html = opts.paragraph_html
        if paragraph_html == nil and not opts.no_paragraph then
            paragraph_html = "<p>The quick brown fox jumps over the lazy dog. " ..
                "It had been doing so all afternoon, to nobody's surprise.</p>"
        end

        reader = koreader.reader({
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

    --- A request the way the plugin builds one, for the paths that bypass a
    --- button. The word and passage are what the cache key is made of.
    local function ask(word, passage)
        plugin:explain({
            word = word,
            context = passage,
            sentence = passage,
            request_id = "aidict-spec-" .. word,
        })
    end

    local function tap_highlight_button()
        local builder = reader.highlight_buttons["13_aidict_explain"]
        local button = builder(reader.ui.highlight)
        button.callback()
        return button
    end

    after_each(function()
        koreader.uninstall()
        Config.BAKED.library_endpoint = ""
    end)

    describe("registration", function()
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
        end)
    end)

    describe("explaining from the highlight menu", function()
        it("closes the dialog, asks the gateway and shows the answer", function()
            build()
            tap_highlight_button()

            assert.is_true(reader.ui.highlight.closed)
            assert.are.equal(1, kor.transport.calls)

            local shown = last_shown()
            assert.are.equal("TextViewer", shown.widget_kind)
            assert.are.equal("fox", shown.title)
            assert.is_truthy(shown.text:find("A wild animal of the dog family.", 1, true))
        end)

        it("sends the whole paragraph as context, stripped of its markup", function()
            build()
            tap_highlight_button()

            local sent = helpers.json.decode(kor.transport.requests[1].body)
            assert.are.equal("fox", sent.word)
            assert.is_truthy(sent.context:find("fox", 1, true))
            -- The second sentence is only in the paragraph, not in the sentence.
            assert.is_truthy(sent.context:find("all afternoon", 1, true))
            assert.is_nil(sent.context:find("<p>", 1, true))
        end)

        it("sends the sentence too, cut out of the paragraph", function()
            build()
            tap_highlight_button()

            local sent = helpers.json.decode(kor.transport.requests[1].body)
            assert.are.equal("The quick brown fox jumps over the lazy dog.", sent.sentence)
        end)

        it("sends the sentence the word is in, not the paragraph's first", function()
            build({
                paragraph_html = "<p>The quick brown dog naps. A fox, by contrast, " ..
                    "jumps all afternoon.</p>",
            })
            tap_highlight_button()

            local sent = helpers.json.decode(kor.transport.requests[1].body)
            assert.are.equal("A fox, by contrast, jumps all afternoon.", sent.sentence)
        end)

        it("sends neither passage when there is no paragraph", function()
            build({ no_paragraph = true })
            tap_highlight_button()

            local sent = helpers.json.decode(kor.transport.requests[1].body)
            assert.are.equal("fox", sent.word)
            assert.is_nil(sent.context)
            assert.is_nil(sent.sentence)
        end)

        it("sends the book it was reading", function()
            build()
            tap_highlight_button()

            local sent = helpers.json.decode(kor.transport.requests[1].body)
            assert.are.equal("Aesop's Fables", sent.title)
            assert.are.equal("Aesop", sent.author)
            assert.are.equal("en", sent.source_lang)
        end)

        it("serves the second tap from the cache without a request", function()
            build()
            tap_highlight_button()
            tap_highlight_button()

            assert.are.equal(1, kor.transport.calls)
            assert.is_truthy(last_shown().text:find("cached", 1, true))
        end)

        it("shows the gateway's error instead of an answer", function()
            build({ responses = { { status = 500, body = helpers.body({ error = "model is down" }) } } })
            tap_highlight_button()

            local shown = last_shown()
            assert.are.equal("InfoMessage", shown.widget_kind)
            assert.are.equal("Model is down.", shown.text)
        end)

        it("says so when the request times out", function()
            build({ responses = { { err = "timeout" } } })
            tap_highlight_button()
            assert.is_truthy(last_shown().text:find("in time", 1, true))
        end)

        it("shows nothing when the reader dismisses the wait", function()
            build()
            kor.dismiss_next = true
            tap_highlight_button()
            assert.are.equal(0, #kor.shown)
        end)

        it("asks to be configured when no endpoint was baked in or set", function()
            build({ no_endpoint = true })
            tap_highlight_button()

            assert.are.equal(0, kor.transport.calls)
            assert.are.equal("InfoMessage", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("endpoint", 1, true))
        end)

        it("shows how long the round trip took", function()
            build()
            kor.request_ms = 1500
            tap_highlight_button()

            assert.is_truthy(last_shown().text:find("1.5s", 1, true))
        end)

        it("shows milliseconds when it was quick", function()
            build()
            kor.request_ms = 120
            tap_highlight_button()

            assert.is_truthy(last_shown().text:find("120ms", 1, true))
        end)

        it("names the word in the progress message", function()
            build()
            tap_highlight_button()
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
            timing = { total_ms = 900, upstream_ms = 850,
                       legs = { sense = 350, examples = 500 } },
        })

        local REVIEWED_ANSWER = helpers.body({
            word = "fox",
            definition = "A wild animal of the dog family.",
            examples = { "The fox ran." },
            model = "spec-model",
            timing = { total_ms = 1800, upstream_ms = 1750,
                       legs = { model = 500, review = 350, retry = 900 } },
            review = { sense = 0.17, examples = 1.33, retried = true },
        })

        it("records where the time went, not just how much", function()
            build({ responses = { { status = 200, body = TIMED_ANSWER } } })
            kor.request_ms = 1500
            tap_highlight_button()

            local line = kor.info_lines[#kor.info_lines]
            assert.is_truthy(line:find("fox", 1, true))
            assert.is_truthy(line:find("1500ms", 1, true))
            assert.is_truthy(line:find("gateway 900ms", 1, true))
            -- Which legs there are says which path the gateway took.
            assert.is_truthy(line:find("examples 500ms", 1, true))
            assert.is_truthy(line:find("sense 350ms", 1, true))
            assert.is_truthy(line:find("spec-model", 1, true))
        end)

        it("names no leg the gateway did not run", function()
            build({ responses = { { status = 200, body = TIMED_ANSWER } } })
            tap_highlight_button()
            local line = kor.info_lines[#kor.info_lines]
            assert.is_nil(line:find("retry", 1, true))
            assert.is_nil(line:find("model ", 1, true))
        end)

        it("says when the gateway doubted its own answer and asked again", function()
            build({ responses = { { status = 200, body = REVIEWED_ANSWER } } })
            tap_highlight_button()

            local line = kor.info_lines[#kor.info_lines]
            assert.is_truthy(line:find("retry 900ms", 1, true))
            assert.is_truthy(line:find("sense=0.17", 1, true))
            assert.is_truthy(line:find("RETRIED", 1, true))
        end)

        it("shows the reader the answer, not the doubts about it", function()
            build({ responses = { { status = 200, body = REVIEWED_ANSWER } } })
            tap_highlight_button()

            local shown = last_shown().text
            assert.is_nil(shown:find("sense", 1, true))
            assert.is_nil(shown:find("RETRIED", 1, true))
            assert.is_truthy(shown:find("A wild animal", 1, true))
        end)

        it("logs a question mark rather than crashing on a gateway that sends no timing", function()
            build()
            kor.request_ms = 1500
            tap_highlight_button()

            local line = kor.info_lines[#kor.info_lines]
            assert.is_truthy(line:find("1500ms", 1, true))
            assert.is_truthy(line:find("gateway ?ms", 1, true))
            -- And no leg invented to fill the gap: a named leg that did not
            -- run reads like a measurement, which is worse than a question
            -- mark.
            assert.is_nil(line:find("sense", 1, true))
            assert.is_nil(line:find("model ", 1, true))
        end)

        it("names the request id, so the device log and Axiom can be lined up", function()
            build()
            tap_highlight_button()

            local sent = kor.transport.requests[1].headers["X-Request-Id"]
            assert.is_truthy(sent)
            assert.is_truthy(sent:match("^aidict%-%x+%-%x+$"))
            assert.is_truthy(kor.info_lines[#kor.info_lines]:find(sent, 1, true))
        end)

        it("names Cloudflare's ray alongside it, when there was one", function()
            build({ responses = { {
                status = 200, body = ANSWER,
                headers = { ["cf-ray"] = "a3e2705c8ddcdda5-IAD" },
            } } })
            tap_highlight_button()

            local line = kor.info_lines[#kor.info_lines]
            assert.is_truthy(line:find("cf=a3e2705c8ddcdda5-IAD", 1, true))
        end)

        it("says nothing about a ray when there was none", function()
            build()
            tap_highlight_button()
            assert.is_nil(kor.info_lines[#kor.info_lines]:find("cf=", 1, true))
        end)

        it("names it on a failure too", function()
            build({ responses = { { err = "timeout" } } })
            tap_highlight_button()

            local sent = kor.transport.requests[1].headers["X-Request-Id"]
            assert.is_truthy(kor.warn_lines[#kor.warn_lines]:find(sent, 1, true))
        end)

        it("gives each lookup its own", function()
            build({ responses = {
                { status = 200, body = ANSWER },
                { status = 200, body = ANSWER },
            } })
            ask("fox", "a sentence about a fox")
            ask("dog", "a sentence about a dog")

            assert.are_not.equal(kor.transport.requests[1].headers["X-Request-Id"],
                                 kor.transport.requests[2].headers["X-Request-Id"])
        end)

        it("records the error code when the gateway refuses", function()
            build({ responses = { { status = 429, body = "" } } })
            tap_highlight_button()

            local line = kor.warn_lines[#kor.warn_lines]
            assert.is_truthy(line:find("fox", 1, true))
            assert.is_truthy(line:find("rate_limited", 1, true))
        end)

        it("records a lookup the reader dismissed, without calling it a failure", function()
            build()
            kor.dismiss_next = true
            tap_highlight_button()

            assert.is_truthy(kor.info_lines[#kor.info_lines]:find("dismissed", 1, true))
            assert.are.equal(0, #kor.warn_lines)
        end)

        it("says how long a failure took, so a timeout is not just an error", function()
            build({ responses = { { err = "timeout" } } })
            kor.request_ms = 30000
            tap_highlight_button()

            local line = kor.warn_lines[#kor.warn_lines]
            assert.is_truthy(line:find("30000ms", 1, true))
            assert.is_truthy(line:find("timeout", 1, true))
        end)

        it("records an answer served from the cache, so the log accounts for every tap", function()
            build()
            tap_highlight_button()
            tap_highlight_button()

            assert.are.equal(1, kor.transport.calls)
            assert.is_truthy(kor.info_lines[#kor.info_lines]:find("from cache", 1, true))
        end)

        it("says why it refused to ask when there is no Wi-Fi", function()
            build({ online = false })
            ask("fox", "a sentence with fox in it")

            assert.are.equal(0, kor.transport.calls)
            assert.is_truthy(kor.warn_lines[#kor.warn_lines]:find("offline", 1, true))
        end)

        it("says why it refused to ask with no endpoint", function()
            build({ no_endpoint = true })
            tap_highlight_button()

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

        it("sends no context when the document gives no paragraph", function()
            build({
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

    --[[--
    The popup KOReader opens on a lookup, with the AI page put first in it.
    The order a real lookup goes in: the announcement, then `showDict` with
    whatever the dictionaries found.
    --]]--
    describe("the AI page in the dictionary popup", function()
        local OXFORD = { dict = "Oxford", word = "fox", definition = "a canid" }

        local function look_up(word, results)
            plugin:onWordLookedUp(word)
            reader.ui.dictionary:showDict(word, results or { OXFORD })
            return reader.ui.dictionary.dict_window
        end

        it("opens on the AI page, with the dictionaries behind it", function()
            build()
            kor.defer_scheduled = true     -- the answer is still out
            local popup = look_up("fox")

            assert.are.equal(2, #popup.results)
            assert.are.equal("AI", popup.results[1].dict)
            assert.are.equal(1, popup.dict_index)
            assert.is_truthy(popup.results[1].definition:find("Asking AI", 1, true))
            assert.are.equal(OXFORD, popup.results[2])
        end)

        it("fills the page in when the answer lands, and redraws it", function()
            build()
            kor.defer_scheduled = true
            local popup = look_up("fox")
            kor.run_scheduled()

            assert.is_truthy(popup.results[1].definition:find("A wild animal of the dog family.", 1, true))
            assert.are.equal(1, popup.redraws)
        end)

        it("asks once, not again when the popup opens", function()
            build()
            kor.defer_scheduled = true
            look_up("fox")
            kor.run_scheduled()

            assert.are.equal(1, kor.forks)
            assert.are.equal(1, kor.transport.calls)
        end)

        it("rewrites a page the reader paged away from, without redrawing it", function()
            build()
            kor.defer_scheduled = true
            local popup = look_up("fox")
            popup.dict_index = 2           -- reading Oxford
            kor.run_scheduled()

            assert.is_truthy(popup.results[1].definition:find("A wild animal", 1, true))
            assert.are.equal(0, popup.redraws)
            assert.are.equal(2, popup.dict_index)
        end)

        it("leaves a popup the reader has closed alone", function()
            build()
            kor.defer_scheduled = true
            local popup = look_up("fox")
            popup.closed = true
            kor.run_scheduled()

            assert.is_truthy(popup.results[1].definition:find("Asking AI", 1, true))
            assert.are.equal(0, popup.redraws)
            -- It still landed in the cache, for the next time.
            assert.is_table(kor.store.data["answers"])
        end)

        it("shows the gateway's error where the answer would be", function()
            build({ responses = { { status = 500, body = helpers.body({ error = "model is down" }) } } })
            kor.defer_scheduled = true
            local popup = look_up("fox")
            kor.run_scheduled()

            assert.is_truthy(popup.results[1].definition:find("Model is down.", 1, true))
            assert.are.equal(1, popup.redraws)
            assert.are.equal(OXFORD, popup.results[2])
        end)

        it("shows an answer it already has at once, marked as cached", function()
            build()
            tap_highlight_button()         -- asked some other time
            local popup = look_up("fox")

            assert.are.equal(1, kor.transport.calls)
            assert.is_truthy(popup.results[1].definition:find("A wild animal", 1, true))
            assert.is_truthy(popup.results[1].definition:find("cached", 1, true))
        end)

        it("does not call an answer cached when it beat the dictionary to the screen", function()
            build()                        -- the stub's scheduler lands it at once
            local popup = look_up("fox")

            assert.is_truthy(popup.results[1].definition:find("A wild animal", 1, true))
            assert.is_nil(popup.results[1].definition:find("cached", 1, true))
        end)

        it("gives a word the dictionaries do not know a popup of its own", function()
            build()
            kor.defer_scheduled = true
            local popup = look_up("fox", {})

            assert.are.equal(1, #popup.results)
            assert.are.equal("AI", popup.results[1].dict)
        end)

        it("starts asking itself if the announcement never came", function()
            build()
            kor.defer_scheduled = true
            reader.ui.dictionary:showDict("fox", { OXFORD })
            local popup = reader.ui.dictionary.dict_window

            assert.are.equal(1, kor.forks)
            assert.is_truthy(popup.results[1].definition:find("Asking AI", 1, true))
        end)

        it("says it is busy rather than asking a third word at once", function()
            build()
            kor.defer_scheduled = true
            look_up("fox")
            look_up("dog")
            local popup = look_up("cat")

            assert.are.equal(2, kor.forks)
            assert.is_truthy(popup.results[1].definition:find("again", 1, true))
        end)

        it("is not there offline: the popup is KOReader's own", function()
            build({ online = false })
            local popup = look_up("fox")

            assert.are.same({ OXFORD }, popup.results)
            assert.are.equal(0, kor.transport.calls)
        end)

        it("is not there without an endpoint", function()
            build({ no_endpoint = true })
            local popup = look_up("fox")

            assert.are.same({ OXFORD }, popup.results)
        end)

        it("still opens the popup when its own part breaks", function()
            build()
            plugin.requestFor = function() error("KOReader moved something") end
            reader.ui.dictionary:showDict("fox", { OXFORD })
            local popup = reader.ui.dictionary.dict_window

            assert.are.same({ OXFORD }, popup.results)
            assert.is_truthy(kor.warn_lines[#kor.warn_lines]:find("could not add the AI page", 1, true))
        end)

        it("forgets its pages when the document closes", function()
            build()
            kor.defer_scheduled = true
            look_up("fox")
            plugin:onCloseDocument()

            assert.are.same({}, plugin.ai_pages)
        end)
    end)

    describe("being offline", function()
        it("does not offer the button at all", function()
            build({ online = false })

            local button = reader.highlight_buttons["13_aidict_explain"](reader.ui.highlight)
            assert.is_false(button.show_in_highlight_dialog_func())
        end)

        it("offers it once Wi-Fi is up", function()
            build()

            local button = reader.highlight_buttons["13_aidict_explain"](reader.ui.highlight)
            assert.is_true(button.show_in_highlight_dialog_func())
        end)

        it("asks nothing and says why, if it is reached anyway", function()
            build({ online = false })
            tap_highlight_button()

            assert.are.equal(0, kor.transport.calls)
            assert.are.equal("InfoMessage", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("Wi%-Fi"))
        end)

        it("still shows an answer it already has", function()
            build()
            tap_highlight_button()
            local saved = kor.store.data["answers"]
            koreader.uninstall()

            build({ online = false, settings = { answers = saved } })
            tap_highlight_button()

            assert.are.equal(0, kor.transport.calls)
            assert.are.equal("TextViewer", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("cached", 1, true))
        end)
    end)

    --[[--
    The dictionary announces every lookup before it has even searched, and
    that is when the plugin starts asking — so the answer is on its way before
    the popup has opened, and in the cache for anything that asks again.
    --]]--
    describe("looking a word up before it is asked for", function()
        local prefetching = build

        it("asks as soon as the dictionary opens", function()
            prefetching()
            plugin:onWordLookedUp("fox")

            assert.are.equal(1, kor.forks)
            assert.are.equal(1, kor.transport.calls)
        end)

        it("puts the answer in the cache, where anything asking again finds it", function()
            prefetching()
            plugin:onWordLookedUp("fox")
            tap_highlight_button()

            -- Still one request: the menu found the answer already there.
            assert.are.equal(1, kor.transport.calls)
            local shown = last_shown()
            assert.are.equal("TextViewer", shown.widget_kind)
            assert.is_truthy(shown.text:find("A wild animal of the dog family.", 1, true))
            assert.is_truthy(shown.text:find("cached", 1, true))
        end)

        it("is found from the highlight menu too, which builds its own request", function()
            -- The two entry points build the request separately; if they ever
            -- disagree about the passage, the fetched-ahead answer is orphaned
            -- and the reader waits for a second identical lookup.
            prefetching()
            plugin:onWordLookedUp("fox")
            tap_highlight_button()

            assert.are.equal(1, kor.transport.calls)
            assert.is_truthy(last_shown().text:find("cached", 1, true))
        end)

        it("writes the cache to disk, so it survives the session too", function()
            prefetching()
            plugin:onWordLookedUp("fox")

            local saved = kor.store.data["answers"]
            assert.is_table(saved)
            assert.is_true(#saved > 0)
        end)

        it("never swallows the event — the dictionary wanted it", function()
            prefetching()
            assert.is_false(plugin:onWordLookedUp("fox"))
        end)

        it("does not ask twice for a word already in the air", function()
            prefetching()
            plugin:onWordLookedUp("fox")
            plugin:onWordLookedUp("fox")

            assert.are.equal(1, kor.forks)
        end)

        it("does not ask for an answer it already has", function()
            prefetching()
            tap_highlight_button()          -- fetched and cached the ordinary way
            plugin:onWordLookedUp("fox")

            assert.are.equal(0, kor.forks)
            assert.are.equal(1, kor.transport.calls)
        end)

        it("stays quiet with no Wi-Fi", function()
            prefetching({ online = false })
            plugin:onWordLookedUp("fox")

            assert.are.equal(0, kor.forks)
            assert.are.equal(0, kor.transport.calls)
        end)

        it("stays quiet with no endpoint to ask", function()
            prefetching({ no_endpoint = true })
            plugin:onWordLookedUp("fox")

            assert.are.equal(0, kor.forks)
        end)

        it("marks an answer that was already waiting as cached", function()
            prefetching()
            plugin:onWordLookedUp("fox")   -- prefetch runs and lands
            tap_highlight_button()

            local shown = last_shown()
            assert.is_truthy(shown.text:find("cached", 1, true))
            assert.is_nil(shown.text:find("prefetch", 1, true))
        end)

        it("marks an answer the reader waited for as prefetch, not cached", function()
            -- The reader tapped while the prefetch was still in the air:
            -- they watched a spinner. Calling that "cached" is what made it
            -- impossible to tell whether the prefetch was doing anything.
            prefetching()
            kor.defer_scheduled = true     -- the prefetch stays in flight
            plugin:onWordLookedUp("fox")
            tap_highlight_button()              -- joins it rather than asking again
            kor.run_scheduled()

            local shown = last_shown()
            assert.are.equal("TextViewer", shown.widget_kind)
            assert.is_truthy(shown.text:find("prefetch", 1, true))
            assert.is_nil(shown.text:find("cached", 1, true))
            -- And it joined rather than asking a second time.
            assert.are.equal(1, kor.transport.calls)
        end)

        it("says nothing to the reader, whatever happens", function()
            prefetching()
            plugin:onWordLookedUp("fox")

            -- Nobody asked for this lookup; it must not put a widget on screen.
            assert.are.equal(0, #kor.shown)
        end)

        it("records the one it fetched ahead, with its id", function()
            prefetching()
            plugin:onWordLookedUp("fox")

            local line = kor.info_lines[#kor.info_lines]
            assert.is_truthy(line:find("fox", 1, true))
            assert.is_truthy(line:find("fetched ahead", 1, true))
        end)

        it("survives a fork that never happens", function()
            prefetching()
            kor.fork_fails = true
            plugin:onWordLookedUp("fox")

            assert.are.equal(0, kor.transport.calls)
            assert.is_truthy(kor.warn_lines[#kor.warn_lines]:find("fork", 1, true))
            -- The button must still work afterwards.
            kor.fork_fails = false
            tap_highlight_button()
            assert.are.equal(1, kor.transport.calls)
        end)

        it("survives a subprocess that dies without a word", function()
            prefetching()
            kor.writes_nothing = true
            plugin:onWordLookedUp("fox")

            assert.is_truthy(kor.warn_lines[#kor.warn_lines]:find("came to nothing", 1, true))
        end)

        it("caches nothing when the gateway refuses, so the button still asks", function()
            prefetching({ responses = { { status = 500, body = "" } } })
            plugin:onWordLookedUp("fox")

            assert.is_truthy(kor.warn_lines[#kor.warn_lines]:find("ahead failed", 1, true))
            tap_highlight_button()
            assert.are.equal(2, kor.transport.calls)
        end)

        it("frees the slot again once it is done, however it went", function()
            prefetching({ responses = { { status = 500, body = "" } } })
            plugin:onWordLookedUp("fox")
            assert.are.equal(0, plugin.prefetch:pending())
        end)

        it("lets go of everything when the document closes", function()
            prefetching()
            plugin:onWordLookedUp("fox")
            plugin:onCloseDocument()

            assert.are.equal(0, plugin.prefetch:pending())
            assert.are.same({}, plugin.prefetch_jobs)
        end)

        it("waits and looks again when the answer is not ready yet", function()
            prefetching()
            kor.ready_after_polls = 3
            plugin:onWordLookedUp("fox")

            assert.is_true(kor.polls > 3)
            -- It still landed: polling is about patience, not about giving up.
            tap_highlight_button()
            assert.are.equal(1, kor.transport.calls)
            assert.is_truthy(last_shown().text:find("cached", 1, true))
        end)

        it("kills a subprocess that never comes back, rather than polling forever", function()
            prefetching()
            kor.never_ready = true
            -- The deadline is set from the first reading and every later one
            -- is long past it, so the give-up branch is reached on the first
            -- poll rather than half a minute later.
            local readings = 0
            plugin.now = function()
                readings = readings + 1
                return os.time() + (readings > 1 and 10000 or 0)
            end
            plugin:onWordLookedUp("fox")

            assert.are.equal(1, kor.terminated)
            assert.are.equal(0, plugin.prefetch:pending())
            assert.is_truthy(kor.warn_lines[#kor.warn_lines]:find("gave up", 1, true))
        end)

        it("closes the pipe on every way out, so a reader never runs out of them", function()
            for _, setup in ipairs({
                function() end,                                  -- the ordinary way
                function() kor.writes_nothing = true end,        -- died silently
            }) do
                prefetching()
                setup()
                plugin:onWordLookedUp("fox")
                assert.is_true(kor.fds_closed >= 1)
            end
        end)

        it("joins the request already in the air instead of asking twice", function()
            -- The reason this matters: the gateway takes seconds, so pressing
            -- AI while the prefetch is still out is the ordinary case, not a
            -- race. A second identical request costs twice and lands no sooner.
            prefetching()
            local key = require("aidict.lookup").key(plugin:requestFor("fox", reader.ui.highlight))
            plugin.prefetch:began(key)
            kor.defer_scheduled = true

            tap_highlight_button()

            assert.are.equal(0, kor.transport.calls)
            assert.is_truthy(last_shown().text:find("Asking AI", 1, true))
        end)

        it("shows the answer the moment the one it waited for lands", function()
            prefetching()
            local request = plugin:requestFor("fox", reader.ui.highlight)
            local key = require("aidict.lookup").key(request)
            plugin.prefetch:began(key)
            kor.defer_scheduled = true
            tap_highlight_button()

            -- The prefetch finishes: its answer goes to the cache and the slot
            -- is freed, exactly as finishPrefetch does it.
            plugin.lookup:remember(request, {
                word = "fox", definition = "A wild animal of the dog family.",
            })
            plugin.prefetch:ended(key)
            kor.run_scheduled()

            assert.are.equal(0, kor.transport.calls)
            assert.is_truthy(last_shown().text:find("A wild animal", 1, true))
        end)

        it("asks properly when the one it waited for came to nothing", function()
            prefetching()
            local key = require("aidict.lookup").key(plugin:requestFor("fox", reader.ui.highlight))
            plugin.prefetch:began(key)
            kor.defer_scheduled = true
            tap_highlight_button()
            -- Nothing asked yet: it is waiting on the one already out.
            assert.are.equal(0, kor.transport.calls)

            -- It ended without writing an answer: the reader must not be left
            -- with a spinner and nothing behind it.
            plugin.prefetch:ended(key)
            kor.run_scheduled()

            assert.are.equal(1, kor.transport.calls)
            assert.is_truthy(last_shown().text:find("A wild animal", 1, true))
        end)
    end)

    describe("the cache on disk", function()
        it("throws away answers kept under the old key, which lack the headword", function()
            build({ settings = { cache_entries = { { key = "x", value = {} } } } })
            assert.is_nil(kor.store.data["cache_entries"])
        end)

        it("is written after a successful lookup", function()
            build()
            tap_highlight_button()

            local saved = kor.store.data["answers"]
            assert.is_table(saved)
            assert.are.equal(1, #saved)
            assert.are.equal("A wild animal of the dog family.", saved[1].value.definition)
        end)

        it("is read back by the next reader session", function()
            build()
            tap_highlight_button()
            local saved = kor.store.data["answers"]
            koreader.uninstall()

            build({ settings = { answers = saved } })
            tap_highlight_button()

            assert.are.equal(0, kor.transport.calls)
            assert.is_truthy(last_shown().text:find("cached", 1, true))
        end)

        it("is emptied by the menu item", function()
            build()
            tap_highlight_button()

            local items = {}
            plugin:addToMainMenu(items)
            for _, item in ipairs(items.aidict.sub_item_table) do
                local label = item.text_func and item.text_func() or item.text
                if label:find("Clear cache") then item.callback() end
            end

            assert.are.same({}, kor.store.data["answers"])
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

            tap_highlight_button()
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

        -- The library's address comes with the package, from a CI secret, so
        -- the menu shows which one this build carries and nothing more.
        it("shows the library address, and says so when there is none", function()
            build({ no_library_endpoint = true })
            local _, missing = menu_item("Library")
            assert.are.equal("Library: not set", missing)

            koreader.uninstall()
            build()
            local _, set = menu_item("Library")
            assert.are.equal("Library: " .. helpers.LIBRARY_ENDPOINT, set)
        end)

        it("does not let the library address be edited on the device", function()
            build()
            local item = menu_item("Library")
            assert.is_nil(item.callback)
            assert.is_true(item.keep_menu_open)
        end)

        -- 0.2.57 let the address be typed in, so a device may still hold one
        -- in its settings. Only the package's counts.
        it("syncs against the package's library address, not a saved one", function()
            build({
                settings = { library_endpoint = "https://stale.test/koreader-library" },
                responses = { { status = 200, body = helpers.body({ version = 1, files = {} }) } },
            })

            plugin:syncLibrary()

            assert.are.equal(helpers.LIBRARY_ENDPOINT .. "/manifest", kor.transport.requests[1].url)
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
            assert.are.equal("ConfirmBox", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("9.9.9", 1, true))
            assert.are.equal("Install", last_shown().ok_text)
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

    describe("installing an update", function()
        local KPM = "/var/local/kmc/kindlehf/bin/kpm"

        local function withKpm(opts)
            opts = opts or {}
            build({ settings = opts.settings })
            -- KPM is a real binary on a Kindle; here it is a path that exists
            -- and a canned thing for it to have printed.
            kor.files[KPM] = 1
            kor.shell = opts.shell or { output = "Installed 1 package(s) succesfully." }
            return plugin
        end

        it("runs KPM on this package, and only this one", function()
            withKpm():installUpdate("9.9.9")

            local command = kor.commands[1]
            assert.is_truthy(command:find("-y install 'koreader-aidict'", 1, true))
            assert.is_truthy(command:find("LD_LIBRARY_PATH='/var/local/kmc/kindlehf/lib'", 1, true))
            -- `kpm upgrade` would walk every package the reader has.
            assert.is_nil(command:find(" upgrade", 1, true))
        end)

        it("offers the restart that loads the new code, rather than taking it", function()
            withKpm():installUpdate("9.9.9")

            assert.are.equal("ConfirmBox", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("Restart", 1, true))
            assert.are.equal(0, #kor.broadcast)

            last_shown().ok_callback()
            assert.are.equal("Restart", kor.broadcast[1].name)
        end)

        it("says so plainly on a device that cannot restart itself", function()
            build({ can_restart = false })
            kor.files[KPM] = 1
            kor.shell = { output = "Installed 1 package(s) succesfully." }

            plugin:installUpdate("9.9.9")

            assert.are.equal("InfoMessage", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("Restart KOReader", 1, true))
        end)

        it("quotes KPM's own failure instead of swallowing it", function()
            withKpm({ shell = {
                output = "Failed to install packages (3: could not reach the repository)",
                ok_status = false,
            } }):installUpdate("9.9.9")

            assert.are.equal("InfoMessage", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("could not reach the repository", 1, true))
            assert.are.equal(0, #kor.broadcast)
        end)

        it("falls back to the search bar when the device has no KPM", function()
            build()
            kor.shell = { output = "should never run" }

            plugin:installUpdate("9.9.9")

            assert.are.equal(0, #kor.commands)
            assert.is_truthy(last_shown().text:find(";kpm install koreader-aidict", 1, true))
        end)

        it("waits for Wi-Fi rather than failing on it", function()
            build({ online = false })
            kor.files[KPM] = 1

            plugin:installUpdate("9.9.9")

            assert.are.equal(0, #kor.commands)
            assert.is_function(kor.deferred)
        end)
    end)

    describe("the book library", function()
        local BOOKS = "/mnt/us/books"

        local function manifest(files)
            return helpers.body({ version = 1, files = files })
        end

        local function book(path, size)
            return { path = path, size = size, etag = "e", url = "https://r2.test/" .. path .. "?sig=x" }
        end

        local function menu_item(matcher)
            local items = {}
            plugin:addToMainMenu(items)
            for _, item in ipairs(items.aidict.sub_item_table) do
                local label = item.text_func and item.text_func() or item.text
                if label:find(matcher) then return item, label end
            end
        end

        local function items()
            local registered = {}
            plugin:addToMainMenu(registered)
            return registered
        end

        it("puts AI dictionary at the top of Tools, not at the end of it", function()
            build()

            -- Appending is what a sorting_hint alone would do, and Tools is
            -- already two pages long — so the entry has to claim the top.
            for _, order in pairs(kor.menu_order) do
                assert.are.equal("aidict", order.tools[1])
            end
            assert.are.equal("AI dictionary", items().aidict.text)
        end)

        it("opens with the three actions, the sync first", function()
            build()
            local sub = items().aidict.sub_item_table

            assert.are.equal("Sync library", sub[1].text)
            assert.are.equal("Send Kindle lookups", sub[2].text)
            -- The version rides on the label: after an update and a restart,
            -- the menu itself is the receipt.
            assert.are.equal("Update the plugin (" .. Version.string .. ")", sub[3].text_func())
            assert.is_true(sub[3].separator)
        end)

        -- The update line already carries it, second from the top.
        it("does not repeat the version on a line of its own", function()
            build()
            for _, item in ipairs(items().aidict.sub_item_table) do
                local label = item.text_func and item.text_func() or item.text
                assert.is_nil(label:find("^Version"))
            end
        end)

        it("registers nothing else in the main menu", function()
            build()
            local ids = {}
            for id in pairs(items()) do ids[#ids + 1] = id end
            assert.are.same({ "aidict" }, ids)
        end)

        it("claims that place once, however many times it is built", function()
            -- init runs once for the FileManager and once for the Reader.
            build()
            local first = #kor.menu_order.reader.tools
            kor.plugin_class:new({ ui = reader.ui, document = reader.document })

            assert.are.equal(first, #kor.menu_order.reader.tools)
            assert.are.equal("aidict", kor.menu_order.reader.tools[1])
        end)

        it("keeps the folder in the plugin's own settings, and picks it", function()
            build()
            local _, label = menu_item("Books folder")
            assert.are.equal("Books folder: /mnt/us/AI_Books", label)

            menu_item("Books folder").callback()
            assert.is_not_nil(kor.path_chooser)
            assert.is_false(kor.path_chooser.select_file)

            kor.path_chooser.onConfirm("/mnt/us/elsewhere")
            assert.are.equal("/mnt/us/elsewhere", kor.store.data.library_dir)
        end)

        it("downloads what the device does not have", function()
            build({
                settings = { library_dir = BOOKS },
                responses = {
                    { status = 200, body = manifest({ book("Lem/Solaris.epub", 10) }) },
                    { status = 200, bytes = 10 },
                },
            })

            plugin:syncLibrary()

            -- The library mount, from its own setting.
            assert.are.equal("https://gw.test/koreader-library/manifest", kor.transport.requests[1].url)
            assert.are.equal(BOOKS .. "/Lem/Solaris.epub.part", kor.transport.requests[2].download_to)
            assert.are.equal(10, kor.files[BOOKS .. "/Lem/Solaris.epub"])
            assert.is_truthy(last_shown().text:find("Downloaded 1 of 1", 1, true))
        end)

        it("says so when there is nothing new", function()
            build({
                settings = { library_dir = BOOKS },
                responses = { { status = 200, body = manifest({ book("A.epub", 10) }) } },
            })
            kor.files[BOOKS .. "/A.epub"] = 10

            plugin:syncLibrary()

            assert.are.equal(1, #kor.transport.requests)
            assert.is_truthy(last_shown().text:find("Nothing new", 1, true))
        end)

        it("names the book that failed rather than only counting it", function()
            build({
                settings = { library_dir = BOOKS },
                responses = {
                    { status = 200, body = manifest({ book("A.epub", 10) }) },
                    { status = 403 },
                },
            })

            plugin:syncLibrary()

            local text = last_shown().text
            assert.is_truthy(text:find("A.epub", 1, true))
            assert.is_truthy(text:find("expired", 1, true))
        end)

        -- And specifically for its own: the dictionary's address is no route
        -- to it now that one is a Worker and the other is the gateway.
        it("says the package has no library address rather than syncing into nowhere", function()
            build({ no_library_endpoint = true })

            plugin:syncLibrary()

            assert.are.equal(0, kor.transport.calls)
            assert.is_truthy(last_shown().text:find("library address", 1, true))
        end)

        it("does not fall back to the dictionary's address", function()
            build({ no_library_endpoint = true, settings = { library_dir = BOOKS } })

            plugin:syncLibrary()

            assert.are.equal(0, kor.transport.calls)
        end)

        it("waits for Wi-Fi instead of failing on it", function()
            build({
                online = false,
                settings = { library_dir = BOOKS },
                responses = { { status = 200, body = manifest({}) } },
            })

            plugin:syncLibrary()

            assert.are.equal(0, kor.transport.calls)
            assert.is_function(kor.deferred)
        end)

        it("is an action a gesture can be bound to, and the event runs it", function()
            build({
                settings = { library_dir = BOOKS },
                responses = { { status = 200, body = manifest({}) } },
            })

            assert.are.equal("Sync library", kor.actions["aidict_sync_library"].title)
            assert.are.equal("AiDictSyncLibrary", kor.actions["aidict_sync_library"].event)

            plugin:onAiDictSyncLibrary()
            assert.are.equal(1, kor.transport.calls)
        end)

        it("reports the gateway's own failure", function()
            build({
                settings = { library_dir = BOOKS },
                responses = { { status = 500, body = "" } },
            })

            plugin:syncLibrary()

            assert.are.equal("InfoMessage", last_shown().widget_kind)
        end)

        describe("when the server moved or deleted a book", function()
            local FROM = BOOKS .. "/English/Fiction/x.epub"
            local TO = BOOKS .. "/English/Business/x.epub"

            --- A device where an earlier sync put `placed` (path -> size),
            --- and a gateway that now lists `listed`.
            local function synced_before(placed, listed, extra)
                extra = extra or {}
                local books = {}
                for path, size in pairs(placed) do
                    books[path] = { size = size, etag = "e-" .. path:match("([^/]*)$") }
                end
                local files = {}
                for _, file in ipairs(listed) do
                    file.etag = "e-" .. file.path:match("([^/]*)$")
                    files[#files + 1] = file
                end
                build({
                    settings = { library_dir = BOOKS },
                    stores = { ["aidict_library.lua"] = { dir = extra.index_dir or BOOKS, books = books } },
                    responses = { { status = 200, body = manifest(files) } },
                })
                for path, size in pairs(placed) do kor.files[BOOKS .. "/" .. path] = size end
            end

            local function saved_index()
                return kor.stores["aidict_library.lua"]
            end

            it("moves the book with its reading state, the way the file manager does", function()
                synced_before({ ["English/Fiction/x.epub"] = 10 }, { book("English/Business/x.epub", 10) })

                plugin:syncLibrary()

                -- No download: the manifest was the only request.
                assert.are.equal(1, kor.transport.calls)
                assert.are.same({
                    "rename " .. FROM .. " -> " .. TO,
                    "DocSettings.updateLocation " .. FROM .. " -> " .. TO,
                    "ReadHistory:updateItem " .. FROM .. " -> " .. TO,
                    "ReadCollection:updateItem " .. FROM .. " -> " .. TO,
                }, kor.book_calls)
                assert.are.equal(10, kor.files[TO])
                assert.is_true(kor.dirs[BOOKS .. "/English/Business"])
                assert.are.same({ BOOKS .. "/English/Fiction" }, kor.rmdirs)
                assert.is_truthy(last_shown().text:find("Moved 1", 1, true))
            end)

            it("remembers where the book is now", function()
                synced_before({ ["English/Fiction/x.epub"] = 10 }, { book("English/Business/x.epub", 10) })

                plugin:syncLibrary()

                local store = saved_index()
                assert.are.equal(BOOKS, store.data.dir)
                assert.are.same({ ["English/Business/x.epub"] = { size = 10, etag = "e-x.epub" } },
                    store.data.books)
                assert.are.equal(1, store.flushed)
            end)

            it("deletes the book and what KOReader kept about it, the way the file manager does", function()
                synced_before({ ["Gone.epub"] = 20 }, {})

                plugin:syncLibrary()

                local gone = BOOKS .. "/Gone.epub"
                assert.are.same({
                    "remove " .. gone,
                    "BookList.resetBookInfoCache " .. gone,
                    "DocSettings.updateLocation " .. gone,
                    "ReadHistory:fileDeleted " .. gone,
                    "ReadCollection:removeItem " .. gone,
                }, kor.book_calls)
                assert.is_nil(kor.files[gone])
                assert.are.same({}, saved_index().data.books)
                assert.is_truthy(last_shown().text:find("Deleted 1", 1, true))
            end)

            it("leaves the book that is open, and says it will move next time", function()
                synced_before({ ["English/Fiction/x.epub"] = 10 }, { book("English/Business/x.epub", 10) })
                kor.reader_ui.instance = { document = { file = FROM } }

                plugin:syncLibrary()

                assert.are.same({}, kor.book_calls)
                assert.are.equal(10, kor.files[FROM])
                assert.are.same({ ["English/Fiction/x.epub"] = { size = 10, etag = "e-x.epub" } },
                    saved_index().data.books)
                assert.is_truthy(last_shown().text:find("x.epub is open, so it moves on the next sync.", 1, true))
            end)

            it("knows the open book from its own reader too", function()
                synced_before({ ["Gone.epub"] = 20 }, {})
                reader.ui.document = { file = BOOKS .. "/Gone.epub" }

                plugin:syncLibrary()

                assert.are.equal(20, kor.files[BOOKS .. "/Gone.epub"])
                assert.is_truthy(last_shown().text:find("Gone.epub is open, so it is deleted on the next sync.", 1, true))
            end)

            it("never deletes a file it did not put there", function()
                synced_before({}, {})
                kor.files[BOOKS .. "/Mine.pdf"] = 3

                plugin:syncLibrary()

                assert.are.equal(3, kor.files[BOOKS .. "/Mine.pdf"])
                assert.are.same({}, kor.book_calls)
            end)

            -- The reader pointed the sync at another folder: what the old
            -- index lists is not this folder's to delete.
            it("starts a fresh index when the books folder changed", function()
                synced_before({ ["Gone.epub"] = 20 }, {}, { index_dir = "/mnt/us/Old_Books" })

                plugin:syncLibrary()

                assert.are.equal(20, kor.files[BOOKS .. "/Gone.epub"])
                assert.are.same({}, kor.book_calls)
                assert.are.equal(BOOKS, saved_index().data.dir)
            end)

            it("puts the book back when its reading state cannot follow, for the next sync to retry", function()
                synced_before({ ["English/Fiction/x.epub"] = 10 }, { book("English/Business/x.epub", 10) })
                kor.docsettings_error = "sidecar unreadable"

                plugin:syncLibrary()

                assert.are.equal(10, kor.files[FROM])
                assert.is_nil(kor.files[TO])
                assert.is_truthy(kor.warn_lines[1]:find("sidecar unreadable", 1, true))
                assert.is_truthy(last_shown().text:find("could not be moved", 1, true))
                -- Still indexed where it is, so the next sync plans the move again.
                assert.is_not_nil(saved_index().data.books["English/Fiction/x.epub"])
            end)

            it("takes the file browser up to the library when its folder is gone", function()
                synced_before({ ["English/Fiction/x.epub"] = 10 }, { book("English/Business/x.epub", 10) })
                local went
                reader.ui.file_chooser = {
                    path = BOOKS .. "/English/Fiction",
                    refreshPath = function() went = "refresh" end,
                    changeToPath = function(_, path) went = path end,
                }

                plugin:syncLibrary()

                assert.are.equal(BOOKS, went)
            end)
        end)

        it("indexes the books a first sync finds and fetches", function()
            build({
                settings = { library_dir = BOOKS },
                responses = {
                    { status = 200, body = manifest({ book("A.epub", 10), book("B.epub", 5) }) },
                    { status = 200, bytes = 5 },
                },
            })
            kor.files[BOOKS .. "/A.epub"] = 10

            plugin:syncLibrary()

            assert.are.same({ ["A.epub"] = { size = 10, etag = "e" }, ["B.epub"] = { size = 5, etag = "e" } },
                kor.stores["aidict_library.lua"].data.books)
            assert.are.equal(BOOKS, kor.stores["aidict_library.lua"].data.dir)
        end)
    end)
    describe("sending the Kindle's lookups", function()
        local Vocab = require("aidict.vocab")

        local function lookup(id, timestamp)
            return { id, "6032", "He was strapped into the seat.", timestamp,
                "strapped", "strap", "en", "B000FC1PJI", "A Book", "An Author" }
        end

        local function receipt(created, existing)
            return { status = 200, body = helpers.body({ created = created, existing = existing or 0, skipped = 0 }) }
        end

        local function withVocab(opts, rows)
            build(opts)
            kor.files[Vocab.PATH] = 1
            kor.vocab_rows = rows
        end

        it("sends what is new since the last upload, and remembers how far it got", function()
            withVocab({
                settings = { vocab_uploaded_through = 2000 },
                responses = { receipt(1, 1) },
            }, { lookup("lk-1", 1000), lookup("lk-2", 2000), lookup("lk-3", 3000) })

            plugin:sendVocab()

            -- Asked first, with the number that is actually new: the lookup
            -- at the cursor comes back from `>=` and has already been sent.
            assert.are.equal("ConfirmBox", last_shown().widget_kind)
            assert.are.equal("New lookups since the last upload: 1\n\nSend them to the word inbox?", last_shown().text)
            assert.are.equal("Send", last_shown().ok_text)
            assert.are.equal(0, kor.transport.calls)
            last_shown().ok_callback()

            -- Read-only: the Kindle's own reader owns the file.
            assert.are.same({ path = Vocab.PATH, mode = "ro" }, kor.vocab_opened)
            assert.is_true(kor.vocab_closed)
            assert.are.equal(1, kor.transport.calls)
            assert.are.equal(helpers.ENDPOINT .. "/vocab", kor.transport.requests[1].url)
            local body = helpers.json.decode(kor.transport.requests[1].body)
            assert.are.equal(2, #body.rows)
            assert.are.equal("lk-2", body.rows[1].lookup_id)

            assert.are.equal(3000, kor.store.data.vocab_uploaded_through)
            assert.are.equal("Sent 2 lookups: 1 new, 1 already there.", last_shown().text)
        end)

        it("sends the whole archive the first time", function()
            withVocab({ responses = { receipt(2) } }, { lookup("lk-1", 1000), lookup("lk-2", 2000) })

            plugin:sendVocab()
            assert.is_truthy(last_shown().text:find("Lookups on this Kindle: 2", 1, true))
            last_shown().ok_callback()

            assert.are.equal(2, #helpers.json.decode(kor.transport.requests[1].body).rows)
            assert.are.equal(2000, kor.store.data.vocab_uploaded_through)
        end)

        it("says so when there is nothing new, and sends nothing", function()
            withVocab({ settings = { vocab_uploaded_through = 5000 } }, { lookup("lk-1", 1000) })

            plugin:sendVocab()

            assert.are.equal(0, kor.transport.calls)
            assert.are.equal("Nothing new since the last upload.", last_shown().text)
        end)

        it("sends nothing when the reader says no", function()
            withVocab({ responses = { receipt(1) } }, { lookup("lk-1", 1000) })

            plugin:sendVocab()

            assert.are.equal("ConfirmBox", last_shown().widget_kind)
            assert.are.equal(0, kor.transport.calls)
            assert.is_nil(kor.store.data.vocab_uploaded_through)
        end)

        it("does not ask about the one lookup it sent last time", function()
            withVocab({ settings = { vocab_uploaded_through = 2000 } }, { lookup("lk-1", 2000) })

            plugin:sendVocab()

            assert.are.equal("Nothing new since the last upload.", last_shown().text)
            assert.are.equal(0, kor.transport.calls)
        end)

        it("keeps what arrived before a failure", function()
            local rows = {}
            for i = 1, Vocab.BATCH + 1 do rows[i] = lookup("lk-" .. i, i) end
            withVocab({
                responses = {
                    receipt(Vocab.BATCH),
                    { status = 502, body = helpers.body({ error = { message = "the word inbox did not answer (TypeError)" } }) },
                },
            }, rows)

            plugin:sendVocab()
            last_shown().ok_callback()

            assert.are.equal(Vocab.BATCH, kor.store.data.vocab_uploaded_through)
            local text = last_shown().text
            assert.is_truthy(text:find("The word inbox did not answer", 1, true))
            assert.is_truthy(text:find("100 new lookups arrived", 1, true))
        end)

        it("says when the device has no vocab.db", function()
            build()

            plugin:sendVocab()

            assert.are.equal(0, kor.transport.calls)
            assert.is_nil(kor.vocab_opened)
            assert.is_truthy(last_shown().text:find("no vocab.db", 1, true))
        end)

        it("says when vocab.db cannot be opened", function()
            withVocab({}, {})
            kor.vocab_error = "database is locked"

            plugin:sendVocab()

            assert.are.equal(0, kor.transport.calls)
            assert.is_truthy(last_shown().text:find("database is locked", 1, true))
        end)

        it("waits for Wi-Fi instead of failing on it", function()
            withVocab({ online = false }, { lookup("lk-1", 1) })

            plugin:sendVocab()
            last_shown().ok_callback()

            assert.are.equal(0, kor.transport.calls)
            assert.is_function(kor.deferred)
        end)

        it("is an action a gesture can be bound to, and the event runs it", function()
            withVocab({ responses = { receipt(1) } }, { lookup("lk-1", 1) })

            assert.are.equal("Send Kindle lookups", kor.actions["aidict_send_vocab"].title)
            assert.are.equal("AiDictSendVocab", kor.actions["aidict_send_vocab"].event)

            plugin:onAiDictSendVocab()
            assert.are.equal("ConfirmBox", last_shown().widget_kind)
            last_shown().ok_callback()
            assert.are.equal(1, kor.transport.calls)
        end)
    end)
end)
