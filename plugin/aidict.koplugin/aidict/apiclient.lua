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
    }, ApiClient)
end

--- Join the endpoint and a path without doubling or dropping the slash.
function ApiClient:url_for(path)
    local base = (self.endpoint or ""):gsub("/+$", "")
    path = tostring(path or ""):gsub("^/+", "")
    return base .. "/" .. path
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
  context      string optional surrounding sentence
  target_lang  string optional
  source_lang  string optional
  title        string optional book title, for disambiguation
  author       string optional
@treturn table result { word, definition, translation, examples, part_of_speech, model }
@treturn table err    { code, message, status }
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
        target_lang = request.target_lang,
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

    local response, transport_err = self.transport({
        url = self:url_for("define"),
        method = "POST",
        headers = headers,
        body = body,
        block_timeout = self.block_timeout,
        total_timeout = self.total_timeout,
    })

    if not response then
        local reason = tostring(transport_err or "network unreachable")
        if reason:lower():find("timeout") then
            return err(ApiClient.ERRORS.TIMEOUT, "the gateway did not answer in time")
        end
        return err(ApiClient.ERRORS.NETWORK, reason)
    end

    local status = tonumber(response.status) or 0
    if status < 200 or status >= 300 then
        local code, message = status_to_error(status, self:_error_message(response.body))
        return err(code, message, { status = status })
    end

    local decode_ok, decoded = pcall(self.json.decode, response.body or "")
    if not decode_ok or type(decoded) ~= "table" then
        return err(ApiClient.ERRORS.BAD_RESPONSE, "the gateway sent something that is not JSON")
    end
    if type(decoded.definition) ~= "string" or decoded.definition == "" then
        local message = self:_error_message(response.body)
        return err(ApiClient.ERRORS.BAD_RESPONSE, message or "the gateway sent no definition")
    end

    local examples = {}
    if type(decoded.examples) == "table" then
        for _, example in ipairs(decoded.examples) do
            if type(example) == "string" and example ~= "" then
                examples[#examples + 1] = example
            end
        end
    end

    return {
        word = type(decoded.word) == "string" and decoded.word or request.word,
        definition = decoded.definition,
        translation = type(decoded.translation) == "string" and decoded.translation or nil,
        part_of_speech = type(decoded.part_of_speech) == "string" and decoded.part_of_speech or nil,
        examples = examples,
        model = type(decoded.model) == "string" and decoded.model or nil,
    }
end

return ApiClient
