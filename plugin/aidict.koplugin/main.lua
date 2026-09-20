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
local util = require("util")
local T = require("ffi/util").template
local _ = require("gettext")

local Context = require("aidict.context")
local Format = require("aidict.format")
local Lookup = require("aidict.lookup")
local Settings = require("aidict.settings")
local Updater = require("aidict.updater")
local Version = require("aidict.version")
local http_transport = require("aidict.http_transport")
local json = require("aidict.json")

local CACHE_KEY = "cache_entries"

local showResult

local AiDict = WidgetContainer:extend{
    name = "aidict",
}

function AiDict:init()
    self.store = LuaSettings:open(DataStorage:getSettingsDir() .. "/aidict.lua")
    self.settings = Settings.new(self.store)
    self.lookup = Lookup.new({
        settings = self.settings,
        transport = http_transport,
        json = json,
    })
    self.lookup:restore_cache(self.store:readSetting(CACHE_KEY))

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

function AiDict:onCloseDocument()
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
        callback = function(dict_popup)
            local word = dict_popup.word
            local context = self:contextFromHighlight(dict_popup.highlight, word)
            dict_popup:onClose()
            self:explain(word, context)
        end,
    })
end

function AiDict:registerHighlightButton()
    -- 12_search is the last built-in entry; 13_ sorts after it.
    self.ui.highlight:addToHighlightDialog("13_aidict_explain", function(this)
        return {
            text = _("Explain with AI"),
            callback = function()
                this:highlightFromHoldPos()
                if not (this.selected_text and this.selected_text.text) then return end
                local word = util.cleanupSelectedText(this.selected_text.text)
                local context = self:contextFromHighlight(this, word)
                this:onClose(true)
                self:explain(word, context)
            end,
        }
    end)
end

----------------------------------------------------------------------------
-- Context
----------------------------------------------------------------------------

--- The sentence around a selection, when the document can produce one.
function AiDict:contextFromHighlight(highlight, word)
    local budget = self.settings:get("context_chars")
    if budget <= 0 then return "" end

    local selected = highlight and highlight.selected_text
    if not (selected and selected.pos0 and selected.pos1) then return "" end

    local sentence
    if self.ui and self.ui.rolling and self.document and self.document.extendXPointersToSentenceSegment then
        local ok, extended = pcall(function()
            return self.document:extendXPointersToSentenceSegment(selected.pos0, selected.pos1)
        end)
        if ok and extended then sentence = extended.text end
    end
    sentence = sentence or selected.text
    if not sentence then return "" end

    return Context.snippet(sentence, word, budget)
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

function AiDict:explain(word, context)
    word = Context.cleanup(word)
    if word == "" then
        UIManager:show(InfoMessage:new{ text = _("Nothing to look up.") })
        return
    end

    local props = self:bookProps()
    local request = {
        word = word,
        context = context or "",
        title = props.title,
        author = props.author,
        source_lang = props.source_lang,
    }

    local cached = self.lookup:peek(request)
    if cached then
        showResult(word, cached, true)
        return
    end

    if NetworkMgr:willRerunWhenOnline(function() self:explain(word, context) end) then
        return
    end

    -- Wrapped so the subprocess doing the request can be dismissed.
    Trapper:wrap(function()
        local completed, outcome = Trapper:dismissableRunInSubprocess(function()
            return self.lookup:fetch(request)
        end, T(_("Asking AI about “%1”…"), word))

        if not completed then
            return -- dismissed by the reader
        end
        if type(outcome) ~= "table" then
            logger.warn("aidict: unusable answer from subprocess", outcome)
            UIManager:show(InfoMessage:new{ text = _("Lookup failed.") })
            return
        end
        if not outcome.ok then
            UIManager:show(InfoMessage:new{ text = Format.error(outcome.err) })
            return
        end

        self.lookup:remember(request, outcome.result)
        self:saveCache()
        showResult(word, outcome.result, false)
    end)
end

--- Ask the repository whether a newer package is published. Installing it
--- is `kpm`'s job, so this only reports.
function AiDict:checkForUpdates()
    local repo_url = self.settings:get("repo_url")
    local channel = self.settings:get("channel")
    local updater = Updater.new({ transport = http_transport, json = json })

    if NetworkMgr:willRerunWhenOnline(function() self:checkForUpdates() end) then
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
        title = word,
        text = Format.result(result, { word = word, cached = from_cache }),
        -- "lookup" is what KOReader uses for dictionary results: same font
        -- size as book info, left-aligned rather than justified.
        text_type = "lookup",
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
                    return T(_("Answer language: %1"), self.settings:get("target_lang"))
                end,
                keep_menu_open = true,
                callback = function() self:editSetting("target_lang", _("Answer language")) end,
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
