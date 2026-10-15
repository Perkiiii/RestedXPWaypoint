-- RXP Waypoint Bridge
-- Core: shared helpers, saved settings, initialisation and slash commands.
-- Load order (see .toc): Core.lua, LabelResolver.lua, RXPAdapter.lua,
-- NavigationResolver.lua, WaypointAdapter.lua, Sync.lua

local addonName, ns = ...

-- Flag attached to every Waypoint UI navigation we create, so we can tell
-- bridge-owned navigation apart from the player's own.
ns.OWNER_FLAG = "RXPWaypointBridge"

ns.Label = {}
ns.RXP = {}
ns.Nav = {}
ns.WUI = {}
ns.Sync = {}

local C_AddOns = C_AddOns
local IsAddOnLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or _G.IsAddOnLoaded
local GetAddOnMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or _G.GetAddOnMetadata
local format = string.format
local type = type
local tostring = tostring
local pairs = pairs
local pcall = pcall
local huge = math.huge
local floor = math.floor

--------------------------------------------------------------------------------
-- Settings (SavedVariables: RXPWaypointBridgeDB)
--------------------------------------------------------------------------------

-- strategy: "coordinates" (v0.3 behaviour, safe default) or "hybrid"
-- (native quest supertracking for eligible turn-ins).
local STRATEGIES = { coordinates = true, hybrid = true }

local DEFAULTS = {
    autoSync = true,
    debug = false,
    strategy = "coordinates",
}

-- Replaced by the saved table on ADDON_LOADED.
ns.db = {}
for key, value in pairs(DEFAULTS) do ns.db[key] = value end

local function LoadSettings()
    local db = _G.RXPWaypointBridgeDB
    if type(db) ~= "table" then
        db = {}
        _G.RXPWaypointBridgeDB = db
    end
    for key, value in pairs(DEFAULTS) do
        if type(db[key]) ~= type(value) then db[key] = value end
    end
    if not STRATEGIES[db.strategy] then db.strategy = DEFAULTS.strategy end
    ns.db = db
end

--------------------------------------------------------------------------------
-- Logging and shared helpers
--------------------------------------------------------------------------------

local PREFIX = "|cff33ff99RXP Waypoint Bridge|r: "
local DEBUG_PREFIX = "|cff33ff99RXPWB|r |cff999999[debug]|r "

function ns.Print(fmt, ...)
    local text = select("#", ...) > 0 and format(fmt, ...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

-- Continuation line without the prefix, for multi-line output.
function ns.PrintLine(fmt, ...)
    local text = select("#", ...) > 0 and format(fmt, ...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("   " .. text)
end

-- Only shown while /rxpwb debug is on.
function ns.Debug(fmt, ...)
    if not ns.db.debug then return end
    local text = select("#", ...) > 0 and format(fmt, ...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(DEBUG_PREFIX .. text)
end

function ns.GetVersion(addon)
    if not GetAddOnMetadata then return nil end
    local ok, version = pcall(GetAddOnMetadata, addon or addonName, "Version")
    return ok and version or nil
end

function ns.IsLoaded(addon)
    if not IsAddOnLoaded then return false end
    local ok, loaded = pcall(IsAddOnLoaded, addon)
    return ok and loaded and true or false
end

function ns.IsFiniteNumber(n)
    return type(n) == "number" and n == n and n ~= huge and n ~= -huge
end

function ns.FormatCoord(n)
    return ns.IsFiniteNumber(n) and format("%.2f", n) or tostring(n)
end

-- "Label - map 1429 (Elwynn Forest) @ 42.10, 65.30"
function ns.DescribeTarget(target)
    return format("%s - map %s%s @ %s, %s",
        target.label or "RestedXP", tostring(target.mapID),
        target.mapName and (" (" .. target.mapName .. ")") or "",
        ns.FormatCoord(target.x), ns.FormatCoord(target.y))
end

local function YesNo(value)
    return value and "|cff00ff00yes|r" or "|cffff4040no|r"
end

local function OnOff(value)
    return value and "|cff00ff00on|r" or "|cffff4040off|r"
end

local function Ago(timestamp)
    if not timestamp then return "" end
    return format(" (%ds ago)", floor(GetTime() - timestamp))
end

--------------------------------------------------------------------------------
-- Commands
--------------------------------------------------------------------------------

function ns.PrintHelp()
    ns.Print("v%s commands:", ns.GetVersion() or "?")
    ns.PrintLine("/rxpwb status - show dependency, waypoint and sync status")
    ns.PrintLine("/rxpwb sync - send RestedXP's current waypoint to Waypoint UI now")
    ns.PrintLine("/rxpwb on - enable automatic sync (currently %s)", OnOff(ns.db.autoSync))
    ns.PrintLine("/rxpwb off - disable automatic sync")
    ns.PrintLine("/rxpwb debug - toggle debug messages (currently %s)", OnOff(ns.db.debug))
    ns.PrintLine("/rxpwb mode coordinates||hybrid - navigation strategy (currently %s)", ns.db.strategy)
end

local function DescribeMode(mode, questID)
    if mode == "native" then
        return questID and format("native quest %d", questID) or "native quest"
    end
    return mode or "none"
end

function ns.PrintStatus()
    local rxp = ns.RXP.GetStatus()
    local wui = ns.WUI.GetStatus()
    local sync = ns.Sync.GetState()

    ns.Print("status (v%s)", ns.GetVersion() or "?")
    ns.PrintLine("RestedXP loaded: %s%s | arrow data: %s",
        YesNo(rxp.loaded), rxp.version and (" (" .. rxp.version .. ")") or "", YesNo(rxp.arrowAvailable))
    ns.PrintLine("Waypoint UI loaded: %s%s | navigation API: %s",
        YesNo(wui.loaded), wui.version and (" (" .. wui.version .. ")") or "", YesNo(wui.apiAvailable))

    local target, reason = ns.RXP.GetTarget()
    if target then
        ns.PrintLine("RXP waypoint: map %s%s @ %s, %s",
            tostring(target.mapID), target.mapName and (" (" .. target.mapName .. ")") or "",
            ns.FormatCoord(target.x), ns.FormatCoord(target.y))
        ns.PrintLine("RXP label: %s", target.label or "(none)")
        local info = target.labelInfo
        if info then
            ns.PrintLine("Label source: %s | cleaned: %s | shortened: %s | fallback: %s",
                info.source, YesNo(info.cleaned), YesNo(info.shortened), YesNo(info.fallback))
            if ns.db.debug and info.raw then
                -- Doubled pipes make chat show the escape codes literally.
                ns.PrintLine("Label raw text: %s", (info.raw:gsub("|", "||")))
            end
        end
        ns.PrintLine("RXP step: %s%s | arrow shown: %s",
            tostring(target.stepIndex or "-"),
            target.hasStep and (target.stepActive and " (active)" or " (inactive)") or "",
            YesNo(target.arrowShown))
    end
    if reason then
        ns.PrintLine("Ready to sync: %s - %s", YesNo(false), reason)
    else
        ns.PrintLine("Ready to sync: %s", YesNo(wui.apiAvailable))
        local decision = ns.Nav.Decide(target, ns.db.strategy)
        if decision.questID then
            local qs = decision.questState or {}
            ns.PrintLine("Turn-in quest: %d (%s) | in log: %s | ready for turn-in: %s%s",
                decision.questID, tostring(decision.questName or "?"), YesNo(qs.inLog), YesNo(qs.ready),
                (decision.pendingTurnIns or 1) > 1 and format(" | %d turn-ins pending here", decision.pendingTurnIns) or "")
        end
        ns.PrintLine("Decision (%s): %s - %s", ns.db.strategy, DescribeMode(decision.mode, decision.questID),
            tostring(decision.reason))
    end

    local nav = ns.WUI.GetNavigation()
    if nav then
        local x = ns.IsFiniteNumber(nav.x) and nav.x * 100 or nil
        local y = ns.IsFiniteNumber(nav.y) and nav.y * 100 or nil
        ns.PrintLine("Waypoint UI destination: %s, map %s @ %s, %s (%s)",
            tostring(nav.name or "?"), tostring(nav.mapID), ns.FormatCoord(x), ns.FormatCoord(y),
            nav.flags == ns.OWNER_FLAG and "set by bridge" or "not set by bridge")
    else
        ns.PrintLine("Waypoint UI destination: none")
    end

    ns.PrintLine("Auto sync: %s%s | strategy: %s | debug: %s", OnOff(ns.db.autoSync),
        ns.db.autoSync and (sync.running and " (running)" or " (not running)") or "",
        ns.db.strategy, OnOff(ns.db.debug))
    ns.PrintLine("Active mode: %s%s | bridge owns active destination: %s",
        DescribeMode(sync.mode, sync.questID), sync.pending and " (transition in progress)" or "",
        YesNo(sync.bridgeActive))
    if sync.lastTransition then
        ns.PrintLine("Last transition: %s%s", sync.lastTransition.text, Ago(sync.lastTransition.time))
    end
    if sync.lastFailure then
        ns.PrintLine("Last failure/fallback: %s%s", sync.lastFailure.text, Ago(sync.lastFailure.time))
    end
    if sync.lastSynced then
        local prefix = sync.lastSynced.mode == "native"
            and format("[%s] ", DescribeMode("native", sync.lastSynced.questID)) or ""
        ns.PrintLine("Last synced: %s%s%s", prefix, ns.DescribeTarget(sync.lastSynced), Ago(sync.lastSynced.time))
        if sync.lastSynced.labelSource then
            ns.PrintLine("Last synced label source: %s", sync.lastSynced.labelSource)
        end
    else
        ns.PrintLine("Last synced: none this session")
    end
    if sync.lastResult then
        ns.PrintLine("Last result: %s%s", sync.lastResult, Ago(sync.lastResultTime))
    end
    if sync.external then
        ns.PrintLine("Outside change: %s (bridge resumes at the next RestedXP destination)", sync.external)
    end
end

local function EnableAutoSync()
    ns.db.autoSync = true
    if ns.Sync.Start() then
        ns.Print("Automatic sync enabled.")
    else
        ns.Print("Automatic sync enabled, but RestedXP or Waypoint UI is unavailable (see /rxpwb status).")
    end
end

local function DisableAutoSync()
    ns.db.autoSync = false
    ns.Sync.Stop()
    ns.Print("Automatic sync disabled. The current Waypoint UI destination was left unchanged.")
end

local function ToggleDebug()
    ns.db.debug = not ns.db.debug
    ns.Print("Debug messages %s.", OnOff(ns.db.debug))
end

local STRATEGY_ALIASES = {
    coordinates = "coordinates", coordinate = "coordinates", coords = "coordinates",
    hybrid = "hybrid",
}

local function SetStrategy(argument)
    local strategy = STRATEGY_ALIASES[argument or ""]
    if not strategy then
        ns.Print("Navigation strategy: %s. Use /rxpwb mode coordinates or /rxpwb mode hybrid.", ns.db.strategy)
        return
    end
    if not STRATEGIES[strategy] then return end
    ns.db.strategy = strategy
    if strategy == "hybrid" then
        ns.Print("Navigation strategy: hybrid (experimental). Eligible quest turn-ins use native quest navigation.")
    else
        ns.Print("Navigation strategy: coordinates. All destinations use RestedXP coordinates.")
    end
    if not ns.db.autoSync then
        ns.PrintLine("Automatic sync is off; the strategy applies to /rxpwb sync and when it is turned on.")
    end
    ns.Sync.OnStrategyChanged()
end

local commands = {
    status = ns.PrintStatus,
    sync = function() ns.Sync.SyncNow() end,
    on = EnableAutoSync,
    off = DisableAutoSync,
    debug = ToggleDebug,
    mode = SetStrategy,
}

SLASH_RXPWAYPOINTBRIDGE1 = "/rxpwb"
SlashCmdList.RXPWAYPOINTBRIDGE = function(input)
    local command, argument = (input or ""):lower():match("^%s*(%S*)%s*(%S*)")
    local handler = commands[command] or ns.PrintHelp
    local ok, err = pcall(handler, argument ~= "" and argument or nil)
    if not ok then
        ns.Print("Internal error: %s", tostring(err))
    end
end

--------------------------------------------------------------------------------
-- Initialisation
--------------------------------------------------------------------------------

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGIN")
eventFrame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" then
        if arg1 ~= addonName then return end
        self:UnregisterEvent("ADDON_LOADED")
        LoadSettings()
        return
    end

    if event ~= "PLAYER_LOGIN" then return end
    self:UnregisterEvent("PLAYER_LOGIN")

    -- All non-load-on-demand addons are loaded by PLAYER_LOGIN.
    local rxp = ns.RXP.GetStatus()
    local wui = ns.WUI.GetStatus()

    ns.Print("v%s loaded (auto sync %s, strategy %s). Type /rxpwb for commands.",
        ns.GetVersion() or "?", OnOff(ns.db.autoSync), ns.db.strategy)
    if not rxp.loaded then
        ns.PrintLine("RestedXP Guides (RXPGuides) is not loaded; sync is unavailable.")
    elseif not rxp.arrowAvailable then
        ns.PrintLine("RestedXP is loaded but its arrow data (RXPG_ARROW) was not found.")
    end
    if not wui.loaded then
        ns.PrintLine("Waypoint UI (WaypointUI) is not loaded; sync is unavailable.")
    elseif not wui.apiAvailable then
        ns.PrintLine("Waypoint UI is loaded but WaypointUIAPI.Navigation was not found.")
    end

    ns.Sync.Initialize()
end)
