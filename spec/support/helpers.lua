--[[--
Test doubles: a settings store, a clock and a transport, all plain tables.
No KOReader module is ever loaded by the suite.
--]]--

local Settings = require("aidict.settings")

local helpers = {}

--- The endpoint the source deliberately leaves empty — it is baked into the
--- package at build time, so the specs supply their own.
helpers.ENDPOINT = "https://gw.test/koreader-ai"

--- A LuaSettings-shaped store backed by a table.
function helpers.store(initial)
    local data = {}
    for k, v in pairs(initial or {}) do data[k] = v end
    return {
        data = data,
        flushed = 0,
        readSetting = function(self, key) return self.data[key] end,
        saveSetting = function(self, key, value) self.data[key] = value end,
        flush = function(self) self.flushed = self.flushed + 1 end,
    }
end

function helpers.settings(initial)
    return Settings.new(helpers.store(initial))
end

--- A clock the test moves by hand.
function helpers.clock(start)
    local t = start or 1000
    return {
        now = function() return t end,
        advance = function(seconds) t = t + seconds end,
        set = function(seconds) t = seconds end,
    }
end

--[[--
A transport that answers from a queue and records what it was asked.

    local tr = helpers.transport({ { status = 200, body = "{}" } })
    tr.fn -> the function to hand to ApiClient
    tr.requests -> every request it received
--]]--
function helpers.transport(responses)
    local tr = { requests = {}, responses = responses or {}, calls = 0 }
    tr.fn = function(request)
        tr.calls = tr.calls + 1
        tr.requests[#tr.requests + 1] = request
        local answer = tr.responses[tr.calls] or tr.responses[#tr.responses]
        if answer == nil then
            return nil, "no canned response"
        end
        if answer.err then
            return nil, answer.err
        end
        return answer
    end
    return tr
end

--[[--
A filesystem in a table: the four calls `library.lua` asks the device for.

`files` maps an absolute path to its size, so a spec says "this book is here
and half-written" by putting a number in it.
--]]--
function helpers.filesystem(files)
    local fs = { files = {}, dirs = {}, removed = {} }
    for path, size in pairs(files or {}) do fs.files[path] = size end

    fs.size = function(path) return fs.files[path] end
    fs.mkdir = function(path) fs.dirs[path] = true; return true end
    fs.rename = function(from, to)
        if fs.files[from] == nil then return nil, "no such file" end
        fs.files[to] = fs.files[from]
        fs.files[from] = nil
        return true
    end
    fs.remove = function(path)
        if fs.files[path] ~= nil then fs.removed[#fs.removed + 1] = path end
        fs.files[path] = nil
    end
    return fs
end

helpers.json = require("dkjson")

--- A JSON body, as the gateway would send it.
function helpers.body(tbl)
    return helpers.json.encode(tbl)
end

return helpers
