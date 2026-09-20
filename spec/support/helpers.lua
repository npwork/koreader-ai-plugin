--[[--
Test doubles: a settings store, a clock and a transport, all plain tables.
No KOReader module is ever loaded by the suite.
--]]--

local Settings = require("aidict.settings")

local helpers = {}

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

helpers.json = require("dkjson")

--- A JSON body, as the gateway would send it.
function helpers.body(tbl)
    return helpers.json.encode(tbl)
end

return helpers
