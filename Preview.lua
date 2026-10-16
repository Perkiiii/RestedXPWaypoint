-- RestedXP Waypoint
-- Preview: shows the bridge's marker icons in game without walking to each
-- RestedXP step (/rxpw preview). A temporary Waypoint UI navigation is
-- placed a short distance in front of the player, with the same icon, colour
-- and label options the bridge uses for real coordinate waypoints.
--
-- While a preview is shown, automatic sync is paused (the saved on/off setting
-- is not touched) so RestedXP cannot replace it; /rxpw preview off removes the
-- preview marker (only that one) and restarts automatic sync if it was running.
-- A preview marker Waypoint UI restores after /reload is recognised by its
-- flag (Preview.RemoveOrphan): automatic sync removes it at its first
-- evaluation, and /rxpw preview off removes it when automatic sync is off.

local _, RXPW = ...
local Preview = {}
RXPW.Preview = Preview

local PREVIEW_FLAG = "RestedXPWaypoint-Preview"
local CYCLE_SECONDS = 4
-- Distance in front of the player, in map fractions. "close" (~30-60 yd in
-- most zones) shows the marker up close; "far" is 300% further away (4x), to
-- see how the marker looks from a distance.
local DISTANCES = {
    close = 0.008,
    far = 0.008 * 4,
}
local DISTANCE_ALIASES = { close = "close", near = "close", far = "far" }

local C_Timer = C_Timer
local format = string.format
local tostring = tostring
local sin, cos = math.sin, math.cos

-- name -> presentation, in cycling order
local ENTRIES = {
    { key = "available",         label = "Accept quest",       quest = "Available" },
    { key = "incomplete",        label = "Quest in progress",  quest = "Incomplete", tint = "IncompleteQuest" },
    { key = "complete",          label = "Ready for turn-in",  quest = "Complete",   tint = "NormalQuest" },
    { key = "flightmaster",      label = "Flight master",      service = "FlightMaster" },
    { key = "classtrainer",      label = "Class trainer",      service = "ClassTrainer" },
    { key = "professiontrainer", label = "Profession trainer", service = "ProfessionTrainer" },
    { key = "food",              label = "Food and drink",     service = "FoodAndDrink" },
    { key = "repair",            label = "Repair",             service = "Repair" },
    { key = "innkeeper",         label = "Innkeeper",          service = "Innkeeper" },
    { key = "stable",            label = "Stable master",      service = "StableMaster" },
    { key = "vendor",            label = "General vendor",     service = "Vendor" },
    { key = "banker",            label = "Banker",             service = "Banker" },
    { key = "grind",             label = "Grind",              service = "Grind" },
    { key = "default",           label = "Default waypoint" },
}
local BY_KEY = {}
for i, entry in ipairs(ENTRIES) do BY_KEY[entry.key] = i end

local state = { active = false, ticker = nil, index = nil, resumeSync = false }

-- Player position on the best map, as 0-1 fractions; nil if unavailable.
local function PlayerPosition()
    local mapID = C_Map and C_Map.GetBestMapForUnit and C_Map.GetBestMapForUnit("player")
    if not mapID then return nil end
    if C_Map.GetPlayerMapPosition then
        local ok, pos = pcall(C_Map.GetPlayerMapPosition, mapID, "player")
        if ok and pos and pos.GetXY then
            local x, y = pos:GetXY()
            if RXPW.IsFiniteNumber(x) and RXPW.IsFiniteNumber(y) and (x ~= 0 or y ~= 0) then return mapID, x, y end
        end
    end
    local LibStub = _G.LibStub
    local HBD = type(LibStub) == "table" and LibStub("HereBeDragons-2.0", true)
    if HBD and HBD.GetPlayerZonePosition then
        local ok, x, y, zone = pcall(HBD.GetPlayerZonePosition, HBD)
        if ok and RXPW.IsFiniteNumber(x) and RXPW.IsFiniteNumber(y) then return zone or mapID, x, y end
    end
    return nil
end

-- A point `offset` ahead of the player (map x grows east, y grows south;
-- facing is radians counter-clockwise from north).
local function PointAhead(offset)
    local mapID, x, y = PlayerPosition()
    if not mapID then return nil end
    local facing = type(GetPlayerFacing) == "function" and GetPlayerFacing() or 0
    if not RXPW.IsFiniteNumber(facing) then facing = 0 end
    local px = x - sin(facing) * offset
    local py = y - cos(facing) * offset
    px = math.min(math.max(px, 0.001), 0.999)
    py = math.min(math.max(py, 0.001), 0.999)
    return mapID, px * 100, py * 100
end

local function Notify()
    if RXPW.Config then RXPW.Config.Notify("preview") end
end

local function EntryPresentation(entry)
    if entry.quest then
        return { questID = 0, status = entry.quest, iconType = "", tintKey = entry.tint }
    elseif entry.service then
        return { service = entry.service }
    end
    return nil
end

local function Show(index, distance)
    local entry = ENTRIES[index]
    local mapID, x, y = PointAhead(DISTANCES[distance] or DISTANCES.close)
    if not mapID then
        RXPW.Print("Preview needs your position on a map (not available here, e.g. in an instance).")
        return false
    end

    -- The same appearance settings as real coordinate waypoints (v0.6.0).
    local presentation = EntryPresentation(entry)
    local icon, _, tint = RXPW.WUI.ResolveAppearance(presentation)
    local target = {
        mapID = mapID, x = x, y = y,
        label = "Preview: " .. entry.label,
        stripCoordinates = true,
        iconTexture = icon,
        tint = tint,
        flags = PREVIEW_FLAG,
    }
    local ok, err = RXPW.WUI.SetNavigation(target, true)
    if not ok then
        RXPW.Print("Preview failed: %s.", tostring(err))
        return false
    end
    state.index = index
    state.distance = distance
    local note = ""
    if not icon then
        note = " - icon turned off in the appearance settings"
    elseif presentation and not RXPW.WUI.GetPresentationIcon(presentation) then
        note = " - icon unavailable (Waypoint UI version?), default icon shown"
    end
    RXPW.Print("Preview %d/%d (%s): %s (%s)%s.", index, #ENTRIES, distance, entry.label, entry.key, note)
    Notify()
    return true
end

local function Begin()
    if state.active then return end
    state.active = true
    state.resumeSync = RXPW.Sync.GetState().running
    RXPW.Sync.Stop()
end

local function StopCycle()
    if state.ticker then
        state.ticker:Cancel()
        state.ticker = nil
    end
end

-- Waypoint UI saves its custom navigation per character, flags included, and
-- restores it after /reload, while this file's session state starts empty.
-- A navigation carrying PREVIEW_FLAG with no preview session is therefore a
-- leftover preview marker. Only that exact flag is ever removed: manual
-- waypoints, other addons' navigation and native quest tracking are untouched.
-- Returns true if a leftover preview marker was removed.
function Preview.RemoveOrphan()
    if state.active or not RXPW.WUI.HasNavigationWithFlag(PREVIEW_FLAG) then return false end
    if not RXPW.WUI.ClearNavigationWithFlag(PREVIEW_FLAG) then return false end
    RXPW.Print("Removed a leftover preview marker from before the reload.")
    return true
end

function Preview.Off(quiet)
    StopCycle()
    if not state.active then
        if Preview.RemoveOrphan() then
            -- Automatic sync may have paused for the marker as a foreign
            -- waypoint; restarting makes the current RestedXP destination a
            -- first activation again.
            if RXPW.Sync.GetState().running then
                RXPW.Sync.Stop()
                RXPW.Sync.Start()
                RXPW.PrintLine("Automatic sync resumed.")
            end
        elseif not quiet then
            RXPW.Print("No preview is shown.")
        end
        Notify()
        return
    end
    RXPW.WUI.ClearNavigationWithFlag(PREVIEW_FLAG)
    state.active = false
    state.index = nil
    if state.resumeSync and RXPW.db.autoSync then
        RXPW.Sync.Start()
        RXPW.Print("Preview removed; automatic sync resumed.")
    else
        RXPW.Print("Preview removed.")
    end
    state.resumeSync = false
    Notify()
end

function Preview.IsActive()
    return state.active
end

-- For the settings panel (v0.6.0): read-only views of the same state.
-- Entries: { key, label } in cycling order.
function Preview.GetEntries()
    local list = {}
    for i, entry in ipairs(ENTRIES) do list[i] = { key = entry.key, label = entry.label } end
    return list
end

-- The entry's own icon art and colour (ignoring the appearance settings).
-- The default entry, and a quest icon this Waypoint UI version cannot show,
-- use the bridge's default icon; it has no colour of its own (Waypoint UI
-- tints it with the marker colour).
function Preview.GetEntryArt(key)
    local entry = ENTRIES[BY_KEY[key] or 0]
    if not entry then return nil end
    local presentation = EntryPresentation(entry)
    local icon = RXPW.WUI.GetPresentationIcon(presentation)
    if not icon then return RXPW.WUI.GetDefaultIcon(), nil end
    return icon, RXPW.WUI.GetPresentationTint(presentation)
end

-- { active, key, distance, cycling, orphan } (orphan: a leftover preview
-- marker restored by Waypoint UI after /reload, see RemoveOrphan)
function Preview.GetState()
    local entry = state.active and state.index and ENTRIES[state.index]
    return { active = state.active, key = entry and entry.key or nil, distance = state.distance,
             cycling = state.ticker ~= nil,
             orphan = not state.active and RXPW.WUI.HasNavigationWithFlag(PREVIEW_FLAG) or false }
end

local function CanPreview()
    if RXPW.WUI.GetStatus().apiAvailable then return true end
    RXPW.Print("Preview needs Waypoint UI's navigation API.")
    return false
end

-- Shows one entry (key) at distance "close" (default) or "far".
function Preview.Show(key, distance)
    local index = BY_KEY[key or ""]
    if not index then
        RXPW.Print("Unknown preview \"%s\".", tostring(key))
        return false
    end
    if not CanPreview() then return false end
    StopCycle()
    Begin()
    if not Show(index, DISTANCES[distance] and distance or "close") then Preview.Off(true) return false end
    return true
end

-- Shows the entry after the current one; distance defaults to the last used.
function Preview.Next(distance)
    if not CanPreview() then return false end
    local index = ((state.index or 0) % #ENTRIES) + 1
    distance = DISTANCES[distance] and distance or state.distance or "close"
    StopCycle()
    Begin()
    if not Show(index, distance) then Preview.Off(true) return false end
    return true
end

-- Cycles through every entry, CYCLE_SECONDS each.
function Preview.ShowAll(distance)
    if not CanPreview() then return false end
    distance = DISTANCES[distance] and distance or "close"
    StopCycle()
    Begin()
    local index = 1
    if not Show(index, distance) then Preview.Off(true) return false end
    state.ticker = C_Timer.NewTicker(CYCLE_SECONDS, function()
        index = index + 1
        if index > #ENTRIES then
            StopCycle()
            RXPW.PrintLine("Preview cycle finished; use /rxpw preview off to resume.")
            Notify()
            return
        end
        Show(index, distance)
    end)
    return true
end

local function PrintUsage()
    RXPW.Print("Preview RestedXP Waypoint marker icons in front of you:")
    RXPW.PrintLine("/rxpw preview all close - cycle through every icon close by (%d s each)", CYCLE_SECONDS)
    RXPW.PrintLine("/rxpw preview all far - the same, 300% further away (4x the distance)")
    RXPW.PrintLine("/rxpw preview next [close||far] - show the next icon")
    RXPW.PrintLine("/rxpw preview flightmaster [close||far] - show the flightmaster icon")
    local keys = {}
    for _, entry in ipairs(ENTRIES) do keys[#keys + 1] = entry.key end
    RXPW.PrintLine("names: %s", table.concat(keys, ", "))
    RXPW.PrintLine("/rxpw preview off - remove the preview and resume automatic sync")
end

-- /rxpw preview [all|next|off|<name>] [close|far]
-- Without a distance word: close (for "next", the distance last used).
function Preview.Command(argument)
    local action, distance
    for word in (argument or ""):gmatch("%S+") do
        if DISTANCE_ALIASES[word] then
            distance = DISTANCE_ALIASES[word]
        elseif not action then
            action = word
        else
            RXPW.Print("Unexpected \"%s\".", word)
            PrintUsage()
            return
        end
    end
    if not action then
        if not distance then
            PrintUsage()
            return
        end
        action = "all" -- "/rxpw preview far" = cycle everything far away
    end
    if action == "off" or action == "stop" then
        Preview.Off()
        return
    end
    if action == "all" then
        Preview.ShowAll(distance)
    elseif action == "next" then
        Preview.Next(distance)
    elseif BY_KEY[action] then
        Preview.Show(action, distance)
    else
        RXPW.Print("Unknown preview \"%s\".", tostring(action))
        PrintUsage()
    end
end
