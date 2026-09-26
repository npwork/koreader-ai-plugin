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

--- The library's one answer to Sync: the books, the settings to apply, and the
--- newest plugin, which is this one unless a spec says otherwise.
local function synced(opts)
    opts = opts or {}
    return { status = 200, body = helpers.body({
        manifest = { version = 1, files = opts.files or {} },
        apply = opts.apply or {},
        -- `plugin = false`: the library could not read the release.
        plugin = opts.plugin ~= false and { version = opts.plugin or Version.string, channel = "stable" } or nil,
    }) }
end

describe("the KOReader layer", function()
    local kor, reader, plugin

    local function build(opts)
        opts = opts or {}
        -- The committed package carries neither address; both are baked in
        -- at build time, the dictionary's as its setting's default and the
        -- library's as a value that is not a setting at all. Give the reader
        -- both unless the spec is about not having one.
        local settings = {}
        Config.DEFAULTS.endpoint = opts.no_endpoint and "" or helpers.ENDPOINT
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
        Config.DEFAULTS.endpoint = ""
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
            assert.are.equal(3, #items.aidict.sub_item_table)
            assert.are.equal("Sync", items.aidict_sync.text)
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

        it("keeps KOReader's query line off the AI page, and on the others", function()
            build()
            local DictQuickLookup = require("ui/widget/dictquicklookup")
            local popup = look_up("fox")

            popup.definition = "entry"
            DictQuickLookup.addQueryWordToResult(popup)
            assert.are.equal("entry", popup.definition)

            local plain = { word = "fox", results = { OXFORD }, definition = "entry" }
            DictQuickLookup.addQueryWordToResult(plain)
            assert.are.equal("entry(query : fox)", plain.definition)
        end)

        it("wraps the query line once however many books are opened", function()
            build()
            local DictQuickLookup = require("ui/widget/dictquicklookup")
            local wrapped = DictQuickLookup.addQueryWordToResult
            plugin:joinDictionaryPopup()
            assert.are.equal(wrapped, DictQuickLookup.addQueryWordToResult)
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
            assert.is_table(kor.store.data["entries"])
        end)

        it("turns to the dictionary when the answer fails, leaving the error on the AI page", function()
            build({ responses = { { status = 500, body = helpers.body({ error = "model is down" }) } } })
            kor.defer_scheduled = true
            local popup = look_up("fox")
            kor.run_scheduled()

            assert.is_truthy(popup.results[1].definition:find("Model is down.", 1, true))
            assert.are.equal(1, popup.redraws)
            assert.are.equal(2, popup.dict_index)
            assert.are.equal(OXFORD, popup.results[2])
        end)

        it("stays on the error when the AI page is the only page", function()
            build({ responses = { { status = 500, body = helpers.body({ error = "model is down" }) } } })
            kor.defer_scheduled = true
            local popup = look_up("fox", {})
            kor.run_scheduled()

            assert.are.equal(1, popup.dict_index)
            assert.is_truthy(popup.results[1].definition:find("Model is down.", 1, true))
        end)

        it("gives up after ten seconds and turns to the dictionary", function()
            build()
            kor.defer_scheduled = true
            kor.never_ready = true
            local clock = 1000
            plugin.now = function() return clock end
            local popup = look_up("fox")

            clock = 1000 + 9               -- slow, but not yet given up on
            kor.run_scheduled()
            assert.are.equal(1, popup.dict_index)
            assert.are.equal(0, kor.terminated)

            clock = 1000 + 11
            kor.run_scheduled()
            assert.are.equal(1, kor.terminated)
            assert.are.equal(2, popup.dict_index)
            assert.is_truthy(popup.results[1].definition:find("No answer in 10 seconds.", 1, true))
            -- Nothing is left in the air, so the next word is asked at once.
            assert.are.equal(0, plugin.prefetch:pending())
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
            local saved = kor.store.data["entries"]
            koreader.uninstall()

            build({ online = false, settings = { entries = saved } })
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

            local saved = kor.store.data["entries"]
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
        it("throws away answers kept under the old keys", function()
            -- The first lacks the headword; the second has Wiktionary's whole
            -- etymology and its ɹ, from before the gateway retold them.
            build({ settings = {
                cache_entries = { { key = "x", value = {} } },
                answers = { { key = "y", value = {} } },
            } })
            assert.is_nil(kor.store.data["cache_entries"])
            assert.is_nil(kor.store.data["answers"])
        end)

        it("is written after a successful lookup", function()
            build()
            tap_highlight_button()

            local saved = kor.store.data["entries"]
            assert.is_table(saved)
            assert.are.equal(1, #saved)
            assert.are.equal("A wild animal of the dog family.", saved[1].value.definition)
        end)

        it("is read back by the next reader session", function()
            build()
            tap_highlight_button()
            local saved = kor.store.data["entries"]
            koreader.uninstall()

            build({ settings = { entries = saved } })
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

            assert.are.same({}, kor.store.data["entries"])
            assert.are.equal("Cached answers cleared.", last_shown().text)
        end)
    end)

    describe("the settings menu", function()
        local function menu_item(matcher)
            local items = {}
            plugin:addToMainMenu(items)
            local all = { items.aidict_sync }
            for _, item in ipairs(items.aidict.sub_item_table) do all[#all + 1] = item end
            for _, item in ipairs(all) do
                local label = item.text_func and item.text_func() or item.text
                if label:find(matcher) then return item, label end
            end
        end

        it("hides whether a key is set behind 'set' or 'none'", function()
            build()
            local _, label = menu_item("API key")
            assert.are.equal("API key: none", label)

            koreader.uninstall()
            build({ settings = { api_key = "s3cret" } })
            local _, with_key = menu_item("API key")
            assert.are.equal("API key: set", with_key)
        end)

        -- The addresses and the books folder come with the package, from its
        -- build secrets; the menu has no line for them.
        -- Earlier versions let the reader type an endpoint in; with no field
        -- left to change it, a saved one would win for good.
        it("drops an endpoint saved on the device for the package's own", function()
            build({ settings = { endpoint = "https://stale.test/ai" } })

            assert.is_nil(kor.store.data.endpoint)
            tap_highlight_button()
            assert.are.equal(helpers.ENDPOINT .. "/define", kor.transport.requests[1].url)
        end)

        it("shows no address and no books folder", function()
            build()
            assert.is_nil(menu_item("Endpoint"))
            assert.is_nil(menu_item("Library"))
            assert.is_nil(menu_item("Books folder"))
            assert.is_nil(menu_item("https?://"))
        end)

        -- 0.2.57 let the address be typed in, so a device may still hold one
        -- in its settings. Only the package's counts.
        it("syncs against the package's library address, not a saved one", function()
            build({
                settings = { library_endpoint = "https://stale.test/koreader-library" },
                responses = { synced() },
            })

            plugin:sync()

            assert.are.equal(helpers.LIBRARY_ENDPOINT .. "/sync", kor.transport.requests[1].url)
        end)

        it("keeps the context size and update channel out of it", function()
            build()
            assert.is_nil(menu_item("Context sent"))
            assert.is_nil(menu_item("Update channel"))
        end)

        describe("syncing settings from the library", function()
            local function sync(responses, opts)
                opts = opts or {}
                build({ responses = responses, can_restart = opts.can_restart })
                for key, value in pairs(opts.global or {}) do kor.global_settings.data[key] = value end
                menu_item("Sync").callback()
            end

            it("writes the queued values into KOReader's settings and offers a restart", function()
                sync({
                    synced({ apply = { { key = "show_bottom_menu", value = false } } }),
                    { status = 200, body = helpers.body({ applied = 1, pending = 0 }) },
                }, { global = { show_bottom_menu = true } })

                assert.is_false(kor.global_settings.data.show_bottom_menu)
                assert.are.equal(1, kor.global_settings.flushed)
                assert.are.equal(helpers.LIBRARY_ENDPOINT .. "/sync", kor.transport.requests[1].url)
                assert.are.equal(helpers.LIBRARY_ENDPOINT .. "/settings", kor.transport.requests[2].url)
                assert.are.equal("POST", kor.transport.requests[2].method)
                assert.are.equal("ConfirmBox", last_shown().widget_kind)
                assert.is_truthy(last_shown().text:find("show_bottom_menu", 1, true))

                last_shown().ok_callback()
                assert.are.equal("Restart", kor.broadcast[#kor.broadcast].name)
            end)

            it("sends when KOReader saved a change this Kindle made itself", function()
                build({ responses = { synced() } })
                kor.global_settings.data.copt_font_size = 22
                plugin:onFlushSettings()
                kor.global_settings.data.copt_font_size = 26
                plugin:onFlushSettings()

                menu_item("Sync").callback()

                -- One request, and no report: the library kept what it carried.
                assert.are.equal(1, kor.transport.calls)
                local request = helpers.json.decode(kor.transport.requests[1].body)
                assert.are.equal(26, request.values.copt_font_size)
                assert.are.equal("number", type(request.changed_at.copt_font_size))
                assert.are.equal(Version.string, request.plugin_version)
                assert.are.equal("stable", request.channel)
            end)

            it("says only that everything is in sync when nothing changed, in one request", function()
                sync({ synced() })
                assert.are.equal(1, kor.transport.calls)
                assert.are.equal("InfoMessage", last_shown().widget_kind)
                assert.are.equal("Everything is in sync, plugin " .. Version.string .. " included.", last_shown().text)
            end)

            it("says only the part that changed", function()
                sync({
                    synced({ apply = { { key = "copt_font_size", value = 24 } } }),
                    { status = 200, body = helpers.body({ applied = 1, pending = 0 }) },
                })
                local text = last_shown().text
                assert.is_truthy(text:find("Settings\nChanged 1: copt_font_size.", 1, true))
                assert.is_nil(text:find("Library", 1, true))
            end)

            it("waits on the network in a subprocess, and a dismissed wait stops the sync", function()
                build({ responses = {
                    synced({ apply = { { key = "copt_font_size", value = 24 } } }),
                } })
                local shown = #kor.shown
                kor.dismiss_next = true
                menu_item("Sync").callback()

                assert.are.equal(0, kor.transport.calls)
                assert.is_nil(kor.global_settings.data.copt_font_size)
                assert.are.equal(shown, #kor.shown)
            end)

            it("stops at a dismissed report, keeping and offering what was applied", function()
                build({ can_restart = true, responses = {
                    synced({ apply = { { key = "copt_font_size", value = 24 } } }),
                } })
                kor.files[require("aidict.vocab").PATH] = 1
                kor.vocab_rows = { { "lk-1", "6032", "s", 1, "w", "w", "en", "B", "T", "A" } }
                -- The request runs; the report is the second wait.
                local waits = 0
                local trapper = package.loaded["ui/trapper"]
                local run = trapper.dismissableRunInSubprocess
                trapper.dismissableRunInSubprocess = function(self, fn, message, simple)
                    waits = waits + 1
                    if waits == 2 then return false end
                    return run(self, fn, message, simple)
                end

                menu_item("Sync").callback()

                assert.are.equal(24, kor.global_settings.data.copt_font_size)
                assert.are.equal(1, kor.transport.calls)
                assert.are.equal("ConfirmBox", last_shown().widget_kind)
                assert.is_nil(last_shown().text:find("Kindle lookups", 1, true))
            end)

            it("says nothing, not \"in sync\", when an earlier change's report is dismissed", function()
                build({ responses = { synced({}) } })
                kor.store.data.settings_unreported = { { key = "copt_font_size", value = 22, previous = 20 } }
                local waits = 0
                local trapper = package.loaded["ui/trapper"]
                local run = trapper.dismissableRunInSubprocess
                trapper.dismissableRunInSubprocess = function(self, fn, message, simple)
                    waits = waits + 1
                    if waits == 2 then return false end
                    return run(self, fn, message, simple)
                end
                local shown = #kor.shown

                menu_item("Sync").callback()

                assert.are.equal(2, waits)
                assert.are.equal(shown, #kor.shown)
                assert.is_table(kor.store.data.settings_unreported)
            end)

            it("says why when the library cannot be reached, once", function()
                sync({ { err = "network unreachable" } })
                assert.are.equal("InfoMessage", last_shown().widget_kind)
                local text = last_shown().text
                assert.is_truthy(text:find("Library\n", 1, true))
                assert.is_truthy(text:find("unreachable", 1, true))
                assert.is_nil(text:find("Settings", 1, true))
            end)
        end)

        describe("one look for every book", function()
            local function open_book(values, font)
                reader.ui.config = { options = {
                    prefix = "copt",
                    { options = { { name = "rotation_mode" }, { name = "h_page_margins" } } },
                    { options = { { name = "font_size" } } },
                } }
                reader.ui.document = { configurable = values }
                reader.ui.font = { font_face = font }
            end

            it("opens a book with the defaults written over its own look", function()
                build()
                open_book({ h_page_margins = { 20, 20 }, font_size = 22 }, "Literata")
                kor.global_settings.data.copt_h_page_margins = { 20, 20 }
                kor.global_settings.data.cre_font = "Bookerly"
                local sidecar = helpers.store({
                    copt_font_size = 30, copt_h_page_margins = { 5, 5 }, font_face = "Noto Serif",
                    copt_rotation_mode = 1, percent_finished = 0.5,
                })

                plugin:onDocSettingsLoad(sidecar, reader.ui.document)

                assert.are.same({
                    copt_h_page_margins = { 20, 20 }, font_face = "Bookerly",
                    copt_rotation_mode = 1, percent_finished = 0.5,
                }, sidecar.data)
            end)

            it("keeps a book it has read before in web rendering, not KOReader's legacy fallback", function()
                build()
                reader.ui.config = { options = { prefix = "copt", { options = { { name = "block_rendering_mode" } } } } }
                reader.ui.document = { configurable = { block_rendering_mode = 3 } }
                local sidecar = helpers.store({ copt_block_rendering_mode = 3, last_xpointer = "/body/p[4]" })

                plugin:onDocSettingsLoad(sidecar, reader.ui.document)
                assert.are.same({ copt_block_rendering_mode = 3, last_xpointer = "/body/p[4]" }, sidecar.data)

                kor.global_settings.data.copt_block_rendering_mode = 2
                plugin:onDocSettingsLoad(sidecar, reader.ui.document)
                assert.are.equal(2, sidecar.data.copt_block_rendering_mode)
            end)

            it("makes a change made in the book the default for every book", function()
                build()
                local look = { h_page_margins = { 20, 20 }, font_size = 22 }
                open_book(look, "Literata")
                plugin:onReadSettings()
                -- The first save only takes in what the Kindle already has.
                plugin:onFlushSettings()

                look.font_size = 26
                reader.ui.font.font_face = "Bookerly"
                plugin:onFlushSettings()
                plugin:onFlushSettings()

                assert.are.same({ copt_font_size = 26, cre_font = "Bookerly" }, kor.global_settings.data)
                assert.are.equal(1, kor.global_settings.flushed)

                -- Logged once each, as the book's, not again as the Kindle's.
                local logged = {}
                for _, line in ipairs(plugin.store:readSetting("settings_log")) do
                    logged[#logged + 1] = line.source .. " " .. line.key .. " " .. tostring(line.value)
                end
                table.sort(logged)
                assert.are.same({ "book copt_font_size 26", "book cre_font Bookerly" }, logged)
                local stamped = plugin.store:readSetting("settings_changed_at")
                assert.are.equal("number", type(stamped.copt_font_size))
                assert.are.equal("number", type(stamped.cre_font))
            end)

            it("leaves a default set by Sync alone while the book shows its older value", function()
                build()
                open_book({ h_page_margins = { 20, 20 }, font_size = 22 }, "Literata")
                plugin:onReadSettings()

                kor.global_settings.data.copt_font_size = 24
                plugin:onCloseDocument()

                assert.are.same({ copt_font_size = 24 }, kor.global_settings.data)
                assert.are.equal(0, kor.global_settings.flushed)
            end)

            it("sends a change made in the open book with the next Sync, saved or not", function()
                build({ responses = { synced() } })
                local look = { h_page_margins = { 20, 20 }, font_size = 22 }
                open_book(look, "Literata")
                plugin:onReadSettings()
                plugin:onFlushSettings()
                look.font_size = 26

                menu_item("Sync").callback()

                local plan_request = helpers.json.decode(kor.transport.requests[1].body)
                assert.are.equal(26, plan_request.values.copt_font_size)
                assert.are.equal("number", type(plan_request.changed_at.copt_font_size))
            end)

            it("hands the open book the style tweaks Sync applied, so closing it keeps them", function()
                local tweaks = { margin_body_0 = true, ["footnote-inpage_epub"] = true }
                build({ responses = {
                    synced({ apply = { { key = "style_tweaks", value = tweaks } } }),
                    { status = 200, body = helpers.body({ applied = 1, pending = 0 }) },
                } })
                open_book({ h_page_margins = { 20, 20 } }, "Literata")
                kor.global_settings.data.style_tweaks = { ["footnote-inpage_epub"] = true }
                reader.ui.styletweak = { global_tweaks = kor.global_settings.data.style_tweaks }

                menu_item("Sync").callback()

                assert.are.same(tweaks, reader.ui.styletweak.global_tweaks)

                -- What ReaderStyleTweak:onSaveSettings does when the book is saved or closed.
                kor.global_settings:saveSetting("style_tweaks", reader.ui.styletweak.global_tweaks)
                assert.are.same(tweaks, kor.global_settings.data.style_tweaks)
            end)

            it("leaves a PDF's own crop, zoom and contrast alone", function()
                build()
                reader.ui.config = { options = { prefix = "kopt", { options = { { name = "zoom_mode" }, { name = "contrast" } } } } }
                reader.ui.document = { configurable = { zoom_mode = "page", contrast = 1.2 } }
                local sidecar = helpers.store({ kopt_zoom_mode = "content", kopt_contrast = 1.5 })

                plugin:onDocSettingsLoad(sidecar, reader.ui.document)
                plugin:onReadSettings()
                reader.ui.document.configurable.contrast = 2
                plugin:onFlushSettings()

                assert.are.same({ kopt_zoom_mode = "content", kopt_contrast = 1.5 }, sidecar.data)
                assert.are.same({}, kor.global_settings.data)
            end)

            it("does nothing in the file manager", function()
                build()
                plugin:onDocSettingsLoad(helpers.store({ copt_font_size = 30 }))
                plugin:onReadSettings()
                plugin:onFlushSettings()
                assert.are.same({}, kor.global_settings.data)
            end)
        end)
    end)

    describe("the update Sync offers", function()
        local function released(version)
            return { status = 200, body = helpers.body({
                channel = "stable",
                packages = { ["koreader-aidict"] = { version = { 9, 9, 9 }, version_string = version } },
            }) }
        end

        it("offers the newer plugin the library named, with no request of its own", function()
            build({ responses = { synced({ plugin = "9.9.9" }) } })
            plugin:sync()

            assert.are.equal(1, kor.transport.calls)
            assert.are.equal("ConfirmBox", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("Plugin 9.9.9 is out; this is " .. Version.string, 1, true))
            assert.are.equal("Install", last_shown().ok_text)
        end)

        it("asks the release repository itself when the library cannot say", function()
            build({
                responses = { synced({ plugin = false }), released("9.9.9") },
                settings = { repo_url = "https://repo.test/kpm" },
            })
            plugin:sync()

            assert.are.equal("https://repo.test/kpm/stable/version.json", kor.transport.requests[2].url)
            assert.is_truthy(last_shown().text:find("Plugin 9.9.9 is out", 1, true))
        end)

        it("still offers it when the library is down, beside saying so", function()
            build({ responses = { { err = "network unreachable" }, released("9.9.9") } })
            plugin:sync()

            local text = last_shown().text
            assert.are.equal("ConfirmBox", last_shown().widget_kind)
            assert.is_truthy(text:find("unreachable", 1, true))
            assert.is_truthy(text:find("Plugin 9.9.9 is out", 1, true))
        end)

        it("says nothing of the plugin when neither can say, or when it is the newest", function()
            build({ responses = { synced({ plugin = false }), { err = "host not found" } } })
            plugin:sync()
            assert.are.equal("Everything is in sync.", last_shown().text)

            build({ responses = { synced({ plugin = "0.0.1" }) } })
            plugin:sync()
            assert.are.equal("InfoMessage", last_shown().widget_kind)
        end)

        it("offers the restart the new settings want when the update is turned down", function()
            build({ can_restart = true, responses = {
                synced({ plugin = "9.9.9", apply = { { key = "copt_font_size", value = 24 } } }),
                { status = 200, body = helpers.body({ applied = 1, pending = 0 }) },
            } })
            plugin:sync()
            assert.is_truthy(last_shown().text:find("Changed 1: copt_font_size.", 1, true))

            last_shown().cancel_callback()
            assert.are.equal("ConfirmBox", last_shown().widget_kind)
            assert.is_truthy(last_shown().text:find("Restart now?", 1, true))
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
            return helpers.body({
                manifest = { version = 1, files = files },
                apply = {},
                plugin = { version = Version.string, channel = "stable" },
            })
        end

        local function book(path, size)
            return { path = path, size = size, etag = "e", url = "https://r2.test/" .. path .. "?sig=x" }
        end

        --- The library's own requests: Sync also fetches and reports the settings.
        local function library_calls()
            local count = 0
            for _, request in ipairs(kor.transport.requests) do
                if not request.url:find("/settings", 1, true) then count = count + 1 end
            end
            return count
        end

        local function items()
            local registered = {}
            plugin:addToMainMenu(registered)
            return registered
        end

        it("puts Sync, then AI dictionary, at the top of Tools, not at the end of it", function()
            build()

            -- Appending is what a sorting_hint alone would do, and Tools is
            -- already two pages long — so the entries have to claim the top.
            for _, order in pairs(kor.menu_order) do
                assert.are.equal("aidict_sync", order.tools[1])
                assert.are.equal("aidict", order.tools[2])
            end
            assert.are.equal("Sync", items().aidict_sync.text)
            assert.is_nil(items().aidict_sync.sub_item_table)
            assert.are.equal("AI dictionary", items().aidict.text)
        end)

        it("keeps Sync out of the submenu, and has no update entry: Sync offers it", function()
            build()
            local sub = items().aidict.sub_item_table

            for _, item in ipairs(sub) do
                local label = item.text_func and item.text_func() or item.text
                assert.is_nil(label:find("Update", 1, true))
            end
        end)

        -- Sync's own message names the version when it is the newest.
        it("does not put the version on a line of its own", function()
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
            table.sort(ids)
            assert.are.same({ "aidict", "aidict_sync" }, ids)
        end)

        it("claims that place once, however many times it is built", function()
            -- init runs once for the FileManager and once for the Reader.
            build()
            local first = #kor.menu_order.reader.tools
            kor.plugin_class:new({ ui = reader.ui, document = reader.document })

            assert.are.equal(first, #kor.menu_order.reader.tools)
            assert.are.equal("aidict_sync", kor.menu_order.reader.tools[1])
            assert.are.equal("aidict", kor.menu_order.reader.tools[2])
        end)

        it("downloads what the device does not have", function()
            build({
                settings = { library_dir = BOOKS },
                responses = {
                    { status = 200, body = manifest({ book("Lem/Solaris.epub", 10) }) },
                    { status = 200, bytes = 10 },
                },
            })

            plugin:sync()

            -- The library mount, from its own setting.
            assert.are.equal("https://gw.test/koreader-library/sync", kor.transport.requests[1].url)
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

            plugin:sync()

            assert.are.equal(1, library_calls())
            assert.are.equal("Everything is in sync, plugin " .. Version.string .. " included.", last_shown().text)
        end)

        it("names the book that failed rather than only counting it", function()
            build({
                settings = { library_dir = BOOKS },
                responses = {
                    { status = 200, body = manifest({ book("A.epub", 10) }) },
                    { status = 403 },
                },
            })

            plugin:sync()

            local text = last_shown().text
            assert.is_truthy(text:find("A.epub", 1, true))
            assert.is_truthy(text:find("expired", 1, true))
        end)

        -- And specifically for its own: the dictionary's address is no route
        -- to it now that one is a Worker and the other is the gateway.
        it("says the package has no library address rather than syncing into nowhere", function()
            build({ no_library_endpoint = true })

            plugin:sync()

            -- Only the release repository, for the update Sync offers.
            assert.are.equal(1, kor.transport.calls)
            assert.is_truthy(kor.transport.requests[1].url:find("/version.json$"))
            assert.is_truthy(last_shown().text:find("library address", 1, true))
        end)

        it("does not fall back to the dictionary's address", function()
            build({ no_library_endpoint = true, settings = { library_dir = BOOKS } })

            plugin:sync()

            for _, request in ipairs(kor.transport.requests) do
                assert.is_truthy(request.url:find("/version.json$"))
            end
        end)

        it("waits for Wi-Fi instead of failing on it", function()
            build({
                online = false,
                settings = { library_dir = BOOKS },
                responses = { { status = 200, body = manifest({}) } },
            })

            plugin:sync()

            assert.are.equal(0, kor.transport.calls)
            assert.is_function(kor.deferred)
        end)

        it("is an action a gesture can be bound to, and the event runs it", function()
            build({
                settings = { library_dir = BOOKS },
                responses = { { status = 200, body = manifest({}) } },
            })

            assert.are.equal("Sync", kor.actions["aidict_sync"].title)
            assert.are.equal("AiDictSync", kor.actions["aidict_sync"].event)
            assert.is_nil(kor.actions["aidict_sync_library"])
            assert.is_nil(kor.actions["aidict_send_vocab"])

            plugin:onAiDictSync()
            assert.are.equal(1, library_calls())
        end)

        it("reports the gateway's own failure", function()
            build({
                settings = { library_dir = BOOKS },
                responses = { { status = 500, body = "" } },
            })

            plugin:sync()

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

                plugin:sync()

                -- No download: the manifest was the only request.
                assert.are.equal(1, library_calls())
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

                plugin:sync()

                local store = saved_index()
                assert.are.equal(BOOKS, store.data.dir)
                assert.are.same({ ["English/Business/x.epub"] = { size = 10, etag = "e-x.epub" } },
                    store.data.books)
                assert.are.equal(1, store.flushed)
            end)

            it("deletes the book and what KOReader kept about it, the way the file manager does", function()
                synced_before({ ["Gone.epub"] = 20, ["A.epub"] = 10 }, { book("A.epub", 10) })

                plugin:sync()

                local gone = BOOKS .. "/Gone.epub"
                assert.are.same({
                    "remove " .. gone,
                    "BookList.resetBookInfoCache " .. gone,
                    "DocSettings.updateLocation " .. gone,
                    "ReadHistory:fileDeleted " .. gone,
                    "ReadCollection:removeItem " .. gone,
                }, kor.book_calls)
                assert.is_nil(kor.files[gone])
                assert.are.same({ ["A.epub"] = { size = 10, etag = "e-A.epub" } }, saved_index().data.books)
                assert.is_truthy(last_shown().text:find("Deleted 1", 1, true))
            end)

            it("leaves the book that is open, and says it will move next time", function()
                synced_before({ ["English/Fiction/x.epub"] = 10 }, { book("English/Business/x.epub", 10) })
                kor.reader_ui.instance = { document = { file = FROM } }

                plugin:sync()

                assert.are.same({}, kor.book_calls)
                assert.are.equal(10, kor.files[FROM])
                assert.are.same({ ["English/Fiction/x.epub"] = { size = 10, etag = "e-x.epub" } },
                    saved_index().data.books)
                assert.is_truthy(last_shown().text:find("x.epub is open, so it moves on the next sync.", 1, true))
            end)

            it("knows the open book from its own reader too", function()
                synced_before({ ["Gone.epub"] = 20, ["A.epub"] = 10 }, { book("A.epub", 10) })
                reader.ui.document = { file = BOOKS .. "/Gone.epub" }

                plugin:sync()

                assert.are.equal(20, kor.files[BOOKS .. "/Gone.epub"])
                assert.is_truthy(last_shown().text:find("Gone.epub is open, so it is deleted on the next sync.", 1, true))
            end)

            it("never deletes a file it did not put there", function()
                synced_before({}, {})
                kor.files[BOOKS .. "/Mine.pdf"] = 3

                plugin:sync()

                assert.are.equal(3, kor.files[BOOKS .. "/Mine.pdf"])
                assert.are.same({}, kor.book_calls)
            end)

            -- The reader pointed the sync at another folder: what the old
            -- index lists is not this folder's to delete.
            it("starts a fresh index when the books folder changed", function()
                synced_before({ ["Gone.epub"] = 20 }, {}, { index_dir = "/mnt/us/Old_Books" })

                plugin:sync()

                assert.are.equal(20, kor.files[BOOKS .. "/Gone.epub"])
                assert.are.same({}, kor.book_calls)
                assert.are.equal(BOOKS, saved_index().data.dir)
            end)

            it("puts the book back when its reading state cannot follow, for the next sync to retry", function()
                synced_before({ ["English/Fiction/x.epub"] = 10 }, { book("English/Business/x.epub", 10) })
                kor.docsettings_error = "sidecar unreadable"

                plugin:sync()

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

                plugin:sync()

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

            plugin:sync()

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

        --- Sync, with no library address: only the lookups travel, and the update check.
        local function sync()
            plugin:sync()
            return last_shown() and last_shown().text
        end

        --- The requests that were not the update check.
        local function sent()
            local requests = {}
            for _, request in ipairs(kor.transport.requests) do
                if not request.url:find("/version.json$") then requests[#requests + 1] = request end
            end
            return requests
        end

        it("sends what is new since the last upload, without asking, and remembers how far it got", function()
            withVocab({
                no_library_endpoint = true,
                settings = { vocab_uploaded_through = 2000 },
                responses = { receipt(1, 1) },
            }, { lookup("lk-1", 1000), lookup("lk-2", 2000), lookup("lk-3", 3000) })

            local text = sync()

            -- Read-only: the Kindle's own reader owns the file.
            assert.are.same({ path = Vocab.PATH, mode = "ro" }, kor.vocab_opened)
            assert.is_true(kor.vocab_closed)
            assert.are.equal(1, #sent())
            assert.are.equal(helpers.ENDPOINT .. "/vocab", kor.transport.requests[1].url)
            local body = helpers.json.decode(kor.transport.requests[1].body)
            assert.are.equal(2, #body.rows)
            assert.are.equal("lk-2", body.rows[1].lookup_id)

            assert.are.equal(3000, kor.store.data.vocab_uploaded_through)
            assert.is_truthy(text:find("Kindle lookups\nSent 2 lookups: 1 new, 1 already there.", 1, true))
        end)

        it("says so when there is nothing new, and sends nothing", function()
            withVocab({ no_library_endpoint = true, settings = { vocab_uploaded_through = 5000 } }, { lookup("lk-1", 1000) })

            local text = sync()

            assert.are.equal(0, #sent())
            assert.is_nil(text:find("Kindle lookups", 1, true))
        end)

        it("does not send again the one lookup it sent last time", function()
            withVocab({ no_library_endpoint = true, settings = { vocab_uploaded_through = 2000 } }, { lookup("lk-1", 2000) })

            local text = sync()

            assert.is_nil(text:find("Kindle lookups", 1, true))
            assert.are.equal(0, #sent())
        end)

        it("keeps what arrived before a failure", function()
            local rows = {}
            for i = 1, Vocab.BATCH + 1 do rows[i] = lookup("lk-" .. i, i) end
            withVocab({
                no_library_endpoint = true,
                responses = {
                    receipt(Vocab.BATCH),
                    { status = 502, body = helpers.body({ error = { message = "the word inbox did not answer (TypeError)" } }) },
                },
            }, rows)

            local text = sync()

            assert.are.equal(Vocab.BATCH, kor.store.data.vocab_uploaded_through)
            assert.is_truthy(text:find("The word inbox did not answer", 1, true))
            assert.is_truthy(text:find("100 new lookups arrived", 1, true))
        end)

        it("says nothing about lookups on a device without the Kindle's reader", function()
            build({ responses = { synced() } })

            local text = sync()

            assert.is_nil(kor.vocab_opened)
            assert.is_nil(text:find("lookups", 1, true))
        end)

        it("waits for Wi-Fi even with nothing but the update to check", function()
            build({ no_library_endpoint = true, online = false })

            plugin:sync()

            assert.are.equal(0, kor.transport.calls)
            assert.is_function(kor.deferred)
        end)

        it("says when vocab.db cannot be opened", function()
            withVocab({ no_library_endpoint = true }, {})
            kor.vocab_error = "database is locked"

            local text = sync()

            assert.are.equal(0, #sent())
            assert.is_truthy(text:find("database is locked", 1, true))
        end)

        it("sends after the library and the settings", function()
            withVocab({
                responses = { synced(), receipt(1) },
            }, { lookup("lk-1", 1) })

            local text = sync()

            assert.are.equal(helpers.ENDPOINT .. "/vocab", kor.transport.requests[2].url)
            -- The library and the settings had nothing new, so only the lookups speak.
            assert.are.equal(1, text:find("Kindle lookups\n", 1, true))
        end)

        it("waits for Wi-Fi instead of failing on it", function()
            withVocab({ no_library_endpoint = true, online = false }, { lookup("lk-1", 1) })

            plugin:sync()

            assert.are.equal(0, kor.transport.calls)
            assert.is_function(kor.deferred)
        end)
    end)
end)
