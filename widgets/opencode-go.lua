-- name = "OpenCode Go"
-- description = "Live rolling, weekly and monthly Go quota, with reset countdowns"
-- icon = "gauge"
-- type = "widget"
-- version = "1.4.2"
-- aio_version = "7.6.0"
-- foldable = "true"
-- on_resume_when_folding = "true"
-- data_source = "https://opencode.ai/zen/go/v1/usage"

local json = require "json"
local prefs = require "prefs"
local ENDPOINT = "https://opencode.ai/zen/go/v1/usage"
local CACHE_FILE = "opencode-go-usage.json"
local KEY_IMPORT = "opencode-go-key.txt"
local WINDOWS = {{"rolling", "Rolling"}, {"weekly", "Weekly"}, {"monthly", "Monthly"}}
local GREEN, AMBER, RED, MUTED = "#7BD99A", "#EDBD65", "#F08080", "#999999"
local state, loaded, loading, requested_at, last_attempt, request_key, message, dialog
local actions = {}
local last_layout
local last_handedness
local render, refresh

local function trim(text)
    return tostring(text or ""):match("^%s*(.-)%s*$")
end

-- Convert RFC 3339 to epoch seconds without depending on the phone's timezone.
local function timestamp(value)
    if type(value) ~= "string" then return nil end
    local y, m, d, h, mi, s, zone = value:match("^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)(.*)$")
    if not y then return nil end
    y, m, d, h, mi, s = tonumber(y), tonumber(m), tonumber(d), tonumber(h), tonumber(mi), tonumber(s)
    if m < 1 or m > 12 or d < 1 or d > 31 or h > 23 or mi > 59 or s > 59 then return nil end
    zone = zone:gsub("^%.%d+", "")
    local offset = 0
    if zone ~= "Z" then
        local sign, zh, zm = zone:match("^([+-])(%d%d):(%d%d)$")
        if not sign or tonumber(zh) > 23 or tonumber(zm) > 59 then return nil end
        offset = (tonumber(zh) * 60 + tonumber(zm)) * 60 * (sign == "+" and 1 or -1)
    end
    local adjusted = y - (m <= 2 and 1 or 0)
    local era = math.floor(adjusted / 400)
    local year = adjusted - era * 400
    local month = m + (m > 2 and -3 or 9)
    local days = era * 146097 + year * 365 + math.floor(year / 4) - math.floor(year / 100)
        + math.floor((153 * month + 2) / 5) + d - 1 - 719468
    return days * 86400 + h * 3600 + mi * 60 + s - offset
end

local function normalize(data)
    if type(data) ~= "table" or type(data.usage) ~= "table" then return nil end
    local result = {usage = {}}
    for _, definition in ipairs(WINDOWS) do
        local name = definition[1]
        local item = data.usage[name]
        if type(item) ~= "table" then return nil end
        local percent = tonumber(item.percent)
        local reset = timestamp(item.resetsAt)
        if not percent or percent ~= percent or percent == math.huge or percent == -math.huge
            or percent < 0 or not reset then return nil end
        result.usage[name] = {percent = percent, resetsAt = item.resetsAt,
            reset = reset, status = item.status == "rate-limited" and "rate-limited" or "ok"}
    end
    return result
end

local function duration(seconds)
    local minutes = math.max(1, math.ceil(seconds / 60))
    local days = math.floor(minutes / 1440)
    local hours = math.floor(minutes / 60) % 24
    if days > 0 then return days .. "d " .. hours .. "h" end
    if hours > 0 then return hours .. "h " .. (minutes % 60) .. "m" end
    return minutes .. "m"
end

local function percent_text(value)
    return (string.format("%.1f", value):gsub("%.0$", ""))
end

local function interval()
    return math.max(1, math.min(60, tonumber(prefs.refresh_minutes) or 5)) * 60
end

local function display_density()
    local ok, value = pcall(function()
        return ui:getContext():getResources():getDisplayMetrics().density
    end)
    return ok and tonumber(value) or 3
end

local function content_width(density)
    local ok, width = pcall(function()
        -- AIO's divider spans the screen minus its two 8dp outer gutters.
        return ui:getContext():getResources():getDisplayMetrics().widthPixels / density - 16
    end)
    return ok and width and width > 0 and math.floor(width + 0.5) or 350
end

local function right_handed()
    local ok, value = pcall(function()
        return ui:getContext():getSharedPreferences("ru.execbit.aiolauncher_preferences", 0)
            :getBoolean("for_right_handed", false)
    end)
    return ok and value == true
end

local function initialize()
    if loaded then return end
    loaded = true
    if prefs.refresh_minutes == nil then prefs.refresh_minutes = 5 end
    if prefs.display_used == nil then prefs.display_used = false end
    local imported = files:read(KEY_IMPORT)
    if imported and trim(imported) ~= "" then
        prefs._api_key = trim(imported)
        files:delete(KEY_IMPORT)
        files:delete(CACHE_FILE)
    end
    if trim(prefs._api_key) ~= "" then
        local cached = files:read(CACHE_FILE)
        if cached then
            local ok, data = pcall(json.decode, cached)
            if ok then
                state = normalize(data)
                if state then state.fetched_at = tonumber(data.fetched_at) or 0 end
            end
        end
    end
end

local function open_key_dialog()
    dialog = "key"
    dialogs:show_edit_dialog("OpenCode Go API key", "Paste a Go key from the OpenCode console. Leave blank to keep the current key.", "")
end

local function show_menu()
    ui:show_context_menu({
        {"refresh", "Refresh now"}, {"external-link", "Open console"}, {"key", "Change API key"},
        {"adjust", prefs.display_used and "Show remaining usage" or "Show used usage"},
        {"clock", "Refresh interval (" .. tostring(prefs.refresh_minutes) .. " min)"}, {"trash", "Remove API key"},
    })
end

render = function()
    actions = {}
    local right = right_handed()
    last_handedness = right
    local gravity = right and "right" or "left"
    local layout = {}
    local function add(kind, text, options, action)
        layout[#layout + 1] = {kind, text, options}
        if action then actions[#layout] = action end
    end
    if trim(prefs._api_key) == "" then
        add("text", "Connect your OpenCode Go account to see your quota.", {size = 14, gravity = gravity, margin = "0 14dp"})
        add("new_line", 2)
        add("button", "Set API key", {gravity = gravity, margin = "0 14dp"}, open_key_dialog)
    elseif not state then
        add("text", message or "Loading your usage…", {size = 14, gravity = gravity, margin = "0 14dp"})
        if not loading then
            add("new_line", 2)
            add("button", "Retry", {gravity = gravity, margin = "0 14dp"}, function() refresh(true) end)
        end
    else
        local minimized = false
        if ui.is_folded then minimized = ui:is_folded()
        elseif ui.folding_flag then minimized = ui:folding_flag() end
        local row_height = minimized and 20 or 28
        local height = row_height * #WINDOWS
        local density = display_density()
        local width = content_width(density)
        local inset = 14
        local bar_start = minimized and 90 or 112
        local bar_width = width - bar_start - (minimized and inset or 80)
        local bar_y = minimized and 7 or 11
        local bar_x = right and (width - bar_start - bar_width) or bar_start
        local label_x, label_anchor = right and (width - inset) or inset, right and "end" or "start"
        local percent_x, percent_anchor = right and inset or (width - inset), right and "start" or "end"
        -- Intrinsic bitmap dimensions give AIO the actual rectangular height
        -- immediately. Forcing a square icon and posting negative margins made
        -- its RecyclerView measure a transient height during folding.
        local primary = "#EEEEEE"
        if aio and aio.colors then
            local theme = aio:colors()
            if theme and type(theme.primary_text) == "string" and theme.primary_text:match("^#%x+$") then
                primary = "#" .. theme.primary_text:sub(-6)
            end
        end
        local pixel_width = math.floor(width * density + 0.5)
        local pixel_height = math.floor(height * density + 0.5)
        local canvas = {'<svg xmlns="http://www.w3.org/2000/svg" width="' .. pixel_width .. '" height="' .. pixel_height
            .. '" viewBox="0 0 ' .. width .. ' ' .. height .. '" font-family="sans-serif">'}
        for i, definition in ipairs(WINDOWS) do
            local item = state.usage[definition[1]]
            local left = math.max(0, 100 - item.percent)
            local color = item.status == "rate-limited" and RED or (left <= 10 and RED or (left <= 25 and AMBER or GREEN))
            local reset_seconds = item.reset - os.time()
            local hint = reset_seconds > 0 and ("Resets in " .. duration(reset_seconds)) or "Reset due"
            if item.status == "rate-limited" then hint = "Limit reached · " .. (reset_seconds > 0 and duration(reset_seconds) or "reset due") end
            local value = prefs.display_used and item.percent or left
            local fill = math.max(0, math.min(100, value)) * bar_width / 100
            local fill_x = right and (bar_x + bar_width - fill) or bar_x
            local row = '<g transform="translate(0 ' .. ((i - 1) * row_height) .. ')">'
                .. '<text x="' .. label_x .. '" y="' .. (minimized and 14 or 11) .. '" text-anchor="' .. label_anchor .. '" font-size="12.5" fill="' .. primary .. '">' .. definition[2] .. '</text>'
                .. '<rect x="' .. bar_x .. '" y="' .. bar_y .. '" width="' .. bar_width .. '" height="5" rx="1" fill="#555555"/>'
                .. '<rect x="' .. tostring(fill_x) .. '" y="' .. bar_y .. '" width="' .. tostring(fill) .. '" height="5" rx="1" fill="' .. color .. '"/>'
            if not minimized then
                row = row .. '<text x="' .. label_x .. '" y="23" text-anchor="' .. label_anchor .. '" font-size="10.5" fill="' .. MUTED .. '">' .. hint .. '</text>'
                    .. '<text x="' .. percent_x .. '" y="18" text-anchor="' .. percent_anchor .. '" font-size="12.5" fill="' .. primary .. '">'
                    .. percent_text(value) .. (prefs.display_used and '% used' or '% left') .. '</text>'
            end
            canvas[#canvas + 1] = row .. '</g>'
        end
        canvas[#canvas + 1] = '</svg>'
        add("icon", "svg:" .. table.concat(canvas), {gravity = gravity}, function() refresh(true) end)
        if message and not minimized then
            add("new_line", 0)
            add("text", message, {size = 11, color = MUTED, font_padding = false, gravity = gravity, margin = "0 14dp"}, function() refresh(true) end)
        end
    end
    local signature = json.encode(layout)
    if signature ~= last_layout then
        last_layout = signature
        gui(layout).render()
    end
end

refresh = function(force)
    initialize()
    if trim(prefs._api_key) == "" then render(); return end
    local now = os.time()
    local reset_due = false
    if state then
        for _, item in pairs(state.usage) do
            if item.percent > 0 and item.reset <= now then reset_due = true end
        end
    end
    if loading then return end
    if not force and last_attempt and now - last_attempt < ((message or reset_due) and 60 or interval()) then return end
    if not force and state and not message and not reset_due and now - state.fetched_at < interval() then return end
    loading, requested_at, last_attempt = true, now, now
    request_key = trim(prefs._api_key)
    message = nil
    render()
    http:set_headers({"Authorization: Bearer " .. request_key,
        "Accept: application/json", "User-Agent: OpenCodeGoUsage/1.0"})
    http:get(ENDPOINT, "usage")
end

function on_load()
    initialize()
    render()
end

function on_resume()
    initialize()
    render()
    refresh(false)
end

function on_alarm()
    refresh(false)
end

function on_tick(ticks)
    if loading and os.time() - requested_at > 45 then
        loading = false
        http:set_headers({})
        message = "Request timed out · tap to retry"
    end
    if right_handed() ~= last_handedness then render() end
    if ticks % 30 == 0 then render(); refresh(false) end
end

function on_network_result_usage(body, code)
    loading = false
    http:set_headers({})
    if request_key ~= trim(prefs._api_key) then refresh(true); return end
    if tonumber(code) == 200 then
        local ok, data = pcall(json.decode, body)
        local result = ok and normalize(data)
        if result then
            state = result
            state.fetched_at = os.time()
            message = nil
            files:write(CACHE_FILE, json.encode(state))
        else message = "Unexpected usage response · tap to retry" end
    elseif tonumber(code) == 401 then message = "API key rejected · change it in widget settings"
    elseif tonumber(code) == 403 then message = "Go access denied · check your key and subscription"
    elseif tonumber(code) == 429 then message = "Too many refreshes · retry shortly"
    else message = "Usage unavailable (HTTP " .. tostring(code) .. ") · tap to retry" end
    render()
end

function on_network_error_usage()
    loading = false
    http:set_headers({})
    if request_key ~= trim(prefs._api_key) then refresh(true); return end
    message = "Connection failed · showing saved usage"
    if not state then message = "Connection failed · tap Retry" end
    render()
end

function on_click(index)
    if actions[index] then actions[index]() end
end

function on_long_click()
    show_menu()
end

function on_settings()
    show_menu()
end

function on_context_menu_click(value)
    if value == 1 then refresh(true)
    elseif value == 2 then intent:open_uri("https://opencode.ai/go")
    elseif value == 3 then open_key_dialog()
    elseif value == 4 then prefs.display_used = not prefs.display_used; render()
    elseif value == 5 then
        dialog = "interval"
        dialogs:show_edit_dialog("Refresh interval", "Minutes between requests (1–60)", tostring(prefs.refresh_minutes))
    elseif value == 6 then
        dialog = "remove"
        dialogs:show_dialog("Remove API key?", "The widget will disconnect and delete its saved usage.", "Remove", "Cancel")
    end
end

function on_dialog_action(value)
    local current = dialog
    dialog = nil
    if value == -1 or value == nil then return end
    if current == "key" then
        local key = trim(value)
        if key ~= "" then
            if key:find("%s") then ui:show_toast("Paste the API key only, without spaces"); return end
            prefs._api_key = key
            state, message, last_attempt = nil, nil, nil
            files:delete(CACHE_FILE)
            render()
            refresh(true)
        end
    elseif current == "interval" then
        local minutes = tonumber(value)
        if minutes and minutes >= 1 and minutes <= 60 then
            prefs.refresh_minutes = math.floor(minutes)
            render()
        else ui:show_toast("Enter a number from 1 to 60") end
    elseif current == "remove" and value == 1 then
        prefs._api_key = nil
        state, message, last_attempt = nil, nil, nil
        files:delete(CACHE_FILE)
        files:delete(KEY_IMPORT)
        render()
    end
end
