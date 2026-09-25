--[[--
Where a slow lookup's time goes before the gateway ever sees it.

The footer's "7.0s total · 1.6s server" says the network ate five seconds and
nothing more. A lookup opens a fresh connection every time, so that network
time is a DNS lookup, a TCP connect, a TLS handshake and the request itself,
and each of those fails differently: slow DNS is the hotel's resolver, a slow
connect is the Wi-Fi or the route, a slow handshake is the Kindle's CPU. This
times each step separately, against the AI endpoint, the library, and
1.1.1.1 as a plain-internet baseline that has nothing of ours in it.

Everything that touches a socket is handed in, so the arithmetic and the
report are tested without one; main.lua wires in luasocket and luasec.
--]]--

local NetCheck = {}
NetCheck.__index = NetCheck

--[[--
@param deps table {
  clock     func() -> milliseconds, monotonic
  resolve   func(host) -> ip | nil, err
  connect   func(ip, port) -> sock | nil, err
  handshake func(sock, host) -> true | nil, err
  close     func(sock)
  fetch     func(url) -> { status, body, headers } | nil, err
}
--]]--
function NetCheck.new(deps)
    return setmetatable({ deps = deps }, NetCheck)
end

--- The host part of an http(s) URL, and the port it implies.
function NetCheck.host_of(url)
    if type(url) ~= "string" then return nil end
    local scheme, host, port = url:match("^(https?)://([^/:?#]+):?(%d*)")
    if not host then return nil end
    port = tonumber(port) or (scheme == "https" and 443 or 80)
    return host, port, scheme == "https"
end

--[[--
The Cloudflare location that answered, when one did: the three letters after
the dash in `cf-ray`, or `colo=` in a /cdn-cgi/trace body. It says whether the
Kindle is reaching Singapore or somewhere much further away.
--]]--
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

--[[--
The places worth timing. The AI endpoint and the library are ours; 1.1.1.1
is Cloudflare's resolver, reached by address so it needs no DNS, and its
trace page names the location the Wi-Fi's route leads to.
--]]--
function NetCheck.targets(endpoint, library_endpoint)
    local targets = {}
    local function add(name, url)
        local host, port, tls = NetCheck.host_of(url)
        if host then
            targets[#targets + 1] = { name = name, host = host, port = port, tls = tls, url = url }
        end
    end
    if type(endpoint) == "string" and endpoint ~= "" then
        add("AI", (endpoint:gsub("/+$", "")) .. "/health")
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

--[[--
One target, one step at a time, each timed on its own. A step that fails
stops the ones that need it and says which it was. The request at the end is
the plugin's own transport, so it pays for DNS, connect and TLS again: that
number is what a lookup against this host costs before the server works.
--]]--
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
    end
    return result
end

--- Every target, `rounds` times over, so a first-time cost shows as one.
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

--[[--
Plain text for a TextViewer and for the log: one block per probe, then a
line saying which step was slowest overall, which is the answer the reader
opened this for.
--]]--
function NetCheck.report(results)
    local lines = {}
    local slowest, slowest_ms = nil, -1
    for _, r in ipairs(results) do
        lines[#lines + 1] = string.format("%s — round %d%s", r.name, r.round or 1,
            r.colo and (" · via " .. r.colo) or "")
        -- The status too: a hotel's captive portal answers fast, and with
        -- something that is not ours.
        lines[#lines + 1] = string.format("  DNS %s · connect %s · TLS %s · request %s%s",
            ms(r.dns_ms), ms(r.tcp_ms), ms(r.tls_ms), ms(r.request_ms),
            r.status and (" (HTTP " .. tostring(r.status) .. ")") or "")
        if r.err then lines[#lines + 1] = "  failed at " .. r.err end
        for _, step in ipairs({ { "DNS", r.dns_ms }, { "connect", r.tcp_ms }, { "TLS", r.tls_ms } }) do
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
