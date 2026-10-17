-- Optional public Waypoint UI settings API. Never reads or writes its private DB.
local _, RXPW = ...
local Adapter = {}
RXPW.WaypointSettings = Adapter
local provider, unsubscribe
local listeners = {}
local UNAVAILABLE = "Requires Waypoint UI's public Settings API v1 (not in the standard 1.7.3 release). Open Waypoint UI Settings to change this option."

local function Notify(key)
    for _, callback in ipairs(listeners) do pcall(callback, key) end
end
function Adapter.RegisterListener(callback)
    if type(callback) == "function" then listeners[#listeners + 1] = callback end
end
function Adapter.Connect()
    local api = type(WaypointUIAPI) == "table" and WaypointUIAPI.Settings
    if type(api) ~= "table" or api.version ~= 1 or type(api.Get) ~= "function"
        or type(api.Set) ~= "function" or type(api.Describe) ~= "function"
        or type(api.OnChange) ~= "function" then api = nil end
    if api == provider then return provider ~= nil end
    if unsubscribe then pcall(unsubscribe) end
    provider, unsubscribe = nil, nil
    if not api then return false end
    local ok, cancel = pcall(api.OnChange, "*", Notify)
    if not ok or type(cancel) ~= "function" then return false end
    provider, unsubscribe = api, cancel
    return true
end
local function Allowed(key)
    if key == "PrefMetric" then return true end
    for _, specs in pairs(RXPW.SettingsSchema) do
        for _, spec in ipairs(specs) do if spec.key == key then return true end end
    end
end
function Adapter.Describe(key)
    if not Allowed(key) or not Adapter.Connect() then return nil, UNAVAILABLE end
    local ok, d = pcall(provider.Describe, key)
    if not ok or type(d) ~= "table" then return nil, UNAVAILABLE end
    local expected = key == "PrefMetric" and "boolean"
    for _, specs in pairs(RXPW.SettingsSchema) do
        for _, spec in ipairs(specs) do if spec.key == key then expected = spec.type end end
    end
    if d.type ~= expected then return nil, UNAVAILABLE end
    if d.type == "number" then
        if not RXPW.IsFiniteNumber(d.min) or not RXPW.IsFiniteNumber(d.max)
            or not RXPW.IsFiniteNumber(d.step) or d.step <= 0 or d.min > d.max then return nil, UNAVAILABLE end
    elseif d.type == "select" then
        if type(d.options) ~= "table" or #d.options == 0 then return nil, UNAVAILABLE end
        for _, option in ipairs(d.options) do
            if type(option) ~= "table" or type(option.label) ~= "string"
                or not RXPW.IsFiniteNumber(option.value) then return nil, UNAVAILABLE end
        end
    elseif d.type ~= "boolean" and d.type ~= "sound" then return nil, UNAVAILABLE end
    return d
end
local function Validate(value, d)
    if d.type == "boolean" then return type(value) == "boolean" end
    if d.type == "sound" then
        return value == "" or (RXPW.IsFiniteNumber(value) and value >= 0 and value == math.floor(value))
    end
    if not RXPW.IsFiniteNumber(value) then return false end
    if d.type == "number" then
        if value < d.min or value > d.max then return false end
        local steps = (value - d.min) / d.step
        return math.abs(steps - math.floor(steps + 0.5)) < 0.00001 or value == d.max
    end
    for _, option in ipairs(d.options) do if option.value == value then return true end end
    return false
end
function Adapter.Get(key)
    local d = Adapter.Describe(key)
    if not d then return nil end
    local ok, value = pcall(provider.Get, key)
    -- Existing values can predate current slider bounds; display them honestly.
    if ok and ((d.type == "number" and RXPW.IsFiniteNumber(value)) or Validate(value, d)) then return value end
end
function Adapter.Set(key, value)
    local d, reason = Adapter.Describe(key)
    if not d then return false, reason end
    if d.enabled == false or d.visible == false then return false, "This option is currently disabled." end
    if not Validate(value, d) then return false, "Invalid setting value." end
    if Adapter.Get(key) == value then return true end
    local ok, accepted, errorText = pcall(provider.Set, key, value)
    if not ok then return false, "Waypoint UI could not apply this setting." end
    return accepted == true, errorText
end
function Adapter.Format(key, value)
    if provider and type(provider.Format) == "function" then
        local ok, text = pcall(provider.Format, key, value)
        if ok and type(text) == "string" then return text end
    end
    return tostring(value)
end
function Adapter.ApplyFirstRunDefault()
    if RXPW.db.mapPinsDefaultPending ~= true or not Adapter.Connect()
        or type(provider.IsExplicit) ~= "function" then return end
    local ok, explicit = pcall(provider.IsExplicit, "CustomMapPinsEnabled")
    if not ok or type(explicit) ~= "boolean" then return end
    if explicit then RXPW.db.mapPinsDefaultPending = nil; return end
    if Adapter.Set("CustomMapPinsEnabled", true) then RXPW.db.mapPinsDefaultPending = nil end
end
