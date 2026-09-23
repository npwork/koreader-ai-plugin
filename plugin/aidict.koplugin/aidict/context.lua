--[[--
Text helpers for turning a selection plus its surroundings into the snippet
that gets sent to the API.

Pure Lua, UTF-8 aware enough for the two things that matter: never cutting a
multi-byte character in half, and never sending a runaway page of text.
--]]--

local Context = {}

--- Collapse runs of whitespace (including the soft hyphens and line breaks
--- that come out of a reflowed document) into single spaces.
function Context.cleanup(text)
    if type(text) ~= "string" then return "" end
    text = text:gsub("\194\173", "")          -- soft hyphen
    text = text:gsub("[\r\n\t]", " ")
    text = text:gsub("%s+", " ")
    return (text:gsub("^%s+", ""):gsub("%s+$", ""))
end

--- Number of bytes that make up the UTF-8 sequence starting at `i`.
local function utf8_seq_len(byte)
    if byte < 0x80 then return 1
    elseif byte >= 0xF0 then return 4
    elseif byte >= 0xE0 then return 3
    elseif byte >= 0xC0 then return 2
    end
    return 1 -- continuation byte: treat as its own, callers step past it
end

--- Length of `text` in UTF-8 characters.
function Context.len(text)
    if type(text) ~= "string" then return 0 end
    local n, i = 0, 1
    while i <= #text do
        i = i + utf8_seq_len(text:byte(i))
        n = n + 1
    end
    return n
end

--- Truncate to `max_chars` characters, counting UTF-8 characters rather than
--- bytes. `from_end` keeps the tail instead of the head.
function Context.truncate(text, max_chars, from_end)
    if type(text) ~= "string" or max_chars == nil then return text or "" end
    if max_chars <= 0 then return "" end

    local offsets = { 1 }
    local i = 1
    while i <= #text do
        i = i + utf8_seq_len(text:byte(i))
        offsets[#offsets + 1] = i
    end
    local char_count = #offsets - 1
    if char_count <= max_chars then return text end

    if from_end then
        return text:sub(offsets[char_count - max_chars + 1])
    end
    return text:sub(1, offsets[max_chars + 1] - 1)
end

--- True when the selection is a single word rather than a phrase.
function Context.is_single_word(text)
    text = Context.cleanup(text)
    return text ~= "" and text:find(" ") == nil
end

--[[--
Build the context snippet sent alongside the word.

@string before   text preceding the selection (may be nil)
@string word     the selection itself
@string after    text following the selection (may be nil)
@int max_chars   budget for the whole snippet, in UTF-8 characters
@treturn string  cleaned snippet containing the word, or "" when there is no
                 room or no surrounding text
--]]--
function Context.build(before, word, after, max_chars)
    word = Context.cleanup(word)
    before = Context.cleanup(before)
    after = Context.cleanup(after)
    max_chars = max_chars or 0

    if max_chars <= 0 then return "" end
    if before == "" and after == "" then return "" end

    local word_len = Context.len(word)
    if word_len >= max_chars then
        -- No budget left for surroundings; the word alone is the context.
        return word
    end

    -- Split what is left evenly, then hand any unused half to the other side.
    -- The spaces that will join the three parts come out of the budget too.
    local separators = 0
    if before ~= "" then separators = separators + 1 end
    if after ~= "" then separators = separators + 1 end
    local budget = math.max(0, max_chars - word_len - separators)
    local want = math.floor(budget / 2)
    local before_len = Context.len(before)
    local after_len = Context.len(after)

    local take_before = math.min(before_len, want)
    local take_after = math.min(after_len, budget - take_before)
    take_before = math.min(before_len, budget - take_after)

    local head = Context.truncate(before, take_before, true)
    local tail = Context.truncate(after, take_after, false)

    local parts = {}
    if head ~= "" then parts[#parts + 1] = head end
    if word ~= "" then parts[#parts + 1] = word end
    if tail ~= "" then parts[#parts + 1] = tail end
    return Context.cleanup(table.concat(parts, " "))
end

--[[--
A context window centred on `word` inside `text`.

Used for the sentence KOReader hands back around a selection: the word is
found in the sentence and the budget is spent evenly on either side of it.

@string text      the sentence, or any surrounding passage
@string word      the selection
@int max_chars    budget in UTF-8 characters
@treturn string
--]]--
function Context.snippet(text, word, max_chars)
    text = Context.cleanup(text)
    word = Context.cleanup(word)
    max_chars = max_chars or 0

    if max_chars <= 0 or text == "" then return "" end
    -- A "context" that is only the word itself carries nothing: it happens
    -- when the document cannot produce a sentence and the selection is all
    -- there is. Send no context rather than the word twice.
    if text:lower() == word:lower() then return "" end
    if Context.len(text) <= max_chars then return text end

    local at = word ~= "" and text:lower():find(word:lower(), 1, true) or nil
    if not at then
        return Context.truncate(text, max_chars)
    end

    local before = text:sub(1, at - 1)
    local after = text:sub(at + #word)
    return Context.build(before, text:sub(at, at + #word - 1), after, max_chars)
end

-- Words a full stop follows without ending the sentence. Lower case, without
-- the stop; a single letter (an initial) is handled on its own.
local ABBREVIATIONS = {
    mr = true, mrs = true, ms = true, dr = true, st = true, jr = true, sr = true,
    prof = true, rev = true, gen = true, col = true, capt = true, lt = true,
    vs = true, ["e.g"] = true, ["i.e"] = true, cf = true,
}

--- Byte ranges of the sentences in `text`, in order.
local function sentence_spans(text)
    local spans, start, i = {}, 1, 1
    while i <= #text do
        -- A stop, any closing quotes or brackets after it, then a space.
        local s, e = text:find("[%.!?\226][\128-\191]*[%.!?]*[\"')%]\226\128-\191]*%s", i)
        if not s then break end
        local stop = text:sub(s, s)
        local ends = true
        if stop == "\226" and text:sub(s, s + 2) ~= "\226\128\166" then
            -- A multi-byte character that is not an ellipsis: a quote or a
            -- dash, not the end of anything.
            ends = false
        elseif stop == "." then
            local before = text:sub(start, s - 1):match("([%a%.]+)$") or ""
            if #before == 1 or ABBREVIATIONS[before:lower()] then ends = false end
        end
        if ends then
            spans[#spans + 1] = { start, e - 1 }
            start = e + 1
        end
        i = e + 1
    end
    if start <= #text then spans[#spans + 1] = { start, #text } end
    return spans
end

--- Is `at` the start of `word` standing on its own, not inside a longer one?
local function whole_word(lower, word, at)
    local before = at > 1 and lower:sub(at - 1, at - 1) or " "
    local after = lower:sub(at + #word, at + #word)
    return not before:match("[%w\128-\255]") and not after:match("[%w\128-\255]")
end

--[[--
The sentence in `paragraph` that holds `word`.

KOReader has nothing that returns it: `extendXPointersToSentenceSegment`, the
name that promises it, only stretches a selection over the punctuation around
it, so a tapped word comes back as itself. The paragraph is there already, so
the sentence is cut out of that.

The first sentence where the word stands on its own wins, then the first that
merely contains it. A word met twice in one paragraph may get the wrong one of
the two; the paragraph goes along as the context either way.

@string paragraph  the passage the selection sits in
@string word       the selection
@treturn string    the sentence, or "" when the word is not in the paragraph
--]]--
function Context.sentence(paragraph, word)
    paragraph = Context.cleanup(paragraph)
    word = Context.cleanup(word)
    if paragraph == "" or word == "" then return "" end

    local lower, needle = paragraph:lower(), word:lower()
    local spans = sentence_spans(paragraph)
    local loose
    local at = lower:find(needle, 1, true)
    while at do
        for _, span in ipairs(spans) do
            if at >= span[1] and at <= span[2] then
                local text = Context.cleanup(paragraph:sub(span[1], span[2]))
                if whole_word(lower, needle, at) then return text end
                loose = loose or text
                break
            end
        end
        at = lower:find(needle, at + 1, true)
    end
    return loose or ""
end

return Context
