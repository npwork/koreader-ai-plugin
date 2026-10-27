-- Only the heading changes. The lookup word, cached answer and definition stay English.
local Header = {}

function Header.available(popup)
    local entry = popup.results and popup.results[popup.dict_index]
    return entry ~= nil and entry.aidict == true and type(entry.aidict_translation) == "string"
        and entry.aidict_translation ~= ""
end

function Header.insertButton(rows, button)
    for _, row in ipairs(rows) do
        for _, existing in ipairs(row) do
            if existing.id == button.id then return false end
        end
    end
    local function insert(row, at)
        for _, existing in ipairs(row) do
            if existing.width then
                existing.width = math.max(1, math.floor(existing.width * #row / (#row + 1)))
            end
        end
        table.insert(row, at, button)
        return true
    end
    for _, anchor in ipairs({ "close", "next_dict" }) do
        for _, row in ipairs(rows) do
            for at, existing in ipairs(row) do
                if existing.id == anchor then return insert(row, anchor == "close" and at or at + 1) end
            end
        end
    end
    if #rows == 0 then rows[1] = {} end
    return insert(rows[#rows], #rows[#rows] + 1)
end

function Header.install(popup, invalidate)
    if popup.aidict_header_hook then return false end
    local text = popup.lookup_word_text
    if not (text and type(text.paintTo) == "function" and type(text.getSize) == "function"
        and type(text.setText) == "function" and type(popup.onTap) == "function") then
        return false
    end
    popup.aidict_header_hook = true

    -- TextWidget has no positioned dimen. Record its actual paint coordinates instead
    -- of guessing where the title is (the popup can be moved or resized).
    local area, russian
    local paint = text.paintTo
    text.paintTo = function(this, bb, x, y, ...)
        local size = this:getSize()
        area = { x = x, y = y, w = size.w, h = size.h }
        return paint(this, bb, x, y, ...)
    end

    local function update_button(this)
        local button = this.button_table and this.button_table:getButtonById("aidict_translate")
        if button then button:enableDisable(Header.available(this)) end
    end

    -- KOReader's update restores the English heading on dictionary and font changes.
    local update = popup.update
    if type(update) == "function" then
        popup.update = function(this, ...)
            russian = false
            local result = update(this, ...)
            update_button(this)
            return result
        end
    end

    popup.onAidictTranslate = function(this)
        if not Header.available(this) then return false end
        local entry = this.results[this.dict_index]
        russian = not russian
        text.lang = russian and "ru" or this.lang_in
        text:setText(russian and entry.aidict_translation or entry.word)
        local size = text:getSize()
        -- Clear the old text too without rebuilding the HTML widget or resetting its scroll.
        invalidate(this, area and { x = area.x, y = area.y,
            w = math.max(area.w, size.w), h = math.max(area.h, size.h) } or nil)
        return true
    end

    local function toggle_tap(this, gesture)
        local pos = gesture and gesture.pos
        if area and pos and pos.x >= area.x and pos.x < area.x + area.w
            and pos.y >= area.y and pos.y < area.y + area.h then
            return this:onAidictTranslate()
        end
        return false
    end

    local tap = popup.onTap
    popup.onTap = function(this, arg, gesture)
        if toggle_tap(this, gesture) then return true end
        return tap(this, arg, gesture)
    end

    -- MovableContainer can consume a Gesture before the popup's onTap receives it.
    -- Intercept only taps on our word before propagating through the child widgets.
    local handle = popup.handleEvent
    if type(handle) == "function" then
        popup.handleEvent = function(this, event)
            if event.handler == "onGotoViewRel" and event.args and event.args[1] == -1
                and this:onAidictTranslate() then return true end
            local gesture = event.handler == "onGesture" and event.args and event.args[1]
            if gesture and gesture.ges == "tap" and toggle_tap(this, gesture) then return true end
            return handle(this, event)
        end
    end
    -- showDict normally hasn't painted yet; also handle builds that paint immediately.
    update_button(popup)
    invalidate(popup)
    return true
end

return Header
