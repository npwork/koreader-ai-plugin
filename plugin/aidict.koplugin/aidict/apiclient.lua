-- transport(request) -> { status, body, headers } | nil, err, where request is
-- { url, method, headers, body, block_timeout, total_timeout } and a timeout's err contains "timeout".

local Version = require("aidict.version")
local NetCheck = require("aidict.netcheck")

local ApiClient = {}
ApiClient.__index = ApiClient

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

-- opts: endpoint (baked in at build time), api_key, transport, json, block_timeout and
-- total_timeout in seconds, and monotonic() in milliseconds to time the round trip.
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

-- The endpoint may carry a `?token=…` query, which has to stay at the end.
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

    -- Failures carry how long they took: a 30-second timeout and an instant "no route to host"
    -- share an error code.
    local elapsed_ms = started and self.monotonic and (self.monotonic() - started) or nil

    local function header(name, alt)
        if not (response and type(response.headers) == "table") then return nil end
        local value = response.headers[name] or response.headers[alt]
        if type(value) == "string" and value ~= "" then return value end
        return nil
    end

    local request_id = header("x-request-id", "X-Request-Id") or request.request_id

    -- Cloudflare's own id, the key into its logs; there only once the request arrived.
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

    local function strings(value)
        local out = {}
        if type(value) == "table" then
            for _, item in ipairs(value) do
                if type(item) == "string" and item ~= "" then out[#out + 1] = item end
            end
        end
        return out
    end

    local examples = strings(decoded.examples)
    -- From the model: rules about endings never reach "went" from "go".
    local forms = strings(decoded.forms)

    -- Sorted longest first: a JSON object arrives unordered, and this is read to find what took the time.
    local server_ms, legs
    if type(decoded.timing) == "table" then
        server_ms = tonumber(decoded.timing.total_ms)
        if type(decoded.timing.legs) == "table" then
            legs = {}
            for name, ms in pairs(decoded.timing.legs) do
                if type(name) == "string" and tonumber(ms) then
                    legs[#legs + 1] = { name = name, ms = tonumber(ms) }
                end
            end
            table.sort(legs, function(a, b)
                if a.ms == b.ms then return a.name < b.name end
                return a.ms > b.ms
            end)
        end
    end

    -- Logged, never shown.
    local review
    if type(decoded.review) == "table" then
        review = {
            sense = tonumber(decoded.review.sense),
            examples = tonumber(decoded.review.examples),
            retried = decoded.review.retried == true,
        }
    end

    local function text(value)
        if type(value) == "string" and value ~= "" then return value end
        return nil
    end

    return {
        word = type(decoded.word) == "string" and decoded.word or request.word,
        lemma = text(decoded.lemma),
        pronunciation = text(decoded.pronunciation),
        etymology = text(decoded.etymology),
        definition = decoded.definition,
        translation = type(decoded.translation) == "string" and decoded.translation or nil,
        part_of_speech = type(decoded.part_of_speech) == "string" and decoded.part_of_speech or nil,
        examples = examples,
        forms = forms,
        model = type(decoded.model) == "string" and decoded.model or nil,
        elapsed_ms = elapsed_ms,
        server_ms = server_ms,
        -- The Kindle's TCP round trip to Cloudflare's edge, as the edge measured it.
        edge_rtt_ms = NetCheck.edge_rtt_of(response),
        legs = legs,
        review = review,
        request_id = request_id,
        cf_ray = cf_ray,
    }
end

return ApiClient
