--[[--
The AI's page in KOReader's dictionary popup.

The popup is a stack of results, one per dictionary, that the reader pages
through. The AI answer goes in as the first of them, so tapping a word shows
it straight away and the ordinary dictionaries are one page further on. It is
there before the answer is: the page says it is asking, and is filled in when
the answer lands, or says why there is none.

This module decides what the page says. Putting it into the popup, and
refreshing it, is `main.lua`'s job.
--]]--

local Format = require("aidict.format")
local Prefetch = require("aidict.prefetch")

local Page = {}

--- What the popup shows as the page's dictionary name.
Page.DICT = "AI"

--[[--
What the page says when the popup opens, from what the lookup found.

@param opts table
  cached  table|nil  an answer already in the cache
  fresh   bool       the cached answer was asked for this very lookup
  wanted  bool       whether a request is (now) on its way
  why     string|nil `Prefetch:wanted`'s reason when it is not
@treturn table|nil the state, or nil for no page at all
--]]--
function Page.opening(opts)
    opts = opts or {}
    if opts.cached then
        -- "cached" means the reader waited for nothing because it was asked
        -- some other time. An answer that beat the dictionary to the screen
        -- was still asked now, and saying "cached" under it would hide that.
        return { kind = "answer", result = opts.cached, source = not opts.fresh and "cached" or nil }
    end
    if opts.wanted or opts.why == Prefetch.SKIP.IN_FLIGHT then
        return { kind = "asking" }
    end
    if opts.why == Prefetch.SKIP.BUSY then
        return { kind = "busy" }
    end
    -- Offline, not configured, nothing to look up: the popup is the ordinary
    -- dictionary, exactly as it was before this plugin put anything in it.
    return nil
end

--- What the page says once the request comes back, from its outcome.
function Page.landed(outcome)
    if type(outcome) == "table" and outcome.ok and type(outcome.result) == "table" then
        return { kind = "answer", result = outcome.result }
    end
    return { kind = "failed", err = type(outcome) == "table" and outcome.err or nil }
end

local function note(text)
    return '<div style="font-style: italic">' .. Format.escape(text) .. "</div>"
end

--[[--
The page itself, in the shape KOReader's dictionary results take.

`aidict` marks it as ours, so it can be found again among the others when the
answer arrives.

@param word  string the word the popup was opened for
@param state table  from `opening` or `landed`
@treturn table
--]]--
function Page.entry(word, state)
    local definition
    -- The popup's header is the entry's `word`. Once there is an answer it
    -- is the dictionary form, as a dictionary's header is: "read" over the
    -- entry, with "as “reading”" under it saying what was tapped. Before,
    -- the header said "reading" and the entry said "read" again below it.
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

--[[--
Whether KOReader should add its "(query : word)" line to the page on top.

KOReader appends the tapped word to whichever page opens the popup, so the
reader can see what was selected. The AI page already says it — the header
and "as “reading”" under it — and the line landed under the footer, repeating
the word a third time. Other dictionaries' pages keep it.
--]]--
function Page.wants_query_line(results)
    return Page.index_in(results) ~= 1
end

--- Where the AI page sits in a popup's results, if it has one.
function Page.index_in(results)
    if type(results) ~= "table" then return nil end
    for index, entry in ipairs(results) do
        if type(entry) == "table" and entry.aidict then return index end
    end
    return nil
end

return Page
