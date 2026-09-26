local Format = {}

function Format.duration(ms)
    ms = tonumber(ms)
    if not ms then return "" end
    if ms < 1000 then return string.format("%dms", math.floor(ms + 0.5)) end
    return string.format("%.1fs", ms / 1000)
end

-- TCP connect, TLS 1.3 and the request: the round trips a fresh lookup flies.
local FLIGHT_ROUND_TRIPS = 3
-- Below this the remainder is clock skew and rounding, not something to chase.
local MIN_REST_MS = 300

-- Device and gateway times are shown, not their difference: that gap is Wi-Fi, DNS, TLS and
-- Cloudflare off two clocks. What is left after three edge round trips shows as "~ elsewhere"
-- only when large enough to read. edge_rtt_ms is the edge's measure of the Kindle's TCP RTT.
function Format.timing(elapsed_ms, server_ms, edge_rtt_ms)
    local total = Format.duration(elapsed_ms)
    if total == "" then return "" end

    local text = total
    local server = Format.duration(server_ms)
    if server ~= "" then text = total .. " total · " .. server .. " server" end

    local rtt = tonumber(edge_rtt_ms)
    if rtt then
        text = text .. string.format(" · %d ms to edge", math.floor(rtt + 0.5))
        local elapsed, spent = tonumber(elapsed_ms), tonumber(server_ms)
        if spent then
            local rest = elapsed - spent - FLIGHT_ROUND_TRIPS * rtt
            if rest >= MIN_REST_MS then text = text .. " · ~" .. Format.duration(rest) .. " elsewhere" end
        end
    end
    return text
end

-- Not a fixed set of names: which legs the gateway reports records which path it took.
function Format.legs(legs)
    if type(legs) ~= "table" then return "" end
    local parts = {}
    for _, leg in ipairs(legs) do
        parts[#parts + 1] = string.format("%s %s", leg.name, Format.duration(leg.ms))
    end
    return table.concat(parts, ", ")
end

-- `fallback` names what failed, for when there is no err to read.
function Format.error(err, fallback)
    if type(err) ~= "table" then return fallback or "Something went wrong." end
    local message = err.message or "it failed"
    return (message:gsub("^%l", string.upper)) .. "."
end

-- Model text may contain `<`, `>` or `&`; unescaped, the first swallows the rest of the entry.
function Format.escape(text)
    if text == nil then return "" end
    return (tostring(text)
        :gsub("&", "&amp;")
        :gsub("<", "&lt;")
        :gsub(">", "&gt;"))
end

-- Regular endings only, matched as whole words: a looser match would light up "fellow" for
-- "fell". Irregulars are missed, which costs only the emphasis.
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

-- Uneven on purpose: an even rhythm reads as one block. In em, so the entry follows the
-- reader's text size.
local GAP = {
    HEADWORD = "0.1em",   -- to the part of speech: the same thought
    OPENING  = "1.0em",   -- the heading block, to the definition
    ANSWER   = "1.8em",   -- the definition, to the evidence for it
    EXAMPLE  = "0.45em",  -- between examples: a list, not a set of paragraphs
    ASIDE    = "1.5em",   -- the examples, to the etymology
    FOOTER   = "3em",     -- the entry, to the model and timings under it
}

-- Placeholders a dictionary writes in a phrase ("make up one's mind") and the articles:
-- marking them would mark nothing, or every one in the sentence.
local STAND_INS = {
    someone = true, somebody = true, something = true, ["one's"] = true,
    ["someone's"] = true, oneself = true, one = true, sb = true, sth = true,
    a = true, an = true, the = true,
}

-- Control characters stand in for the tags while the text is still raw, so the
-- escaping that follows cannot eat them and cannot be fooled by them.
local OPEN, CLOSE = "\1", "\2"

function Format.highlight(text, words)
    if type(text) ~= "string" then return "" end

    local wanted = {}
    for _, word in ipairs(words or {}) do
        -- A phrase is marked word by word, only its first word inflected (the endings rule
        -- would make "offer" of "of"), stand-ins left out. A hyphenated word stays whole.
        local parts = {}
        for part in tostring(word):gmatch("%S+") do parts[#parts + 1] = part end
        if #parts == 1 then
            for form in pairs(inflections_of(parts[1])) do wanted[form] = true end
        else
            for i, part in ipairs(parts) do
                local lower = part:lower()
                if i == 1 then
                    for form in pairs(inflections_of(part)) do wanted[form] = true end
                elseif not STAND_INS[lower] then
                    wanted[lower] = true
                end
            end
        end
    end
    if not next(wanted) then return Format.escape(text) end

    local function mark(token)
        if wanted[token:lower()] then return OPEN .. token .. CLOSE end
        return token
    end
    -- A hyphenated token is marked whole when it is the word itself, else
    -- word by word: "star" still lights up in "star-studded".
    local marked = text:gsub("[%a'%-]+", function(token)
        if wanted[token:lower()] then return OPEN .. token .. CLOSE end
        return (token:gsub("[%a']+", mark))
    end)

    return (Format.escape(marked)
        :gsub(OPEN, "<b>")
        :gsub(CLOSE, "</b>"))
end

local function headwords(result, opts)
    local tapped = result.word or opts.word or ""
    local headword = result.lemma
    if type(headword) ~= "string" or headword == "" then headword = tapped end
    return headword, tapped
end

-- `opts.shown` is a word the window already displays above the entry: a headword that only
-- repeats it is left out, and its pronunciation moves to the part-of-speech line.
function Format.result(result, opts)
    opts = opts or {}
    if type(result) ~= "table" then return "" end

    local out = {}
    local headword, tapped = headwords(result, opts)
    local repeats = type(opts.shown) == "string" and opts.shown ~= ""
        and headword:lower() == opts.shown:lower()
    local pronunciation = type(result.pronunciation) == "string" and result.pronunciation ~= ""
        and Format.escape(result.pronunciation) or nil

    if headword ~= "" and not repeats then
        local head = "<b>" .. Format.escape(headword) .. "</b>"
        if pronunciation then
            head = head .. string.format(' <span style="font-size: 0.7em">%s</span>', pronunciation)
        end
        out[#out + 1] = string.format(
            '<div style="font-size: 1.35em; margin-bottom: ' .. GAP.HEADWORD ..
            '">%s</div>', head
        )
    end

    local under = {}
    if repeats and pronunciation then under[#under + 1] = pronunciation end
    if result.part_of_speech and result.part_of_speech ~= "" then
        under[#under + 1] = "<i>" .. Format.escape(result.part_of_speech) .. "</i>"
    end
    -- Only when filed elsewhere than tapped: "strap" for "strapped".
    if headword ~= "" and tapped ~= "" and tapped:lower() ~= headword:lower() then
        under[#under + 1] = "as “" .. Format.escape(tapped) .. "”"
    end
    if #under > 0 then
        out[#out + 1] = string.format(
            '<div style="font-size: 0.85em; margin-bottom: ' .. GAP.OPENING ..
            '">%s</div>', table.concat(under, " · ")
        )
    end

    -- `result.translation` is cached but deliberately not shown: where it belongs is undecided.

    if result.definition and result.definition ~= "" then
        out[#out + 1] = string.format(
            '<div style="font-size: 1.1em; margin-bottom: ' .. GAP.ANSWER ..
            '">%s</div>', Format.escape(result.definition)
        )
    end

    if type(result.examples) == "table" and #result.examples > 0 then
        -- The gateway's `forms` reach what no rule does: "went" for "go".
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

    -- Labelled and in roman: unlabelled it passes for another example, and italics read poorly at length.
    if type(result.etymology) == "string" and result.etymology ~= "" then
        out[#out + 1] = string.format(
            '<div style="font-size: 0.85em; margin-bottom: ' .. GAP.ASIDE ..
            '"><span style="font-size: 0.8em">ORIGIN</span> %s</div>', Format.escape(result.etymology)
        )
    end

    local footer = {}
    if result.model and result.model ~= "" then footer[#footer + 1] = result.model end
    -- "prefetch" is not "cached": it was already on its way, so the wait was shorter than the timings say.
    if opts.source == "cached" or opts.source == "prefetch" then
        footer[#footer + 1] = opts.source
    end
    if result.elapsed_ms then
        footer[#footer + 1] = Format.timing(result.elapsed_ms, result.server_ms, result.edge_rtt_ms)
    end
    if #footer > 0 then
        out[#out + 1] = string.format(
            '<div style="font-size: 0.65em; margin-top: ' .. GAP.FOOTER .. '">%s</div>',
            Format.escape(table.concat(footer, " · "))
        )
    end

    return table.concat(out)
end

function Format.title(result, word)
    local headword = headwords(type(result) == "table" and result or {}, { word = word })
    return headword
end

return Format
