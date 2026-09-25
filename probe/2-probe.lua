-- Probe: what the look is at open, then act like Sync mid-book, then restart.
local UIManager = require("ui/uimanager")
local Event = require("ui/event")
local phase = os.getenv("PROBE_PHASE") or "?"
local function dump(v) if type(v) ~= "table" then return tostring(v) end local t = {} for k, x in pairs(v) do t[#t+1] = tostring(k) .. "=" .. dump(x) end table.sort(t) return "{" .. table.concat(t, ",") .. "}" end
local function report(tag)
    local ReaderUI = require("apps/reader/readerui")
    local ui = ReaderUI.instance
    local conf = ui and ui.document and ui.document.configurable
    print(string.format("PROBE %s %s: G.h=%s G.tweaks=%s book.h=%s sidecar.h=%s block=%s", phase, tag,
        dump(G_reader_settings:readSetting("copt_h_page_margins")),
        dump(G_reader_settings:readSetting("style_tweaks")),
        conf and dump(conf.h_page_margins) or "-",
        ui and ui.doc_settings and dump(ui.doc_settings:readSetting("copt_h_page_margins")) or "-",
        conf and dump(conf.block_rendering_mode) or "-"))
end
UIManager:scheduleIn(8, function() report("opened") end)
if phase == "sync" then
    UIManager:scheduleIn(10, function()
        G_reader_settings:saveSetting("copt_h_page_margins", { 30, 30 })
        local tweaks = G_reader_settings:readSetting("style_tweaks") or {}
        local new = {} for k, v in pairs(tweaks) do new[k] = v end
        new.margin_body_0 = true
        G_reader_settings:saveSetting("style_tweaks", new)
        G_reader_settings:flush()
        local ui = require("apps/reader/readerui").instance
        print("PROBE adopt", tostring(ui.aidict and ui.aidict.adoptStyleTweaks))
        if ui.aidict then ui.aidict:adoptStyleTweaks({ { key = "style_tweaks" } }) end
        report("synced")
    end)
    UIManager:scheduleIn(14, function() print("PROBE restarting") UIManager:broadcastEvent(Event:new("Restart")) end)
elseif phase == "close" then
    UIManager:scheduleIn(12, function() print("PROBE closing") UIManager:broadcastEvent(Event:new("Close")) end)
end
