local logger = require("logger")

-- `download_to` streams the body to that file and returns it empty: a book held in a Lua
-- string on a Kindle can run it out of memory.
return function(request)
    local http = require("socket.http")
    local ltn12 = require("ltn12")
    local socket = require("socket")
    local socketutil = require("socketutil")

    local sink = {}
    local req = {
        url = request.url,
        method = request.method or "GET",
        headers = request.headers,
    }
    if request.download_to then
        local file, open_err = io.open(request.download_to, "wb")
        if not file then
            return nil, "cannot write " .. request.download_to .. ": " .. tostring(open_err)
        end
        -- ltn12 closes it, on success and on a broken transfer alike.
        req.sink = ltn12.sink.file(file)
    else
        req.sink = ltn12.sink.table(sink)
    end
    if request.body then
        req.source = ltn12.source.string(request.body)
    end

    logger.dbg("aidict:", req.method, req.url)
    socketutil:set_timeout(request.block_timeout, request.total_timeout)
    local code, headers, status = socket.skip(1, http.request(req))
    socketutil:reset_timeout()

    if headers == nil then
        -- luasocket reports the failure in `code` ("timeout", "closed", …)
        return nil, tostring(status or code or "network unreachable")
    end

    return {
        status = tonumber(code) or 0,
        body = table.concat(sink),
        headers = headers,
    }
end
