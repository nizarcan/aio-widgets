package.path = "tests/support/?.lua;" .. package.path
local json = require "json"
local source = assert(io.open("widgets/opencode-go.lua")):read("*a")
local fixture = json.decode(assert(io.open("tests/fixtures/usage-success.json")):read("*a"))
local count = 0
local TEST_NOW = 1791828000 -- Fixed UTC clock; fixtures are synthetic.

local function runtime(settings, disk, device)
    local env = setmetatable({}, {__index = _G})
    settings, disk = settings or {}, disk or {}
    env.os = setmetatable({time = function() return TEST_NOW end}, {__index = os})
    local calls = {requests = {}, disk = disk, prefs = settings}
    device = device or {}
    local Class = require("android_graphics")(calls)
    env.require = function(name) if name == "prefs" then return settings end; return require(name) end
    env.files = {
        read = function(_, name) return disk[name] end,
        write = function(_, name, data) disk[name] = data end,
        delete = function(_, name) disk[name] = nil end,
    }
    env.gui = function(layout) return {render = function() calls.layout = layout; calls.renders = (calls.renders or 0) + 1 end} end
    env.http = {
        set_headers = function(_, headers) calls.headers = headers end,
        get = function(_, url, id) calls.requests[#calls.requests + 1] = {url, id} end,
    }
    env.dialogs = setmetatable({}, {__index = function(_, name) return function(_, ...) calls.dialog = {name, ...} end end})
    env.ui = {show_toast = function(_, text) calls.toast = text end, show_context_menu = function(_, items) calls.menu = items end,
        builder_image = device.images and function() end or nil,
        is_folded = function() return calls.minimized or false end,
        getContext = function() return {
            getClass = function() return Class end,
            getResources = function() return {getDisplayMetrics = function() return device.metrics or {density = 3} end} end,
            getSharedPreferences = function(_, name) assert(name == "ru.execbit.aiolauncher_preferences"); return {
                getBoolean = function(_, key) assert(key == "for_right_handed"); return calls.right_handed or false end,
            } end,
        } end}
    env.intent = {open_uri = function(_, uri) calls.uri = uri end}
    local chunk
    if setfenv then chunk = assert(loadstring(source)); setfenv(chunk, env)
    else chunk = assert(load(source, "widget", "t", env)) end
    chunk()
    return env, calls
end

local function contains(calls, text)
    for _, item in ipairs(calls.layout) do
        if type(item[2]) == "string" and item[2]:find(text, 1, true) then return true end
    end
    return false
end

local function check(condition, label)
    assert(condition, label)
    count = count + 1
end

local env, calls = runtime()
env.on_load(); env.on_resume(); env.on_alarm()
check(#calls.requests == 0 and contains(calls, "Set API key"), "No-key setup")

env, calls = runtime({}, {["opencode-go-key.txt"] = " test-key\n"})
env.on_load(); env.on_resume(); env.on_alarm()
check(calls.prefs._api_key == "test-key" and calls.disk["opencode-go-key.txt"] == nil, "Import once and remove bootstrap")
check(#calls.requests == 1 and calls.requests[1][1] == "https://opencode.ai/zen/go/v1/usage", "Idempotent callbacks and endpoint")
env.on_network_result_usage(json.encode(fixture), 200)
check(contains(calls, "86% left") and contains(calls, "95% left") and contains(calls, "76% left"), "Actual API units and remaining quota")
check(#calls.headers == 0, "Clear auth headers after request")
local cached = json.decode(calls.disk["opencode-go-usage.json"])
check(cached.usage.rolling.reset == 1791838610, "UTC reset timestamp")
check(not calls.disk["opencode-go-usage.json"]:find("test-key", 1, true), "No credentials in cache")
env.on_long_click(); env.on_context_menu_click(4)
check(contains(calls, "14% used") and contains(calls, "24% used"), "Used mode toggle")
env.on_resume(); check(#calls.requests == 1, "Cache throttles refresh")
local renders = calls.renders
env.on_resume()
check(calls.renders == renders, "Unchanged resume does not rebuild the widget")

calls.minimized = true
env.on_resume()
check(contains(calls, "Rolling") and contains(calls, "Weekly") and contains(calls, "Monthly"), "Minimized keeps all three labels")
check(not contains(calls, "% used") and not contains(calls, "% left") and not contains(calls, "Resets in"), "Minimized hides percentages and countdowns")
check(contains(calls, 'viewBox="0 0 350 60"'), "Minimized compact geometry")
check(#calls.requests == 1, "Minimizing does not trigger an extra request")
calls.minimized = false
env.on_resume()
check(contains(calls, "14% used") and contains(calls, "Resets in") and contains(calls, 'viewBox="0 0 350 84"'), "Expanding restores usage and countdowns")

calls.right_handed = true
env.on_tick(1)
check(contains(calls, '<text x="336" y="11" text-anchor="end"') and contains(calls, '<text x="14" y="18" text-anchor="start"'), "Right-handed columns and readable text")
local fill_x, fill_width = calls.layout[1][2]:match('<rect x="([%d.]+)" y="11" width="([%d.]+)" height="5" rx="1" fill="#7BD99A"')
check(math.abs(tonumber(fill_x) + tonumber(fill_width) - 238) < 0.01, "Right-handed fills anchored to the right edge")
check(calls.layout[1][3].gravity == "right" and #calls.requests == 1, "Handedness updates without a network refresh")
calls.minimized = true; env.on_resume()
check(contains(calls, '<text x="336" y="14" text-anchor="end"') and contains(calls, '<rect x="14" y="7" width="246"'), "Right-handed minimized layout")
calls.right_handed = false; env.on_tick(2)
check(contains(calls, '<text x="14" y="14" text-anchor="start"') and contains(calls, '<rect x="90" y="7" width="246"'), "Left-handed live setting change")
calls.minimized = false; env.on_resume()

env.on_long_click(); env.on_context_menu_click(1)
env.on_network_result_usage("not JSON", 200)
check(contains(calls, "Unexpected usage response") and contains(calls, "14% used"), "Malformed response preserves saved reading")
env.on_long_click(); env.on_context_menu_click(1); env.on_network_result_usage("{}", 401)
check(contains(calls, "API key rejected"), "Authentication failure")
env.on_long_click(); env.on_context_menu_click(1); env.on_network_error_usage("private server details")
check(contains(calls, "Connection failed") and not contains(calls, "private server details"), "Offline state without sensitive error details")

local abnormal = json.decode(json.encode(fixture))
abnormal.usage.rolling.percent = 104
abnormal.usage.rolling.status = "rate-limited"
env.on_long_click(); env.on_context_menu_click(4)
env.on_long_click(); env.on_context_menu_click(1); env.on_network_result_usage(json.encode(abnormal), 200)
check(contains(calls, "0% left") and contains(calls, "Limit reached"), "Rate limit and over-quota clamp")
abnormal.usage.rolling.resetsAt = "2026-10-12T23:56:50.000+03:00"
env.on_long_click(); env.on_context_menu_click(1); env.on_network_result_usage(json.encode(abnormal), 200)
cached = json.decode(calls.disk["opencode-go-usage.json"])
check(cached.usage.rolling.reset == 1791838610, "Timezone offset matches UTC")

local restarted, restarted_calls = runtime(calls.prefs, calls.disk)
restarted.on_load(); restarted.on_resume()
check(contains(restarted_calls, "76% left") and #restarted_calls.requests == 0, "Cache survives launcher restart")
env.on_long_click(); env.on_context_menu_click(5); env.on_dialog_action("0")
check(calls.prefs.refresh_minutes == 5, "Invalid refresh interval rejected")
env.on_long_click(); env.on_context_menu_click(5); env.on_dialog_action("2")
check(calls.prefs.refresh_minutes == 2, "Refresh interval change")
env.on_long_click(); env.on_context_menu_click(6); env.on_dialog_action(2)
check(calls.prefs._api_key == "test-key", "Removal cancel")
env.on_long_click(); env.on_context_menu_click(6); env.on_dialog_action(1)
check(calls.prefs._api_key == nil and calls.disk["opencode-go-usage.json"] == nil and contains(calls, "Set API key"), "Remove key and cache")

-- AIO 7.6.1 must never send the SVG through its negative-size icon renderer.
env, calls = runtime({_api_key = "test-key", display_used = true}, {}, {images = true, metrics = {density = 2.8125, widthPixels = 1080}})
env.on_load(); env.on_resume(); env.on_network_result_usage(json.encode(fixture), 200)
local image_options = calls.layout[1][3]
local frame = calls.frames[#calls.frames]
check(calls.layout[1][1] == "image" and calls.layout[1][2]:match("^data:image/png;base64,"), "AIO 7.6.1 uses a PNG image, not an auto-sized SVG icon")
check(image_options.width == 368 and image_options.height == 84 and frame.width == 1035 and frame.height == 236, "Modern image reserves rectangular dp size with positive pixel dimensions")
check(contains(calls, "14% used") and contains(calls, "Resets in") and #frame.text == 9, "Modern expanded image includes labels, percentages, and reset times")
local encodes = calls.encodes
renders = calls.renders
env.on_resume()
check(calls.encodes == encodes and calls.renders == renders, "Unchanged panel is neither encoded nor rebuilt")
calls.minimized = true; calls.right_handed = true; env.on_resume()
frame = calls.frames[#calls.frames]
check(calls.layout[1][3].height == 60 and frame.height == 169 and #frame.text == 3 and not contains(calls, "% used"), "Modern minimized image reserves only 60dp and hides details")
check(frame.text[1][2] == 354 and frame.text[1][6] == "right" and frame.rects[1][1] == 14 and frame.rects[1][3] == 278, "Modern right-handed image preserves balanced margins and aligned track")
check(math.abs(frame.rects[2][3] - 278) < 0.01 and #calls.requests == 1, "Modern right-handed fill and folding preserve request throttling")
calls.right_handed = false; env.on_tick(1)
frame = calls.frames[#calls.frames]
check(frame.text[1][2] == 14 and frame.text[1][6] == "left" and frame.rects[1][1] == 90, "Modern image follows live left-handed preference")
calls.fail_png = true; calls.minimized = false; env.on_resume()
check(contains(calls, "Widget image unavailable") and calls.recycles == #calls.frames and calls.closes == #calls.frames, "Rendering failure is concise and releases graphics resources")
calls.fail_png = false; env.on_click(1)
check(calls.layout[1][1] == "image" and calls.layout[1][3].height == 84, "Image rendering recovers on retry")
local zero = json.decode(json.encode(fixture))
for _, item in pairs(zero.usage) do item.percent = 0 end
env.on_long_click(); env.on_context_menu_click(1); env.on_network_result_usage(json.encode(zero), 200)
frame = calls.frames[#calls.frames]
check(#frame.rects == 3 and contains(calls, "0% used"), "Empty meters keep tracks without zero-width fill shapes")
for _, density in ipairs({0, -1, math.huge, 0/0}) do
    env, calls = runtime({_api_key = "test-key"}, {}, {images = true, metrics = {density = density, widthPixels = 0}})
    env.on_load(); env.on_resume(); env.on_network_result_usage(json.encode(fixture), 200)
    frame = calls.frames[#calls.frames]
    check(frame.width == 1050 and frame.height == 252 and calls.layout[1][1] == "image", "Invalid display metrics cannot create a non-positive bitmap")
end
print("Passed " .. count .. " widget behavior checks")
