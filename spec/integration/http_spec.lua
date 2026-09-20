--[[--
The one layer the unit suite cannot reach: a real HTTP request, over a real
socket, through the same `http_transport.lua` that runs on the Kindle.

The gateway is `spec/support/fake_gateway.py`; the only KOReader pieces stubbed
are `logger` and `socketutil`, and `socketutil` is stubbed to do what KOReader's
does — set luasocket's timeout.
--]]--

local gateway = require("support.gateway")
local helpers = require("support.helpers")

local PORT = tonumber(os.getenv("AIDICT_TEST_PORT") or "8732")

describe("http transport, end to end", function()
    local server, ApiClient, transport

    setup(function()
        server = gateway.start(PORT)
        -- Required after the stubs are in place: the transport requires
        -- `logger` at load time.
        ApiClient = require("aidict.apiclient")
        transport = require("aidict.http_transport")
    end)

    teardown(function()
        if server then server.stop() end
    end)

    local function client(path, opts)
        opts = opts or {}
        return ApiClient.new({
            endpoint = server.url(path or ""),
            api_key = opts.api_key,
            transport = transport,
            json = helpers.json,
            block_timeout = opts.block_timeout,
            total_timeout = opts.total_timeout,
        })
    end

    it("gets a real answer over a real socket", function()
        local result, err = client():define({ word = "fox", context = "the quick brown fox" })

        assert.is_nil(err)
        assert.are.equal("fox", result.word)
        assert.are.equal("A wild animal of the dog family.", result.definition)
        assert.are.equal("лиса", result.translation)
        assert.are.equal(1, #result.examples)
        assert.are.equal("fake-gateway", result.model)
    end)

    it("really puts the word, context and bearer token on the wire", function()
        client(nil, { api_key = "s3cret" }):define({
            word = "fox",
            context = "the quick brown fox",
            sentence = "the quick brown fox",
            title = "Aesop",
        })

        -- The gateway keeps the last request it saw; ask it what arrived.
        local response = transport({
            url = server.url("/last"),
            method = "GET",
            headers = { ["Accept"] = "application/json" },
            block_timeout = 5,
            total_timeout = 10,
        })
        local seen = helpers.json.decode(response.body)

        assert.are.equal("POST", seen.method)
        assert.are.equal("/define", seen.path)
        assert.are.equal("application/json", seen.headers["content-type"])
        assert.are.equal("Bearer s3cret", seen.headers["authorization"])
        assert.are.equal("fox", seen.body.word)
        assert.are.equal("the quick brown fox", seen.body.context)
        assert.are.equal("the quick brown fox", seen.body.sentence)
        assert.are.equal("koreader-aidict", seen.body.client)
    end)

    it("really carries the request id there and back", function()
        local result = client():define({ word = "fox", request_id = "aidict-1-abc" })
        assert.are.equal("aidict-1-abc", result.request_id)

        local response = transport({
            url = server.url("/last"),
            method = "GET",
            headers = { ["Accept"] = "application/json" },
            block_timeout = 5,
            total_timeout = 10,
        })
        local seen = helpers.json.decode(response.body)
        assert.are.equal("aidict-1-abc", seen.headers["x-request-id"])
    end)

    it("reads an id the gateway minted on its own", function()
        local result = client():define({ word = "fox" })
        assert.are.equal("gateway-minted", result.request_id)
    end)

    it("reports a real 500 with the gateway's message", function()
        local _, err = client("/boom"):define({ word = "fox" })
        assert.are.equal(ApiClient.ERRORS.SERVER_ERROR, err.code)
        assert.are.equal("upstream model is down", err.message)
        assert.are.equal(500, err.status)
    end)

    it("reports a real 401", function()
        local _, err = client("/locked"):define({ word = "fox" })
        assert.are.equal(ApiClient.ERRORS.UNAUTHORIZED, err.code)
    end)

    it("reports a body that is not JSON", function()
        local _, err = client("/garbage"):define({ word = "fox" })
        assert.are.equal(ApiClient.ERRORS.BAD_RESPONSE, err.code)
    end)

    it("times out on a gateway that never answers", function()
        local started = os.time()
        local _, err = client("/slow", { block_timeout = 1, total_timeout = 2 }):define({ word = "fox" })

        assert.are.equal(ApiClient.ERRORS.TIMEOUT, err.code)
        assert.is_true(os.difftime(os.time(), started) < 3)
    end)

    it("reports a refused connection as a network error", function()
        local nowhere = ApiClient.new({
            endpoint = string.format("http://127.0.0.1:%d", PORT + 7),
            transport = transport,
            json = helpers.json,
            block_timeout = 2,
            total_timeout = 4,
        })
        local _, err = nowhere:define({ word = "fox" })
        assert.are.equal(ApiClient.ERRORS.NETWORK, err.code)
    end)

    it("reads a real version manifest for the update check", function()
        local Updater = require("aidict.updater")
        local updater = Updater.new({
            transport = transport,
            json = helpers.json,
            current = { 0, 1, 0 },
        })
        local info, err = updater:check(server.url(""), "stable")

        assert.is_nil(err)
        assert.is_true(info.available)
        assert.are.equal("9.9.9", info.latest)
    end)
end)
