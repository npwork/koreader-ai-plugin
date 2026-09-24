--[[--
One Sync: the steps in turn, and one summary of what each did.

Each step is `{ title, run }`. `run()` returns what to say, then optionally
how many KOReader settings it changed and whether to stop after it:

* nil — the reader dismissed it; nothing more runs, and it says nothing;
* false — nothing to say: nothing changed, or nothing here for this step;
* text — said under the step's title.

Only what changed is said; a sync where every step had nothing to say is
`in_sync`.

A step that failed says so and the next one still runs: the library being
down is no reason to keep the lookups on the device.
--]]--

local Sync = {}

--- @treturn table `{ text, changed, empty, in_sync }`
function Sync.run(steps)
    local sections, changed, dismissed = {}, 0, false
    for _, step in ipairs(steps) do
        local text, count, stop = step.run()
        if text == nil then
            dismissed = true
            break
        end
        if text then
            sections[#sections + 1] = step.title .. "\n" .. text
            changed = changed + (tonumber(count) or 0)
        end
        if stop then break end
    end
    return {
        text = table.concat(sections, "\n\n"),
        changed = changed,
        empty = #sections == 0,
        in_sync = #sections == 0 and not dismissed,
    }
end

return Sync
