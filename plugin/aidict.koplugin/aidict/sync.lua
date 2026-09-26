-- run() returns text to say, false when there is nothing to say, or nil when dismissed (nothing
-- more runs); then optionally the settings changed and whether to stop. A failed step does not stop the rest.

local Sync = {}

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
