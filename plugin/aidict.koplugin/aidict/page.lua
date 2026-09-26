local ApiClient = require("aidict.apiclient")
local Format = require("aidict.format")
local Prefetch = require("aidict.prefetch")

local Page = {}

Page.DICT = "AI"

-- Seconds: five times the usual wait, far less than the 30 the HTTP timeouts allow on a bad hotspot.
Page.PATIENCE = 10

function Page.gave_up()
    return {
        ok = false,
        err = {
            code = ApiClient.ERRORS.TIMEOUT,
            message = "no answer in " .. Page.PATIENCE .. " seconds",
        },
    }
end

-- opts: cached answer, fresh (asked for this very lookup), wanted (a request is on its way),
-- why (Prefetch:wanted's reason). Nil means no page at all.
function Page.opening(opts)
    opts = opts or {}
    if opts.cached then
        -- An answer that beat the dictionary to the screen was still asked now: not "cached".
        return { kind = "answer", result = opts.cached, source = not opts.fresh and "cached" or nil }
    end
    if opts.wanted or opts.why == Prefetch.SKIP.IN_FLIGHT then
        return { kind = "asking" }
    end
    if opts.why == Prefetch.SKIP.BUSY then
        return { kind = "busy" }
    end
    -- Offline, not configured, nothing to look up: the popup is the ordinary dictionary.
    return nil
end

function Page.landed(outcome)
    if type(outcome) == "table" and outcome.ok and type(outcome.result) == "table" then
        return { kind = "answer", result = outcome.result }
    end
    return { kind = "failed", err = type(outcome) == "table" and outcome.err or nil }
end

local function note(text)
    return '<div style="font-style: italic">' .. Format.escape(text) .. "</div>"
end

-- `aidict = true` marks it as ours, to find it among the results when the answer arrives.
function Page.entry(word, state)
    local definition
    -- Once answered, the header is the dictionary form, with "as “reading”" under it for what was tapped.
    local header = word
    if state.kind == "answer" then
        header = Format.title(state.result, word)
        definition = Format.result(state.result, { word = word, source = state.source, shown = header })
    elseif state.kind == "asking" then
        definition = note("Asking AI about “" .. word .. "”…")
    elseif state.kind == "busy" then
        definition = note("Still answering the words before this one. Look it up again in a moment.")
    else
        definition = note(Format.error(state.err, "The lookup failed."))
    end
    return {
        dict = Page.DICT,
        word = header,
        definition = definition,
        is_html = true,
        aidict = true,
    }
end

-- The AI page already names the word in its header; other dictionaries' pages keep the line.
function Page.wants_query_line(results)
    return Page.index_in(results) ~= 1
end

-- The first dictionary behind a failed AI page; nil when the AI page is all there is.
function Page.instead(results, index)
    if type(results) ~= "table" or type(index) ~= "number" then return nil end
    for i = index + 1, #results do
        if type(results[i]) == "table" and not results[i].aidict then return i end
    end
    return nil
end

function Page.index_in(results)
    if type(results) ~= "table" then return nil end
    for index, entry in ipairs(results) do
        if type(entry) == "table" and entry.aidict then return index end
    end
    return nil
end

return Page
