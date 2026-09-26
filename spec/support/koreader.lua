local helpers = require("support.helpers")

-- Captured once at load: install may run several times before uninstall, and would otherwise
-- save a fake as the original.
local real_os = { rename = os.rename, remove = os.remove }
local real_io = { popen = io.popen }

local koreader = {}

--- KOReader's class system, copied from frontend/ui/widget/widget.lua.
local function widget_class()
    local Widget = {}
    function Widget:extend(subclass_prototype)
        local o = subclass_prototype or {}
        setmetatable(o, self)
        self.__index = self
        return o
    end
    function Widget:new(o)
        o = self:extend(o)
        if o._init then o:_init() end
        if o.init then o:init() end
        return o
    end
    return Widget
end

-- opts: responses (see helpers.transport), online (false defers NetworkMgr), settings (pre-written).
function koreader.install(opts)
    opts = opts or {}

    local recorder = {
        shown = {},          -- every widget handed to UIManager:show
        store = helpers.store(opts.settings),
        transport = helpers.transport(opts.responses or {}),
        deferred = nil,      -- the callback NetworkMgr kept for later
        online = opts.online ~= false,
        dismiss_next = false,
        clock_ms = 0,
        request_ms = 0,
        info_lines = {},
        files = {},          -- fake filesystem: path -> size
        dirs = {},           -- folders the sync created
        removed = {},        -- what the sync threw away
        rmdirs = {},         -- folders it removed
        book_calls = {},     -- renames, removes and KOReader's bookkeeping, in order
        stores = {},         -- every other LuaSettings file, by name
        actions = {},        -- what the plugin registered with Dispatcher
        warn_lines = {},
        forks = 0,
        polls = 0,
        fds_closed = 0,
        ready_after_polls = 0,
        never_ready = false,
        terminated = 0,
        fork_fails = false,
        can_restart = opts.can_restart ~= false,
        broadcast = {},      -- events the plugin sent everyone
        commands = {},       -- shell commands it ran
        shell = nil,         -- what the next command answers with
        writes_nothing = false,
    }

    local Widget = widget_class()

    local function recording_widget(kind)
        local W = Widget:extend{ widget_kind = kind }
        return W
    end

    package.loaded["ui/widget/container/widgetcontainer"] = Widget
    package.loaded["ui/widget/infomessage"] = recording_widget("InfoMessage")
    package.loaded["ui/widget/textviewer"] = recording_widget("TextViewer")
    package.loaded["ui/widget/confirmbox"] = recording_widget("ConfirmBox")
    package.loaded["ui/widget/dictquicklookup"] = {
        addQueryWordToResult = function(this)
            this.definition = (this.definition or "") .. "(query : " .. tostring(this.word) .. ")"
        end,
    }
    local InputDialog = recording_widget("InputDialog")
    function InputDialog:onShowKeyboard() self.keyboard_shown = true end
    function InputDialog:getInputText() return self.input end
    package.loaded["ui/widget/inputdialog"] = InputDialog

    recorder.scheduled = {}
    --- Run one round of what is waiting, as the scheduler would a tick later.
    function recorder.run_scheduled()
        local due = recorder.scheduled
        recorder.scheduled = {}
        for _, callback in ipairs(due) do callback() end
        return #due
    end

    package.loaded["ui/uimanager"] = {
        show = function(_, widget)
            recorder.shown[#recorder.shown + 1] = widget
            return widget
        end,
        close = function(_, widget)
            widget.closed = true
        end,
        forceRePaint = function() end,
        isWidgetShown = function(_, widget)
            return widget ~= nil and not widget.closed
        end,
        -- Immediate by default. `defer_scheduled` queues instead, for a loop that waits on something
        -- elsewhere and would otherwise recurse until the stack gives out.
        broadcastEvent = function(_, event)
            recorder.broadcast[#recorder.broadcast + 1] = event
        end,
        scheduleIn = function(_, _, callback)
            if recorder.defer_scheduled then
                recorder.scheduled[#recorder.scheduled + 1] = callback
            else
                callback()
            end
        end,
    }

    package.loaded["ui/trapper"] = {
        wrap = function(_, fn) return fn() end,
        dismissableRunInSubprocess = function(_, fn, message)
            recorder.last_progress_message = message
            if recorder.dismiss_next then
                recorder.dismiss_next = false
                return false, nil
            end
            -- The real one serialises the result out of a fork, so only plain data survives.
            return true, fn()
        end,
    }

    package.loaded["ui/network/manager"] = {
        isConnected = function() return recorder.online end,
        isOnline = function() return recorder.online end,
        willRerunWhenOnline = function(_, callback)
            if recorder.online then return false end
            recorder.deferred = callback
            return true
        end,
        -- Offline, the real one puts up KOReader's own prompt; the spec keeps the callback.
        runWhenConnected = function(_, callback)
            if not recorder.online then
                recorder.deferred = callback
                return
            end
            return callback()
        end,
    }

    -- `recorder.files` is path -> size, read by the library sync and written by the fake transport.
    local function holds_anything(path)
        local prefix = path .. "/"
        for held in pairs(recorder.files) do
            if held:sub(1, #prefix) == prefix then return true end
        end
        for held in pairs(recorder.dirs) do
            if held:sub(1, #prefix) == prefix then return true end
        end
        return false
    end

    package.loaded["libs/libkoreader-lfs"] = {
        -- A single field when asked by name, else the table. A folder is one `mkdir` made or one
        -- with a file under it.
        attributes = function(path, request)
            local all
            local size = recorder.files[path]
            if size ~= nil then
                all = { mode = "file", size = size }
            elseif recorder.dirs[path] or holds_anything(path) then
                all = { mode = "directory", size = 0 }
            else
                return nil
            end
            if request then return all[request] end
            return all
        end,
        mkdir = function(path)
            recorder.dirs[path] = true
            return true
        end,
        -- Refuses a folder with anything left in it, as the real one does.
        rmdir = function(path)
            if holds_anything(path) then return nil, "Directory not empty" end
            recorder.dirs[path] = nil
            recorder.rmdirs[#recorder.rmdirs + 1] = path
            return true
        end,
    }

    -- Each call records itself in `book_calls` beside the renames and removes, so a spec can
    -- assert the file moves first, then its bookkeeping.
    local function log_call(line)
        recorder.book_calls[#recorder.book_calls + 1] = line
    end
    package.loaded["docsettings"] = {
        updateLocation = function(from, to)
            if recorder.docsettings_error then error(recorder.docsettings_error) end
            log_call(to and ("DocSettings.updateLocation " .. from .. " -> " .. to)
                or ("DocSettings.updateLocation " .. from))
        end,
    }
    package.loaded["readhistory"] = {
        updateItem = function(_, from, to) log_call("ReadHistory:updateItem " .. from .. " -> " .. to) end,
        fileDeleted = function(_, path) log_call("ReadHistory:fileDeleted " .. path) end,
    }
    package.loaded["readcollection"] = {
        updateItem = function(_, from, to) log_call("ReadCollection:updateItem " .. from .. " -> " .. to) end,
        removeItem = function(_, path) log_call("ReadCollection:removeItem " .. path) end,
    }
    package.loaded["ui/widget/booklist"] = {
        resetBookInfoCache = function(path) log_call("BookList.resetBookInfoCache " .. path) end,
    }
    -- KOReader's global settings, where the defaults for new books live.
    recorder.global_settings = helpers.store()
    rawset(_G, "G_reader_settings", recorder.global_settings)

    -- No book open unless a spec opens one: `kor.reader_ui.instance = {…}`.
    recorder.reader_ui = { instance = nil }
    package.loaded["apps/reader/readerui"] = recorder.reader_ui

    -- Honours the bound value as the query's `timestamp >= ?` does, and records how the file was opened.
    recorder.vocab_rows = {}
    package.loaded["lua-ljsqlite3/init"] = {
        open = function(path, mode)
            recorder.vocab_opened = { path = path, mode = mode }
            if recorder.vocab_error then error(recorder.vocab_error) end
            return {
                prepare = function()
                    local since, index = 0, 0
                    return {
                        bind1 = function(self, _, value) since = value; return self end,
                        step = function()
                            while true do
                                index = index + 1
                                local row = recorder.vocab_rows[index]
                                if not row then return nil end
                                if row[4] >= since then return row end
                            end
                        end,
                        close = function() end,
                    }
                end,
                close = function() recorder.vocab_closed = true end,
            }
        end,
    }

    recorder.real_io_popen = io.popen
    io.popen = function(command, ...)
        recorder.commands[#recorder.commands + 1] = command
        local answer = recorder.shell
        if answer == nil then return recorder.real_io_popen(command, ...) end
        return {
            read = function() return answer.output or "" end,
            close = function() return answer.ok_status ~= false end,
        }
    end

    -- These would reach the machine running the suite: swapped for the fake filesystem until `uninstall`.
    os.rename = function(from, to)
        if recorder.files[from] == nil then return nil, "no such file" end
        log_call("rename " .. from .. " -> " .. to)
        recorder.files[to] = recorder.files[from]
        recorder.files[from] = nil
        return true
    end
    os.remove = function(path)
        if recorder.files[path] ~= nil then
            log_call("remove " .. path)
            recorder.removed[#recorder.removed + 1] = path
            recorder.files[path] = nil
        end
        return true
    end

    -- `aidict.lua` is the plugin's settings, `recorder.store`; any other file
    -- gets a store of its own, kept by name and seeded from `opts.stores`.
    package.loaded["luasettings"] = {
        open = function(_, path)
            local name = path:match("([^/]*)$")
            if name == "aidict.lua" then return recorder.store end
            if not recorder.stores[name] then
                recorder.stores[name] = helpers.store(opts.stores and opts.stores[name])
            end
            return recorder.stores[name]
        end,
    }

    package.loaded["datastorage"] = {
        getSettingsDir = function() return "/tmp/aidict-spec" end,
    }

    package.loaded["device"] = {
        model = "SpecDevice",
        canRestart = function() return recorder.can_restart end,
    }

    package.loaded["ui/event"] = {
        new = function(_, name) return { name = name } end,
    }

    -- Fresh per install, so one spec's insert cannot leak into the next.
    recorder.menu_order = {
        reader = { tools = { "read_timer", "calibre", "more_tools" } },
        filemanager = { tools = { "read_timer", "calibre", "more_tools" } },
    }
    package.loaded["ui/elements/reader_menu_order"] = recorder.menu_order.reader
    package.loaded["ui/elements/filemanager_menu_order"] = recorder.menu_order.filemanager

    package.loaded["ui/widget/pathchooser"] = {
        new = function(_, chooser)
            recorder.path_chooser = chooser
            return { widget_kind = "PathChooser", opts = chooser }
        end,
    }

    package.loaded["dispatcher"] = {
        registerAction = function(_, name, definition)
            recorder.actions[name] = definition
        end,
    }

    package.loaded["ui/time"] = {
        now = function() return recorder.clock_ms end,
        to_ms = function(value) return value end,
    }

    package.loaded["logger"] = {
        dbg = function() end,
        info = function(...)
            recorder.last_info = { ... }
            recorder.info_lines[#recorder.info_lines + 1] = table.concat({ ... }, " ")
        end,
        warn = function(...)
            recorder.last_warning = { ... }
            recorder.warn_lines[#recorder.warn_lines + 1] = table.concat({ ... }, " ")
        end,
        err = function() end,
    }

    package.loaded["gettext"] = setmetatable({}, {
        __call = function(_, text) return text end,
    })

    -- The fake fork runs the task inline and keeps what it wrote; `fork_fails` and `writes_nothing`
    -- drive the two ways it comes to nothing.
    package.loaded["ffi/util"] = {
        -- No symlinks in a table of files.
        realpath = function(path) return path end,
        template = function(text, ...)
            local args = { ... }
            return (text:gsub("%%(%d)", function(index)
                return tostring(args[tonumber(index)])
            end))
        end,

        runInSubProcess = function(task, with_pipe)
            recorder.forks = recorder.forks + 1
            if recorder.fork_fails then return false, "could not fork" end
            recorder.written = nil
            task(4242, "child-fd")
            if recorder.writes_nothing then recorder.written = nil end
            return 4242, with_pipe and "parent-fd" or nil
        end,
        writeToFD = function(_, data) recorder.written = data end,
        -- `ready_after_polls` and `never_ready` make the parent wait, so polling and giving up are reachable.
        getNonBlockingReadSize = function()
            recorder.polls = recorder.polls + 1
            if recorder.never_ready then return 0 end
            if recorder.polls <= (recorder.ready_after_polls or 0) then return 0 end
            return recorder.written and #recorder.written or 0
        end,
        isSubProcessDone = function()
            return not (recorder.never_ready or
                        recorder.polls <= (recorder.ready_after_polls or 0))
        end,
        readAllFromFD = function()
            local data = recorder.written
            recorder.written = nil
            recorder.fds_closed = recorder.fds_closed + 1
            return data or ""
        end,
        terminateSubProcess = function() recorder.terminated = recorder.terminated + 1 end,
    }

    package.loaded["util"] = {
        cleanupSelectedText = function(text)
            text = text:gsub("^[\n%s]*", ""):gsub("[\n%s]*$", "")
            text = text:gsub("%s*\n%s*", "\n"):gsub("%s%s+", " ")
            return text
        end,
        -- Enough of KOReader's converter for the paragraph HTML crengine hands back.
        htmlToPlainText = function(text)
            text = text:gsub("%s*<%s*br%s*/?>%s*", "\n")
            text = text:gsub("%s*</%s*p%s*>%s*", "\n")
            text = text:gsub("%s*<%s*p%s*>%s*", "\n")
            text = text:gsub("<[^>]*>", "")
            text = text:gsub("&amp;", "&"):gsub("&lt;", "<"):gsub("&gt;", ">")
            return (text:gsub("^[\n%s]*", ""):gsub("[\n%s]*$", ""))
        end,
    }

    -- The wrapper moves the fake clock by `request_ms`, so a spec can say how long a request took.
    package.loaded["aidict.http_transport"] = function(request)
        recorder.clock_ms = recorder.clock_ms + (recorder.request_ms or 0)
        local response, err = recorder.transport.fn(request)
        -- The queued response says how many bytes landed on disk.
        if request.download_to and response and response.bytes then
            recorder.files[request.download_to] = response.bytes
        end
        return response, err
    end
    package.loaded["aidict.json"] = helpers.json

    for _, module in ipairs({
        "main", "aidict.apiclient", "aidict.cache", "aidict.config", "aidict.context",
        "aidict.format", "aidict.lookup", "aidict.settings", "aidict.updater", "aidict.version",
    }) do
        if module == "main" then package.loaded[module] = nil end
    end

    recorder.plugin_class = require("main")
    return recorder
end

-- So the unit specs get a clean interpreter.
function koreader.uninstall()
    os.rename = real_os.rename
    os.remove = real_os.remove
    io.popen = real_io.popen
    rawset(_G, "G_reader_settings", nil)
    for _, module in ipairs({
        "ui/widget/container/widgetcontainer", "ui/widget/infomessage", "ui/widget/textviewer",
        "ui/widget/inputdialog", "ui/widget/confirmbox", "ui/uimanager", "ui/trapper",
        "ui/network/manager", "ui/event",
        "luasettings", "datastorage", "device", "logger", "gettext", "ffi/util", "util", "ui/time",
        "libs/libkoreader-lfs", "lua-ljsqlite3/init", "dispatcher",
        "docsettings", "readhistory", "readcollection", "ui/widget/booklist",
        "apps/reader/readerui",
        "ui/elements/reader_menu_order", "ui/elements/filemanager_menu_order",
        "ui/widget/pathchooser",
        "aidict.http_transport", "aidict.json", "main",
    }) do
        package.loaded[module] = nil
    end
end

function koreader.reader(opts)
    opts = opts or {}
    local reader = {
        highlight_buttons = {},
        menu_items = nil,
    }

    reader.ui = {
        rolling = opts.rolling ~= false,
        doc_props = opts.doc_props or {
            display_title = "Aesop's Fables",
            authors = "Aesop",
            language = "en",
        },
        menu = {
            registerToMainMenu = function(_, plugin) reader.registered_plugin = plugin end,
        },
        -- The popup keeps the results table it was given, opens on the first, and redraws on
        -- changeDictionary: the three things the plugin relies on.
        dictionary = {
            showDict = function(this, word, results)
                this.dict_window = {
                    widget_kind = "DictQuickLookup",
                    word = word,
                    results = results,
                    dict_index = 1,
                    redraws = 0,
                    changeDictionary = function(popup, index)
                        popup.dict_index = index
                        popup.redraws = popup.redraws + 1
                    end,
                }
            end,
        },
        highlight = {
            selected_text = opts.selected_text,
            addToHighlightDialog = function(_, id, builder)
                reader.highlight_buttons[id] = builder
            end,
            highlightFromHoldPos = function() end,
            onClose = function(this) this.closed = true end,
        },
    }

    reader.document = {
        getHTMLFromXPointer = function(_, _, _, _)
            return opts.paragraph_html
        end,
    }

    return reader
end

return koreader
