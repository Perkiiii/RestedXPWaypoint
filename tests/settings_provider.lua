-- Stateful fake of the proposed public contract; no private DB access by the addon.
return function(R)
    local P = { version = 1, values = {}, explicit = {}, descriptors = {}, writes = 0, subscriptions = 0 }
    local listeners = {}
    for _, specs in pairs(R.SettingsSchema) do
        for _, spec in ipairs(specs) do
            local d = { type = spec.type, visible = true, enabled = true }
            local value
            if spec.type == "boolean" then value = true
            elseif spec.type == "select" then
                value = 1; d.options = { { value = 1, label = "First" }, { value = 2, label = "Second" } }
            elseif spec.type == "sound" then value = 89712
            else value = 1; d.min, d.max, d.step = 0.1, 2, 0.1 end
            d.default = value
            P.descriptors[spec.key], P.values[spec.key] = d, value
        end
    end
    P.descriptors.CustomMapPinsEnabled.default = false
    P.values.CustomMapPinsEnabled = false
    function P.Get(key) return P.values[key] end
    function P.IsExplicit(key) return P.explicit[key] == true end
    function P.Describe(key) return P.descriptors[key] end
    function P.Format(key, value) return tostring(value) .. " units" end
    function P.OnChange(key, callback)
        P.subscriptions = P.subscriptions + 1
        local token = { key = key, callback = callback }; listeners[token] = true
        return function() listeners[token] = nil end
    end
    function P.Set(key, value)
        if P.values[key] == value then return true end
        P.writes = P.writes + 1; P.values[key] = value; P.explicit[key] = true
        for token in pairs(listeners) do
            if token.key == "*" or token.key == key then token.callback(key, value) end
        end
        return true
    end
    function P.listenerCount() local n = 0; for _ in pairs(listeners) do n = n + 1 end; return n end
    return P
end
