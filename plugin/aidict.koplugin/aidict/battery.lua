-- A log of battery readings for Sync to send: what drains the Kindle, lookups or the rest.
-- opts.device() returns what KOReader knows ({ pct, charging, wifi, online, fl }); opts.fs has
-- list(dir) -> names and read(path) -> text|nil, for the kernel's own power_supply figures.

local Battery = {}
Battery.__index = Battery

Battery.KEY = "entries"
Battery.PROBED_KEY = "probed"
Battery.SEQ_KEY = "seq"
-- Sync may be a week away; this is about a week of reading.
Battery.MAX = 1500
-- Readings while reading come from page turns, not a timer, so an idle Kindle is never woken.
Battery.EVERY = 600
Battery.SYSFS = "/sys/class/power_supply"
-- Of each supply's uevent, what a reading keeps; the probe keeps all of it.
Battery.FIELDS = {
    status = true, capacity = true, current_now = true, current_avg = true, voltage_now = true,
    charge_now = true, charge_counter = true, charge_full = true, energy_now = true, power_now = true,
    temp = true, cycle_count = true, online = true,
}

function Battery.new(opts)
    assert(opts and opts.store, "Battery needs a store")
    return setmetatable({
        store = opts.store,
        device = opts.device or function() return {} end,
        fs = opts.fs,
        now = opts.now or os.time,
        pages = 0,
    }, Battery)
end

local function uevent(text, keep)
    local fields = {}
    for key, value in tostring(text or ""):gmatch("POWER_SUPPLY_([%w_]+)=([^\n]*)") do
        key = key:lower()
        if not keep or keep[key] then fields[key] = tonumber(value) or value end
    end
    return fields
end

-- { [supply] = fields }, or nil where the kernel exposes none.
function Battery:supplies(keep)
    if not self.fs then return nil end
    local ok, names = pcall(self.fs.list, Battery.SYSFS)
    if not ok or type(names) ~= "table" then return nil end
    local found
    for _, name in ipairs(names) do
        local read, text = pcall(self.fs.read, Battery.SYSFS .. "/" .. name .. "/uevent")
        if read and text then
            local fields = uevent(text, keep)
            if next(fields) ~= nil then
                found = found or {}
                found[name] = fields
            end
        end
    end
    return found
end

-- The first supply's current_now, raw (the kernel's unit, usually µA), or nil.
function Battery:current()
    local supplies = self:supplies({ current_now = true })
    if not supplies then return nil end
    local names = {}
    for name in pairs(supplies) do names[#names + 1] = name end
    table.sort(names)
    for _, name in ipairs(names) do
        local value = supplies[name].current_now
        if type(value) == "number" then return value end
    end
    return nil
end

function Battery:entries()
    local list = self.store:readSetting(Battery.KEY)
    if type(list) ~= "table" then list = {} end
    return list
end

function Battery:record(event, extra)
    local ok, known = pcall(self.device)
    local n = (tonumber(self.store:readSetting(Battery.SEQ_KEY)) or 0) + 1
    self.store:saveSetting(Battery.SEQ_KEY, n)
    local entry = { n = n, at = self.now(), event = event, pages = self.pages }
    if ok and type(known) == "table" then
        for key, value in pairs(known) do entry[key] = value end
    end
    entry.ps = self:supplies(Battery.FIELDS)
    for key, value in pairs(extra or {}) do entry[key] = value end
    self.pages = 0
    self.last_at = entry.at

    local list = self:entries()
    list[#list + 1] = entry
    while #list > Battery.MAX do table.remove(list, 1) end
    self.store:saveSetting(Battery.KEY, list)
    return entry
end

-- Per page turn: counts it, and records a reading once EVERY seconds have gone by.
function Battery:turned()
    self.pages = self.pages + 1
    local now = self.now()
    if self.last_at == nil then self.last_at = now end
    if now - self.last_at >= Battery.EVERY then return self:record("reading") end
    return nil
end

-- Once per plugin version: everything each supply reports, to learn what this Kindle has.
function Battery:probe(version)
    if self.store:readSetting(Battery.PROBED_KEY) == version then return nil end
    self.store:saveSetting(Battery.PROBED_KEY, version)
    return self:record("probe", { ps = self:supplies() or false })
end

-- Copies, so what is recorded while Sync is on its way is kept for the next one.
function Battery:pending()
    local copy = {}
    for i, entry in ipairs(self:entries()) do copy[i] = entry end
    return copy
end

function Battery:delivered(sent)
    if type(sent) ~= "table" or #sent == 0 then return 0 end
    local through = tonumber(sent[#sent].n) or 0
    local left, dropped = {}, 0
    for _, entry in ipairs(self:entries()) do
        if (tonumber(entry.n) or 0) > through then left[#left + 1] = entry else dropped = dropped + 1 end
    end
    self.store:saveSetting(Battery.KEY, left)
    return dropped
end

-- Mean and peak of the current readings taken while a lookup ran.
function Battery.draw(readings)
    if type(readings) ~= "table" or #readings == 0 then return nil end
    local sum, peak = 0, readings[1]
    for _, value in ipairs(readings) do
        sum = sum + value
        if math.abs(value) > math.abs(peak) then peak = value end
    end
    return { mean = math.floor(sum / #readings + 0.5), peak = peak, n = #readings }
end

return Battery
