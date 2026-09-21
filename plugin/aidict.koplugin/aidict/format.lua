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
Text from a model, made safe to put inside markup.

Everything shown comes from a language model, which means a definition may
legitimately contain `<`, `>` or `&` — explaining "gt", quoting code, naming
"AT&T". Unescaped, the first of those silently swallows the rest of the entry.
--]]--
function Format.escape(text)
    if text == nil then return "" end
    return (tostring(text)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;"))
end

--- The headword this entry is filed under, and what the reader actually tapped.
local function headwords(result, opts)
    local tapped = result.word or opts.word or ""
    local headword = result.lemma
    if type(headword) ~= "string" or headword == "" then headword = tapped end
    return headword, tapped
end

--[[--
The entry, as HTML for a `TextViewer` opened with `text_format = "html"`.

Markup rather than plain text because the parts have different jobs and a wall
of one typeface makes the reader find them: the headword is what the entry is
about, the part of speech qualifies it, the definition is the answer, and the
examples are evidence for it. Numbered rather than bulleted so that "the second
one" is a thing that can be said.

Sizes are relative, never absolute — the reader has already chosen a comfortable
size for this screen and the entry should move with it, not argue.

@param result table  an `ApiClient:define` result
@param opts   table  { word = string, cached = bool }
@treturn string
--]]--
function Format.result(result, opts)
    opts = opts or {}
    if type(result) ~= "table" then return "" end

    local out = {}
    local headword, tapped = headwords(result, opts)

    if headword ~= "" then
        -- The pronunciation rides on the headword's line, where a dictionary
        -- puts it: it is how to say *this* word, not a fact about it.
        local head = "<b>" .. Format.escape(headword) .. "</b>"
        if type(result.pronunciation) == "string" and result.pronunciation ~= "" then
            head = head .. string.format(
                ' <span style="font-size: 0.7em">%s</span>',
                Format.escape(result.pronunciation)
            )
        end
        out[#out + 1] = string.format(
            '<div style="font-size: 1.35em; margin-bottom: 0.1em">%s</div>', head
        )

        -- The part of speech and the tapped form answer the same question —
        -- "why am I looking at this word?" — so they share a line under it.
        local under = {}
        if result.part_of_speech and result.part_of_speech ~= "" then
            under[#under + 1] = "<i>" .. Format.escape(result.part_of_speech) .. "</i>"
        end
        -- Only worth saying when the entry is filed elsewhere than the reader
        -- tapped: "strap" for "strapped" needs the bridge, "fell" does not.
        if tapped ~= "" and tapped:lower() ~= headword:lower() then
            under[#under + 1] = "as “" .. Format.escape(tapped) .. "”"
        end
        if #under > 0 then
            out[#out + 1] = string.format(
                '<div style="font-size: 0.85em; margin-bottom: 0.9em">%s</div>',
                table.concat(under, " · ")
            )
        end
    end

    -- `result.translation` is fetched and cached but deliberately not shown:
    -- how a translation should sit next to an English explanation is still an
    -- open question.

    if result.definition and result.definition ~= "" then
        out[#out + 1] = string.format(
            '<div style="margin-bottom: 0.9em">%s</div>',
            Format.escape(result.definition)
        )
    end

    if type(result.examples) == "table" and #result.examples > 0 then
        local items = {}
        for _, example in ipairs(result.examples) do
            items[#items + 1] = string.format(
                '<li style="margin-bottom: 0.4em">%s</li>', Format.escape(example)
            )
        end
        out[#out + 1] = string.format(
            '<ol style="margin: 0 0 0.9em 1.1em; padding: 0">%s</ol>',
            table.concat(items)
        )
    end

    -- Last, and quieter than the rest: where a word came from is worth reading
    -- once and never the thing the reader opened this for.
    if type(result.etymology) == "string" and result.etymology ~= "" then
        out[#out + 1] = string.format(
            '<div style="font-size: 0.85em; margin-bottom: 0.9em">' ..
            '<i>%s</i></div>', Format.escape(result.etymology)
        )
    end

    local footer = {}
    if result.model and result.model ~= "" then footer[#footer + 1] = result.model end
    if opts.cached then
        footer[#footer + 1] = "cached"
    elseif result.elapsed_ms then
        footer[#footer + 1] = Format.timing(result.elapsed_ms, result.server_ms)
    end
    if #footer > 0 then
        out[#out + 1] = string.format(
            '<div style="font-size: 0.8em">%s</div>',
            Format.escape(table.concat(footer, " · "))
        )
    end

    return table.concat(out)
end

--- The title bar: the headword, so the top of the entry is a dictionary word.
function Format.title(result, word)
    local headword = headwords(type(result) == "table" and result or {}, { word = word })
    return headword
end

return Format
