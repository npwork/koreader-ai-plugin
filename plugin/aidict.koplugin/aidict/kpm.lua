--[[--
Driving KPM, the Kindle package manager, from inside the package it installed.

`;kpm install koreader-aidict` in the Kindle's search bar is what a reader
would otherwise type, which means leaving KOReader, waking the home screen and
getting the spelling right. This is the same command, found and read back for
them.

Pure Lua: the caller passes in a way to test for a file and a way to run a
command, so the whole thing is exercised without a Kindle.
--]]--

local Kpm = {}

--[[--
Where KPM's own package puts its binary, one per platform.

Its `install.sh` writes both `kindlepw2` and `kindlehf` and chmods whichever
exist, so a device carries the one it can run. `libkpm.so` sits beside it in
`../lib`, which is why the command sets LD_LIBRARY_PATH rather than trusting
an rpath we did not build.
--]]--
Kpm.CANDIDATES = {
    "/var/local/kmc/kindlehf/bin/kpm",
    "/var/local/kmc/kindlepw2/bin/kpm",
}

--- The first candidate this device actually has, or nil.
-- @param exists function(path) -> boolean
function Kpm.find(exists)
    for _, path in ipairs(Kpm.CANDIDATES) do
        if exists(path) then return path end
    end
    return nil
end

--[[--
The command that updates one package.

`install` rather than `upgrade`: KPM's `upgrade` walks every package the
reader has installed, and a button in this plugin has no business updating
somebody else's. `install` is documented as "(Re)Install/Upgrade one or more
packages", so it does exactly this one.

`-y` because there is nobody at a terminal to answer; stderr is folded into
stdout because that is where KPM's failures are.
--]]--
function Kpm.command(binary, package_id)
    local lib = binary:gsub("/bin/kpm$", "/lib")
    return string.format("LD_LIBRARY_PATH='%s' '%s' -y install '%s' 2>&1",
        lib, binary, package_id)
end

--- The last line with anything in it — what a failure is usually said in.
local function last_line(output)
    local last
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        if line:match("%S") then last = line end
    end
    return last
end

--[[--
What KPM's own words mean.

It says "Installed 1 package(s) succesfully." — with that spelling — so both
are matched rather than betting on the typo surviving a release. An exit
status is not enough on its own: KPM logs its failures and still exits 0 in
cases we cannot enumerate from here, so the text decides and the status only
breaks a tie.
--]]--
function Kpm.interpret(output, ok_status)
    local text = tostring(output or "")
    if text:lower():find("succes?sfully", 1, false) then
        return true, last_line(text)
    end
    local failure = text:match("([^\r\n]*Failed to[^\r\n]*)")
    if failure then return false, failure end
    if ok_status == false then
        return false, last_line(text) or "KPM failed without saying why"
    end
    return false, last_line(text) or "KPM said nothing at all"
end

return Kpm
