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
How long it took, measured twice.

A single number cannot be acted on: three seconds of radio and three seconds
of model look identical on the screen and want opposite fixes. So both are
shown — what the device stopwatched from sending the request to holding the
response, and what the gateway says it spent inside its own handler.

Deliberately two measurements and not three: the gap between them is not one
thing. It is the Wi-Fi waking, DNS, the handshake, Cloudflare and the flight
each way, taken off two different clocks on two different machines. Naming it
"network" would be a claim neither number supports; a reader who wants it can
subtract, knowing what they have subtracted.

@param elapsed_ms number  the whole round trip, as the device measured it
@param server_ms  number  what the gateway says it spent, when it says
@treturn string
--]]--
function Format.timing(elapsed_ms, server_ms)
    local total = Format.duration(elapsed_ms)
    if total == "" then return "" end

    local server = Format.duration(server_ms)
    if server == "" then return total end

    return total .. " total · " .. server .. " server"
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
