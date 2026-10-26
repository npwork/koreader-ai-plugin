-- Only the heading changes. The lookup word, cached answer and definition stay English.
local Header = {}

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

    -- KOReader's update restores the English heading on dictionary changes and font
    -- changes. Keep our display state in step, without changing that behaviour.
    local update = popup.update
    if type(update) == "function" then
        popup.update = function(this, ...)
            russian = false
            return update(this, ...)
        end
    end

    local function toggle(this, gesture)
        local entry = this.results and this.results[this.dict_index]
        local translation = entry and entry.aidict_translation
        local pos = gesture and gesture.pos
        if entry and entry.aidict and type(translation) == "string" and translation ~= ""
            and area and pos and pos.x >= area.x and pos.x < area.x + area.w
            and pos.y >= area.y and pos.y < area.y + area.h then
            russian = not russian
            text.lang = russian and "ru" or this.lang_in
            text:setText(russian and translation or entry.word)
            local size = text:getSize()
            -- Clear the old text too when the replacement is shorter. This refresh
            -- does not rebuild the HTML widget or reset its scroll position.
            invalidate(this, { x = area.x, y = area.y,
                w = math.max(area.w, size.w), h = math.max(area.h, size.h) })
            return true
        end
        return false
    end

    local tap = popup.onTap
    popup.onTap = function(this, arg, gesture)
        if toggle(this, gesture) then return true end
        return tap(this, arg, gesture)
    end

    -- MovableContainer can consume a Gesture before the popup's onTap receives it.
    -- Intercept only taps on our word before propagating through the child widgets.
    local handle = popup.handleEvent
    if type(handle) == "function" then
        popup.handleEvent = function(this, event)
            local gesture = event.handler == "onGesture" and event.args and event.args[1]
            if gesture and gesture.ges == "tap" and toggle(this, gesture) then return true end
            return handle(this, event)
        end
    end
    -- showDict normally hasn't painted yet; also handle builds that paint immediately.
    invalidate(popup)
    return true
end

return Header
