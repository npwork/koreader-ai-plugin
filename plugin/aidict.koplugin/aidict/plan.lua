--[[--
What to download: the manifest against what is already on the device.

The whole decision lives here, in a function that takes a `size_of` rather
than touching the filesystem — so "new", "half-downloaded" and "already have
it" are three assertions rather than three trips to a Kindle.
--]]--

local Plan = {}

--[[--
@param entries  table    from `manifest.parse`
@param size_of  function (relative path) -> bytes on the device, or nil
@treturn table  { downloads = { entry, … }, have = n, bytes = n }
--]]--
function Plan.build(entries, size_of)
    local plan = { downloads = {}, have = 0, bytes = 0 }

    for _, entry in ipairs(entries or {}) do
        local local_size = size_of(entry.path)
        -- Size, not existence. A download the Kindle lost Wi-Fi halfway
        -- through leaves a file that exists and is wrong, and "it is already
        -- there" would keep it wrong for ever.
        if local_size == entry.size then
            plan.have = plan.have + 1
        else
            plan.downloads[#plan.downloads + 1] = entry
            plan.bytes = plan.bytes + entry.size
        end
    end

    return plan
end

return Plan
