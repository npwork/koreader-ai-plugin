--[[--
Turns an API result into the text KOReader puts in a TextViewer.
--]]--

local Format = {}

--- Milliseconds as something worth reading on a small screen.
function Format.duration(ms)
    ms = tonumber(ms)
    if not ms then return "" end
    if ms < 1000 then return string.format("%dms", math.floor(ms + 0.5)) end
    return string.format("%.1fs", ms / 1000)
end

--[[--
How long it took, and where the time went.

A single number cannot be acted on: three seconds of radio and three seconds
of model look identical on the screen and want opposite fixes. The gateway
reports what it spent, the client times the whole round trip, and the
difference is everything between the two — waking the Wi-Fi, the handshake,
the flight. That difference is the number worth naming, so it is subtracted
here rather than left to be done in the reader's head.

@param elapsed_ms number  the whole round trip, as the device measured it
@param server_ms  number  what the gateway says it spent, when it says
@treturn string
--]]--
function Format.timing(elapsed_ms, server_ms)
    local total = Format.duration(elapsed_ms)
    if total == "" then return "" end

    server_ms = tonumber(server_ms)
    if not server_ms then return total end

    -- The two are measured by different clocks on different machines, so the
    -- subtraction can come out at or below zero when the gateway is quick and
    -- the network is quicker. "network 0ms" is not a finding, and a negative
    -- one is noise, so the breakdown is simply dropped.
    local network_ms = tonumber(elapsed_ms) - server_ms
    if network_ms <= 0 then return total end

    return string.format(
        "%s (%s server, %s network)",
        total, Format.duration(server_ms), Format.duration(network_ms)
    )
end

--- Human-readable one-liner for an `ApiClient` error.
function Format.error(err)
    if type(err) ~= "table" then return "Lookup failed." end
    local message = err.message or "lookup failed"
    return (message:gsub("^%l", string.upper)) .. "."
end

--[[--
@param result table  an `ApiClient:define` result
@param opts   table  { word = string, cached = bool }
@treturn string
--]]--
function Format.result(result, opts)
    opts = opts or {}
    if type(result) ~= "table" then return "" end

    local lines = {}
    local headword = result.word or opts.word
    if headword and headword ~= "" then
        local head = headword
        if result.part_of_speech and result.part_of_speech ~= "" then
            head = head .. "  (" .. result.part_of_speech .. ")"
        end
        lines[#lines + 1] = head
        lines[#lines + 1] = ""
    end

    lines[#lines + 1] = result.definition or ""

    -- `result.translation` is fetched and cached but deliberately not shown:
    -- how a translation should sit next to an English explanation is still an
    -- open question.

    if type(result.examples) == "table" and #result.examples > 0 then
        lines[#lines + 1] = ""
        for _, example in ipairs(result.examples) do
            lines[#lines + 1] = "• " .. example
        end
    end

    local footer = {}
    if result.model and result.model ~= "" then footer[#footer + 1] = result.model end
    if opts.cached then
        footer[#footer + 1] = "cached"
    elseif result.elapsed_ms then
        footer[#footer + 1] = Format.timing(result.elapsed_ms, result.server_ms)
    end
    if #footer > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "— " .. table.concat(footer, " · ")
    end

    return table.concat(lines, "\n")
end

return Format
