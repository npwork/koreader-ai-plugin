local Kpm = {}

-- KPM's install.sh writes both; libkpm.so sits in ../lib, hence LD_LIBRARY_PATH, not an rpath.
Kpm.CANDIDATES = {
    "/var/local/kmc/kindlehf/bin/kpm",
    "/var/local/kmc/kindlepw2/bin/kpm",
}

function Kpm.find(exists)
    for _, path in ipairs(Kpm.CANDIDATES) do
        if exists(path) then return path end
    end
    return nil
end

-- `install`, not `upgrade`: upgrade walks every installed package. stderr is folded in because
-- that is where KPM's failures are.
function Kpm.command(binary, package_id)
    local lib = binary:gsub("/bin/kpm$", "/lib")
    return string.format("LD_LIBRARY_PATH='%s' '%s' -y install '%s' 2>&1",
        lib, binary, package_id)
end

local function last_line(output)
    local last
    for line in tostring(output or ""):gmatch("[^\r\n]+") do
        if line:match("%S") then last = line end
    end
    return last
end

-- KPM writes "succesfully", so both spellings match. The text decides: KPM can log a failure and
-- still exit 0, so the status only breaks a tie.
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
