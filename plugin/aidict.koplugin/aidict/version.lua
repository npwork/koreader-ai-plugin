--[[--
Single source of truth for the plugin version.

`scripts/kpmrepo.py` reads this file to name the .kpkg and to fill the KPM
manifest, so the number here is the number that ships.
--]]--

return {
    string = "0.1.0",
    -- KPM stores versions as a [major, minor, patch] triple.
    major = 0,
    minor = 1,
    patch = 0,
}
