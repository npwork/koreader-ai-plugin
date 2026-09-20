--[[--
Enough of KOReader to load `main.lua` and press its buttons.

These are stubs, not a simulator: each one mirrors the shape of the real
module (`Widget:extend`/`new`, `UIManager:show`, `Trapper:wrap`) and records
what the plugin did with it, so the specs can assert on widgets shown, buttons
registered and requests made — without an emulator.
--]]--

local helpers = require("support.helpers")

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

    package.loaded["ui/uimanager"] = {
        show = function(_, widget)
            recorder.shown[#recorder.shown + 1] = widget
            return widget
        end,
        close = function(_, widget)
            widget.closed = true
        end,
        scheduleIn = function(_, _, callback) callback() end,
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
        willRerunWhenOnline = function(_, callback)
            if recorder.online then return false end
            recorder.deferred = callback
            return true
        end,
    }

    package.loaded["luasettings"] = {
        open = function(_, _) return recorder.store end,
    }

    package.loaded["datastorage"] = {
        getSettingsDir = function() return "/tmp/aidict-spec" end,
    }

    package.loaded["device"] = { model = "SpecDevice" }

    package.loaded["logger"] = {
        dbg = function() end,
        info = function() end,
        warn = function(...) recorder.last_warning = { ... } end,
        err = function() end,
    }

    package.loaded["gettext"] = setmetatable({}, {
        __call = function(_, text) return text end,
    })

    package.loaded["ffi/util"] = {
        template = function(text, ...)
            local args = { ... }
            return (text:gsub("%%(%d)", function(index)
                return tostring(args[tonumber(index)])
            end))
        end,
    }

    package.loaded["util"] = {
        cleanupSelectedText = function(text)
            text = text:gsub("^[\n%s]*", ""):gsub("[\n%s]*$", "")
            text = text:gsub("%s*\n%s*", "\n"):gsub("%s%s+", " ")
            return text
        end,
    }

    -- The plugin's own transport and codec, swapped for the test doubles.
    package.loaded["aidict.http_transport"] = recorder.transport.fn
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
    for _, module in ipairs({
        "ui/widget/container/widgetcontainer", "ui/widget/infomessage", "ui/widget/textviewer",
        "ui/widget/inputdialog", "ui/uimanager", "ui/trapper", "ui/network/manager",
        "luasettings", "datastorage", "device", "logger", "gettext", "ffi/util", "util",
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
    }

    return reader
end

return koreader
