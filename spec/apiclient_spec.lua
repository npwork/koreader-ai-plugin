local ApiClient = require("aidict.apiclient")
local Version = require("aidict.version")
local helpers = require("support.helpers")

local function client(transport, opts)
    opts = opts or {}
    return ApiClient.new({
        endpoint = opts.endpoint or "https://gw.test/koreader-ai",
        api_key = opts.api_key,
        transport = transport.fn,
        json = helpers.json,
        block_timeout = opts.block_timeout,
        total_timeout = opts.total_timeout,
    })
end

local GOOD_BODY = helpers.body({
    word = "fox",
    definition = "A small wild dog-like animal.",
    translation = "лиса",
    part_of_speech = "noun",
    examples = { "The fox ran.", "A fox in the henhouse." },
    model = "test-model",
})

describe("api client", function()
    describe("the request it builds", function()
        it("posts JSON to <endpoint>/define", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            client(tr):define({ word = "fox" })

            local request = tr.requests[1]
            assert.are.equal("https://gw.test/koreader-ai/define", request.url)
            assert.are.equal("POST", request.method)
            assert.are.equal("application/json", request.headers["Content-Type"])
            assert.are.equal(tostring(#request.body), request.headers["Content-Length"])
        end)

        it("does not double the slash when the endpoint has one", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            client(tr, { endpoint = "https://gw.test/koreader-ai/" }):define({ word = "fox" })
            assert.are.equal("https://gw.test/koreader-ai/define", tr.requests[1].url)
        end)

        it("sends the word, context and book details", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            client(tr):define({
                word = "fox",
                context = "the quick brown fox jumps",
                target_lang = "ru",
                title = "Aesop",
                author = "Aesop",
            })

            local sent = helpers.json.decode(tr.requests[1].body)
            assert.are.equal("fox", sent.word)
            assert.are.equal("the quick brown fox jumps", sent.context)
            assert.are.equal("ru", sent.target_lang)
            assert.are.equal("Aesop", sent.title)
            assert.are.equal("koreader-aidict", sent.client)
            assert.are.equal(Version.string, sent.client_version)
        end)

        it("leaves an empty context out of the payload", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            client(tr):define({ word = "fox", context = "" })
            assert.is_nil(helpers.json.decode(tr.requests[1].body).context)
        end)

        it("sends a bearer token only when there is one", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            client(tr, { api_key = "s3cret" }):define({ word = "fox" })
            assert.are.equal("Bearer s3cret", tr.requests[1].headers["Authorization"])

            local anon = helpers.transport({ { status = 200, body = GOOD_BODY } })
            client(anon, { api_key = "" }):define({ word = "fox" })
            assert.is_nil(anon.requests[1].headers["Authorization"])
        end)

        it("passes the timeouts down to the transport", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            client(tr, { block_timeout = 7, total_timeout = 21 }):define({ word = "fox" })
            assert.are.equal(7, tr.requests[1].block_timeout)
            assert.are.equal(21, tr.requests[1].total_timeout)
        end)
    end)

    describe("a good answer", function()
        it("comes back as a result table", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            local result, err = client(tr):define({ word = "fox" })

            assert.is_nil(err)
            assert.are.equal("fox", result.word)
            assert.are.equal("A small wild dog-like animal.", result.definition)
            assert.are.equal("лиса", result.translation)
            assert.are.equal("noun", result.part_of_speech)
            assert.are.equal(2, #result.examples)
            assert.are.equal("test-model", result.model)
        end)

        it("accepts any 2xx", function()
            local tr = helpers.transport({ { status = 201, body = GOOD_BODY } })
            local result = client(tr):define({ word = "fox" })
            assert.is_truthy(result)
        end)

        it("fills in the word when the gateway omits it", function()
            local tr = helpers.transport({
                { status = 200, body = helpers.body({ definition = "a definition" }) },
            })
            local result = client(tr):define({ word = "fox" })
            assert.are.equal("fox", result.word)
            assert.are.same({}, result.examples)
        end)

        it("drops examples that are not strings", function()
            local tr = helpers.transport({
                { status = 200, body = helpers.body({
                    definition = "d", examples = { "good", 42, "", "also good" },
                }) },
            })
            local result = client(tr):define({ word = "fox" })
            assert.are.same({ "good", "also good" }, result.examples)
        end)
    end)

    describe("errors", function()
        it("rejects an empty word without calling the network", function()
            local tr = helpers.transport({})
            local _, err = client(tr):define({ word = "   " })
            assert.are.equal(ApiClient.ERRORS.INVALID_REQUEST, err.code)
            assert.are.equal(0, tr.calls)
        end)

        it("reports an unset endpoint", function()
            local tr = helpers.transport({})
            local _, err = client(tr, { endpoint = "" }):define({ word = "fox" })
            assert.are.equal(ApiClient.ERRORS.NOT_CONFIGURED, err.code)
            assert.are.equal(0, tr.calls)
        end)

        it("turns a transport timeout into a timeout error", function()
            local tr = helpers.transport({ { err = "timeout" } })
            local _, err = client(tr):define({ word = "fox" })
            assert.are.equal(ApiClient.ERRORS.TIMEOUT, err.code)
        end)

        it("turns any other transport failure into a network error", function()
            local tr = helpers.transport({ { err = "host not found" } })
            local _, err = client(tr):define({ word = "fox" })
            assert.are.equal(ApiClient.ERRORS.NETWORK, err.code)
            assert.are.equal("host not found", err.message)
        end)

        it("maps 401 and 403 to unauthorized", function()
            for _, status in ipairs({ 401, 403 }) do
                local tr = helpers.transport({ { status = status, body = "" } })
                local _, err = client(tr):define({ word = "fox" })
                assert.are.equal(ApiClient.ERRORS.UNAUTHORIZED, err.code)
                assert.are.equal(status, err.status)
            end
        end)

        it("maps 429 to rate limited", function()
            local tr = helpers.transport({ { status = 429, body = "" } })
            local _, err = client(tr):define({ word = "fox" })
            assert.are.equal(ApiClient.ERRORS.RATE_LIMITED, err.code)
        end)

        it("maps 5xx to a server error", function()
            local tr = helpers.transport({ { status = 503, body = "" } })
            local _, err = client(tr):define({ word = "fox" })
            assert.are.equal(ApiClient.ERRORS.SERVER_ERROR, err.code)
        end)

        it("maps anything else to a plain http error", function()
            local tr = helpers.transport({ { status = 418, body = "" } })
            local _, err = client(tr):define({ word = "fox" })
            assert.are.equal(ApiClient.ERRORS.HTTP_ERROR, err.code)
            assert.is_truthy(err.message:find("418"))
        end)

        it("uses the gateway's own message when it sends one", function()
            local tr = helpers.transport({
                { status = 400, body = helpers.body({ error = { message = "context too long" } }) },
            })
            local _, err = client(tr):define({ word = "fox" })
            assert.are.equal("context too long", err.message)
        end)

        it("also reads a plain string error field", function()
            local tr = helpers.transport({
                { status = 500, body = helpers.body({ error = "upstream is down" }) },
            })
            local _, err = client(tr):define({ word = "fox" })
            assert.are.equal("upstream is down", err.message)
        end)

        it("rejects a body that is not JSON", function()
            local tr = helpers.transport({ { status = 200, body = "<html>502</html>" } })
            local _, err = client(tr):define({ word = "fox" })
            assert.are.equal(ApiClient.ERRORS.BAD_RESPONSE, err.code)
        end)

        it("rejects a 200 with no definition in it", function()
            local tr = helpers.transport({ { status = 200, body = helpers.body({ word = "fox" }) } })
            local _, err = client(tr):define({ word = "fox" })
            assert.are.equal(ApiClient.ERRORS.BAD_RESPONSE, err.code)
        end)

        it("rejects an empty definition", function()
            local tr = helpers.transport({
                { status = 200, body = helpers.body({ definition = "" }) },
            })
            local _, err = client(tr):define({ word = "fox" })
            assert.are.equal(ApiClient.ERRORS.BAD_RESPONSE, err.code)
        end)
    end)
end)
