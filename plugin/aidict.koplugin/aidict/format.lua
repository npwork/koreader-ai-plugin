--[[--
Turns an API result into the text KOReader puts in a TextViewer.
--]]--

local Format = {}

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

    if result.translation and result.translation ~= "" then
        lines[#lines + 1] = ""
        lines[#lines + 1] = result.translation
    end

    if type(result.examples) == "table" and #result.examples > 0 then
        lines[#lines + 1] = ""
        for _, example in ipairs(result.examples) do
            lines[#lines + 1] = "• " .. example
        end
    end

    local footer = {}
    if result.model and result.model ~= "" then footer[#footer + 1] = result.model end
    if opts.cached then footer[#footer + 1] = "cached" end
    if #footer > 0 then
        lines[#lines + 1] = ""
        lines[#lines + 1] = "— " .. table.concat(footer, " · ")
    end

    return table.concat(lines, "\n")
end

return Format
