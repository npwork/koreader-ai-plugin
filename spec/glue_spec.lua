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

        reader = koreader.reader({
            sentence = sentence,
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
            assert.is_truthy(shown.text:find("лиса", 1, true))
        end)

        it("sends the sentence around the word as context", function()
            build({ sentence = "The quick brown fox jumps over the lazy dog." })
            tap_dict_button()

            local sent = helpers.json.decode(kor.transport.requests[1].body)
            assert.are.equal("fox", sent.word)
            assert.is_truthy(sent.context:find("fox", 1, true))
            assert.is_truthy(sent.context:find("quick brown", 1, true))
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

        it("names the word in the progress message", function()
            build()
            tap_dict_button()
            assert.is_truthy(kor.last_progress_message:find("fox", 1, true))
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

        it("falls back to the selection when the document has no sentence", function()
            build({ no_sentence = true, selected_text = { text = "fox jumps", pos0 = "p1", pos1 = "p2" } })
            tap_highlight_button()

            assert.are.equal(1, kor.transport.calls)
            local sent = helpers.json.decode(kor.transport.requests[1].body)
            assert.are.equal("fox jumps", sent.word)
            -- The selection is all the context there is, so none is sent.
            assert.is_nil(sent.context)
        end)
    end)

    describe("being offline", function()
        it("defers the lookup instead of failing", function()
            build({ online = false })
            tap_dict_button()

            assert.are.equal(0, kor.transport.calls)
            assert.are.equal(0, #kor.shown)
            assert.is_function(kor.deferred)
        end)

        it("runs the same lookup once the network is up", function()
            build({ online = false })
            tap_dict_button()

            kor.online = true
            kor.deferred()

            assert.are.equal(1, kor.transport.calls)
            assert.are.equal("TextViewer", last_shown().widget_kind)
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
