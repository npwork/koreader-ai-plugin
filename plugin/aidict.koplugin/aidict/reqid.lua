-- Minted on the device, so a request that never arrived can still be matched to the gateway's log.
-- The gateway keeps a client id only if it matches [A-Za-z0-9._-]{1,64}.

local Reqid = {}

local NOISE_MAX = 0xffffff

function Reqid.generate(now, random)
    local seconds = math.floor(tonumber(now) or 0) % 0x100000000
    local noise = 0
    if type(random) == "function" then
        -- The range must be passed: math.random() alone returns a fraction that floors to zero.
        local value = tonumber(random(0, NOISE_MAX)) or 0
        if value > 0 and value < 1 then value = value * (NOISE_MAX + 1) end
        noise = math.floor(value) % (NOISE_MAX + 1)
    end
    return string.format("aidict-%08x-%06x", seconds, noise)
end

return Reqid
