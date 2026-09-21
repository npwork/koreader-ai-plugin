--[[--
AI dictionary: explains the word you tapped, in context, by asking a remote
AI service.

Everything in this file is KOReader glue — widgets, menus, events. The
behaviour lives in `aidict/`, which is plain Lua and covered by `spec/`.

@module koplugin.aidict
--]]--

local DataStorage = require("datastorage")
local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local Context = require("aidict.context")
local Format = require("aidict.format")
local Reqid = require("aidict.reqid")
local Lookup = require("aidict.lookup")
local Prefetch = require("aidict.prefetch")
local Settings = require("aidict.settings")
local Updater = require("aidict.updater")
local Version = require("aidict.version")
local http_transport = require("aidict.http_transport")
local json = require("aidict.json")

local CACHE_KEY = "cache_entries"

-- How often a prefetch in the background is checked on. Nothing is waiting on
-- it, so this is about not spinning rather than about being quick.
local PREFETCH_POLL_SECONDS = 0.5

--- The ids a finished lookup is known by, for the log line.
-- The request id is always there; the ray only once Cloudflare saw it.
local function marks(source, request)
    source = source or {}
    local id = tostring(source.request_id or (request and request.request_id) or "?")
    if source.cf_ray then return id .. " cf=" .. tostring(source.cf_ray) end
    return id
end

local showResult

--- Whether asking is possible at all right now.
-- Cheap on purpose: NetworkMgr:isOnline() resolves a hostname, which is far
-- too slow to decide whether to draw a button.
local function canAsk()
    return NetworkMgr:isConnected()
end

local AiDict = WidgetContainer:extend{
    name = "aidict",
}

function AiDict:init()
    -- LuaJIT hands out the same sequence to every run otherwise, and request
    -- ids that repeat across sessions are worse than none.
    math.randomseed(os.time())

    self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/aidict.lua")
    self.settings = Settings.new(self.store)
    self.lookup = Lookup.new({
        settings = self.settings,
        transport = http_transport,
        json = json,
        monotonic = function() return time.to_ms(time.now()) end,
    })
    self.lookup:restore_cache(self.store:readSetting(CACHE_KEY))
    self.prefetch = Prefetch.new({ settings = self.settings })
    self.prefetch_jobs = {}
    -- Named rather than called directly so a spec can move it: the give-up
    -- branch below is otherwise half a minute away.
    self.now = os.time

    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    if self.ui and self.ui.dictionary and self.ui.dictionary.addToDictButtons then
        self:registerDictButton()
    end
    if self.document and self.ui and self.ui.highlight then
        self:registerHighlightButton()
    end
end

--- Persist the cache so an answer survives closing the book.
function AiDict:saveCache()
    self.store:saveSetting(CACHE_KEY, self.lookup:dump_cache())
    self.store:flush()
end

--[[--
KOReader announces every dictionary lookup, before it has even searched. That
is the earliest the word is known, and the reader is about to spend a few
seconds on the dictionary entry — so it is the moment to start asking, if the
reader wants that.

Nothing here may block: the dictionary window is opening behind it.
--]]--
function AiDict:onWordLookedUp(word)
    if not (self.prefetch and self.lookup) then return end

    local request = self:requestFor(word, self.ui and self.ui.highlight)
    local key = request and Lookup.key(request) or nil
    local wanted, why = self.prefetch:wanted(key, {
        offline = not canAsk(),
        cached = request ~= nil and self.lookup:peek(request) ~= nil,
    })
    if not wanted then
        -- dbg, not info: this fires on every dictionary lookup, and the
        -- commonest answer is "prefetch is off".
        logger.dbg("aidict: not fetching ahead:", why)
        return
    end
    self:startPrefetch(request, key)
    -- Never swallow the event: the dictionary is the one that wanted it.
    return false
end

--[[--
Fork, ask, and let it finish on its own.

This is the same work the button does, minus everything that waits or draws:
`Trapper` exists to show a dismissable progress window, and here there is
nobody to show it to.
--]]--
function AiDict:startPrefetch(request, key)
    local ffiutil = require("ffi/util")
    local lookup, codec = self.lookup, json

    local ok, pid, fd = pcall(ffiutil.runInSubProcess, function(_, child_write_fd)
        local outcome = lookup:fetch(request)
        -- JSON rather than the serialiser Trapper uses: the payload is plain
        -- data, and the codec is already a dependency of everything here.
        local encoded, payload = pcall(codec.encode, outcome)
        ffiutil.writeToFD(child_write_fd, encoded and payload or "", true)
    end, true)

    if not ok or not pid then
        logger.warn("aidict: could not fork to fetch", request.word, "ahead:", tostring(pid))
        return false
    end

    self.prefetch:began(key)
    local job = {
        key = key,
        request = request,
        pid = pid,
        fd = fd,
        -- The subprocess has its own timeouts; this is the backstop for one
        -- that is wedged rather than slow.
        deadline = self.now() + self.settings:get("total_timeout") + 5,
    }
    self.prefetch_jobs[key] = job
    self:pollPrefetch(job)
    return true
end

function AiDict:pollPrefetch(job)
    UIManager:scheduleIn(PREFETCH_POLL_SECONDS, function()
        -- The document may have closed under it, taking the job with it.
        if self.prefetch_jobs[job.key] ~= job then return end
        local ffiutil = require("ffi/util")

        local readable = job.fd and ffiutil.getNonBlockingReadSize(job.fd) ~= 0
        local finished = ffiutil.isSubProcessDone(job.pid)

        if readable then
            local raw = ffiutil.readAllFromFD(job.fd)   -- closes the fd
            job.fd = nil
            self:finishPrefetch(job, raw)
            if not finished then
                -- It wrote before exiting; collect it shortly so it does not
                -- linger as a zombie.
                UIManager:scheduleIn(1, function() ffiutil.isSubProcessDone(job.pid) end)
            end
            return
        end

        if finished then
            -- Gone without writing: it failed in a way it could not report.
            if job.fd then ffiutil.readAllFromFD(job.fd); job.fd = nil end
            self:finishPrefetch(job, nil, "the subprocess wrote nothing")
            return
        end

        if self.now() > job.deadline then
            ffiutil.terminateSubProcess(job.pid)
            if job.fd then ffiutil.readAllFromFD(job.fd); job.fd = nil end
            self:finishPrefetch(job, nil, "gave up waiting")
            return
        end

        self:pollPrefetch(job)
    end)
end

--- Put what came back into the cache, so the button finds it already there.
function AiDict:finishPrefetch(job, raw, why)
    self.prefetch_jobs[job.key] = nil
    self.prefetch:ended(job.key)

    if not raw or raw == "" then
        logger.warn(string.format("aidict: fetching %s ahead came to nothing (%s)",
            job.request.word, why or "no data"))
        return
    end

    local ok, outcome = pcall(json.decode, raw)
    if not (ok and type(outcome) == "table") then
        logger.warn("aidict: fetching", job.request.word, "ahead returned junk")
        return
    end
    if not outcome.ok then
        local err = outcome.err or {}
        logger.warn(string.format("aidict: fetching %s ahead failed (%s: %s)",
            job.request.word, tostring(err.code), tostring(err.message)))
        return
    end

    self.lookup:remember(job.request, outcome.result)
    self:saveCache()
    logger.info(string.format("aidict: %s fetched ahead in %sms, waiting in the cache [%s]",
        job.request.word, tostring(outcome.result.elapsed_ms or "?"),
        marks(outcome.result, job.request)))
end

--- Kill anything still in the air. A closed document has nowhere to put it.
function AiDict:stopPrefetching()
    if not self.prefetch_jobs then return end
    local ffiutil = require("ffi/util")
    for key, job in pairs(self.prefetch_jobs) do
        pcall(ffiutil.terminateSubProcess, job.pid)
        if job.fd then pcall(ffiutil.readAllFromFD, job.fd) end
        self.prefetch_jobs[key] = nil
    end
    self.prefetch:clear()
end

function AiDict:onCloseDocument()
    self:stopPrefetching()
    self:saveCache()
end

function AiDict:onFlushSettings()
    self:saveCache()
end

----------------------------------------------------------------------------
-- Entry points
----------------------------------------------------------------------------

function AiDict:registerDictButton()
    self.ui.dictionary:addToDictButtons({
        id = "aidict_explain",
        menu_text = _("Explain with AI"),
        text = _("AI"),
        -- Without Wi-Fi the button is not there at all, rather than there and
        -- failing.
        show_func = function() return canAsk() end,
        callback = function(dict_popup)
            -- Built before the popup closes: closing can clear the selection
            -- the passage is read from.
            local request = self:requestFor(dict_popup.word, dict_popup.highlight)
            dict_popup:onClose()
            self:explain(request)
        end,
    })
end

function AiDict:registerHighlightButton()
    -- 12_search is the last built-in entry; 13_ sorts after it.
    self.ui.highlight:addToHighlightDialog("13_aidict_explain", function(this)
        return {
            text = _("Explain with AI"),
            show_in_highlight_dialog_func = function() return canAsk() end,
            callback = function()
                this:highlightFromHoldPos()
                if not (this.selected_text and this.selected_text.text) then return end
                local word = util.cleanupSelectedText(this.selected_text.text)
                local request = self:requestFor(word, this)
                this:onClose(true)
                self:explain(request)
            end,
        }
    end)
end

----------------------------------------------------------------------------
-- Context
----------------------------------------------------------------------------

--- The sentence a selection sits in, when the document can produce one.
function AiDict:sentenceFor(highlight)
    local selected = highlight and highlight.selected_text
    if not (selected and selected.pos0 and selected.pos1) then return "" end

    local sentence
    if self.ui and self.ui.rolling and self.document and self.document.extendXPointersToSentenceSegment then
        local ok, extended = pcall(function()
            return self.document:extendXPointersToSentenceSegment(selected.pos0, selected.pos1)
        end)
        if ok and extended then sentence = extended.text end
    end
    return Context.cleanup(sentence or selected.text)
end

--[[--
The paragraph a selection sits in.

crengine can hand back the HTML of the block element containing a position —
which is the paragraph — so this is the real passage the reader is looking at,
not just the sentence. That is what lets the other side tell which sense of a
word is meant. Falls back to the sentence when the document cannot produce it
(a paged PDF, an older build).
--]]--
function AiDict:paragraphFor(highlight)
    local selected = highlight and highlight.selected_text
    if not (selected and selected.pos0) then return "" end
    if not (self.document and self.document.getHTMLFromXPointer) then return "" end

    local ok, html = pcall(function()
        -- 0 = no debug decoration; true = start from the final block parent.
        return self.document:getHTMLFromXPointer(selected.pos0, 0, true)
    end)
    if not (ok and type(html) == "string" and html ~= "") then return "" end

    return Context.cleanup(util.htmlToPlainText(html))
end

--- What gets sent with the word: the paragraph, and the sentence inside it.
function AiDict:contextFor(highlight, word)
    local budget = self.settings:get("context_chars")
    if budget <= 0 then return "", "" end

    local sentence = self:sentenceFor(highlight)
    local paragraph = self:paragraphFor(highlight)

    if paragraph == "" then
        -- No paragraph: the sentence is all the context there is.
        return Context.snippet(sentence, word, budget), sentence
    end

    return Context.snippet(paragraph, word, budget), sentence
end

function AiDict:bookProps()
    local props = self.ui and self.ui.doc_props
    if not props then return {} end
    return {
        title = props.display_title,
        author = props.authors,
        source_lang = props.language,
    }
end

----------------------------------------------------------------------------
-- The lookup itself
----------------------------------------------------------------------------

--[[--
Everything the gateway is asked, in one place.

Both the button and the prefetch build their request here, and that is not
tidiness: the cache key is the word plus its passage, so an answer fetched
ahead is only ever found again if the two agree character for character on
what the passage was.

@treturn table the request, or nil when there is nothing to look up
--]]--
function AiDict:requestFor(word, highlight)
    word = Context.cleanup(word)
    if word == "" then return nil end

    local context, sentence = self:contextFor(highlight, word)
    local props = self:bookProps()
    return {
        word = word,
        context = context or "",
        sentence = sentence or "",
        title = props.title,
        author = props.author,
        source_lang = props.source_lang,
        -- Minted here rather than in the subprocess: a fork inherits the
        -- random seed, so ids made after the fork would repeat.
        request_id = Reqid.generate(os.time(), math.random),
    }
end

function AiDict:explain(request)
    local word = request and request.word or ""
    if word == "" then
        UIManager:show(InfoMessage:new{ text = _("Nothing to look up.") })
        return
    end

    if not self.settings:is_configured() then
        logger.warn("aidict: " .. word .. " not asked: no endpoint configured")
        UIManager:show(InfoMessage:new{
            text = _("Set the AI endpoint first, in the AI dictionary menu."),
        })
        return
    end

    local cached = self.lookup:peek(request)
    if cached then
        logger.info(string.format("aidict: %s from cache (no request)", word))
        showResult(word, cached, true)
        return
    end

    if not canAsk() then
        -- Deliberately not offering to turn Wi-Fi on: the reader asked for a
        -- word, not for a connection.
        logger.warn(string.format("aidict: %s not asked: offline", word))
        UIManager:show(InfoMessage:new{ text = _("No Wi-Fi, so there is nothing to ask.") })
        return
    end

    -- Wrapped so the subprocess doing the request can be dismissed.
    Trapper:wrap(function()
        local completed, outcome = Trapper:dismissableRunInSubprocess(function()
            return self.lookup:fetch(request)
        end, T(_("Asking AI about “%1”…"), word))

        if not completed then
            logger.info(string.format("aidict: %s dismissed by the reader", word))
            return
        end
        if type(outcome) ~= "table" then
            logger.warn("aidict: unusable answer from subprocess", outcome)
            UIManager:show(InfoMessage:new{ text = _("Lookup failed.") })
            return
        end
        if not outcome.ok then
            local err = outcome.err or {}
            logger.warn(string.format("aidict: %s failed after %sms (%s: %s) [%s]",
                word, tostring(err.elapsed_ms or "?"),
                tostring(err.code), tostring(err.message), marks(err, request)))
            UIManager:show(InfoMessage:new{ text = Format.error(outcome.err) })
            return
        end

        self.lookup:remember(request, outcome.result)
        self:saveCache()

        local result = outcome.result
        -- Everything the gateway told us about where its time went, plus what
        -- its reviewer made of the answer. One line per lookup, so a slow or
        -- doubtful one can be taken apart afterwards from the device alone.
        local split = string.format("gateway %sms: model %sms, review %sms",
            tostring(result.server_ms or "?"), tostring(result.model_ms or "?"),
            tostring(result.review_ms or "?"))
        if result.retry_ms and result.retry_ms > 0 then
            split = split .. string.format(", retry %sms", tostring(result.retry_ms))
        end
        local judged = ""
        if result.review then
            judged = string.format(" sense=%s ex=%s%s",
                tostring(result.review.sense or "?"), tostring(result.review.examples or "?"),
                result.review.retried and " RETRIED" or "")
        end
        logger.info(string.format(
            "aidict: %s ok in %sms (%s, %s)%s [%s]",
            word, tostring(result.elapsed_ms or "?"), split,
            tostring(result.model or "?"), judged, marks(result, request)))

        showResult(word, result, false)
    end)
end

--- Ask the repository whether a newer package is published. Installing it
--- is `kpm`'s job, so this only reports.
function AiDict:checkForUpdates()
    local repo_url = self.settings:get("repo_url")
    local channel = self.settings:get("channel")
    local updater = Updater.new({ transport = http_transport, json = json })

    if not canAsk() then
        UIManager:show(InfoMessage:new{ text = _("No Wi-Fi, so updates cannot be checked.") })
        return
    end

    Trapper:wrap(function()
        local completed, outcome = Trapper:dismissableRunInSubprocess(function()
            local info, err = updater:check(repo_url, channel)
            return { ok = info ~= nil, info = info, err = err }
        end, _("Checking for updates…"))

        if not completed then return end
        if type(outcome) ~= "table" or not outcome.ok then
            local err = type(outcome) == "table" and outcome.err or nil
            UIManager:show(InfoMessage:new{ text = Format.error(err) })
            return
        end

        local info = outcome.info
        if info.available then
            UIManager:show(InfoMessage:new{
                text = T(_("Version %1 is available on the %2 channel (you have %3).\n\nInstall it from the Kindle search bar:\n;kpm upgrade %4"),
                    info.latest, info.channel, info.current, Updater.PACKAGE_ID),
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Version %1 is the newest on the %2 channel."), info.current, info.channel),
            })
        end
    end)
end

function showResult(word, result, from_cache)
    UIManager:show(TextViewer:new{
        title = Format.title(result, word),
        text = Format.result(result, { word = word, cached = from_cache }),
        -- "lookup" is what KOReader uses for dictionary results: same font
        -- size as book info, left-aligned rather than justified.
        text_type = "lookup",
        -- The entry is markup, not a wall of one typeface: TextViewer renders
        -- it through crengine when told the format, the same engine that draws
        -- the book underneath it.
        text_format = "html",
    })
end

----------------------------------------------------------------------------
-- Menu
----------------------------------------------------------------------------

function AiDict:editSetting(key, title, opts)
    opts = opts or {}
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = tostring(self.settings:get(key)),
        input_type = opts.numeric and "number" or "string",
        text_type = opts.password and "password" or nil,
        buttons = {{
            {
                text = _("Cancel"),
                id = "close",
                callback = function() UIManager:close(dialog) end,
            },
            {
                text = _("Save"),
                is_enter_default = true,
                callback = function()
                    local value = dialog:getInputText()
                    if opts.numeric then value = tonumber(value) end
                    local ok, reason = self.settings:set(key, value)
                    if not ok then
                        UIManager:show(InfoMessage:new{ text = reason })
                        return
                    end
                    self.settings:flush()
                    self.lookup:reload()
                    UIManager:close(dialog)
                end,
            },
        }},
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function AiDict:addToMainMenu(menu_items)
    menu_items.aidict = {
        text = _("AI dictionary"),
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text_func = function()
                    return T(_("Endpoint: %1"), self.settings:get("endpoint"))
                end,
                keep_menu_open = true,
                callback = function() self:editSetting("endpoint", _("AI gateway endpoint")) end,
            },
            {
                text_func = function()
                    local key = self.settings:get("api_key")
                    return T(_("API key: %1"), key ~= "" and _("set") or _("none"))
                end,
                keep_menu_open = true,
                callback = function()
                    self:editSetting("api_key", _("API key"), { password = true })
                end,
            },
            {
                text_func = function()
                    return T(_("Context sent: %1 characters"), self.settings:get("context_chars"))
                end,
                keep_menu_open = true,
                separator = true,
                callback = function()
                    self:editSetting("context_chars", _("Context characters"), { numeric = true })
                end,
            },
            {
                text_func = function()
                    return T(_("Clear cache (%1 answers)"), self.lookup.cache:count())
                end,
                keep_menu_open = true,
                callback = function()
                    self.lookup:clear_cache()
                    self:saveCache()
                    UIManager:show(InfoMessage:new{ text = _("Cached answers cleared.") })
                end,
            },
            {
                text_func = function()
                    return T(_("Update channel: %1"), self.settings:get("channel"))
                end,
                keep_menu_open = true,
                callback = function()
                    local next_channel = self.settings:get("channel") == "stable" and "dev" or "stable"
                    self.settings:set("channel", next_channel)
                    self.settings:flush()
                end,
            },
            {
                text = _("Look words up before I ask"),
                help_text = _("Start asking when the dictionary opens, so the answer is already there when you press AI. Costs a request for every dictionary lookup, not only the ones you press AI on."),
                checked_func = function() return self.settings:get("prefetch") end,
                callback = function()
                    self.settings:set("prefetch", not self.settings:get("prefetch"))
                    self.settings:flush()
                end,
            },
            {
                text = _("Check for updates"),
                keep_menu_open = true,
                callback = function() self:checkForUpdates() end,
            },
            {
                text = T(_("Version %1"), Version.string),
                keep_menu_open = true,
                callback = function()
                    UIManager:show(InfoMessage:new{
                        text = T(_("AI dictionary %1\nDevice: %2"), Version.string, Device.model),
                    })
                end,
            },
        },
    }
end

return AiDict
