--[[--
One Sync: the steps in turn, and one summary of what each did.

Each step is `{ title, run }`. `run()` returns what to say, then optionally
how many KOReader settings it changed and whether to stop after it:

* nil — the reader dismissed it; nothing more runs, and it says nothing;
* false — nothing to say (a device with nothing for this step);
* text — said under the step's title.

A step that failed says so and the next one still runs: the library being
down is no reason to keep the lookups on the device.
--]]--

local Sync = {}

--- @treturn table `{ text, changed, empty }`
function Sync.run(steps)
    local sections, changed = {}, 0
    for _, step in ipairs(steps) do
        local text, count, stop = step.run()
        if text == nil then break end
        if text then
            sections[#sections + 1] = step.title .. "\n" .. text
            changed = changed + (tonumber(count) or 0)
        end
        if stop then break end
    end
    return { text = table.concat(sections, "\n\n"), changed = changed, empty = #sections == 0 }
end

return Sync
