local RemoteSettings = require("aidict.remote_settings")
local Version = require("aidict.version")
local helpers = require("support.helpers")

local json = helpers.json

local function remote(responses, opts)
    opts = opts or {}
    local tr = helpers.transport(responses)
    return RemoteSettings.new({
        endpoint = opts.endpoint or helpers.LIBRARY_ENDPOINT,
        api_key = opts.api_key or "owner-key",
        transport = tr.fn,
        json = json,
    }), tr
end

local function planned(apply)
    return { status = 200, body = helpers.body({ apply = apply }) }
end

local REPORTED = { status = 200, body = helpers.body({ applied = 0, pending = 0 }) }

describe("settings from the library", function()
    describe("applying the queue", function()
        it("sets values and removes reset keys, keeping what each replaced", function()
            local store = helpers.store({ show_bottom_menu = true, cre_font = "Noto Serif" })
            local applied = RemoteSettings.apply(store, {
                { key = "show_bottom_menu", value = false },
                { key = "copt_h_page_margins", value = { 20, 20 } },
                { key = "cre_font", reset = true },
            })

            assert.are.same({ show_bottom_menu = false, copt_h_page_margins = { 20, 20 } }, store.data)
            assert.are.same({
                { key = "show_bottom_menu", value = false, previous = true },
                { key = "copt_h_page_margins", value = { 20, 20 } },
                { key = "cre_font", reset = true, previous = "Noto Serif" },
            }, applied)
        end)

        it("skips a change it cannot trust: a bad key, no value, a value that is not plain data", function()
            local store = helpers.store()
            local applied = RemoteSettings.apply(store, {
                { key = "../etc", value = 1 },
                { key = "copt_font_size" },
                { key = "copt_font_size", value = function() end },
                "not a change",
            })
            assert.are.same({}, applied)
            assert.are.same({}, store.data)
        end)

        it("stores its own copy, so the decoder's table cannot change under the store", function()
            local store = helpers.store()
            local margins = { 20, 20 }
            RemoteSettings.apply(store, { { key = "copt_h_page_margins", value = margins } })
            margins[1] = 40
            assert.are.same({ 20, 20 }, store.data.copt_h_page_margins)
        end)
    end)

    describe("the snapshot sent back", function()
        it("carries every plain setting and drops what JSON cannot carry", function()
            local cycle = {}
            cycle.self = cycle
            local values = RemoteSettings.snapshot({
                copt_font_size = 22,
                show_bottom_menu = false,
                cre_font = "Literata",
                copt_h_page_margins = { 20, 20 },
                callback = function() end,
                nan = 0 / 0,
                cycle = cycle,
            }, json)
            assert.are.same({
                copt_font_size = 22,
                show_bottom_menu = false,
                cre_font = "Literata",
                copt_h_page_margins = { 20, 20 },
            }, values)
        end)

        it("keeps other plugins' secrets on the device, at any depth", function()
            local values = RemoteSettings.snapshot({
                kosync = { username = "nick", userkey = "md5", sync_forward = 1 },
                exporter = { readwise = { token = "rw", enabled = true }, joplin = { ip = "1.2.3.4", token = "j" } },
                calibre_wireless_password = "pw",
                opds_servers = { { title = "Shelf", url = "https://x", username = "n", password = "p" } },
                copt_font_size = 22,
            }, json)
            assert.are.same({
                kosync = { username = "nick", sync_forward = 1 },
                exporter = { readwise = { enabled = true }, joplin = { ip = "1.2.3.4" } },
                opds_servers = { { title = "Shelf", url = "https://x", username = "n" } },
                copt_font_size = 22,
            }, values)
        end)
    end)

    describe("a sync", function()
        it("sends every setting with the device's key, applies the plan, flushes, and reports", function()
            local store = helpers.store({ show_bottom_menu = true, copt_font_size = 22 })
            local r, tr = remote({ planned({ { key = "show_bottom_menu", value = false } }), REPORTED })

            local result = r:sync(store, { outbox = helpers.store() })

            assert.are.equal(helpers.LIBRARY_ENDPOINT .. "/settings/plan", tr.requests[1].url)
            assert.are.equal("POST", tr.requests[1].method)
            assert.are.equal("Bearer owner-key", tr.requests[1].headers["Authorization"])
            assert.are.same({ values = { show_bottom_menu = true, copt_font_size = 22 } },
                json.decode(tr.requests[1].body))
            assert.are.equal(1, store.flushed)

            assert.are.equal("POST", tr.requests[2].method)
            assert.are.same({
                applied = { { key = "show_bottom_menu", value = false, previous = true } },
                values = { show_bottom_menu = false, copt_font_size = 22 },
                plugin_version = Version.string,
            }, json.decode(tr.requests[2].body))

            assert.is_true(result.reported)
            assert.are.equal(1, #result.applied)
        end)

        it("still reports every setting when there is nothing to apply, and leaves the store unflushed", function()
            local store = helpers.store({ copt_font_size = 22 })
            local r, tr = remote({ planned({}), REPORTED })

            local result = r:sync(store, { outbox = helpers.store() })

            assert.are.equal(0, #result.applied)
            assert.are.equal(0, store.flushed)
            local report = json.decode(tr.requests[2].body)
            assert.is_nil(report.applied)
            assert.are.same({ copt_font_size = 22 }, report.values)
        end)

        it("keeps a ?token= in the address at the end", function()
            local r, tr = remote({ planned({}), REPORTED }, { endpoint = "https://gw.test/koreader-library/?token=t" })
            r:sync(helpers.store(), { outbox = helpers.store() })
            assert.are.equal("https://gw.test/koreader-library/settings/plan?token=t", tr.requests[1].url)
            assert.are.equal("https://gw.test/koreader-library/settings?token=t", tr.requests[2].url)
        end)

        it("changes nothing when there is no plan", function()
            local store = helpers.store({ copt_font_size = 22 })
            local r, tr = remote({ { status = 401, body = "{}" } })

            local result, err = r:sync(store, { outbox = helpers.store() })

            assert.is_nil(result)
            assert.are.equal("unauthorized", err.code)
            assert.are.equal(1, tr.calls)
            assert.are.same({ copt_font_size = 22 }, store.data)
        end)

        it("says so when the report back fails, the changes staying made", function()
            local store = helpers.store()
            local r = remote({ planned({ { key = "copt_font_size", value = 24 } }), { err = "timeout" } })

            local result = r:sync(store, { outbox = helpers.store() })

            assert.are.equal(24, store.data.copt_font_size)
            assert.is_false(result.reported)
            assert.are.equal("timeout", result.report_error.code)
        end)

        it("keeps unreported changes, and reports each with the value it first replaced", function()
            local store = helpers.store({ copt_font_size = 22 })
            local outbox = helpers.store()
            local change = planned({ { key = "copt_font_size", value = 24 } })

            local first = remote({ change, { err = "timeout" } }):sync(store, { outbox = outbox })
            assert.is_false(first.reported)
            assert.are.same({ { key = "copt_font_size", value = 24, previous = 22 } },
                outbox.data[RemoteSettings.OUTBOX_KEY])

            -- The library never heard, so it hands out the same change again.
            local r, tr = remote({ change, REPORTED })
            local second = r:sync(store, { outbox = outbox })

            assert.is_true(second.reported)
            assert.are.same({ { key = "copt_font_size", value = 24, previous = 22 } },
                json.decode(tr.requests[2].body).applied)
            assert.is_nil(outbox.data[RemoteSettings.OUTBOX_KEY])
        end)

        it("reports an unreported change the library no longer hands out", function()
            local outbox = helpers.store({
                [RemoteSettings.OUTBOX_KEY] = { { key = "show_bottom_menu", value = false, previous = true } },
            })
            local r, tr = remote({ planned({ { key = "copt_font_size", value = 24 } }), REPORTED })

            r:sync(helpers.store(), { outbox = outbox })

            assert.are.same({
                { key = "show_bottom_menu", value = false, previous = true },
                { key = "copt_font_size", value = 24 },
            }, json.decode(tr.requests[2].body).applied)
        end)

        it("sends both requests through the offload, and a cancelled fetch changes nothing", function()
            local store = helpers.store({ copt_font_size = 22 })
            local r, tr = remote({ planned({ { key = "copt_font_size", value = 24 } }), REPORTED })
            local tasks = 0
            local result = r:sync(store, { outbox = helpers.store(), offload = function(task)
                tasks = tasks + 1
                local raw = task()
                assert.are.equal("string", type(raw))
                return raw
            end })
            assert.are.equal(2, tasks)
            assert.is_true(result.reported)
            assert.are.equal(24, store.data.copt_font_size)

            local cancelled, err = r:sync(store, { outbox = helpers.store(), offload = function() return nil end })
            assert.is_nil(cancelled)
            assert.are.equal("cancelled", err.code)
            assert.are.equal(2, tr.calls)
        end)

        it("sends when this Kindle changed each of its own settings, and forgets once reported", function()
            local store = helpers.store({ copt_font_size = 22, show_bottom_menu = true })
            local outbox = helpers.store()
            RemoteSettings.notice(store.data, outbox, json, 100)
            store.data.copt_font_size = 26
            store.data.show_bottom_menu = nil

            local r, tr = remote({ planned({}), REPORTED })
            r:sync(store, { outbox = outbox, now = function() return 200 end })

            assert.are.same({ copt_font_size = 200, show_bottom_menu = 200 },
                json.decode(tr.requests[1].body).changed_at)
            assert.are.same({}, outbox.data[RemoteSettings.CHANGED_KEY])

            -- Nothing changed since: nothing to send.
            local again, tr2 = remote({ planned({}), REPORTED })
            again:sync(store, { outbox = outbox, now = function() return 300 end })
            assert.is_nil(json.decode(tr2.requests[1].body).changed_at)
        end)

        it("keeps the times while the report has not arrived", function()
            local store = helpers.store({ copt_font_size = 22 })
            local outbox = helpers.store()
            RemoteSettings.notice(store.data, outbox, json, 100)
            store.data.copt_font_size = 26

            remote({ planned({}), { err = "timeout" } }):sync(store, { outbox = outbox, now = function() return 200 end })
            local r, tr = remote({ planned({}), REPORTED })
            r:sync(store, { outbox = outbox, now = function() return 300 end })

            assert.are.same({ copt_font_size = 200 }, json.decode(tr.requests[1].body).changed_at)
        end)

        it("does not count what the library applied as this Kindle's own change", function()
            local store = helpers.store({ copt_font_size = 22, cre_font = "Literata" })
            local outbox = helpers.store()
            RemoteSettings.notice(store.data, outbox, json, 100)

            remote({
                planned({ { key = "copt_font_size", value = 24 }, { key = "cre_font", reset = true } }),
                { err = "timeout" },
            }):sync(store, { outbox = outbox, now = function() return 200 end })

            assert.are.same({}, RemoteSettings.notice(store.data, outbox, json, 300))
        end)

        it("keeps a change seen while the report was on its way", function()
            local store = helpers.store({ copt_font_size = 22, cre_font = "Literata" })
            local outbox = helpers.store()
            RemoteSettings.notice(store.data, outbox, json, 100)
            store.data.copt_font_size = 26

            local r = remote({})
            local calls = 0
            r:sync(store, { outbox = outbox, now = function() return 200 end, offload = function()
                calls = calls + 1
                if calls == 2 then
                    -- KOReader saves its settings while the report is sent.
                    store.data.cre_font = "Bookerly"
                    RemoteSettings.notice(store.data, outbox, json, 250)
                    return json.encode({ ok = true })
                end
                return json.encode({ plan = { apply = {} } })
            end })

            assert.are.same({ cre_font = 250 }, outbox.data[RemoteSettings.CHANGED_KEY])
        end)

        it("does not take a secret the library applied for this Kindle's own change", function()
            local store = helpers.store({ kosync = { username = "nick" } })
            local outbox = helpers.store()
            RemoteSettings.notice(store.data, outbox, json, 100)

            remote({
                planned({
                    { key = "kosync", value = { username = "nick", userkey = "md5" } },
                    { key = "calibre_wireless_password", value = "pw" },
                }),
                { err = "timeout" },
            }):sync(store, { outbox = outbox, now = function() return 200 end })

            assert.are.same({}, RemoteSettings.notice(store.data, outbox, json, 300))
        end)
    end)

    describe("noticing this Kindle's own changes", function()
        it("only records the first time, then stamps what changed or went", function()
            local data = { copt_font_size = 22, cre_font = "Literata", copt_h_page_margins = { 20, 20 } }
            local outbox = helpers.store()

            assert.are.same({}, RemoteSettings.notice(data, outbox, json, 100))
            data.copt_font_size = 24
            data.cre_font = nil
            data.show_bottom_menu = false
            assert.are.same({ copt_font_size = 200, cre_font = 200, show_bottom_menu = 200 },
                RemoteSettings.notice(data, outbox, json, 200))
        end)

        it("keeps the first time a change was seen, and saves only when something moved", function()
            local data = { copt_font_size = 22 }
            local outbox = helpers.store()
            RemoteSettings.notice(data, outbox, json, 100)
            data.copt_font_size = 24
            RemoteSettings.notice(data, outbox, json, 200)
            local flushed = outbox.flushed

            assert.are.same({ copt_font_size = 200 }, RemoteSettings.notice(data, outbox, json, 300))
            assert.are.equal(flushed, outbox.flushed)
        end)

        it("tells apart values whose parts would read the same run together", function()
            local outbox = helpers.store()
            RemoteSettings.notice({ t = { a = "x", b = "y" } }, outbox, json, 100)
            assert.are.same({ t = 200 },
                RemoteSettings.notice({ t = { a = "x,string:b=string:y" } }, outbox, json, 200))
        end)

        it("does not take a table built in another order for a change", function()
            local outbox = helpers.store()
            RemoteSettings.notice({ kosync = { a = 1, b = 2, c = 3 } }, outbox, json, 100)
            local rebuilt = {}
            rebuilt.c, rebuilt.a, rebuilt.b = 3, 1, 2
            assert.are.same({}, RemoteSettings.notice({ kosync = rebuilt }, outbox, json, 200))
        end)
    end)

    describe("without an address", function()
        it("refuses to start", function()
            local r = remote({}, { endpoint = "" })
            local result, err = r:sync(helpers.store(), { outbox = helpers.store() })
            assert.is_nil(result)
            assert.are.equal("not_configured", err.code)
        end)
    end)
end)
