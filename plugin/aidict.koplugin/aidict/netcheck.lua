-- Times DNS, connect, TLS and the request separately: each is slow for a different reason
-- (the resolver, the route, the Kindle's CPU).

local NetCheck = {}
NetCheck.__index = NetCheck

-- deps: clock() -> monotonic ms, resolve(host) -> ip, connect(ip, port) -> sock, handshake(sock, host),
-- close(sock), fetch(url) -> response; a failing step returns nil, err.
function NetCheck.new(deps)
    return setmetatable({ deps = deps }, NetCheck)
end

function NetCheck.host_of(url)
    if type(url) ~= "string" then return nil end
    local scheme, host, port = url:match("^(https?)://([^/:?#]+):?(%d*)")
    if not host then return nil end
    port = tonumber(port) or (scheme == "https" and 443 or 80)
    return host, port, scheme == "https"
end

-- The three letters after the dash in `cf-ray`, or `colo=` in a /cdn-cgi/trace body.
function NetCheck.colo_of(response)
    if type(response) ~= "table" then return nil end
    local headers = type(response.headers) == "table" and response.headers or {}
    local ray = headers["cf-ray"] or headers["CF-Ray"]
    if type(ray) == "string" then
        local colo = ray:match("%-(%u%u%u)$")
        if colo then return colo end
    end
    if type(response.body) == "string" then
        return response.body:match("colo=(%u%u%u)")
    end
    return nil
end

-- From `Server-Timing: edge;dur=23;desc="SIN"`: the network's share without the Kindle's DNS and TLS work.
function NetCheck.edge_rtt_of(response)
    if type(response) ~= "table" or type(response.headers) ~= "table" then return nil end
    local header = response.headers["server-timing"] or response.headers["Server-Timing"]
    if type(header) ~= "string" then return nil end
    return tonumber(header:match("edge;[^,]*dur=([%d%.]+)"))
end

-- 1.1.1.1 is reached by address, so it needs no DNS, and its trace page names the colo.
function NetCheck.targets(endpoint, library_endpoint)
    local targets = {}
    local function add(name, url)
        local host, port, tls = NetCheck.host_of(url)
        if host then
            targets[#targets + 1] = { name = name, host = host, port = port, tls = tls, url = url }
        end
    end
    if type(endpoint) == "string" and endpoint ~= "" then
        -- An endpoint carrying ?token= keeps it after /health, as ApiClient:url_for does.
        local base, query = endpoint:match("^([^?]*)(.*)$")
        add("AI", (base:gsub("/+$", "")) .. "/health" .. query)
    end
    if type(library_endpoint) == "string" and library_endpoint ~= "" then
        add("Library", library_endpoint)
    end
    add("Internet (1.1.1.1)", "https://1.1.1.1/cdn-cgi/trace")
    return targets
end

local function is_address(host)
    return host:match("^%d+%.%d+%.%d+%.%d+$") ~= nil
end

-- The request goes through the plugin's own transport, so it pays DNS, connect and TLS again:
-- what a lookup costs before the server works.
function NetCheck:probe(target)
    local d = self.deps
    local result = { name = target.name, host = target.host }
    local function lap(fn, ...)
        local started = d.clock()
        local a, b = fn(...)
        return math.floor(d.clock() - started + 0.5), a, b
    end

    local ip = target.host
    if not is_address(ip) then
        local ms, resolved, err = lap(d.resolve, target.host)
        result.dns_ms = ms
        if not resolved then
            result.err = "DNS: " .. tostring(err or "no answer")
            return result
        end
        ip = resolved
    end
    result.ip = ip

    local ms, sock, err = lap(d.connect, ip, target.port)
    result.tcp_ms = ms
    if not sock then
        result.err = "connect: " .. tostring(err or "failed")
        return result
    end
    if target.tls then
        local hs_ms, ok, hs_err = lap(d.handshake, sock, target.host)
        result.tls_ms = hs_ms
        if not ok then
            pcall(d.close, sock)
            result.err = "TLS: " .. tostring(hs_err or "failed")
            return result
        end
    end
    pcall(d.close, sock)

    if target.url then
        local req_ms, response, req_err = lap(d.fetch, target.url)
        result.request_ms = req_ms
        if not response then
            result.err = "request: " .. tostring(req_err or "failed")
            return result
        end
        result.status = response.status
        result.colo = NetCheck.colo_of(response)
        result.edge_rtt_ms = NetCheck.edge_rtt_of(response)
    end
    return result
end

-- `rounds` times over, so a first-time cost shows as one.
function NetCheck:run(targets, rounds)
    local results = {}
    for round = 1, rounds or 2 do
        for _, target in ipairs(targets) do
            local result = self:probe(target)
            result.round = round
            results[#results + 1] = result
        end
    end
    return results
end

local function ms(value)
    return value and (tostring(value) .. " ms") or "–"
end

function NetCheck.report(results)
    local lines = {}
    local slowest, slowest_ms = nil, -1
    for _, r in ipairs(results) do
        lines[#lines + 1] = string.format("%s — round %d%s", r.name, r.round or 1,
            r.colo and (" · via " .. r.colo) or "")
        -- The status too: a hotel's captive portal answers fast, with something not ours.
        lines[#lines + 1] = string.format("  DNS %s · connect %s · TLS %s · request %s%s",
            ms(r.dns_ms), ms(r.tcp_ms), ms(r.tls_ms), ms(r.request_ms),
            r.status and (" (HTTP " .. tostring(r.status) .. ")") or "")
        if r.edge_rtt_ms then
            lines[#lines + 1] = string.format("  round trip to the edge, as Cloudflare saw it: %s ms", tostring(r.edge_rtt_ms))
        end
        if r.err then lines[#lines + 1] = "  failed at " .. r.err end
        -- The request repeats DNS, connect and TLS, so what it adds is the server and the transfer.
        local rest
        if r.request_ms then
            rest = math.max(0, r.request_ms - (r.dns_ms or 0) - (r.tcp_ms or 0) - (r.tls_ms or 0))
        end
        for _, step in ipairs({
            { "DNS", r.dns_ms }, { "connect", r.tcp_ms }, { "TLS", r.tls_ms },
            { "server and transfer", rest },
        }) do
            if step[2] and step[2] > slowest_ms then
                slowest, slowest_ms = string.format("%s to %s", step[1], r.name), step[2]
            end
        end
    end
    if slowest then
        lines[#lines + 1] = ""
        lines[#lines + 1] = string.format("Slowest step: %s, %d ms.", slowest, slowest_ms)
    end
    return table.concat(lines, "\n")
end

return NetCheck
