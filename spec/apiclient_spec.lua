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
        monotonic = opts.monotonic,
    })
end

--- A millisecond clock that only moves when a request is made.
local function stopwatch(per_request_ms)
    local ms = 0
    return {
        read = function() return ms end,
        tick = function() ms = ms + per_request_ms end,
    }
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

        it("keeps a query string at the end, where the gateway looks for it", function()
            -- The key can ride in the baked-in URL instead of a header, which
            -- is one secret to inject at build time instead of two.
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            client(tr, { endpoint = "https://gw.test/koreader-ai?token=s3cret" })
                :define({ word = "fox" })
            assert.are.equal("https://gw.test/koreader-ai/define?token=s3cret",
                tr.requests[1].url)
        end)

        it("handles a trailing slash and a query string together", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            client(tr, { endpoint = "https://gw.test/koreader-ai/?token=s3cret" })
                :define({ word = "fox" })
            assert.are.equal("https://gw.test/koreader-ai/define?token=s3cret",
                tr.requests[1].url)
        end)

        it("sends the word, context and book details", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            client(tr):define({
                word = "fox",
                context = "the quick brown fox jumps",
                sentence = "the quick brown fox jumps",
                title = "Aesop",
                author = "Aesop",
            })

            local sent = helpers.json.decode(tr.requests[1].body)
            assert.are.equal("fox", sent.word)
            assert.are.equal("the quick brown fox jumps", sent.context)
            assert.are.equal("the quick brown fox jumps", sent.sentence)
            assert.is_nil(sent.target_lang)
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

    describe("the request id", function()
        it("goes out as X-Request-Id", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            client(tr):define({ word = "fox", request_id = "aidict-1-2" })
            assert.are.equal("aidict-1-2", tr.requests[1].headers["X-Request-Id"])
        end)

        it("is left out when there is none", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            client(tr):define({ word = "fox" })
            assert.is_nil(tr.requests[1].headers["X-Request-Id"])
        end)

        it("comes back on the answer", function()
            local tr = helpers.transport({
                { status = 200, body = GOOD_BODY, headers = { ["x-request-id"] = "gw-generated" } },
            })
            local result = client(tr):define({ word = "fox" })
            assert.are.equal("gw-generated", result.request_id)
        end)

        it("prefers what the gateway echoed over what we sent", function()
            local tr = helpers.transport({
                { status = 200, body = GOOD_BODY, headers = { ["x-request-id"] = "echoed" } },
            })
            local result = client(tr):define({ word = "fox", request_id = "ours" })
            assert.are.equal("echoed", result.request_id)
        end)

        it("falls back to ours when the gateway echoes nothing", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            local result = client(tr):define({ word = "fox", request_id = "ours" })
            assert.are.equal("ours", result.request_id)
        end)

        it("survives on an error, which is when it matters most", function()
            -- The gateway may have answered after the device gave up; ours is
            -- the only thing that ties the two halves together.
            local tr = helpers.transport({ { err = "timeout" } })
            local _, e = client(tr):define({ word = "fox", request_id = "ours" })
            assert.are.equal("ours", e.request_id)
        end)

        it("picks up Cloudflare's ray when there is one", function()
            local tr = helpers.transport({
                { status = 200, body = GOOD_BODY,
                  headers = { ["cf-ray"] = "a3e2705c8ddcdda5-IAD" } },
            })
            local result = client(tr):define({ word = "fox", request_id = "ours" })
            assert.are.equal("a3e2705c8ddcdda5-IAD", result.cf_ray)
            -- The ray never displaces ours: it only exists once the request
            -- arrived, and the one worth correlating is the one that did not.
            assert.are.equal("ours", result.request_id)
        end)

        it("has no ray when nothing was in front of the gateway", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            assert.is_nil(client(tr):define({ word = "fox" }).cf_ray)
        end)

        it("keeps the ray on an error the gateway did answer", function()
            local tr = helpers.transport({
                { status = 503, body = "", headers = { ["cf-ray"] = "ray-503-IAD" } },
            })
            local _, e = client(tr):define({ word = "fox", request_id = "ours" })
            assert.are.equal("ray-503-IAD", e.cf_ray)
        end)

        it("has no ray on a request that never arrived", function()
            local tr = helpers.transport({ { err = "timeout" } })
            local _, e = client(tr):define({ word = "fox", request_id = "ours" })
            assert.is_nil(e.cf_ray)
            assert.are.equal("ours", e.request_id)
        end)

        it("is the gateway's own on an http error it did answer", function()
            local tr = helpers.transport({
                { status = 500, body = "", headers = { ["x-request-id"] = "gw-500" } },
            })
            local _, e = client(tr):define({ word = "fox", request_id = "ours" })
            assert.are.equal("gw-500", e.request_id)
            assert.are.equal(500, e.status)
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

    describe("timing", function()
        it("measures the round trip with the clock it was given", function()
            local watch = stopwatch(250)
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            local unwrapped = tr.fn
            tr.fn = function(request) watch.tick() return unwrapped(request) end

            local result = client(tr, { monotonic = watch.read }):define({ word = "fox" })
            assert.are.equal(250, result.elapsed_ms)
        end)

        it("works without a clock, and then reports no time", function()
            local tr = helpers.transport({ { status = 200, body = GOOD_BODY } })
            local result = client(tr):define({ word = "fox" })
            assert.is_nil(result.elapsed_ms)
        end)

        it("reads the gateway's own split out of the answer", function()
            local tr = helpers.transport({
                { status = 200, body = helpers.body({
                    definition = "d",
                    timing = { total_ms = 1800, upstream_ms = 1750, model_ms = 500,
                               review_ms = 350, retry_ms = 900 },
                }) },
            })
            local result = client(tr):define({ word = "fox" })
            assert.are.equal(1800, result.server_ms)
            assert.are.equal(500, result.model_ms)
            assert.are.equal(350, result.review_ms)
            assert.are.equal(900, result.retry_ms)
        end)

        it("carries what the gateway's reviewer thought, for the log", function()
            local tr = helpers.transport({
                { status = 200, body = helpers.body({
                    definition = "d",
                    review = { sense = 0.17, examples = 1.33, retried = true },
                }) },
            })
            local result = client(tr):define({ word = "fox" })
            assert.are.equal(0.17, result.review.sense)
            assert.are.equal(1.33, result.review.examples)
            assert.is_true(result.review.retried)
        end)

        it("has no review when the gateway took no second opinion", function()
            local tr = helpers.transport({
                { status = 200, body = helpers.body({ definition = "d" }) },
            })
            assert.is_nil(client(tr):define({ word = "fox" }).review)
        end)

        it("reports no split when the gateway sends none", function()
            local tr = helpers.transport({
                { status = 200, body = helpers.body({ definition = "d" }) },
            })
            local result = client(tr):define({ word = "fox" })
            assert.is_nil(result.server_ms)
            assert.is_nil(result.model_ms)
        end)

        it("shrugs off a timing field that is not a pair of numbers", function()
            for _, timing in ipairs({ "soon", 42, { total_ms = "fast" } }) do
                local tr = helpers.transport({
                    { status = 200, body = helpers.body({ definition = "d", timing = timing }) },
                })
                local result, e = client(tr):define({ word = "fox" })
                assert.is_nil(e)
                assert.is_nil(result.server_ms)
            end
        end)

        it("says how long a failure took, not just that it failed", function()
            -- A 30-second timeout and an instant "no route to host" are
            -- different problems wearing the same error code.
            local watch = stopwatch(30000)
            local tr = helpers.transport({ { err = "timeout" } })
            local unwrapped = tr.fn
            tr.fn = function(request) watch.tick() return unwrapped(request) end

            local _, e = client(tr, { monotonic = watch.read }):define({ word = "fox" })
            assert.are.equal(30000, e.elapsed_ms)
        end)

        it("times every failure past the request, whatever went wrong", function()
            local cases = {
                { { err = "host not found" } },
                { { status = 500, body = "" } },
                { { status = 200, body = "<html>" } },
                { { status = 200, body = helpers.body({ word = "fox" }) } },
            }
            for _, responses in ipairs(cases) do
                local watch = stopwatch(70)
                local tr = helpers.transport(responses)
                local unwrapped = tr.fn
                tr.fn = function(request) watch.tick() return unwrapped(request) end

                local _, e = client(tr, { monotonic = watch.read }):define({ word = "fox" })
                assert.are.equal(70, e.elapsed_ms)
            end
        end)

        it("reports no time for a failure that never reached the network", function()
            local watch = stopwatch(100)
            local tr = helpers.transport({})
            local _, e = client(tr, { monotonic = watch.read }):define({ word = "  " })
            assert.is_nil(e.elapsed_ms)
            assert.are.equal(0, tr.calls)
        end)

        it("keeps our round trip and the gateway's number apart", function()
            -- The difference between the two is the network and the Kindle's
            -- radio, which is the number actually worth watching.
            local watch = stopwatch(1200)
            local tr = helpers.transport({
                { status = 200, body = helpers.body({
                    definition = "d", timing = { total_ms = 300, upstream_ms = 290 },
                }) },
            })
            local unwrapped = tr.fn
            tr.fn = function(request) watch.tick() return unwrapped(request) end

            local result = client(tr, { monotonic = watch.read }):define({ word = "fox" })
            assert.are.equal(1200, result.elapsed_ms)
            assert.are.equal(300, result.server_ms)
        end)
    end)
end)
