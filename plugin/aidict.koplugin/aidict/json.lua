--[[--
The JSON codec the plugin uses, as an `{ encode, decode }` pair.

KOReader ships rapidjson (fast, C) and a pure-Lua fallback; the tests pass
their own codec instead, which is why every other module takes one as an
argument rather than requiring this file.
--]]--

local ok, rapidjson = pcall(require, "rapidjson")
if ok and rapidjson and rapidjson.encode then
    return {
        encode = function(value) return rapidjson.encode(value) end,
        decode = function(text) return rapidjson.decode(text) end,
    }
end

local JSON = require("json")
return {
    encode = function(value) return JSON.encode(value) end,
    decode = function(text) return JSON.decode(text) end,
}
