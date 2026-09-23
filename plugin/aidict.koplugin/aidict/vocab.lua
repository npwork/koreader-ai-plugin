--[[--
Kindle's own vocabulary, sent to the word inbox from the device.

The Kindle's reader writes every dictionary lookup into `vocab.db`, and
getting those into the Words inbox used to mean pulling the file off the
device. This reads it where it lives and sends only the lookups newer than
the last upload, a batch at a time, to the dictionary's `/vocab`, which files
them in the inbox. The server maps each row and keys it on its lookup id, so
a row sent twice is written once: the cursor is only there to save the
radio, and losing it costs a longer upload, never a duplicate.

Everything that touches the world is injected — `transport` for HTTP,
`json` for encoding, `read` for the database, `random` for the request ids —
so `spec/` drives the whole upload against tables.

    read(since_ms) -> rows, err
      rows = list of { lookup_id, position, usage, timestamp, word, stem,
                       lang, book_asin, book_title, book_authors }
             oldest first, timestamp >= since_ms
--]]--

local Version = require("aidict.version")

local Vocab = {}
Vocab.__index = Vocab

--- Where the Kindle's reader keeps it.
Vocab.PATH = "/mnt/us/system/vocabulary/vocab.db"

--- Rows per request; the server takes at most this many.
Vocab.BATCH = 100

--[[--
The lookups the pipeline wants: English looked up in an English dictionary,
which is the extractor's own filter, oldest first.

`>=` rather than `>`: two lookups can share a millisecond, and a batch that
ends between them would otherwise lose the second. The server already has
the one sent before, so the overlap costs a row, not a duplicate.
--]]--
Vocab.QUERY = [[
SELECT l.id, l.pos, l.usage, l.timestamp,
       w.word, w.stem, w.lang,
       b.asin, b.title, b.authors
FROM LOOKUPS l
JOIN WORDS w ON w.id = l.word_key
JOIN BOOK_INFO b ON b.id = l.book_key
JOIN DICT_INFO d ON d.id = l.dict_key
WHERE d.langin = 'en' AND d.langout = 'en' AND l.timestamp >= ?
ORDER BY l.timestamp, l.id
]]

--- The columns of `QUERY`, in order, as the server names them.
Vocab.COLUMNS = {
    "lookup_id", "position", "usage", "timestamp",
    "word", "stem", "lang",
    "book_asin", "book_title", "book_authors",
}

local function text(value)
    if value == nil then return "" end
    if type(value) == "string" then return value end
    -- An INTEGER column arrives as 64-bit cdata, whose tostring ends in "LL".
    local number = tonumber(value)
    if number then return tostring(number) end
    return tostring(value)
end

--[[--
One row of `QUERY` as the server wants it.

SQLite's integers arrive as 64-bit cdata from the real driver, which no JSON
encoder knows; `tonumber` makes the timestamp a number, which holds a
millisecond clock exactly. A NULL is an empty string, as the extractor
reads it.
--]]--
function Vocab.row(values)
    local row = {}
    for index, name in ipairs(Vocab.COLUMNS) do
        row[name] = text(values[index])
    end
    row.timestamp = tonumber(values[4]) or -1
    return row
end

--[[--
A UUID v4, because that is the only request id the inbox accepts. Random
rather than derived: the rows carry their own identity, and this only lets a
retried request replay its answer.
--]]--
function Vocab.request_id(random)
    local function hex(digits)
        local out = {}
        for i = 1, digits do out[i] = string.format("%x", random(0, 15)) end
        return table.concat(out)
    end
    return string.format("%s-%s-4%s-%x%s-%s",
        hex(8), hex(4), hex(3), 8 + random(0, 3), hex(3), hex(12))
end

--[[--
@param opts table
  endpoint  string the dictionary's address, as `ApiClient` takes it
  api_key   string
  transport func
  json      table
  random    func   random(lo, hi), math.random fits
--]]--
function Vocab.new(opts)
    opts = opts or {}
    assert(type(opts.transport) == "function", "Vocab needs a transport function")
    assert(type(opts.json) == "table", "Vocab needs a json codec")
    assert(type(opts.random) == "function", "Vocab needs a random function")
    return setmetatable({
        endpoint = opts.endpoint,
        api_key = opts.api_key,
        transport = opts.transport,
        json = opts.json,
        random = opts.random,
        block_timeout = opts.block_timeout or 15,
        -- A hundred rows is one transaction on the server, behind a function
        -- that may be starting cold.
        total_timeout = opts.total_timeout or 60,
        user_agent = opts.user_agent or ("koreader-aidict/" .. Version.string),
    }, Vocab)
end

--- The endpoint plus `vocab`, keeping a `?token=` query at the end.
function Vocab:url()
    local base = self.endpoint or ""
    local query = ""
    local mark = base:find("?", 1, true)
    if mark then
        query = base:sub(mark)
        base = base:sub(1, mark - 1)
    end
    return base:gsub("/+$", "") .. "/vocab" .. query
end

local function error_message(json, body)
    if type(body) ~= "string" or body == "" then return nil end
    local ok, decoded = pcall(json.decode, body)
    if not ok or type(decoded) ~= "table" or type(decoded.error) ~= "table" then return nil end
    local message = decoded.error.message
    return type(message) == "string" and message or nil
end

--- Sends one batch. @treturn table counts @treturn table err
function Vocab:send(rows)
    local ok, body = pcall(self.json.encode, {
        request_id = Vocab.request_id(self.random),
        rows = rows,
    })
    if not ok then
        return nil, { code = "invalid_request", message = "could not encode the lookups" }
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
        url = self:url(),
        method = "POST",
        headers = headers,
        body = body,
        block_timeout = self.block_timeout,
        total_timeout = self.total_timeout,
    })
    if not response then
        local reason = tostring(transport_err or "network unreachable")
        if reason:lower():find("timeout") then
            return nil, { code = "timeout", message = "the server did not answer in time" }
        end
        return nil, { code = "network", message = reason }
    end

    local status = tonumber(response.status) or 0
    if status < 200 or status >= 300 then
        local message = error_message(self.json, response.body)
        local code = (status == 401 or status == 403) and "unauthorized"
            or (status >= 500 and "server_error" or "http_error")
        return nil, {
            code = code,
            status = status,
            message = message or ("unexpected response (HTTP " .. status .. ")"),
        }
    end

    local decoded_ok, decoded = pcall(self.json.decode, response.body or "")
    if not decoded_ok or type(decoded) ~= "table" or tonumber(decoded.created) == nil then
        return nil, { code = "bad_response", message = "the server sent something that is not a receipt" }
    end
    return {
        created = tonumber(decoded.created) or 0,
        existing = tonumber(decoded.existing) or 0,
        skipped = tonumber(decoded.skipped) or 0,
    }
end

--[[--
Everything since `since_ms`, in batches, oldest first.

@treturn table report { rows, created, existing, skipped, batches, cursor }
               `cursor` is the newest timestamp the server has acknowledged,
               and is the one to store — also after a failure, so the next
               upload resumes past what already arrived.
@treturn table err    set when a read or a batch failed
--]]--
function Vocab:upload(read, since_ms)
    since_ms = tonumber(since_ms) or 0
    local report = { rows = 0, created = 0, existing = 0, skipped = 0, batches = 0, cursor = since_ms }

    if type(self.endpoint) ~= "string" or not self.endpoint:match("^https?://") then
        return report, { code = "not_configured", message = "the AI endpoint is not set" }
    end

    local raw, read_err = read(since_ms)
    if not raw then
        return report, { code = "unreadable", message = tostring(read_err or "vocab.db could not be read") }
    end

    local rows = {}
    for _, values in ipairs(raw) do rows[#rows + 1] = Vocab.row(values) end
    report.rows = #rows

    for start = 1, #rows, Vocab.BATCH do
        local batch = {}
        for i = start, math.min(start + Vocab.BATCH - 1, #rows) do batch[#batch + 1] = rows[i] end
        local counts, err = self:send(batch)
        if not counts then return report, err end
        report.batches = report.batches + 1
        report.created = report.created + counts.created
        report.existing = report.existing + counts.existing
        report.skipped = report.skipped + counts.skipped
        for _, row in ipairs(batch) do
            if row.timestamp > report.cursor then report.cursor = row.timestamp end
        end
    end
    return report
end

return Vocab
