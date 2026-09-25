--[[--
AI dictionary: explains the word you tapped, in context, by asking a remote
AI service.

Everything in this file is KOReader glue — widgets, menus, events. The
behaviour lives in `aidict/`, which is plain Lua and covered by `spec/`.

@module koplugin.aidict
--]]--

local DataStorage = require("datastorage")
local DictQuickLookup = require("ui/widget/dictquicklookup")
local Device = require("device")
local Dispatcher = require("dispatcher")
local DocSettings = require("docsettings")
local InfoMessage = require("ui/widget/infomessage")
local InputDialog = require("ui/widget/inputdialog")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local PathChooser = require("ui/widget/pathchooser")
local ReadCollection = require("readcollection")
local ReadHistory = require("readhistory")
local TextViewer = require("ui/widget/textviewer")
local Trapper = require("ui/trapper")
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local ConfirmBox = require("ui/widget/confirmbox")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
local time = require("ui/time")
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local Config = require("aidict.config")
local Context = require("aidict.context")
local Format = require("aidict.format")
local Reqid = require("aidict.reqid")
local Library = require("aidict.library")
local Kpm = require("aidict.kpm")
local Look = require("aidict.look")
local NetCheck = require("aidict.netcheck")
local Lookup = require("aidict.lookup")
local Page = require("aidict.page")
local Prefetch = require("aidict.prefetch")
local RemoteSettings = require("aidict.remote_settings")
local Settings = require("aidict.settings")
local Sync = require("aidict.sync")
local Updater = require("aidict.updater")
local Vocab = require("aidict.vocab")
local Version = require("aidict.version")
local http_transport = require("aidict.http_transport")
local json = require("aidict.json")

-- Renamed whenever the answers kept under it change: the old keys hold
-- entries without their headword, pronunciation and etymology, and then ones
-- with Wiktionary's whole etymology and its ɹ, which the cache would
-- otherwise serve for a month.
local CACHE_KEY = "entries"
local DEAD_CACHE_KEYS = { "cache_entries", "answers" }

--- The plugin's one entry in the main menu; everything else is inside it.
local MENU_ID = "aidict"

--[[--
Put "AI dictionary" at the top of the Tools tab rather than three taps deep.

A plugin's menu item is *appended* to whatever section its `sorting_hint`
names (see `MenuSorter:sort`), and Tools is already two pages long — so the
hint alone would land it on the second page, inside More tools. The order
tables are cached by `require`, though, and KOReader's own
`ui/plugin/insert_menu` edits them the same way. Inserting at index 1 puts
Sync, the first line inside, two taps from the reader.

Idempotent on purpose: `init` runs once per FileManager and once per Reader,
and this must not add the entry twice.
--]]--
local function claimMenuPosition()
    for _, order in ipairs({
        require("ui/elements/reader_menu_order"),
        require("ui/elements/filemanager_menu_order"),
    }) do
        local placed = false
        for _, id in ipairs(order.tools) do
            if id == MENU_ID then placed = true break end
        end
        if not placed then table.insert(order.tools, 1, MENU_ID) end
    end
end

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
    for _, dead in ipairs(DEAD_CACHE_KEYS) do
        if self.store:readSetting(dead) ~= nil then self.store:saveSetting(dead, nil) end
    end
    self.prefetch = Prefetch.new({ settings = self.settings })
    self.prefetch_jobs = {}
    -- AI pages in dictionary popups still waiting for their answer.
    self.ai_pages = {}
    -- Named rather than called directly so a spec can move it: the give-up
    -- branch below is otherwise half a minute away.
    self.now = os.time

    -- So the sync can be a gesture rather than three taps into a menu: the
    -- Kindle has no keyboard to reach for and this is the one action worth
    -- doing from anywhere.
    Dispatcher:registerAction("aidict_sync", {
        category = "none",
        event = "AiDictSync",
        title = _("Sync"),
        general = true,
    })

    claimMenuPosition()
    if self.ui and self.ui.menu then
        self.ui.menu:registerToMainMenu(self)
    end
    if self.ui and self.ui.dictionary then
        self:joinDictionaryPopup()
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
is the earliest the word is known, so it is the moment to start asking: the
popup that opens a moment later shows the AI page first, and every
millisecond spent here is one the reader does not spend looking at "Asking".

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
        -- commonest answer is "already cached".
        logger.dbg("aidict: not fetching ahead:", why)
        return false
    end
    self:startPrefetch(request, key)
    -- Never swallow the event: the dictionary is the one that wanted it.
    return false
end

--[[--
Fork, ask, and let it finish on its own.

This is the same work the highlight menu's Explain does, minus everything that
waits or draws: `Trapper` exists to show a dismissable progress window, and
here the popup's AI page is what the reader watches instead.
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

--[[--
Put what came back into the cache, and onto any AI page waiting for it.

Every way out of here fills the pages, the failures included: a page left
saying "Asking" is a page that lies.
--]]--
function AiDict:finishPrefetch(job, raw, why)
    self.prefetch_jobs[job.key] = nil
    self.prefetch:ended(job.key)

    if not raw or raw == "" then
        logger.warn(string.format("aidict: fetching %s ahead came to nothing (%s)",
            job.request.word, why or "no data"))
        self:fillPages(job.key, nil)
        return
    end

    local ok, outcome = pcall(json.decode, raw)
    if not (ok and type(outcome) == "table") then
        logger.warn("aidict: fetching", job.request.word, "ahead returned junk")
        self:fillPages(job.key, nil)
        return
    end
    if not outcome.ok then
        local err = outcome.err or {}
        logger.warn(string.format("aidict: fetching %s ahead failed (%s: %s)",
            job.request.word, tostring(err.code), tostring(err.message)))
        self:fillPages(job.key, outcome)
        return
    end

    self.lookup:remember(job.request, outcome.result)
    self:saveCache()
    -- So a popup that opens after this does not call it "cached": it was
    -- asked for this very lookup, only quicker than the dictionary.
    self.just_landed = job.key
    logger.info(string.format("aidict: %s fetched ahead in %sms, waiting in the cache [%s]",
        job.request.word, tostring(outcome.result.elapsed_ms or "?"),
        marks(outcome.result, job.request)))
    self:fillPages(job.key, outcome)
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
    self.ai_pages = {}
end

function AiDict:onCloseDocument()
    self:keepLookGlobal()
    self:stopPrefetching()
    self:saveCache()
end

function AiDict:onFlushSettings()
    self:keepLookGlobal()
    self:saveCache()
    -- KOReader keeps no time for a setting's change; this save is the nearest
    -- one, and Sync needs it to decide who changed a key last.
    RemoteSettings.notice(G_reader_settings.data, self.store, json, os.time())
end

----------------------------------------------------------------------------
-- Entry points
----------------------------------------------------------------------------

--[[--
Leave KOReader's "(query : word)" line off the AI page.

KOReader adds it to the popup's first page in `addQueryWordToResult`, a
method kept separate so it can be patched. It runs while the popup is being
built, before `showDict` hands the popup back, so it is the class that is
wrapped, once per KOReader run: the plugin is initialised again for every
book.
--]]--
local function keepQueryLineOffAiPage()
    local add = DictQuickLookup.addQueryWordToResult
    if type(add) ~= "function" or DictQuickLookup.aidict_query_line then return end
    DictQuickLookup.aidict_query_line = add
    DictQuickLookup.addQueryWordToResult = function(this, ...)
        if not Page.wants_query_line(this.results) then return end
        return add(this, ...)
    end
end

--[[--
Put the AI page first in KOReader's dictionary popup.

KOReader has no hook for adding a result, so this wraps the dictionary's
`showDict`, which is handed the results just before it builds the popup. Only
this reader's dictionary is wrapped, not the class: Wikipedia shares the class
and should stay as it is.

Anything unexpected in there — a KOReader that has moved things around — must
cost the AI page and nothing else, so the plugin's own part is guarded and the
dictionary always gets its call.
--]]--
function AiDict:joinDictionaryPopup()
    keepQueryLineOffAiPage()
    local dictionary = self.ui.dictionary
    local show = dictionary.showDict
    if type(show) ~= "function" then
        logger.warn("aidict: this KOReader's dictionary has no showDict; no AI page")
        return
    end
    dictionary.showDict = function(this, word, results, ...)
        local ok, page, with_page = pcall(self.openPage, self, word, results)
        if not ok then
            logger.warn("aidict: could not add the AI page:", tostring(page))
            page, with_page = nil, nil
        end
        show(this, word, with_page or results, ...)
        if page then
            local tracked, err = pcall(self.trackPage, self, page, this.dict_window)
            if not tracked then logger.warn("aidict: lost track of the AI page:", tostring(err)) end
        end
    end
end

--[[--
Decide the AI page for a popup about to open, and put it first in its results.

The request normally went out a moment ago, from `onWordLookedUp`; this starts
it only when that did not happen.

@treturn table|nil the page to keep an eye on, when it is still waiting
@treturn table|nil the results with the page in them, when there is a page
--]]--
function AiDict:openPage(word, results)
    local request = self:requestFor(word, self.ui and self.ui.highlight)
    if not request then return nil end
    local key = Lookup.key(request)

    local cached = self.lookup:peek(request)
    local fresh = cached ~= nil and self.just_landed == key
    local wanted, why = false, nil
    if not cached then
        wanted, why = self.prefetch:wanted(key, { offline = not canAsk() })
        if wanted then
            wanted = self:startPrefetch(request, key)
            -- It can land before this line, where the scheduler runs things
            -- at once; a page that says "Asking" over a cached answer would
            -- wait for an update that already happened.
            cached = self.lookup:peek(request)
            fresh = cached ~= nil
        end
    end
    self.just_landed = nil

    local state = Page.opening({ cached = cached, fresh = fresh, wanted = wanted, why = why })
    if not state then
        logger.dbg("aidict: no AI page for", request.word, why)
        return nil
    end

    if type(results) ~= "table" then results = {} end
    table.insert(results, 1, Page.entry(request.word, state))
    if state.kind ~= "asking" then return nil, results end
    return { key = key, word = request.word }, results
end

--- Remember the popup a waiting page ended up in, so the answer can find it.
function AiDict:trackPage(page, popup)
    if not (popup and Page.index_in(popup.results)) then
        -- The page would say "Asking" forever; the log is where that shows.
        logger.warn("aidict: the popup for", page.word, "is not where it was expected")
        return
    end
    page.popup = popup
    self.ai_pages[#self.ai_pages + 1] = page
end

--[[--
Give every page waiting on `key` what came back, and redraw the one the
reader is looking at.

A page the reader has paged away from is only rewritten: the popup reads its
results again when it pages back.
--]]--
function AiDict:fillPages(key, outcome)
    local still = {}
    for _, page in ipairs(self.ai_pages) do
        if page.key ~= key then
            still[#still + 1] = page
        else
            local popup = page.popup
            local shown = not UIManager.isWidgetShown or UIManager:isWidgetShown(popup)
            local index = shown and Page.index_in(popup.results)
            if index then
                popup.results[index] = Page.entry(page.word, Page.landed(outcome))
                if popup.dict_index == index and popup.changeDictionary then
                    popup:changeDictionary(index)
                end
            end
        end
    end
    self.ai_pages = still
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

--[[--
The paragraph a selection sits in.

crengine can hand back the HTML of the block element containing a position —
which is the paragraph — so this is the real passage the reader is looking at,
not just the sentence. That is what lets the other side tell which sense of a
word is meant. Empty when the document cannot produce it (a paged PDF, an
older build).
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

--[[--
What gets sent with the word: the paragraph, and the sentence inside it.

The sentence is cut out of the paragraph here rather than asked of KOReader,
whose `extendXPointersToSentenceSegment` only stretches a selection over the
punctuation around it: every tap on the Kindle filed the word as its own
sentence. The Words inbox takes the sentence first, so that was all the
catalog would have had to go on.
--]]--
function AiDict:contextFor(highlight, word)
    local budget = self.settings:get("context_chars")
    if budget <= 0 then return "", "" end

    local paragraph = self:paragraphFor(highlight)
    local sentence = Context.snippet(Context.sentence(paragraph, word), word, budget)
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

The lookup announcement, the popup's AI page and the highlight menu all build
their request here, and that is not tidiness: the cache key is the word plus
its passage, so an answer fetched ahead is only ever found again if they agree
character for character on what the passage was.

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
        showResult(word, cached, "cached")
        return
    end

    -- This exact question is already in the air: the dictionary opened a
    -- moment ago and the request went out then. Waiting for that answer beats
    -- asking again — it is most of the way here, and a second identical
    -- request would cost twice over and arrive no sooner.
    local pending = Lookup.key(request)
    if self.prefetch:is_pending(pending) then
        self:joinPrefetch(request, pending)
        return
    end

    self:askNow(request)
end

--[[--
Wait for a prefetch already in flight rather than starting a second request.

The prefetch has its own poll running on the scheduler and writes the answer
to the cache when it lands, so there is nothing to do here but watch for it —
and get out of the way if it fails, or if the reader gives up.
--]]--
function AiDict:joinPrefetch(request, key)
    local word = request.word
    logger.info(string.format("aidict: %s already on its way, waiting for it", word))

    local waiting = InfoMessage:new{
        text = T(_("Asking AI about “%1”…"), word),
        dismissable = true,
    }
    local given_up = false
    waiting.dismiss_callback = function() given_up = true end
    UIManager:show(waiting)

    -- The prefetch's own deadline plus a moment, so this never outlives the
    -- thing it is waiting for.
    local deadline = self.now() + self.settings:get("total_timeout") + 6

    local function look()
        if given_up then
            logger.info(string.format("aidict: %s given up on while waiting", word))
            return
        end

        local cached = self.lookup:peek(request)
        if cached then
            UIManager:close(waiting)
            logger.info(string.format("aidict: %s caught the one already asked", word))
            -- Not "cached": the reader watched a spinner for this one. It was
            -- on its way before they asked, which is a different thing and
            -- the only way to see the prefetch working.
            showResult(word, cached, "prefetch")
            return
        end

        if not self.prefetch:is_pending(key) then
            -- It finished without an answer. Ask properly rather than leaving
            -- the reader with nothing.
            UIManager:close(waiting)
            logger.info(string.format("aidict: %s came to nothing ahead, asking now", word))
            self:askNow(request)
            return
        end

        if self.now() > deadline then
            UIManager:close(waiting)
            logger.warn(string.format("aidict: %s still not here, gave up waiting", word))
            UIManager:show(InfoMessage:new{ text = Format.error(nil, _("The lookup failed.")) })
            return
        end

        UIManager:scheduleIn(PREFETCH_POLL_SECONDS, look)
    end

    UIManager:scheduleIn(PREFETCH_POLL_SECONDS, look)
end

--- Ask the gateway now, showing a progress the reader can dismiss.
function AiDict:askNow(request)
    local word = request.word

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
            UIManager:show(InfoMessage:new{ text = Format.error(outcome.err, _("The lookup failed.")) })
            return
        end

        self.lookup:remember(request, outcome.result)
        self:saveCache()

        local result = outcome.result
        -- Everything the gateway told us about where its time went, plus what
        -- its reviewer made of the answer. One line per lookup, so a slow or
        -- doubtful one can be taken apart afterwards from the device alone.
        local legs = Format.legs(result.legs)
        local split = string.format("gateway %sms%s, edge rtt %sms",
            tostring(result.server_ms or "?"), legs ~= "" and (": " .. legs) or "",
            tostring(result.edge_rtt_ms or "?"))
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

        showResult(word, result, nil)
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
            UIManager:show(InfoMessage:new{ text = Format.error(err, _("The update check failed.")) })
            return
        end

        local info = outcome.info
        if info.available then
            UIManager:show(ConfirmBox:new{
                text = T(_("Version %1 is available on the %2 channel.\nYou have %3.\n\nInstall it now?"),
                    info.latest, info.channel, info.current),
                ok_text = _("Install"),
                ok_callback = function() self:installUpdate(info.latest) end,
            })
        else
            UIManager:show(InfoMessage:new{
                text = T(_("Version %1 is the newest on the %2 channel."), info.current, info.channel),
            })
        end
    end)
end

--[[--
Where a lookup's network time goes: DNS, connect, TLS and the request, each
timed on its own against the AI endpoint, the library and 1.1.1.1. The
footer only says how much the network took; this says which step took it.

The sockets are luasocket's and luasec's, KOReader's own. The handshake does
not verify the certificate: this measures the handshake, it sends nothing
over it, and the request that follows goes through the checked transport.
--]]--
function AiDict:networkCheck()
    if not canAsk() then
        UIManager:show(InfoMessage:new{ text = _("No Wi-Fi, so there is nothing to check.") })
        return
    end
    local targets = NetCheck.targets(self.settings:get("endpoint"), Config.BAKED.library_endpoint)

    Trapper:wrap(function()
        local completed, outcome = Trapper:dismissableRunInSubprocess(function()
            local socket = require("socket")
            local ssl = require("ssl")
            local TIMEOUT = 10
            local check = NetCheck.new({
                clock = function() return time.to_ms(time.now()) end,
                resolve = function(host) return socket.dns.toip(host) end,
                connect = function(ip, port)
                    local sock = socket.tcp()
                    sock:settimeout(TIMEOUT)
                    local ok, err = sock:connect(ip, port)
                    if not ok then
                        sock:close()
                        return nil, err
                    end
                    return sock
                end,
                handshake = function(sock, host)
                    local conn, err = ssl.wrap(sock, {
                        mode = "client", protocol = "any", verify = "none",
                        options = { "all", "no_sslv2", "no_sslv3" },
                    })
                    if not conn then return nil, err end
                    if not host:match("^%d+%.%d+%.%d+%.%d+$") then conn:sni(host) end
                    conn:settimeout(TIMEOUT)
                    local ok, hs_err = conn:dohandshake()
                    -- Closed here, the wrapper and the socket under it: only
                    -- the handshake's time is wanted from it.
                    conn:close()
                    return ok, hs_err
                end,
                close = function(sock) sock:close() end,
                fetch = function(url)
                    return http_transport({
                        url = url, method = "GET", block_timeout = TIMEOUT, total_timeout = 15,
                    })
                end,
            })
            return NetCheck.report(check:run(targets, 2))
        end, _("Checking the network…"))

        if not completed then return end
        if type(outcome) ~= "string" then
            UIManager:show(InfoMessage:new{ text = _("The network check failed.") })
            return
        end
        logger.info("aidict: network check\n" .. outcome)
        UIManager:show(TextViewer:new{
            title = _("Network check"),
            text = outcome,
        })
    end)
end

--[[--
The real filesystem, in the five calls `library.lua` asks for.

KOReader bundles lfs; `spec/` passes a table of fake files instead, which is
the whole reason the library module never requires it.
--]]--
local function deviceFilesystem()
    local lfs = require("libs/libkoreader-lfs")
    return {
        size = function(path)
            local attributes = lfs.attributes(path)
            if attributes and attributes.mode == "file" then return attributes.size end
            return nil
        end,
        mkdir = function(path) return lfs.mkdir(path) end,
        rename = function(from, to) return os.rename(from, to) end,
        remove = function(path) os.remove(path) end,
        rmdir = function(path) return lfs.rmdir(path) end,
    }
end

--[[--
The book being read, if any.

`ReaderUI.instance` is the open reader wherever the sync was started from;
the plugin's own `ui` is the same reader when the sync was started inside a
book, and is asked too, so the check does not rest on one field alone.
Required when asked rather than at the top, the way KOReader's own file
manager reaches the reader: the two modules load each other's worlds, and a
plugin loaded by both should not be what ties them together.
--]]--
local function openBookIn(ui)
    local loaded, ReaderUI = pcall(require, "apps/reader/readerui")
    local reader = loaded and type(ReaderUI) == "table" and ReaderUI.instance or nil
    for _, candidate in ipairs({ reader or false, ui or false }) do
        local document = candidate and candidate.document
        if type(document) == "table" and type(document.file) == "string" then
            return document.file
        end
    end
    return nil
end

local function isOpen(ui, path)
    local open = openBookIn(ui)
    if not open then return false end
    if open == path then return true end
    -- The reader may hold the path through a symlink the books folder does
    -- not, or the other way round.
    local realpath = require("ffi/util").realpath
    if type(realpath) ~= "function" then return false end
    return (realpath(open) or open) == (realpath(path) or path)
end

--- One piece of KOReader's bookkeeping. The file itself has already moved
--- or gone by the time this runs, so a failure here is logged rather than
--- turned into a failed move: undoing the file would only lose more.
local function bookkeep(what, fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then logger.warn("aidict: library", what, "failed:", tostring(err)) end
end

--[[--
Move and delete a book the way KOReader's own file manager does, so what goes
with the book goes with it: the `.sdr` beside it (page, bookmarks,
highlights), its line in History and its place in any collection.

The book that is open is refused with "open", for `Library:settle` to leave
for the next sync. The reader writes its sidecar when it closes, to the path
it opened — so moving the file under it would leave the reading state behind
at the old path, and deleting it would bring a sidecar back for a book that
is gone.
--]]--
local function bookOps(ui)
    return {
        relocate = function(from, to)
            if isOpen(ui, from) then return false, "open" end
            local ok, err = os.rename(from, to)
            if not ok then return false, tostring(err or "could not move the file") end
            -- The sidecar is the reading position itself, so it is the one
            -- step that must not fail quietly: put the file back and report
            -- the move failed, and the index keeps the old path for the next
            -- sync to try again, sidecar and all.
            local moved, sidecar_err = pcall(DocSettings.updateLocation, from, to)
            if not moved then
                logger.warn("aidict: library sidecar move failed:", tostring(sidecar_err))
                os.rename(to, from)
                return false, "could not move the reading state: " .. tostring(sidecar_err)
            end
            bookkeep("history move", ReadHistory.updateItem, ReadHistory, from, to)
            bookkeep("collection move", ReadCollection.updateItem, ReadCollection, from, to)
            return true
        end,
        discard = function(path)
            if isOpen(ui, path) then return false, "open" end
            local ok, err = os.remove(path)
            if not ok then return false, tostring(err or "could not delete the file") end
            -- The cover-browser cache, where the KOReader in use has one.
            local has_booklist, BookList = pcall(require, "ui/widget/booklist")
            if has_booklist and type(BookList) == "table" and BookList.resetBookInfoCache then
                bookkeep("book info reset", BookList.resetBookInfoCache, path)
            end
            bookkeep("sidecar purge", DocSettings.updateLocation, path)
            bookkeep("history delete", ReadHistory.fileDeleted, ReadHistory, path)
            bookkeep("collection delete", ReadCollection.removeItem, ReadCollection, path)
            return true
        end,
    }
end

--[[--
What earlier syncs placed in the books folder: the only files a sync will
ever move or delete.

Its own file rather than a key in `aidict.lua`: it is a few hundred rows the
settings have no use for. It belongs to one folder — pointing the sync at
another starts a fresh index, so the books left in the old folder are never
taken for books this one lost.
--]]--
local LIBRARY_INDEX = "aidict_library.lua"

function AiDict:libraryIndexStore()
    if not self.library_store then
        self.library_store = LuaSettings:open(DataStorage:getSettingsDir() .. "/" .. LIBRARY_INDEX)
    end
    return self.library_store
end

function AiDict:libraryIndex(dir)
    local store = self:libraryIndexStore()
    if store:readSetting("dir") ~= dir then return {} end
    return store:readSetting("books") or {}
end

function AiDict:saveLibraryIndex(dir, books)
    local store = self:libraryIndexStore()
    store:saveSetting("dir", dir)
    store:saveSetting("books", books)
    store:flush()
end

local function basename(path)
    return path:match("([^/]*)$")
end

--- What the sync changed, in the words the InfoMessage uses; false when nothing did.
local function describeSync(report, settled)
    local lines = {}
    if report.downloaded == 0 and #report.failed == 0 and settled.moved == 0 and settled.deleted == 0 then
        if #settled.deferred == 0 and #settled.failed == 0 then return false end
    else
        local done = {}
        if report.total > 0 then
            done[#done + 1] = T(_("Downloaded %1 of %2 (%3 MB)."),
                report.downloaded, report.total,
                string.format("%.1f", report.bytes / 1024 / 1024))
        end
        if settled.moved > 0 then
            done[#done + 1] = T(_("Moved %1 to their new folders."), settled.moved)
        end
        if settled.deleted > 0 then
            done[#done + 1] = T(_("Deleted %1 the library no longer has."), settled.deleted)
        end
        lines[1] = table.concat(done, " ")
    end
    if #report.failed > 0 then
        lines[#lines + 1] = T(_("%1 failed: %2"),
            #report.failed, report.failed[1].path .. " — " .. tostring(report.failed[1].reason))
    end
    -- Only one book can be open, so there is one of these at most.
    local open = settled.deferred[1]
    if open and open.action == "move" then
        lines[#lines + 1] = T(_("%1 is open, so it moves on the next sync."), basename(open.from))
    elseif open then
        lines[#lines + 1] = T(_("%1 is open, so it is deleted on the next sync."), basename(open.from))
    end
    if #settled.failed > 0 then
        local first = settled.failed[1]
        lines[#lines + 1] = T(_("%1 could not be moved or deleted: %2"),
            #settled.failed, first.from .. " — " .. tostring(first.reason))
    end
    return table.concat(lines, "\n\n")
end

--[[--
Mirror the gateway's library: pull the books this device does not have, and
move or delete the ones the server moved or deleted.

A step of `sync`, inside its Trapper coroutine: returns what changed, false
when nothing did, or nil when the reader dismissed it.
--]]--
function AiDict:libraryStep(endpoint)
    local dir = tostring(self.settings:get("library_dir")):gsub("/+$", "")
    local library = Library.new({
        endpoint = endpoint,
        api_key = self.settings:get("api_key"),
        transport = http_transport,
        json = json,
        fs = deviceFilesystem(),
    })

    local index = self:libraryIndex(dir)
    -- In a subprocess so the reader can give up on it: a first sync over a
    -- Kindle's radio is minutes, and the files it has already written stay
    -- written when they do. Only the downloads happen there; see
    -- `Library:settle` for why the moves cannot.
    local completed, outcome = Trapper:dismissableRunInSubprocess(function()
        local report, err = library:sync(dir, { index = index })
        return { ok = report ~= nil, report = report, err = err }
    end, T(_("Syncing %1…"), dir))

    if not completed then return nil end
    if type(outcome) ~= "table" or not outcome.ok then
        local err = type(outcome) == "table" and outcome.err or nil
        return Format.error(err, _("The library sync failed."))
    end

    local report = outcome.report
    local ops = bookOps(self.ui)
    ops.index = index
    local settled = library:settle(report, dir, ops)
    self:saveLibraryIndex(dir, settled.index)

    logger.info(string.format(
        "aidict: library sync — %d downloaded, %d moved, %d deleted, %d already here, " ..
        "%d failed, %d dropped, %d left for the next sync",
        report.downloaded, settled.moved, settled.deleted, report.have, #report.failed,
        report.dropped or 0, #settled.deferred + #settled.failed))

    -- The file browser is very likely sitting on the folder that just gained
    -- ten books — or on one a move just emptied and removed, which has
    -- nothing left to show but the library above it.
    local browser = self.ui and self.ui.file_chooser
    if browser and browser.path and browser.path:find(dir, 1, true) == 1 then
        local lfs = require("libs/libkoreader-lfs")
        if lfs.attributes(browser.path, "mode") == "directory" then
            browser:refreshPath()
        else
            browser:changeToPath(dir)
        end
    end
    return describeSync(report, settled)
end

--[[--
`vocab.db`, read the way `Vocab.upload` asks: every lookup since `since`, as
positional rows. Here and not in `aidict/` because it is the one place that
opens SQLite, which only KOReader has.

Read-only, because the Kindle's own reader owns the file and may be writing
to it; a read never takes a lock that could make that fail.
--]]--
local function readVocab(since)
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(Vocab.PATH, "mode") ~= "file" then
        return nil, "there is no vocab.db on this device"
    end
    local SQ3 = require("lua-ljsqlite3/init")
    local opened, conn = pcall(SQ3.open, Vocab.PATH, "ro")
    if not opened then return nil, tostring(conn) end
    local rows = {}
    local ok, err = pcall(function()
        local stmt = conn:prepare(Vocab.QUERY)
        stmt:bind1(1, since)
        while true do
            local row = stmt:step()
            if not row then break end
            -- Copied: the driver may hand back the same table each step.
            local copy = {}
            for i = 1, #Vocab.COLUMNS do copy[i] = row[i] end
            rows[#rows + 1] = copy
        end
        stmt:close()
    end)
    conn:close()
    if not ok then return nil, tostring(err) end
    return rows
end

--[[--
Four bytes of the kernel's randomness, for seeding a forked child.

A child starts from the parent's random state, and the parent's does not move
when the child draws: two uploads in one session would mint the same request
ids, and the inbox would answer the second with the first's receipt.
--]]--
local function freshSeed()
    local file = io.open("/dev/urandom", "rb")
    if file then
        local bytes = file:read(4)
        file:close()
        if bytes and #bytes == 4 then
            local a, b, c, d = bytes:byte(1, 4)
            return ((a * 256 + b) * 256 + c) * 256 + d
        end
    end
    return os.time()
end

--[[--
Send the words looked up in the Kindle's own reader since the last upload.

A step of `sync`, run only where the Kindle's reader left a `vocab.db`:
returns what it sent, false when there was nothing to send, or nil when the
reader dismissed it.
--]]--
function AiDict:lookupsStep()
    local since = self.settings:get("vocab_uploaded_through")
    local rows, err = readVocab(since)
    if not rows then
        return Format.error({ message = err }, _("vocab.db could not be read."))
    end
    if Vocab.pending(rows, since) == 0 then return false end

    local vocab = Vocab.new({
        endpoint = self.settings:get("endpoint"),
        api_key = self.settings:get("api_key"),
        transport = http_transport,
        json = json,
        random = math.random,
    })
    -- In a subprocess so the reader can give up on it: the first upload is
    -- the whole archive, a few dozen requests over the Kindle's radio. What
    -- already arrived stays arrived; the next upload sends it again and the
    -- server writes nothing.
    local completed, outcome = Trapper:dismissableRunInSubprocess(function()
        math.randomseed(freshSeed())
        local report, upload_err = vocab:upload(function() return rows end, since)
        return { report = report, err = upload_err }
    end, _("Sending Kindle lookups…"))

    if not completed then return nil end
    if type(outcome) ~= "table" or type(outcome.report) ~= "table" then
        return _("Sending the lookups failed.")
    end

    local report = outcome.report
    -- Also after a failure: the batches that arrived need not go again.
    if (tonumber(report.cursor) or 0) > since then
        self.settings:set("vocab_uploaded_through", report.cursor)
        self.settings:flush()
    end
    logger.info(string.format(
        "aidict: vocab upload — %d rows in %d batches, %d new, %d already there, %d skipped%s",
        report.rows, report.batches, report.created, report.existing, report.skipped,
        outcome.err and (", failed: " .. tostring(outcome.err.message)) or ""))

    if outcome.err then
        local text = Format.error(outcome.err, _("Sending the lookups failed."))
        if report.batches > 0 then
            text = text .. "\n\n" .. T(_("%1 new lookups arrived before it stopped."), report.created)
        end
        return text
    end
    return T(_("Sent %1 lookups: %2 new, %3 already there."), report.rows, report.created, report.existing)
end

--[[--
Where synced books go, picked rather than typed.

An absolute path on a Kindle keyboard is a typo waiting to happen, and a typo
here makes a second folder rather than an error.
--]]--
function AiDict:chooseLibraryFolder()
    UIManager:show(PathChooser:new{
        select_file = false,
        path = self.settings:get("library_dir"),
        onConfirm = function(path)
            local ok, reason = self.settings:set("library_dir", path)
            if not ok then
                UIManager:show(InfoMessage:new{ text = reason })
                return
            end
            self.settings:flush()
        end,
    })
end

--[[--
Run KPM on this device and hand back what it said.

Forked, because the download and the unpacking both block, and the reader
should be able to give up on them. Whatever KPM wrote to disk stays written
either way — it is the package manager's own business, not a transaction we
opened.
--]]--
local function runKpm(command)
    local pipe = io.popen(command)
    if not pipe then return nil end
    local output = pipe:read("*a")
    -- Lua 5.1's close() returns only a boolean; the exit status is the
    -- tiebreaker anyway, never the verdict on its own.
    local closed = pipe:close()
    return { output = output or "", ok_status = closed ~= false }
end

--[[--
Update the package this plugin ships in, without leaving KOReader.

The alternative is the Kindle's search bar — leave the book, wake the home
screen, type `;kpm install koreader-aidict` correctly — which is enough
friction that an update waits weeks.

KPM replaces `aidict.koplugin` underneath a running KOReader, which is safe:
the Lua already loaded stays loaded, and the new files are picked up at the
next restart. So the restart is offered rather than taken.
--]]--
function AiDict:installUpdate(version)
    local lfs = require("libs/libkoreader-lfs")
    local binary = Kpm.find(function(path) return lfs.attributes(path, "mode") == "file" end)
    if not binary then
        UIManager:show(InfoMessage:new{
            text = T(_("KPM is not on this device, so the update has to be installed from the Kindle search bar:\n\n;kpm install %1"),
                Updater.PACKAGE_ID),
        })
        return
    end

    local command = Kpm.command(binary, Updater.PACKAGE_ID)
    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            -- Which channel it is coming from, because "installing 0.2.50"
            -- means something different on dev than on stable.
            local progress = version
                and T(_("Installing %1 from the %2 channel…"), version, self.settings:get("channel"))
                or T(_("Installing %1…"), Updater.PACKAGE_ID)
            local completed, result = Trapper:dismissableRunInSubprocess(function()
                return runKpm(command)
            end, progress)

            if not completed then return end
            if type(result) ~= "table" then
                UIManager:show(InfoMessage:new{ text = _("KPM could not be started.") })
                return
            end

            local ok, message = Kpm.interpret(result.output, result.ok_status)
            logger.info("aidict: kpm install —", ok and "ok" or "failed", tostring(message))
            if not ok then
                UIManager:show(InfoMessage:new{
                    text = T(_("The update failed.\n\n%1"), tostring(message)),
                })
                return
            end

            if not Device:canRestart() then
                UIManager:show(InfoMessage:new{
                    text = _("Installed. Restart KOReader to load it."),
                })
                return
            end
            UIManager:show(ConfirmBox:new{
                text = _("Installed. KOReader has to restart to load it.\n\nRestart now?"),
                ok_text = _("Restart"),
                ok_callback = function()
                    UIManager:broadcastEvent(Event:new("Restart"))
                end,
            })
        end)
    end)
end

--- @param source string|nil "cached", "prefetch", or nil for a fresh ask.
function showResult(word, result, source)
    UIManager:show(TextViewer:new{
        title = Format.title(result, word),
        text = Format.result(result, { word = word, source = source }),
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
-- Settings from the library
----------------------------------------------------------------------------

--- The names of the settings a sync changed, for the message that reports it.
local function changedKeys(applied)
    local keys = {}
    for _, change in ipairs(applied) do keys[#keys + 1] = change.key end
    return table.concat(keys, ", ")
end

--[[--
Sync KOReader's settings with the library, both ways: apply what it holds for
this Kindle, and report back every setting, this Kindle's own changes included.

A step of `sync`: returns what to say, how many settings changed, and whether
the reader dismissed the report; nil when they dismissed the fetch. The requests run in a subprocess, so a slow
gateway cannot freeze the reader; the writes happen in this process, because
a change to `G_reader_settings` made in a forked child dies with it.
--]]--
function AiDict:settingsStep(endpoint)
    -- A change made in the open book since the last save is this Kindle's too.
    self:keepLookGlobal()
    local remote = RemoteSettings.new({
        endpoint = endpoint,
        api_key = self.settings:get("api_key"),
        transport = http_transport,
        json = json,
    })
    local function offload(task)
        local completed, raw = Trapper:dismissableRunInSubprocess(task, _("Syncing settings…"), true)
        if not completed then return nil end
        return raw
    end

    local result, err = remote:sync(G_reader_settings, { outbox = self.store, offload = offload, now = os.time })
    if not result and err and err.code == "cancelled" then return nil end
    if not result then return Format.error(err, _("Syncing the settings failed.")), 0 end
    logger.info(string.format("aidict: settings sync — %d applied, reported: %s%s",
        #result.applied, tostring(result.reported),
        result.report_error and (" (" .. tostring(result.report_error.message) .. ")") or ""))

    local dismissed = result.report_error and result.report_error.code == "cancelled"
    local said = {}
    if #result.applied > 0 then
        said[#said + 1] = T(_("Changed %1: %2."), #result.applied, changedKeys(result.applied))
    end
    if not result.reported and not dismissed then
        said[#said + 1] = _("This Kindle's settings could not be sent back to the library.")
    end
    if #said == 0 and dismissed then return nil end
    local text = #said > 0 and table.concat(said, " ") or false
    -- Dismissing the report stops the sync too, but what was applied stays
    -- applied, and says so.
    return text, #result.applied, dismissed
end

--[[--
Everything that goes between this Kindle and the gateway, in one go: the
library, KOReader's settings, and the Kindle's own lookups. How the steps
combine is `aidict.sync`; what each does is its step here.
--]]--
function AiDict:sync()
    local endpoint = Library.endpoint_from(Config.BAKED.library_endpoint)
    local lfs = require("libs/libkoreader-lfs")
    local has_lookups = lfs.attributes(Vocab.PATH, "mode") == "file"
    local no_address = _("This package was built without a library address.")
    -- Nothing to send anywhere: say so without turning the radio on.
    if not endpoint and not has_lookups then
        UIManager:show(InfoMessage:new{ text = no_address })
        return
    end

    local steps = {}
    if endpoint then
        steps[#steps + 1] = { title = _("Library"), run = function() return self:libraryStep(endpoint) end }
        steps[#steps + 1] = { title = _("Settings"), run = function() return self:settingsStep(endpoint) end }
    else
        steps[#steps + 1] = { title = _("Library and settings"), run = function() return no_address end }
    end
    if has_lookups then
        steps[#steps + 1] = { title = _("Kindle lookups"), run = function() return self:lookupsStep() end }
    end

    NetworkMgr:runWhenConnected(function()
        Trapper:wrap(function()
            local outcome = Sync.run(steps)
            if outcome.in_sync then
                UIManager:show(InfoMessage:new{ text = _("Everything is in sync."), timeout = 3 })
                return
            end
            if outcome.empty then return end
            if outcome.changed == 0 then
                UIManager:show(InfoMessage:new{ text = outcome.text })
            elseif not Device:canRestart() then
                UIManager:show(InfoMessage:new{
                    text = outcome.text .. "\n\n" .. _("Restart KOReader to use the new settings."),
                })
            else
                UIManager:show(ConfirmBox:new{
                    text = outcome.text .. "\n\n" .. _("Most settings take effect after KOReader restarts.\n\nRestart now?"),
                    ok_text = _("Restart"),
                    ok_callback = function() UIManager:broadcastEvent(Event:new("Restart")) end,
                })
            end
        end)
    end)
end

--- The gesture, if the reader bound one.
function AiDict:onAiDictSync()
    self:sync()
    return true
end

----------------------------------------------------------------------------
-- Look
----------------------------------------------------------------------------

--- The open book's look as default settings; nil in the file manager, or for a PDF.
function AiDict:openBookLook()
    local config, document = self.ui.config, self.ui.document
    if not (config and Look.is_global(config.options) and document and document.configurable) then return nil end
    return Look.defaults(config.options, document.configurable, self.ui.font and self.ui.font.font_face)
end

--[[--
A book opens with the global look: the defaults are written over its own
before KOReader reads them. KOReader sends this after the plugins are loaded
and before any module reads the book's settings.
--]]--
function AiDict:onDocSettingsLoad(doc_settings)
    local config = self.ui and self.ui.config
    if not (doc_settings and config and Look.is_global(config.options)) then return end
    local function default(key) return G_reader_settings:readSetting(key) end
    for _, entry in ipairs(Look.book_look(config.options, default)) do
        if entry.value == nil then
            doc_settings:delSetting(entry.key)
        else
            doc_settings:saveSetting(entry.key, entry.value)
        end
    end
end

--- The look the book opened with, so only what the reader changes goes global.
function AiDict:onReadSettings()
    local look = self:openBookLook()
    if not look then return end
    self.look_seen = {}
    Look.changed(self.look_seen, look)
end

--[[--
What the reader changed in the open book becomes the default for every book.

Only what changed since it opened: a default Sync applied meanwhile shows in
the book after a restart, and the book's older value must not undo it.
--]]--
function AiDict:keepLookGlobal()
    if not self.look_seen then return end
    local look = self:openBookLook()
    if not look then return end
    local changed = Look.changed(self.look_seen, look)
    for _, entry in ipairs(changed) do
        G_reader_settings:saveSetting(entry.key, entry.value)
    end
    if #changed > 0 then G_reader_settings:flush() end
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
    -- One entry, first in Tools. The actions open it, because they are
    -- what gets pressed; the settings follow.
    menu_items[MENU_ID] = {
        text = _("AI dictionary"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Sync"),
                help_text = _("Download new books and apply the library's moves, apply the KOReader settings set from the library and send this Kindle's back, and send the words looked up in the Kindle's own reader to the word inbox."),
                keep_menu_open = true,
                callback = function() self:sync() end,
            },
            {
                -- The version is on the label because this is the one entry
                -- that changes it: after an update and a restart, the menu
                -- itself is the receipt.
                text_func = function() return T(_("Update the plugin (%1)"), Version.string) end,
                keep_menu_open = true,
                separator = true,
                callback = function() self:checkForUpdates() end,
            },
            {
                text = _("Network check"),
                help_text = _("Time each step of reaching the AI endpoint, the library and the internet: DNS, connect, TLS and the request. Shows which one a slow lookup is waiting on."),
                keep_menu_open = true,
                separator = true,
                callback = function() self:networkCheck() end,
            },
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
                separator = true,
                callback = function()
                    self:editSetting("api_key", _("API key"), { password = true })
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
                -- Shown, never edited: the address comes with the package,
                -- from the AIDICT_LIBRARY_ENDPOINT secret, and a new one
                -- arrives the same way.
                text_func = function()
                    local address = Config.BAKED.library_endpoint
                    return T(_("Library: %1"), address ~= "" and address or _("not set"))
                end,
                keep_menu_open = true,
            },
            {
                text_func = function()
                    return T(_("Books folder: %1"), self.settings:get("library_dir"))
                end,
                keep_menu_open = true,
                callback = function() self:chooseLibraryFolder() end,
            },
        },
    }
end

return AiDict
