--[[--
The one place in the plugin that speaks HTTP, built on KOReader's bundled
luasocket. Kept behind the `transport` contract from `apiclient.lua` so the
tests never need a socket.
--]]--

local logger = require("logger")

--[[--
@param request table { url, method, headers, body, block_timeout, total_timeout }
@treturn table  response { status, body, headers }
@treturn string error when the request never produced a response
--]]--
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
        sink = ltn12.sink.table(sink),
    }
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
