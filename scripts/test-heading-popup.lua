-- Run from a real KOReader directory with its ./luajit, using SDL's dummy driver.
require("setupkoenv")
G_defaults = require("luadefaults"):open()
G_reader_settings = require("luasettings"):open(os.tmpname())
local Device = require("device")
require("document/canvascontext"):init(Device)
local UIManager = require("ui/uimanager")
local Geom = require("ui/geometry")
local Event = require("ui/event")
local DictQuickLookup = require("ui/widget/dictquicklookup")
local plugin_dir = assert(os.getenv("AIDICT_PLUGIN_DIR"), "AIDICT_PLUGIN_DIR is required")
package.path = plugin_dir .. "/?.lua;" .. package.path
local AiDict = dofile(plugin_dir .. "/main.lua")
local entry = AiDict:dictionaryEntry("swagger", { kind = "answer", result = {
    word = "swagger", lemma = "swagger", pronunciation = "/ˈswæɡ.ə/", part_of_speech = "verb",
    definition = "To behave (especially to walk or carry oneself) in a pompous, superior manner.",
    translation = "важничать",
    examples = { "The new manager swaggered into the office.", "She did not swagger.", "He swaggered past his rivals." },
    etymology = "From swag, frequentative of sway.", model = "saved lookup",
} })
local ui = { handleEvent = function() end }
ui.dictionary = {
    default_layout = { { "prev_dict", "next_dict", "close" } },
    showDict = function(this, word, results)
        this.dict_window = DictQuickLookup:new{ word = word, results = results, ui = ui }
        UIManager:show(this.dict_window)
    end,
}
-- A supplied answer avoids network and credentials; the real main.lua installs
-- the popup hooks and the real KOReader widgets do the layout, paint and taps.
local plugin = setmetatable({ ui = ui,
    openPage = function(_, _, results)
        table.insert(results, 1, entry)
        return nil, results
    end,
}, { __index = AiDict })
plugin:joinDictionaryPopup()
ui.dictionary:showDict("swagger", { { dict = "Oxford", word = "swagger", definition = "An ordinary entry." } })
local popup = ui.dictionary.dict_window
assert(popup.aidict_header_hook, "main.lua did not install the word toggle")
local heading = popup.lookup_word_text
local paint = heading.paintTo
local area
heading.paintTo = function(this, bb, x, y, ...)
    area = { x = x, y = y, w = this:getSize().w, h = this:getSize().h }
    return paint(this, bb, x, y, ...)
end
UIManager:forceRePaint()
assert(area, "The real heading was not painted")
assert(heading.text == "swagger")
local body = popup.text_widget
local screenshots = os.getenv("AIDICT_SCREENSHOT_DIR") or "/tmp"
Device.screen.bb:writePNG(screenshots .. "/kindle-word-english.png")
local function tap_word()
    return popup:handleEvent(Event:new("Gesture", {
        ges = "tap", pos = Geom:new{ x = area.x + 2, y = area.y + 2 },
    }))
end
assert(tap_word())
assert(heading.text == "важничать")
assert(popup.lookupword == "swagger" and entry.word == "swagger")
assert(popup.text_widget == body, "Definition was rebuilt")
UIManager:forceRePaint()
Device.screen.bb:writePNG(screenshots .. "/kindle-word-russian.png")
assert(tap_word())
assert(heading.text == "swagger")
popup:changeDictionary(2)
assert(heading.text == "swagger")
popup:changeDictionary(1)
assert(heading.text == "swagger")
print("PASS: real popup switches swagger to Russian and back; lookup and definition widget unchanged")
UIManager:close(popup)

entry = AiDict:dictionaryEntry("passé", { kind = "answer", result = {
    word = "passé", lemma = "passé", pronunciation = "/ˈpæseɪ/", part_of_speech = "adjective",
    definition = "No longer fashionable; out of date.",
    examples = {
        "The fashion for neon colours is completely passé.",
        "“PASSÉ”—that style looked passe\204\129; naïve enthusiasm kept it alive.",
        "Her once-popular catchphrase now sounded rather passé.",
    },
} })
assert(entry.definition:find("completely <b>passé</b>.", 1, true))
assert(entry.definition:find("“<b>PASSÉ</b>”—that style looked <b>passe\204\129</b>", 1, true))
local malformed = "\128\192\193\245\255 é\128\128\128 "
local damaged = AiDict:dictionaryEntry("passé", { kind = "answer", result = {
    word = "passé", examples = { malformed .. "passé" },
} })
assert(damaged.definition:find(malformed .. "<b>passé</b>", 1, true))
local invalid_word = "passé\128"
local ignored = AiDict:dictionaryEntry(invalid_word, { kind = "answer", result = {
    word = invalid_word, examples = { "passé" },
} })
assert(not ignored.definition:find("<b>", 1, true))
ui.dictionary:showDict("passé", {})
UIManager:forceRePaint()
Device.screen.bb:writePNG(screenshots .. "/kindle-word-example-bold.png")
UIManager:close(ui.dictionary.dict_window)
print("PASS: accented example words are bold with Unicode case folding and combining marks")
