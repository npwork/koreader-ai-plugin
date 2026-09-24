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

local function queued(pending)
    return { status = 200, body = helpers.body({ pending = pending }) }
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
        it("fetches the queue with the device's key, applies it, flushes, and reports", function()
            local store = helpers.store({ show_bottom_menu = true, copt_font_size = 22 })
            local r, tr = remote({ queued({ { key = "show_bottom_menu", value = false } }), REPORTED })

            local result = r:sync(store, { outbox = helpers.store() })

            assert.are.equal(helpers.LIBRARY_ENDPOINT .. "/settings", tr.requests[1].url)
            assert.are.equal("GET", tr.requests[1].method)
            assert.are.equal("Bearer owner-key", tr.requests[1].headers["Authorization"])
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

        it("still reports every setting when nothing was queued, and leaves the store unflushed", function()
            local store = helpers.store({ copt_font_size = 22 })
            local r, tr = remote({ queued({}), REPORTED })

            local result = r:sync(store, { outbox = helpers.store() })

            assert.are.equal(0, #result.applied)
            assert.are.equal(0, store.flushed)
            local report = json.decode(tr.requests[2].body)
            assert.is_nil(report.applied)
            assert.are.same({ copt_font_size = 22 }, report.values)
        end)

        it("keeps a ?token= in the address at the end", function()
            local r, tr = remote({ queued({}), REPORTED }, { endpoint = "https://gw.test/koreader-library/?token=t" })
            r:sync(helpers.store(), { outbox = helpers.store() })
            assert.are.equal("https://gw.test/koreader-library/settings?token=t", tr.requests[1].url)
        end)

        it("changes nothing when the queue cannot be fetched", function()
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
            local r = remote({ queued({ { key = "copt_font_size", value = 24 } }), { err = "timeout" } })

            local result = r:sync(store, { outbox = helpers.store() })

            assert.are.equal(24, store.data.copt_font_size)
            assert.is_false(result.reported)
            assert.are.equal("timeout", result.report_error.code)
        end)

        it("keeps unreported changes, and reports each with the value it first replaced", function()
            local store = helpers.store({ copt_font_size = 22 })
            local outbox = helpers.store()
            local change = queued({ { key = "copt_font_size", value = 24 } })

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
            local r, tr = remote({ queued({ { key = "copt_font_size", value = 24 } }), REPORTED })

            r:sync(helpers.store(), { outbox = outbox })

            assert.are.same({
                { key = "show_bottom_menu", value = false, previous = true },
                { key = "copt_font_size", value = 24 },
            }, json.decode(tr.requests[2].body).applied)
        end)

        it("sends both requests through the offload, and a cancelled fetch changes nothing", function()
            local store = helpers.store({ copt_font_size = 22 })
            local r, tr = remote({ queued({ { key = "copt_font_size", value = 24 } }), REPORTED })
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

        it("refuses to start without an address", function()
            local r = remote({}, { endpoint = "" })
            local result, err = r:sync(helpers.store(), { outbox = helpers.store() })
            assert.is_nil(result)
            assert.are.equal("not_configured", err.code)
        end)
    end)
end)
