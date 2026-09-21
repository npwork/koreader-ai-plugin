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

--[[--
Where the gateway's own time went, longest leg first.

Not a fixed set of names: the gateway answers a lookup one of two ways, and
which legs it reports is the record of which one it took. A line that named
three fixed legs would have to lie about the path it did not take.

@param legs table  {{ name = string, ms = number }, ...}
@treturn string  e.g. "examples 1165ms, sense 731ms"
--]]--
function Format.legs(legs)
    if type(legs) ~= "table" then return "" end
    local parts = {}
    for _, leg in ipairs(legs) do
        parts[#parts + 1] = string.format("%s %s", leg.name, Format.duration(leg.ms))
    end
    return table.concat(parts, ", ")
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

--[[--
The word under discussion, marked wherever it appears in an example.

Not a substring search: the examples carry inflected forms ("strap" is
illustrated by "strapped"), and matching loosely enough to catch those would
also light up "fellow" for "fell". So the forms are generated from the
headword by the endings English actually inflects with, and only whole words
that land in that set are marked.

It misses the irregulars — "left" is never reached from "leave" — and a miss
costs nothing but the emphasis. Reaching further would cost a wrong word in
bold, which is worse than a plain one.
--]]--
local SUFFIXES = {
    "", "s", "es", "ed", "d", "ing", "er", "est", "en", "ies", "ied",
}

local function inflections_of(form)
    local forms = {}
    if type(form) ~= "string" or form == "" then return forms end
    form = form:lower()
    forms[form] = true

    local stems = { form }
    local last = form:sub(-1)
    -- The two spelling rules come first: "y" is not a vowel, so left to the
    -- doubling branch it would make "carryy" and never reach "carries".
    if last == "e" then
        -- leave → leaving
        stems[#stems + 1] = form:sub(1, -2)
    elseif last == "y" then
        -- carry → carries, carried
        stems[#stems + 1] = form:sub(1, -2) .. "i"
    elseif last:match("%a") and not last:match("[aeiou]") then
        -- strap → strapped, strapping
        stems[#stems + 1] = form .. last
    end

    for _, stem in ipairs(stems) do
        for _, suffix in ipairs(SUFFIXES) do
            forms[stem .. suffix] = true
        end
    end
    return forms
end

--[[--
The space between the parts, which is what does the separating.

Not one gap repeated: an even rhythm is exactly what makes an entry read as a
single block, however many pieces it has. Lines belonging to the same thought
sit close, and the jump between one thought and the next is large enough to
see without looking for it — the definition and the examples answer different
questions, so the widest gap in the entry is the one between them.

In `em`, like every size here, so the whole entry breathes with whatever text
size the reader has chosen.
--]]--
local GAP = {
    HEADWORD = "0.1em",   -- to the part of speech: the same thought
    OPENING  = "1.0em",   -- the heading block, to the definition
    ANSWER   = "1.8em",   -- the definition, to the evidence for it
    EXAMPLE  = "0.45em",  -- between examples: a list, not a set of paragraphs
    ASIDE    = "1.5em",   -- the examples, to the etymology and the footer
}

-- Control characters stand in for the tags while the text is still raw, so the
-- escaping that follows cannot eat them and cannot be fooled by them.
local OPEN, CLOSE = "\1", "\2"

--[[--
@param text  string  one example sentence, as the model wrote it
@param words table   the headword and the tapped form
@treturn string escaped HTML with the word in bold wherever it stands
--]]--
function Format.highlight(text, words)
    if type(text) ~= "string" then return "" end

    local wanted = {}
    for _, word in ipairs(words or {}) do
        for form in pairs(inflections_of(word)) do wanted[form] = true end
    end
    if not next(wanted) then return Format.escape(text) end

    local marked = text:gsub("[%a']+", function(token)
        if wanted[token:lower()] then return OPEN .. token .. CLOSE end
        return token
    end)

    return (Format.escape(marked)
        :gsub(OPEN, "<b>")
        :gsub(CLOSE, "</b>"))
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
            '<div style="font-size: 1.35em; margin-bottom: ' .. GAP.HEADWORD ..
            '">%s</div>', head
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
                '<div style="font-size: 0.85em; margin-bottom: ' .. GAP.OPENING ..
                '">%s</div>', table.concat(under, " · ")
            )
        end
    end

    -- `result.translation` is fetched and cached but deliberately not shown:
    -- how a translation should sit next to an English explanation is still an
    -- open question.

    if result.definition and result.definition ~= "" then
        -- Slightly larger than everything around it: it is the answer, and
        -- the examples and the etymology are support for it.
        out[#out + 1] = string.format(
            '<div style="font-size: 1.1em; margin-bottom: ' .. GAP.ANSWER ..
            '">%s</div>', Format.escape(result.definition)
        )
    end

    if type(result.examples) == "table" and #result.examples > 0 then
        -- Three sources for what to mark, and they cover different gaps: the
        -- headword and the tapped form are always known, the endings rule
        -- reaches the regular inflections, and the gateway's `forms` reach the
        -- ones no rule does — "went" for "go", "mice" for "mouse".
        local marks = { headword, tapped }
        if type(result.forms) == "table" then
            for _, form in ipairs(result.forms) do marks[#marks + 1] = form end
        end

        local items = {}
        for _, example in ipairs(result.examples) do
            items[#items + 1] = string.format(
                '<li style="margin-bottom: ' .. GAP.EXAMPLE .. '">%s</li>',
                Format.highlight(example, marks)
            )
        end
        out[#out + 1] = string.format(
            '<ol style="margin: 0 0 ' .. GAP.ASIDE .. ' 1.1em; padding: 0">%s</ol>',
            table.concat(items)
        )
    end

    -- Last, and quieter than the rest: where a word came from is worth reading
    -- once and never the thing the reader opened this for.
    if type(result.etymology) == "string" and result.etymology ~= "" then
        out[#out + 1] = string.format(
            '<div style="font-size: 0.85em; margin-bottom: ' .. GAP.ASIDE ..
            '"><i>%s</i></div>', Format.escape(result.etymology)
        )
    end

    local footer = {}
    if result.model and result.model ~= "" then footer[#footer + 1] = result.model end
    -- "cached" says the reader waited for nothing this time; the timings say
    -- what the answer cost when it was actually fetched. Both are worth
    -- knowing and neither replaces the other — showing only the first leaves
    -- no way to tell a lookup that was free because it was prefetched from
    -- one that was free because it was looked up last week.
    if opts.cached then footer[#footer + 1] = "cached" end
    if result.elapsed_ms then
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
