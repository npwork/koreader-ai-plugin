--[[--
LRU cache with a TTL, for answers that cost a round trip to get.

The clock is injected so the tests can move time without sleeping, and the
whole thing serialises to a plain table so it can be handed to LuaSettings.
--]]--

local Cache = {}
Cache.__index = Cache

--[[--
@param opts table
  max_entries int   entries kept before the least recently used is dropped
  ttl         int   seconds an entry stays fresh; 0 means never expires
  now         func  returns the current time in seconds (defaults to os.time)
--]]--
function Cache.new(opts)
    opts = opts or {}
    return setmetatable({
        max_entries = opts.max_entries or 200,
        ttl = opts.ttl or 0,
        now = opts.now or os.time,
        entries = {},   -- key -> { value = ..., stored_at = ... }
        order = {},     -- keys, least recently used first
    }, Cache)
end

--- Stable cache key. Case and surrounding whitespace do not create new entries.
function Cache.key(...)
    local parts = {}
    for i = 1, select("#", ...) do
        local part = select(i, ...)
        part = tostring(part or ""):lower()
        part = part:gsub("%s+", " "):gsub("^ ", ""):gsub(" $", "")
        parts[#parts + 1] = part
    end
    return table.concat(parts, "\1")
end

local function forget(self, key)
    self.entries[key] = nil
    for i, k in ipairs(self.order) do
        if k == key then
            table.remove(self.order, i)
            break
        end
    end
end

local function touch(self, key)
    for i, k in ipairs(self.order) do
        if k == key then
            table.remove(self.order, i)
            break
        end
    end
    self.order[#self.order + 1] = key
end

local function expired(self, entry)
    return self.ttl > 0 and (self.now() - entry.stored_at) >= self.ttl
end

--- @treturn value, or nil when absent or stale.
function Cache:get(key)
    local entry = self.entries[key]
    if not entry then return nil end
    if expired(self, entry) then
        forget(self, key)
        return nil
    end
    touch(self, key)
    return entry.value
end

function Cache:set(key, value)
    if self.max_entries <= 0 then return end
    if self.entries[key] then
        forget(self, key)
    end
    self.entries[key] = { value = value, stored_at = self.now() }
    self.order[#self.order + 1] = key
    while #self.order > self.max_entries do
        forget(self, self.order[1])
    end
end

function Cache:remove(key)
    forget(self, key)
end

function Cache:clear()
    self.entries = {}
    self.order = {}
end

function Cache:count()
    return #self.order
end

--- Drop every stale entry. Returns how many went.
function Cache:prune()
    local dropped = 0
    local keys = {}
    for i, key in ipairs(self.order) do keys[i] = key end
    for _, key in ipairs(keys) do
        local entry = self.entries[key]
        if entry and expired(self, entry) then
            forget(self, key)
            dropped = dropped + 1
        end
    end
    return dropped
end

--- Serialisable snapshot: plain tables only, safe for LuaSettings.
function Cache:dump()
    local items = {}
    for _, key in ipairs(self.order) do
        local entry = self.entries[key]
        if entry then
            items[#items + 1] = { key = key, value = entry.value, stored_at = entry.stored_at }
        end
    end
    return items
end

--- Rebuild from a `dump()` snapshot, dropping whatever has since expired.
function Cache:restore(items)
    self:clear()
    if type(items) ~= "table" then return end
    for _, item in ipairs(items) do
        if type(item) == "table" and item.key and item.stored_at then
            local entry = { value = item.value, stored_at = item.stored_at }
            if not expired(self, entry) then
                self.entries[item.key] = entry
                self.order[#self.order + 1] = item.key
            end
        end
    end
    while #self.order > self.max_entries do
        forget(self, self.order[1])
    end
end

return Cache
