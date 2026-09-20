--[[--
An id for one lookup, so the line in `koreader.log` and the line in the
gateway's log can be put side by side afterwards.

The device mints it rather than the gateway, because a request that never
arrives is exactly the one worth correlating: the gateway may have answered
while the Kindle had already given up, and only the device's id ties the two
halves together.

Short on purpose — it is read off an e-ink screen or a log on a device with
no scrollback. The gateway keeps a client-sent id only if it matches
`[A-Za-z0-9._-]{1,64}`, which this always does.
--]]--

local Reqid = {}

--[[--
@param now    number seconds since the epoch (os.time)
@param random func   called as random(0, max) — math.random fits
@treturn string e.g. "aidict-68ce5f3a-9c41f2"
--]]--
local NOISE_MAX = 0xffffff

function Reqid.generate(now, random)
    local seconds = math.floor(tonumber(now) or 0) % 0x100000000
    local noise = 0
    if type(random) == "function" then
        -- The range has to be passed: math.random() with no arguments answers
        -- a fraction below 1, which floors to zero and makes every id in the
        -- same second identical.
        local value = tonumber(random(0, NOISE_MAX)) or 0
        if value > 0 and value < 1 then value = value * (NOISE_MAX + 1) end
        noise = math.floor(value) % (NOISE_MAX + 1)
    end
    return string.format("aidict-%08x-%06x", seconds, noise)
end

return Reqid
