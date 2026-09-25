local NetCheck = require("aidict.netcheck")

-- A clock that each step moves forward by a fixed amount, so every timing in
-- a result is known in advance.
local function fake(steps, overrides)
    local now = 0
    local function takes(ms, fn)
        return function(...)
            now = now + ms
            return fn(...)
        end
    end
    local deps = {
        clock = function() return now end,
        resolve = takes(steps.dns or 0, function() return "104.21.1.1" end),
        connect = takes(steps.tcp or 0, function() return {} end),
        handshake = takes(steps.tls or 0, function() return true end),
        close = function() end,
        fetch = takes(steps.request or 0, function()
            return { status = 200, body = "", headers = {
                ["cf-ray"] = "a400d1578e720387-SIN", ["server-timing"] = 'edge;dur=23;desc="SIN"',
            } }
        end),
    }
    for k, v in pairs(overrides or {}) do deps[k] = v end
    return NetCheck.new(deps)
end

describe("netcheck", function()
    describe("targets", function()
        it("times the AI endpoint's health, the library and a baseline", function()
            local targets = NetCheck.targets("https://koreader-ai.npwork.workers.dev/",
                "https://npwork.uk/koreader-library")
            assert.are.equal(3, #targets)
            assert.are.equal("https://koreader-ai.npwork.workers.dev/health", targets[1].url)
            assert.are.equal("koreader-ai.npwork.workers.dev", targets[1].host)
            assert.are.equal(443, targets[1].port)
            assert.are.equal("npwork.uk", targets[2].host)
            assert.are.equal("1.1.1.1", targets[3].host)
        end)

        it("still has the baseline when nothing of ours is set", function()
            local targets = NetCheck.targets("", nil)
            assert.are.equal(1, #targets)
            assert.are.equal("1.1.1.1", targets[1].host)
        end)
    end)

    describe("colo_of", function()
        it("reads the location off cf-ray", function()
            assert.are.equal("SIN", NetCheck.colo_of({ headers = { ["cf-ray"] = "abc-SIN" } }))
        end)

        it("reads it off a trace page", function()
            assert.are.equal("CGK", NetCheck.colo_of({ headers = {}, body = "ip=1.2.3.4\ncolo=CGK\n" }))
        end)

        it("says nothing when there is nothing to say", function()
            assert.is_nil(NetCheck.colo_of({ headers = {}, body = "" }))
            assert.is_nil(NetCheck.colo_of(nil))
        end)
    end)

    describe("edge_rtt_of", function()
        it("reads the edge round trip off Server-Timing", function()
            assert.are.equal(23, NetCheck.edge_rtt_of({ headers = { ["server-timing"] = 'edge;dur=23;desc="SIN"' } }))
        end)

        it("finds it among other entries", function()
            assert.are.equal(180, NetCheck.edge_rtt_of({ headers = { ["server-timing"] = 'app;dur=5, edge;dur=180;desc="SIN"' } }))
        end)

        it("says nothing without it", function()
            assert.is_nil(NetCheck.edge_rtt_of({ headers = {} }))
        end)
    end)

    describe("probe", function()
        local target = { name = "AI", host = "example.com", port = 443, tls = true, url = "https://example.com/health" }

        it("times each step on its own", function()
            local r = fake({ dns = 3000, tcp = 40, tls = 600, request = 1700 }):probe(target)
            assert.are.equal(3000, r.dns_ms)
            assert.are.equal(40, r.tcp_ms)
            assert.are.equal(600, r.tls_ms)
            assert.are.equal(1700, r.request_ms)
            assert.are.equal("SIN", r.colo)
            assert.are.equal(200, r.status)
            assert.is_nil(r.err)
        end)

        it("skips DNS for an address", function()
            local asked = false
            local r = fake({}, { resolve = function() asked = true end }):probe(
                { name = "1.1.1.1", host = "1.1.1.1", port = 443, tls = true })
            assert.is_false(asked)
            assert.is_nil(r.dns_ms)
            assert.are.equal("1.1.1.1", r.ip)
        end)

        it("stops at the step that failed and names it", function()
            local connected = false
            local r = fake({ dns = 5000 }, {
                resolve = function() return nil, "timeout" end,
                connect = function() connected = true end,
            }):probe(target)
            assert.are.equal("DNS: timeout", r.err)
            assert.is_false(connected)
        end)

        it("closes the socket when the handshake fails", function()
            local closed = false
            local r = fake({}, {
                handshake = function() return nil, "closed" end,
                close = function() closed = true end,
            }):probe(target)
            assert.are.equal("TLS: closed", r.err)
            assert.is_true(closed)
        end)
    end)

    describe("run and report", function()
        it("probes every target each round and names the slowest step", function()
            local check = fake({ dns = 3000, tcp = 40, tls = 600, request = 1700 })
            local results = check:run(NetCheck.targets("https://a.example", nil), 2)
            assert.are.equal(4, #results)
            assert.are.equal(2, results[4].round)
            local text = NetCheck.report(results)
            assert.is_truthy(text:find("DNS 3000 ms · connect 40 ms · TLS 600 ms · request 1700 ms (HTTP 200)", 1, true))
            assert.is_truthy(text:find("via SIN", 1, true))
            assert.is_truthy(text:find("as Cloudflare saw it: 23 ms", 1, true))
            assert.is_truthy(text:find("Slowest step: DNS to AI, 3000 ms.", 1, true))
        end)

        it("shows a failure where it happened", function()
            local check = fake({}, { connect = function() return nil, "timeout" end })
            local text = NetCheck.report(check:run(NetCheck.targets("", nil), 1))
            assert.is_truthy(text:find("failed at connect: timeout", 1, true))
        end)
    end)
end)
