--[[--
Client for the AI gateway.

Everything that touches the network is injected as `transport`, and JSON
encoding as `json`, so this module is plain Lua and fully unit-testable.

    transport(request) -> response | nil, err
      request  = { url, method, headers = {}, body = string|nil,
                   block_timeout, total_timeout }
      response = { status = int, body = string, headers = table }
      err      = "timeout" | any other string

    json.encode(table) -> string
    json.decode(string) -> table | nil, err
--]]--

local Version = require("aidict.version")

local ApiClient = {}
ApiClient.__index = ApiClient

--- Error codes callers can branch on. Anything user-visible is built from
--- these plus `err.message`.
ApiClient.ERRORS = {
    INVALID_REQUEST = "invalid_request",
    NOT_CONFIGURED = "not_configured",
    NETWORK = "network",
    TIMEOUT = "timeout",
    UNAUTHORIZED = "unauthorized",
    RATE_LIMITED = "rate_limited",
    SERVER_ERROR = "server_error",
    HTTP_ERROR = "http_error",
    BAD_RESPONSE = "bad_response",
}

local function err(code, message, extra)
    local e = { code = code, message = message }
    if extra then
        for k, v in pairs(extra) do e[k] = v end
    end
    return nil, e
end

--[[--
@param opts table
  endpoint      string base URL of the gateway, baked into the package
                       at build time
  api_key       string optional bearer token
  transport     func   see above, required
  json          table  encode/decode pair, required
  block_timeout int    seconds
  total_timeout int    seconds
  monotonic     func   optional, returns milliseconds from a monotonic clock;
                       used to time the round trip
--]]--
function ApiClient.new(opts)
    opts = opts or {}
    assert(type(opts.transport) == "function", "ApiClient needs a transport function")
    assert(type(opts.json) == "table", "ApiClient needs a json codec")
    return setmetatable({
        endpoint = opts.endpoint,
        api_key = opts.api_key,
        transport = opts.transport,
        json = opts.json,
        block_timeout = opts.block_timeout or 10,
        total_timeout = opts.total_timeout or 30,
        user_agent = opts.user_agent or ("koreader-aidict/" .. Version.string),
        monotonic = opts.monotonic,
    }, ApiClient)
end

--[[--
Join the endpoint and a path without doubling or dropping the slash.

The endpoint may already carry a query string — the gateway accepts its key
as `?token=…` as well as a bearer header, and baking the whole URL into the
package is one secret instead of two. The query has to stay at the end, so it
is lifted off and put back rather than having the path appended after it.
--]]--
function ApiClient:url_for(path)
    local base = self.endpoint or ""
    local query = ""
    local mark = base:find("?", 1, true)
    if mark then
        query = base:sub(mark)
        base = base:sub(1, mark - 1)
    end
    base = base:gsub("/+$", "")
    path = tostring(path or ""):gsub("^/+", "")
    return base .. "/" .. path .. query
end

local function status_to_error(status, message)
    if status == 401 or status == 403 then
        return ApiClient.ERRORS.UNAUTHORIZED, message or "the gateway rejected this device's key"
    elseif status == 429 then
        return ApiClient.ERRORS.RATE_LIMITED, message or "too many requests, try again shortly"
    elseif status >= 500 then
        return ApiClient.ERRORS.SERVER_ERROR, message or ("the gateway failed (HTTP " .. status .. ")")
    end
    return ApiClient.ERRORS.HTTP_ERROR, message or ("unexpected response (HTTP " .. status .. ")")
end

--- Pull `{"error": ...}` out of a body that may or may not be JSON.
function ApiClient:_error_message(body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, decoded = pcall(self.json.decode, body)
    if not ok or type(decoded) ~= "table" then return nil end
    local e = decoded.error
    if type(e) == "string" then return e end
    if type(e) == "table" and type(e.message) == "string" then return e.message end
    if type(decoded.message) == "string" then return decoded.message end
    return nil
end

--[[--
Ask the gateway to explain a word.

@param request table
  word         string required
  context      string optional surrounding paragraph
  sentence     string optional sentence containing the word
  source_lang  string optional
  title        string optional book title, for disambiguation
  author       string optional
  request_id   string optional, sent as X-Request-Id so both logs agree
@treturn table result { word, definition, translation, examples, part_of_speech,
                        model, timings, review }
@treturn table err    { code, message, status, elapsed_ms, request_id, cf_ray }
--]]--
function ApiClient:define(request)
    request = request or {}
    if type(request.word) ~= "string" or request.word:gsub("%s", "") == "" then
        return err(ApiClient.ERRORS.INVALID_REQUEST, "no word to look up")
    end
    if type(self.endpoint) ~= "string" or not self.endpoint:match("^https?://") then
        return err(ApiClient.ERRORS.NOT_CONFIGURED, "the AI endpoint is not set")
    end

    local payload = {
        word = request.word,
        context = request.context ~= "" and request.context or nil,
        sentence = request.sentence ~= "" and request.sentence or nil,
        source_lang = request.source_lang,
        title = request.title,
        author = request.author,
        client = "koreader-aidict",
        client_version = Version.string,
    }

    local encoded_ok, body = pcall(self.json.encode, payload)
    if not encoded_ok then
        return err(ApiClient.ERRORS.INVALID_REQUEST, "could not encode the request")
    end

    local headers = {
        ["Content-Type"] = "application/json",
        ["Accept"] = "application/json",
        ["Content-Length"] = tostring(#body),
        ["User-Agent"] = self.user_agent,
    }
    if type(self.api_key) == "string" and self.api_key ~= "" then
        headers["Authorization"] = "Bearer " .. self.api_key
    end
    if type(request.request_id) == "string" and request.request_id ~= "" then
        headers["X-Request-Id"] = request.request_id
    end

    local started = self.monotonic and self.monotonic() or nil
    local response, transport_err = self.transport({
        url = self:url_for("define"),
        method = "POST",
        headers = headers,
        body = body,
        block_timeout = self.block_timeout,
        total_timeout = self.total_timeout,
    })

    -- Every failure past this point carries how long it took to fail and which
    -- request it was. A 30-second timeout and an instant "no route to host"
    -- are the same error code with very different causes, and the log is where
    -- that is read.
    local elapsed_ms = started and self.monotonic and (self.monotonic() - started) or nil

    local function header(name, alt)
        if not (response and type(response.headers) == "table") then return nil end
        local value = response.headers[name] or response.headers[alt]
        if type(value) == "string" and value ~= "" then return value end
        return nil
    end

    -- The gateway echoes the id back; if it never answered, ours is all there
    -- is — and it is still the id the gateway logged under, if it got that far.
    local request_id = header("x-request-id", "X-Request-Id") or request.request_id

    -- Cloudflare sits in front of the gateway and stamps its own id on the
    -- request. It exists only once the request arrived, so it can never
    -- replace ours — but when it is there it is the key into Cloudflare's
    -- own logs, which nothing else gives us.
    local cf_ray = header("cf-ray", "CF-Ray")

    local function fail(code, message, extra)
        extra = extra or {}
        extra.elapsed_ms = elapsed_ms
        extra.request_id = request_id
        extra.cf_ray = cf_ray
        return err(code, message, extra)
    end

    if not response then
        local reason = tostring(transport_err or "network unreachable")
        if reason:lower():find("timeout") then
            return fail(ApiClient.ERRORS.TIMEOUT, "the gateway did not answer in time")
        end
        return fail(ApiClient.ERRORS.NETWORK, reason)
    end

    local status = tonumber(response.status) or 0
    if status < 200 or status >= 300 then
        local code, message = status_to_error(status, self:_error_message(response.body))
        return fail(code, message, { status = status })
    end

    local decode_ok, decoded = pcall(self.json.decode, response.body or "")
    if not decode_ok or type(decoded) ~= "table" then
        return fail(ApiClient.ERRORS.BAD_RESPONSE, "the gateway sent something that is not JSON")
    end
    if type(decoded.definition) ~= "string" or decoded.definition == "" then
        local message = self:_error_message(response.body)
        return fail(ApiClient.ERRORS.BAD_RESPONSE, message or "the gateway sent no definition")
    end

    local examples = {}
    if type(decoded.examples) == "table" then
        for _, example in ipairs(decoded.examples) do
            if type(example) == "string" and example ~= "" then
                examples[#examples + 1] = example
            end
        end
    end

    -- The gateway reports where its own time went: the model call, the second
    -- opinion on the answer, and the retry that opinion may have caused. The
    -- difference between its total and our round trip is the network and the
    -- Kindle's radio.
    local server_ms, model_ms, review_ms, retry_ms
    if type(decoded.timing) == "table" then
        server_ms = tonumber(decoded.timing.total_ms)
        model_ms = tonumber(decoded.timing.model_ms)
        review_ms = tonumber(decoded.timing.review_ms)
        retry_ms = tonumber(decoded.timing.retry_ms)
    end

    -- What the reviewer made of the answer. Logged, never shown.
    local review
    if type(decoded.review) == "table" then
        review = {
            sense = tonumber(decoded.review.sense),
            examples = tonumber(decoded.review.examples),
            retried = decoded.review.retried == true,
        }
    end

    return {
        word = type(decoded.word) == "string" and decoded.word or request.word,
        definition = decoded.definition,
        translation = type(decoded.translation) == "string" and decoded.translation or nil,
        part_of_speech = type(decoded.part_of_speech) == "string" and decoded.part_of_speech or nil,
        examples = examples,
        model = type(decoded.model) == "string" and decoded.model or nil,
        elapsed_ms = elapsed_ms,
        server_ms = server_ms,
        model_ms = model_ms,
        review_ms = review_ms,
        retry_ms = retry_ms,
        review = review,
        request_id = request_id,
        cf_ray = cf_ray,
    }
end

return ApiClient
