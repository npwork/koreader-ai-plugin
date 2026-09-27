local Battery = require("aidict.battery")
local helpers = require("support.helpers")

local UEVENT = table.concat({
    "POWER_SUPPLY_NAME=bd71827_bat",
    "POWER_SUPPLY_STATUS=Discharging",
    "POWER_SUPPLY_CAPACITY=81",
    "POWER_SUPPLY_CURRENT_NOW=-45000",
    "POWER_SUPPLY_VOLTAGE_NOW=3950000",
    "POWER_SUPPLY_MODEL_NAME=whatever",
}, "\n")

local function fs(files)
    return {
        list = function()
            local names = {}
            for path in pairs(files) do names[#names + 1] = path:match("power_supply/([^/]+)/") end
            table.sort(names)
            return names
        end,
        read = function(path) return files[path] end,
    }
end

local function battery(opts)
    opts = opts or {}
    local clock = opts.clock or helpers.clock(1000)
    local b = Battery.new({
        store = opts.store or helpers.store(),
        now = clock.now,
        device = opts.device or function() return { pct = 81, charging = false, wifi = true } end,
        fs = opts.fs,
    })
    return b, clock
end

describe("battery", function()
    it("records what the device knows, with the event and time", function()
        local b = battery()
        local entry = b:record("resume")
        assert.are.equal("resume", entry.event)
        assert.are.equal(1000, entry.at)
        assert.are.equal(81, entry.pct)
        assert.is_true(entry.wifi)
        assert.are.same({ entry }, b:pending())
    end)

    it("keeps the kernel's figures it cares about, as numbers", function()
        local b = battery({ fs = fs({ ["/sys/class/power_supply/bd71827_bat/uevent"] = UEVENT }) })
        local entry = b:record("resume")
        assert.are.same({
            status = "Discharging", capacity = 81, current_now = -45000, voltage_now = 3950000,
        }, entry.ps.bd71827_bat)
        assert.are.equal(-45000, b:current())
    end)

    it("does without the kernel's figures where it has none", function()
        local b = battery({ fs = { list = function() error("no such dir") end, read = function() end } })
        assert.is_nil(b:record("resume").ps)
        assert.is_nil(b:current())
    end)

    it("still records when the device cannot be asked", function()
        local b = battery({ device = function() error("no powerd") end })
        assert.are.equal("suspend", b:record("suspend").event)
    end)

    it("lets extra fields through", function()
        local entry = battery():record("lookup", { ms = 2100, ok = true })
        assert.are.equal(2100, entry.ms)
        assert.is_true(entry.ok)
    end)

    it("counts page turns and records a reading every ten minutes of them", function()
        local b, clock = battery()
        b:record("resume")
        clock.advance(Battery.EVERY - 1)
        assert.is_nil(b:turned())
        clock.advance(1)
        local entry = b:turned()
        assert.are.equal("reading", entry.event)
        assert.are.equal(2, entry.pages)
        assert.are.equal(0, b:record("suspend").pages)
    end)

    it("keeps only the newest entries", function()
        local b = battery()
        for _ = 1, Battery.MAX + 3 do b:record("reading") end
        local list = b:pending()
        assert.are.equal(Battery.MAX, #list)
        assert.are.equal(4, list[1].n)
    end)

    it("drops what Sync delivered and keeps what came after", function()
        local b = battery()
        b:record("resume")
        b:record("reading")
        local sent = b:pending()
        b:record("suspend")
        assert.are.equal(2, b:delivered(sent))
        local left = b:pending()
        assert.are.equal(1, #left)
        assert.are.equal("suspend", left[1].event)
        assert.are.equal(0, b:delivered({}))
    end)

    it("numbers entries on across instances sharing a store", function()
        local store = helpers.store()
        battery({ store = store }):record("resume")
        assert.are.equal(2, battery({ store = store }):record("suspend").n)
    end)

    it("probes the whole uevent once per plugin version", function()
        local b = battery({ fs = fs({ ["/sys/class/power_supply/bd71827_bat/uevent"] = UEVENT }) })
        local entry = b:probe("0.3.1")
        assert.are.equal("probe", entry.event)
        assert.are.equal("whatever", entry.ps.bd71827_bat.model_name)
        assert.is_nil(b:probe("0.3.1"))
        assert.is_not_nil(b:probe("0.3.2"))
    end)

    it("writes the file only when something was recorded since the last write", function()
        local store = helpers.store()
        local b = battery({ store = store })
        assert.is_false(b:save())
        b:record("resume")
        assert.is_true(b:save())
        assert.is_false(b:save())
        assert.are.equal(1, store.flushed)
    end)

    it("sums up the current drawn during a lookup", function()
        assert.are.same({ mean = -150, peak = -250, n = 3 }, Battery.draw({ -100, -250, -100 }))
        assert.is_nil(Battery.draw({}))
    end)
end)
