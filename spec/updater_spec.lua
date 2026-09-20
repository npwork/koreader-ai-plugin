local Updater = require("aidict.updater")
local helpers = require("support.helpers")

local function manifest(version, extra)
    local packages = {
        ["koreader-aidict"] = {
            version = version,
            version_string = table.concat(version, "."),
            url = "https://repo.example/kpm/stable/packages/koreader-aidict/artifacts/x.kpkg",
            sha256 = "deadbeef",
        },
    }
    local body = { channel = "stable", packages = packages }
    for k, v in pairs(extra or {}) do body[k] = v end
    return helpers.body(body)
end

local function updater(transport, current)
    return Updater.new({
        transport = transport.fn,
        json = helpers.json,
        current = current or { 0, 1, 0 },
    })
end

describe("updater", function()
    describe("version parsing", function()
        it("reads a three-part version", function()
            assert.are.same({ 1, 2, 3 }, Updater.parse("1.2.3"))
        end)

        it("rejects anything else", function()
            assert.is_nil(Updater.parse("1.2"))
            assert.is_nil(Updater.parse("v1.2.3"))
            assert.is_nil(Updater.parse(nil))
        end)
    end)

    describe("version comparison", function()
        it("orders by major, then minor, then patch", function()
            assert.are.equal(-1, Updater.compare({ 0, 1, 0 }, { 1, 0, 0 }))
            assert.are.equal(-1, Updater.compare({ 1, 1, 0 }, { 1, 2, 0 }))
            assert.are.equal(-1, Updater.compare({ 1, 1, 1 }, { 1, 1, 2 }))
            assert.are.equal(1, Updater.compare({ 2, 0, 0 }, { 1, 9, 9 }))
            assert.are.equal(0, Updater.compare({ 1, 2, 3 }, { 1, 2, 3 }))
        end)

        it("does not compare 10 as if it were 1", function()
            assert.are.equal(1, Updater.compare({ 0, 10, 0 }, { 0, 9, 0 }))
        end)
    end)

    describe("url", function()
        it("points at the channel's version manifest", function()
            assert.are.equal("https://repo.example/kpm/dev/version.json",
                Updater.url_for("https://repo.example/kpm/", "dev"))
        end)
    end)

    describe("check", function()
        it("reports an update when the channel is ahead", function()
            local tr = helpers.transport({ { status = 200, body = manifest({ 0, 2, 0 }) } })
            local info, err = updater(tr, { 0, 1, 0 }):check("https://repo.example/kpm", "stable")

            assert.is_nil(err)
            assert.is_true(info.available)
            assert.are.equal("0.1.0", info.current)
            assert.are.equal("0.2.0", info.latest)
            assert.are.equal("deadbeef", info.sha256)
        end)

        it("reports nothing to do when versions match", function()
            local tr = helpers.transport({ { status = 200, body = manifest({ 0, 1, 0 }) } })
            local info = updater(tr, { 0, 1, 0 }):check("https://repo.example/kpm", "stable")
            assert.is_false(info.available)
        end)

        it("does not offer a downgrade", function()
            local tr = helpers.transport({ { status = 200, body = manifest({ 0, 1, 0 }) } })
            local info = updater(tr, { 0, 3, 0 }):check("https://repo.example/kpm", "stable")
            assert.is_false(info.available)
        end)

        it("asks the channel it was given", function()
            local tr = helpers.transport({ { status = 200, body = manifest({ 0, 2, 0 }) } })
            updater(tr):check("https://repo.example/kpm", "dev")
            assert.are.equal("https://repo.example/kpm/dev/version.json", tr.requests[1].url)
            assert.are.equal("GET", tr.requests[1].method)
        end)

        it("passes the network failure back", function()
            local tr = helpers.transport({ { err = "host not found" } })
            local _, err = updater(tr):check("https://repo.example/kpm", "stable")
            assert.are.equal("network", err.code)
        end)

        it("reports an http failure", function()
            local tr = helpers.transport({ { status = 404, body = "" } })
            local _, err = updater(tr):check("https://repo.example/kpm", "stable")
            assert.are.equal("http_error", err.code)
            assert.are.equal(404, err.status)
        end)

        it("rejects a manifest that is not JSON", function()
            local tr = helpers.transport({ { status = 200, body = "not json" } })
            local _, err = updater(tr):check("https://repo.example/kpm", "stable")
            assert.are.equal("bad_response", err.code)
        end)

        it("says so when the channel does not carry the package", function()
            local tr = helpers.transport({
                { status = 200, body = helpers.body({ channel = "dev", packages = {} }) },
            })
            local _, err = updater(tr):check("https://repo.example/kpm", "dev")
            assert.are.equal("not_published", err.code)
        end)
    end)
end)
