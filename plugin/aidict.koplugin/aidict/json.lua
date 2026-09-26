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
