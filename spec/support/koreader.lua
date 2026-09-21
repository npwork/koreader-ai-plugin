--[[--
Enough of KOReader to load `main.lua` and press its buttons.

These are stubs, not a simulator: each one mirrors the shape of the real
module (`Widget:extend`/`new`, `UIManager:show`, `Trapper:wrap`) and records
what the plugin did with it, so the specs can assert on widgets shown, buttons
registered and requests made — without an emulator.
--]]--

local helpers = require("support.helpers")

--[[--
The real `os.rename` and `os.remove`, captured once at load.

`install` swaps them for the fake filesystem and may run several times before
an `uninstall` — so capturing them per install would eventually save a fake as
the original and never give the suite its own back.
--]]--
local real_os = { rename = os.rename, remove = os.remove }

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

--[[--
Install the stubs and return the recorder.

@param opts table
  responses table  canned transport responses, see helpers.transport
  online    bool   false makes NetworkMgr defer the call (default true)
  settings  table  values pre-written into the settings store
--]]--
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
        actions = {},        -- what the plugin registered with Dispatcher
        warn_lines = {},
        forks = 0,
        polls = 0,
        fds_closed = 0,
        ready_after_polls = 0,
        never_ready = false,
        terminated = 0,
        fork_fails = false,
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
        -- Immediate by default, which is what every existing spec wants: the
        -- prefetch poll then runs to completion inside onWordLookedUp.
        --
        -- `defer_scheduled` queues instead, for the one thing that cannot be
        -- tested otherwise: a loop that waits for something to happen
        -- elsewhere would, run immediately, simply recurse until the stack
        -- gives out. `run_scheduled` then drains one round at a time.
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
            -- The real thing serialises the result out of a forked process,
            -- so anything that survives here must be plain data.
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
        -- The real one turns the radio on and then runs the callback; offline
        -- it would put up KOReader's own prompt, so the spec keeps it.
        runWhenConnected = function(_, callback)
            if not recorder.online then
                recorder.deferred = callback
                return
            end
            return callback()
        end,
    }

    --[[--
    KOReader's lfs, backed by `recorder.files` — a path-to-size table the
    library sync reads and the fake transport writes.
    --]]--
    package.loaded["libs/libkoreader-lfs"] = {
        attributes = function(path)
            local size = recorder.files[path]
            if size == nil then return nil end
            return { mode = "file", size = size }
        end,
        mkdir = function(path)
            recorder.dirs[path] = true
            return true
        end,
    }

    -- `os.rename` and `os.remove` are the right calls on the device, and the
    -- wrong ones here — they would reach the machine running the suite. They
    -- are swapped for the fake filesystem and put back by `uninstall`.
    os.rename = function(from, to)
        if recorder.files[from] == nil then return nil, "no such file" end
        recorder.files[to] = recorder.files[from]
        recorder.files[from] = nil
        return true
    end
    os.remove = function(path)
        if recorder.files[path] ~= nil then
            recorder.removed[#recorder.removed + 1] = path
            recorder.files[path] = nil
        end
        return true
    end

    package.loaded["luasettings"] = {
        open = function(_, _) return recorder.store end,
    }

    package.loaded["datastorage"] = {
        getSettingsDir = function() return "/tmp/aidict-spec" end,
    }

    package.loaded["device"] = { model = "SpecDevice" }

    --[[--
    The two menu order tables. KOReader caches them through `require`, which
    is what lets a plugin put itself somewhere other than the end; the stub
    keeps that shape so a spec can read back where the entry landed. Fresh
    tables per install, so one spec's insert cannot leak into the next.
    --]]--
    recorder.menu_order = {
        reader = { tools = { "read_timer", "calibre", "more_tools" } },
        filemanager = { tools = { "read_timer", "calibre", "more_tools" } },
    }
    package.loaded["ui/elements/reader_menu_order"] = recorder.menu_order.reader
    package.loaded["ui/elements/filemanager_menu_order"] = recorder.menu_order.filemanager

    -- The folder picker, which answers with whatever the spec told it to.
    package.loaded["ui/widget/pathchooser"] = {
        new = function(_, chooser)
            recorder.path_chooser = chooser
            return { widget_kind = "PathChooser", opts = chooser }
        end,
    }

    -- KOReader's Dispatcher, reduced to the registration the plugin does so
    -- a spec can see which actions a gesture could be bound to.
    package.loaded["dispatcher"] = {
        registerAction = function(_, name, definition)
            recorder.actions[name] = definition
        end,
    }

    package.loaded["ui/time"] = {
        now = function() return recorder.clock_ms end,
        to_ms = function(value) return value end,
    }

    -- The timing line the plugin logs is the only way to see, from a device
    -- in the field, where a slow lookup spent its time — so the specs read it.
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

    --[[--
    KOReader's ffi/util, reduced to the two things the plugin uses: string
    templating and the fork-and-pipe the prefetch runs on.

    The fake fork runs the task inline and keeps what it wrote, which preserves
    the only semantics the plugin depends on — the task runs somewhere else,
    writes once, and the parent reads it later. `forks` counts them so a spec
    can assert that nothing was started; `fork_fails` and `writes_nothing`
    drive the two ways it can come to nothing.
    --]]--
    package.loaded["ffi/util"] = {
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
        -- A real fork is not ready on the first look. `ready_after_polls`
        -- makes the parent wait, and `never_ready` makes it wait forever, so
        -- the polling and the give-up branch are both reachable.
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

    -- The plugin's own transport and codec, swapped for the test doubles.
    -- The wrapper moves the fake clock by `request_ms`, so a spec can say how
    -- long a request "took".
    package.loaded["aidict.http_transport"] = function(request)
        recorder.clock_ms = recorder.clock_ms + (recorder.request_ms or 0)
        local response, err = recorder.transport.fn(request)
        -- The real transport streams a download straight to disk; the queued
        -- response says how many bytes landed there.
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

--- Undo `install`, so the unit specs get a clean interpreter.
function koreader.uninstall()
    os.rename = real_os.rename
    os.remove = real_os.remove
    for _, module in ipairs({
        "ui/widget/container/widgetcontainer", "ui/widget/infomessage", "ui/widget/textviewer",
        "ui/widget/inputdialog", "ui/uimanager", "ui/trapper", "ui/network/manager",
        "luasettings", "datastorage", "device", "logger", "gettext", "ffi/util", "util", "ui/time",
        "libs/libkoreader-lfs", "dispatcher",
        "ui/elements/reader_menu_order", "ui/elements/filemanager_menu_order",
        "ui/widget/pathchooser",
        "aidict.http_transport", "aidict.json", "main",
    }) do
        package.loaded[module] = nil
    end
end

--[[--
A reader with a document open: the objects the plugin registers against.
--]]--
function koreader.reader(opts)
    opts = opts or {}
    local reader = {
        dict_buttons = {},
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
        dictionary = {
            addToDictButtons = function(_, spec) reader.dict_buttons[spec.id] = spec end,
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
        extendXPointersToSentenceSegment = function(_, _, _)
            return { text = opts.sentence }
        end,
        -- crengine returns the HTML of the block element around a position,
        -- which is the paragraph.
        getHTMLFromXPointer = function(_, _, _, _)
            return opts.paragraph_html
        end,
    }

    return reader
end

return koreader
