local socket = require("socket")

local gateway = {}

-- Only luasocket's module-level timeout, which is all the transport uses.
local function install_koreader_stubs()
    package.loaded["logger"] = {
        dbg = function() end,
        info = function() end,
        warn = function() end,
        err = function() end,
    }
    package.loaded["socketutil"] = {
        set_timeout = function(_, block_timeout, total_timeout)
            local http = require("socket.http")
            http.TIMEOUT = block_timeout or 10
            socket.TIMEOUT = total_timeout
        end,
        reset_timeout = function()
            require("socket.http").TIMEOUT = 60
        end,
    }
end

--- @treturn table { url(path) -> string, stop() }
function gateway.start(port)
    install_koreader_stubs()

    local handle = io.popen(
        string.format("python3 spec/support/fake_gateway.py %d >/dev/null 2>&1 & echo $!", port))
    local pid = handle:read("*l")
    handle:close()

    local deadline = os.time() + 15
    while true do
        local probe = socket.tcp()
        probe:settimeout(0.2)
        local ok = probe:connect("127.0.0.1", port)
        probe:close()
        if ok then break end
        if os.time() > deadline then
            error("the fake gateway never came up on port " .. port)
        end
        socket.sleep(0.1)
    end

    return {
        port = port,
        url = function(path)
            return string.format("http://127.0.0.1:%d%s", port, path or "")
        end,
        stop = function()
            if pid then os.execute("kill " .. pid .. " 2>/dev/null") end
        end,
    }
end

return gateway
