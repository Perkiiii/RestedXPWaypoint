-- RestedXP Waypoint
-- Core: shared helpers, saved settings, initialisation and slash commands.
-- Load order (see .toc): Core.lua, LabelResolver.lua, RXPAdapter.lua,
-- NavigationResolver.lua, WaypointAdapter.lua, Sync.lua, Preview.lua,
-- SettingsSchema.lua, WaypointSettingsAdapter.lua, SettingsWidgets.lua,
-- SettingsTabs.lua, SettingsPanel.lua

local addonName, RXPW = ...

-- Flag attached to every Waypoint UI navigation we create, so we can tell
-- bridge-owned navigation apart from the player's own.
RXPW.OWNER_FLAG = "RestedXPWaypoint"

RXPW.Label = {}
RXPW.RXP = {}
RXPW.Nav = {}
RXPW.WUI = {}
RXPW.Sync = {}

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
-- Settings (SavedVariables: RXPWDB)
--------------------------------------------------------------------------------

-- strategy: "coordinates" (v0.3 behaviour), "hybrid" (recommended default; v0.4:
-- native quest supertracking for eligible turn-ins) or "native-first" (v0.5:
-- native supertracking for eligible turn-ins and quest objectives).
local STRATEGIES = { coordinates = true, hybrid = true, ["native-first"] = true }

-- Appearance (v0.6.0) controls only what the bridge supplies to Waypoint UI
-- for its own custom navigation: questIcons / serviceIcons = context icons,
-- customColors = the quest colour or service palette (r/g/b). Native quest
-- markers are drawn by Waypoint UI and are never affected.
local DEFAULTS = {
    autoSync = true,
    debug = false,
    strategy = "hybrid",
    questIcons = true,
    serviceIcons = true,
    customColors = true,
    stepSound = true,
}
-- Restore order: presentation first, sync last (it starts evaluating).
local SETTING_ORDER = { "questIcons", "serviceIcons", "customColors", "stepSound", "debug", "strategy", "autoSync" }

-- Replaced by the saved table on ADDON_LOADED.
RXPW.db = {}
for key, value in pairs(DEFAULTS) do RXPW.db[key] = value end

local function LoadSettings()
    local db = _G.RXPWDB
    if type(db) ~= "table" then
        -- One-time default for the external arrow option. Keep it pending if
        -- RestedXP is unavailable; never overwrite a returning user's choice.
        db = { arrowDefaultPending = true, mapPinsDefaultPending = true }
        _G.RXPWDB = db
    end
    for key, value in pairs(DEFAULTS) do
        if type(db[key]) ~= type(value) then db[key] = value end
    end
    if not STRATEGIES[db.strategy] then db.strategy = DEFAULTS.strategy end
    RXPW.db = db
end

local function ApplyArrowDefault()
    if RXPW.db.arrowDefaultPending == true
        and type(RXPW.RXP.SetArrowHidden) == "function"
        and RXPW.RXP.SetArrowHidden(true) then
        RXPW.db.arrowDefaultPending = nil
    end
end

--------------------------------------------------------------------------------
-- Logging and shared helpers
--------------------------------------------------------------------------------

local PREFIX = "|cff33ff99RestedXP Waypoint|r: "
local DEBUG_PREFIX = "|cff33ff99RXPW|r |cff999999[debug]|r "

function RXPW.Print(fmt, ...)
    local text = select("#", ...) > 0 and format(fmt, ...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. text)
end

-- Continuation line without the prefix, for multi-line output.
function RXPW.PrintLine(fmt, ...)
    local text = select("#", ...) > 0 and format(fmt, ...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage("   " .. text)
end

-- Only shown while /rxpw debug is on.
function RXPW.Debug(fmt, ...)
    if not RXPW.db.debug then return end
    local text = select("#", ...) > 0 and format(fmt, ...) or fmt
    DEFAULT_CHAT_FRAME:AddMessage(DEBUG_PREFIX .. text)
end

function RXPW.GetVersion(addon)
    if not GetAddOnMetadata then return nil end
    local ok, version = pcall(GetAddOnMetadata, addon or addonName, "Version")
    return ok and version or nil
end

function RXPW.IsLoaded(addon)
    if not IsAddOnLoaded then return false end
    local ok, loaded = pcall(IsAddOnLoaded, addon)
    return ok and loaded and true or false
end

function RXPW.IsFiniteNumber(n)
    return type(n) == "number" and n == n and n ~= huge and n ~= -huge
end

function RXPW.FormatCoord(n)
    return RXPW.IsFiniteNumber(n) and format("%.2f", n) or tostring(n)
end

-- "Label - map 1429 (Elwynn Forest) @ 42.10, 65.30"
function RXPW.DescribeTarget(target)
    return format("%s - map %s%s @ %s, %s",
        target.label or "RestedXP", tostring(target.mapID),
        target.mapName and (" (" .. target.mapName .. ")") or "",
        RXPW.FormatCoord(target.x), RXPW.FormatCoord(target.y))
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

function RXPW.PrintHelp()
    RXPW.Print("RestedXP Waypoint v%s commands:", RXPW.GetVersion() or "?")
    RXPW.PrintLine("Usage: /rxpw <command> [arguments]")
    RXPW.PrintLine("/rxpw config - open the settings page (Options > AddOns > RestedXP Waypoint)")
    RXPW.PrintLine("/rxpw status - show dependency, waypoint and sync status")
    RXPW.PrintLine("/rxpw sync - send RestedXP's current waypoint to Waypoint UI now")
    RXPW.PrintLine("/rxpw on - enable automatic sync (currently %s)", OnOff(RXPW.db.autoSync))
    RXPW.PrintLine("/rxpw off - disable automatic sync")
    RXPW.PrintLine("/rxpw debug - toggle debug messages (currently %s)", OnOff(RXPW.db.debug))
    RXPW.PrintLine("/rxpw mode coordinates - use RestedXP coordinates for every destination")
    RXPW.PrintLine("/rxpw mode hybrid - use native navigation for eligible turn-ins")
    RXPW.PrintLine("/rxpw mode native-first - use native navigation for eligible objectives and turn-ins")
    RXPW.PrintLine("Current navigation strategy: %s", RXPW.db.strategy)
    RXPW.PrintLine("/rxpw inspect - show how the resolver reads RestedXP's current step")
    RXPW.PrintLine("/rxpw preview all close - cycle through all marker icons nearby")
    RXPW.PrintLine("/rxpw preview all far - cycle through all marker icons farther away")
    RXPW.PrintLine("/rxpw preview next - show the next marker icon")
    RXPW.PrintLine("/rxpw preview flightmaster - show the flightmaster marker icon")
    RXPW.PrintLine("/rxpw preview off - remove the preview and resume automatic sync")
end

local KIND_NAMES = { turnin = "turn-in", objective = "objective" }

local function DescribeMode(mode, questID, kind)
    if mode == "native" then
        local text = questID and format("native quest %d", questID) or "native quest"
        return KIND_NAMES[kind] and format("%s (%s)", text, KIND_NAMES[kind]) or text
    end
    return mode or "none"
end

-- Navigation, quest context and presentation lines. They are independent:
-- navigation (role, coordinates) is what RestedXP's waypoint is; the quest
-- context (native-first structural analysis, in every strategy since v0.5.6)
-- decides the marker icon and colour. For coordinate decisions the target is
-- prepared like Sync does (RXPW.Sync.PrepareTarget: label, icon, tint), so the
-- caller can compare it with what Waypoint UI shows.
local QUEST_KIND_NAMES = { accept = "accept", turnin = "turn-in", objective = "objective" }

local function PrintContext(decision, target)
    local ctx = target and RXPW.Nav.GetContextDecision(target, decision) or decision
    local iconName, tintName, p
    if target and decision.mode ~= "native" then
        iconName, tintName = select(2, RXPW.Sync.PrepareTarget(target, decision))
        p = target.presentation
    end

    if target then
        RXPW.PrintLine("Navigation: %s | role: %s | route-critical: %s | map %s @ %s, %s",
            DescribeMode(decision.mode, decision.questID, decision.kind), tostring(ctx.role or "-"),
            YesNo(ctx.routeCritical), tostring(target.mapID), RXPW.FormatCoord(target.x), RXPW.FormatCoord(target.y))
    elseif decision.role then
        RXPW.PrintLine("Waypoint role: %s | route-critical: %s", decision.role, YesNo(decision.routeCritical))
    end
    local c = ctx.context
    if c then
        RXPW.PrintLine("Quest context: quest %d %s | %s | from %s", c.questID, c.title,
            c.kind == "turnin" and (c.ready and "turn-in, ready" or "turn-in") or "objective", tostring(c.source))
    elseif p and p.questID then
        -- No structural quest target (a route point, an accept): the quest of
        -- the waypoint's own step, which is what the marker shows.
        RXPW.PrintLine("Quest context: quest %d %s | %s, %s | from %s", p.questID, tostring(p.title or "?"),
            QUEST_KIND_NAMES[p.kind] or tostring(p.kind), tostring(p.status):lower(), tostring(p.source))
    else
        RXPW.PrintLine("Quest context: none")
    end
    if decision.continuity then
        RXPW.PrintLine("Native continuity: %s - %s", decision.continuity.ok and "preserved" or "not used",
            tostring(decision.continuity.detail))
    end
    if not target then return end
    if decision.mode == "native" then
        RXPW.PrintLine("Marker icon: Waypoint UI's native quest marker")
        return
    end
    local category = "default (travel or other)"
    if p and p.service then
        category = "service " .. p.service
    elseif p then
        category = format("quest %d %s", p.questID, tostring(p.status))
    end
    RXPW.PrintLine("Marker icon: %s | %s | colour: %s", category,
        iconName and (p and format("%s (%s)", iconName, tostring(p.source)) or iconName) or "Waypoint UI default",
        target.tint and tostring(tintName) or "Waypoint UI default")
    RXPW.PrintLine("Marker texture: %s", target.iconTexture or "Waypoint UI default")
    if p and p.serviceSource then RXPW.PrintLine("Service source: %s", p.serviceSource) end
    if p then
        RXPW.PrintLine("Icon reason: %s", p.iconReason or (p.service and "service directive" or "quest instruction"))
        if p.rejectedService then RXPW.Debug("Icon service rejected: %s", p.rejectedService) end
    end
end

-- Candidate lines for a shared-circuit (multi-quest) decision.
local function PrintCandidates(decision)
    if not decision.candidates then return end
    for _, c in ipairs(decision.candidates) do
        RXPW.PrintLine("Candidate %d: %s%s - %s%s", c.questID, tostring(c.title or "?"),
            c.progress and (" - " .. c.progress) or "", c.eligible and "eligible" or tostring(c.reason),
            c.selected and " [selected]" or "")
    end
    if decision.questID and decision.selection then
        RXPW.PrintLine("Selected %d: %s", decision.questID, decision.selection)
    end
end

function RXPW.PrintStatus()
    local rxp = RXPW.RXP.GetStatus()
    local wui = RXPW.WUI.GetStatus()
    local sync = RXPW.Sync.GetState()

    RXPW.Print("status (v%s)", RXPW.GetVersion() or "?")
    RXPW.PrintLine("RestedXP loaded: %s%s | arrow data: %s",
        YesNo(rxp.loaded), rxp.version and (" (" .. rxp.version .. ")") or "", YesNo(rxp.arrowAvailable))
    RXPW.PrintLine("Waypoint UI loaded: %s%s | navigation API: %s",
        YesNo(wui.loaded), wui.version and (" (" .. wui.version .. ")") or "", YesNo(wui.apiAvailable))

    local target, reason = RXPW.RXP.GetTarget()
    if target then
        RXPW.PrintLine("RXP waypoint: map %s%s @ %s, %s",
            tostring(target.mapID), target.mapName and (" (" .. target.mapName .. ")") or "",
            RXPW.FormatCoord(target.x), RXPW.FormatCoord(target.y))
        RXPW.PrintLine("RXP label: %s", target.label or "(none)")
        local info = target.labelInfo
        if info then
            RXPW.PrintLine("Label source: %s | cleaned: %s | shortened: %s | fallback: %s",
                info.source, YesNo(info.cleaned), YesNo(info.shortened), YesNo(info.fallback))
            if RXPW.db.debug and info.raw then
                -- Doubled pipes make chat show the escape codes literally.
                RXPW.PrintLine("Label raw text: %s", (info.raw:gsub("|", "||")))
            end
        end
        RXPW.PrintLine("RXP step: %s%s | arrow shown: %s",
            tostring(target.stepIndex or "-"),
            target.hasStep and (target.stepActive and " (active)" or " (inactive)") or "",
            YesNo(target.arrowShown))
    end
    if reason then
        RXPW.PrintLine("Ready to sync: %s - %s", YesNo(false), reason)
    else
        RXPW.PrintLine("Ready to sync: %s", YesNo(wui.apiAvailable))
        local decision = RXPW.Nav.Decide(target, RXPW.db.strategy, RXPW.Sync.GetDecisionContext())
        PrintCandidates(decision)
        if decision.questID then
            local qs = decision.questState or {}
            RXPW.PrintLine("Quest: %d (%s) | %s | in log: %s | ready for turn-in: %s",
                decision.questID, tostring(decision.questName or "?"),
                tostring(decision.classification or decision.kind or "?"), YesNo(qs.inLog), YesNo(qs.ready))
            if decision.progress then
                RXPW.PrintLine("Objectives RestedXP targets here: %s", decision.progress)
            end
            if (decision.pendingTurnIns or 1) > 1 then
                RXPW.PrintLine("Turn-ins pending at this destination: %d (first one is used)", decision.pendingTurnIns)
            end
        end
        RXPW.PrintLine("Native eligible (%s analysis): %s", decision.analysis or "?", YesNo(decision.nativeEligible))
        RXPW.PrintLine("Decision (%s): %s - %s", RXPW.db.strategy,
            DescribeMode(decision.mode, decision.questID, decision.kind), tostring(decision.reason))
        PrintContext(decision, target)
    end

    local nav = RXPW.WUI.GetNavigation()
    if nav then
        local x = RXPW.IsFiniteNumber(nav.x) and nav.x * 100 or nil
        local y = RXPW.IsFiniteNumber(nav.y) and nav.y * 100 or nil
        RXPW.PrintLine("Waypoint UI destination: %s, map %s @ %s, %s (%s)",
            tostring(nav.name or "?"), tostring(nav.mapID), RXPW.FormatCoord(x), RXPW.FormatCoord(y),
            nav.flags == RXPW.OWNER_FLAG and ("set by RestedXP Waypoint" .. (nav.iconTexture and ", custom icon" or "")) or "not set by RestedXP Waypoint")
    else
        RXPW.PrintLine("Waypoint UI destination: none")
    end
    if nav and nav.flags == RXPW.OWNER_FLAG then
        RXPW.PrintLine("Stored bridge marker: %s (active navigation ownership: %s)",
            RXPW.WUI.IsOwnedNavigationTracked() and "actively followed" or "retained, inactive", YesNo(sync.bridgeActive))
    end
    if sync.markerCleanup then RXPW.PrintLine("Marker cleanup: %s", sync.markerCleanup) end
    if sync.trackingEvidence then
        RXPW.PrintLine("Last quest setter evidence: quest %d, %s", sync.trackingEvidence.questID, sync.trackingEvidence.source)
    end
    if target and not reason and nav and nav.flags == RXPW.OWNER_FLAG and target.label then
        local same = RXPW.WUI.IsShowingTarget(target)
        RXPW.PrintLine("Objective label: RestedXP \"%s\" | expected \"%s\" | displayed \"%s\" | stale: %s",
            tostring(target.rxpLabel or target.label), target.label, tostring(nav.name),
            same and YesNo(nav.name ~= target.label or nav.iconTexture ~= target.iconTexture)
                or "n/a (Waypoint UI is not following this destination)")
    end

    RXPW.PrintLine("Auto sync: %s%s | strategy: %s | debug: %s", OnOff(RXPW.db.autoSync),
        RXPW.db.autoSync and (sync.running and " (running)" or " (not running)") or "",
        RXPW.db.strategy, OnOff(RXPW.db.debug))
    RXPW.PrintLine("Active mode: %s%s | RestedXP Waypoint owns active destination: %s",
        DescribeMode(sync.mode, sync.questID, sync.kind),
        sync.areaCheck and " (re-checking the native target for RestedXP's new activity)"
            or sync.pending and " (transition in progress)" or "",
        YesNo(sync.bridgeActive))
    if sync.lastTransition then
        RXPW.PrintLine("Last transition: %s%s", sync.lastTransition.text, Ago(sync.lastTransition.time))
    end
    if sync.lastFailure then
        RXPW.PrintLine("Last failure/fallback: %s%s", sync.lastFailure.text, Ago(sync.lastFailure.time))
    end
    if sync.lastSynced then
        local prefix = sync.lastSynced.mode == "native"
            and format("[%s] ", DescribeMode("native", sync.lastSynced.questID)) or ""
        RXPW.PrintLine("Last synced: %s%s%s", prefix, RXPW.DescribeTarget(sync.lastSynced), Ago(sync.lastSynced.time))
        if sync.lastSynced.labelSource then
            RXPW.PrintLine("Last synced label source: %s", sync.lastSynced.labelSource)
        end
    else
        RXPW.PrintLine("Last synced: none this session")
    end
    if sync.lastResult then
        RXPW.PrintLine("Last result: %s%s", sync.lastResult, Ago(sync.lastResultTime))
    end
    if sync.external then
        RXPW.PrintLine("Outside change: %s", sync.external)
    end
    if sync.overrideActive then
        RXPW.PrintLine("Automatic sync: %s", sync.resumePending and "waiting for the one-second resume delay"
            or "paused for external navigation; resumes one second after it ends")
    end
    if sync.guideTrackingQuest then
        RXPW.PrintLine("Guide quest tracking: quest %d (observed RestedXP setter)", sync.guideTrackingQuest)
    end
    if sync.inheritedQuest then
        RXPW.PrintLine("Startup quest: quest %d (origin unknown; does not suspend sync)", sync.inheritedQuest)
    end
end

--------------------------------------------------------------------------------
-- Configuration (v0.6.0): the single place a setting changes
--
-- RXPWDB is the only store. /rxpw commands and the settings panel both call
-- Config.Set, which validates, saves, applies the existing behaviour (start or
-- stop sync, strategy re-evaluation, presentation refresh) and notifies
-- listeners such as the settings panel. Nothing keeps a second copy.
--------------------------------------------------------------------------------

local Config = {}
RXPW.Config = Config
Config.STRATEGIES = { "coordinates", "hybrid", "native-first" }
-- Settings page order and names. Only the labels are new: saved values and
-- /rxpw mode keep the ids, and each strategy's behaviour is unchanged.
Config.STRATEGY_OPTIONS = {
    { value = "hybrid", label = "Hybrid (Recommended)",
        description = "Uses Blizzard quest waypoints where appropriate, while following RestedXP coordinates for travel and other guide instructions." },
    { value = "coordinates", label = "RestedXP Coordinates",
        description = "Always follows RestedXP's coordinates for navigation." },
    { value = "native-first", label = "Blizzard Waypoints",
        description = "Prioritizes Blizzard's native quest navigation when available, falling back to RestedXP coordinates when necessary." },
}

local listeners = {}

function Config.Get(key)
    return RXPW.db[key]
end

function Config.GetDefault(key)
    return DEFAULTS[key]
end

-- fn(key) is called after a setting (or "preview" state) changed.
function Config.RegisterListener(fn)
    listeners[#listeners + 1] = fn
end

function Config.Notify(key)
    for _, fn in ipairs(listeners) do
        local ok, err = pcall(fn, key)
        if not ok then RXPW.Debug("Settings listener error: %s", tostring(err)) end
    end
end

local function ApplyAutoSync(enabled)
    if enabled then
        if RXPW.Preview and RXPW.Preview.IsActive() then RXPW.Preview.Off(true) end
        if RXPW.Sync.Start() then
            RXPW.Print("Automatic sync enabled.")
        else
            RXPW.Print("Automatic sync enabled, but RestedXP or Waypoint UI is unavailable (see /rxpw status).")
        end
    else
        RXPW.Sync.Stop()
        RXPW.Print("Automatic sync disabled. The current Waypoint UI destination was left unchanged.")
    end
end

local function ApplyStrategy(strategy)
    if strategy == "native-first" then
        RXPW.Print("Navigation strategy: native-first (experimental). Quest turn-ins and objectives RestedXP is leading you to use native quest navigation; travel uses RestedXP coordinates.")
    elseif strategy == "hybrid" then
        RXPW.Print("Navigation strategy: hybrid. Eligible quest turn-ins use native quest navigation.")
    else
        RXPW.Print("Navigation strategy: coordinates. All destinations use RestedXP coordinates.")
    end
    if not RXPW.db.autoSync then
        RXPW.PrintLine("Automatic sync is off; the strategy applies to /rxpw sync and when it is turned on.")
    end
    RXPW.Sync.OnStrategyChanged()
end

local function ApplyAppearance()
    RXPW.Sync.OnPresentationChanged()
end

local APPLY = {
    autoSync = ApplyAutoSync,
    strategy = ApplyStrategy,
    debug = function(enabled) RXPW.Print("Debug messages %s.", OnOff(enabled)) end,
    questIcons = ApplyAppearance,
    serviceIcons = ApplyAppearance,
    customColors = ApplyAppearance,
    stepSound = function() end, -- read at the next existing navigation write; no synthetic audio
}

-- Saves and applies a setting. Returns true when the value was valid.
-- Like the slash commands always did, an unchanged value is applied again
-- (e.g. /rxpw on restarts sync if needed); the panel only calls it on change.
function Config.Set(key, value)
    local default = DEFAULTS[key]
    if default == nil or type(value) ~= type(default) then return false end
    if key == "strategy" and not STRATEGIES[value] then return false end
    RXPW.db[key] = value
    APPLY[key](value)
    Config.Notify(key)
    return true
end

function Config.Toggle(key)
    return Config.Set(key, not RXPW.db[key])
end

-- Resets this page's settings through Config.Set and the approved RXP adapter.
-- Also hides RestedXP's arrow. Auto-sync/strategy can resume or change bridge
-- navigation; Waypoint UI settings stay.
function Config.RestoreDefaults()
    for _, key in ipairs(SETTING_ORDER) do
        if RXPW.db[key] ~= DEFAULTS[key] then Config.Set(key, DEFAULTS[key]) end
    end
    RXPW.db.arrowDefaultPending = true
    ApplyArrowDefault()
    RXPW.Print("Settings restored to their defaults.")
    Config.Notify("defaults")
end

local function EnableAutoSync() Config.Set("autoSync", true) end
local function DisableAutoSync() Config.Set("autoSync", false) end
local function ToggleDebug() Config.Toggle("debug") end

local STRATEGY_ALIASES = {
    coordinates = "coordinates", coordinate = "coordinates", coords = "coordinates",
    hybrid = "hybrid",
    ["native-first"] = "native-first", nativefirst = "native-first", native = "native-first",
}

local function SetStrategy(argument)
    local strategy = STRATEGY_ALIASES[argument or ""]
    if not strategy then
        RXPW.Print("Navigation strategy: %s. Use /rxpw mode coordinates, hybrid or native-first.", RXPW.db.strategy)
        return
    end
    Config.Set("strategy", strategy)
end

local function OpenSettings()
    if not (RXPW.SettingsPanel and RXPW.SettingsPanel.Open()) then
        RXPW.Print("The settings page is not available in this client; use the /rxpw commands.")
    end
end

-- On-demand dump of what the navigation resolver sees (never printed automatically).
function RXPW.PrintInspect()
    RXPW.Print("inspect (strategy %s)", RXPW.db.strategy)
    local target, reason = RXPW.RXP.GetTarget()
    if not target then
        RXPW.PrintLine("No RestedXP waypoint: %s", tostring(reason))
        return
    end
    RXPW.PrintLine("RXP waypoint: step %s, map %s @ %s, %s%s", tostring(target.stepIndex or "-"), tostring(target.mapID),
        RXPW.FormatCoord(target.x), RXPW.FormatCoord(target.y), reason and (" (not usable: " .. reason .. ")") or "")
    for _, line in ipairs(RXPW.Nav.Inspect(target.element)) do
        RXPW.PrintLine("%s", line)
    end
    if reason then return end

    local decision = RXPW.Nav.Decide(target, "native-first", RXPW.Sync.GetDecisionContext())
    PrintCandidates(decision)
    RXPW.PrintLine("Native-first analysis: %s - %s", YesNo(decision.nativeEligible), tostring(decision.reason))
    PrintContext(decision, target)
    if decision.questID then
        RXPW.PrintLine("Candidate: quest %d (%s), %s%s", decision.questID, tostring(decision.questName or "?"),
            tostring(decision.classification or decision.kind or "?"),
            decision.progress and (", targets " .. decision.progress) or "")
    end
    if RXPW.db.strategy ~= "native-first" then
        local current = RXPW.Nav.Decide(target, RXPW.db.strategy, RXPW.Sync.GetDecisionContext())
        RXPW.PrintLine("Current strategy (%s): %s - %s", RXPW.db.strategy,
            DescribeMode(current.mode, current.questID, current.kind), tostring(current.reason))
    end

    local sync = RXPW.Sync.GetState()
    RXPW.PrintLine("Active mode: %s", DescribeMode(sync.mode, sync.questID, sync.kind))
    if sync.lastVerification then
        local v = sync.lastVerification
        RXPW.PrintLine("Last native verification: quest %d %s - %s%s", v.questID, v.ok and "passed" or "FAILED",
            tostring(v.detail), Ago(v.time))
    else
        RXPW.PrintLine("Last native verification: none this session")
    end
end

local commands = {
    inspect = RXPW.PrintInspect,
    preview = function(argument) RXPW.Preview.Command(argument) end,
    status = RXPW.PrintStatus,
    sync = function() RXPW.Sync.SyncNow() end,
    on = EnableAutoSync,
    off = DisableAutoSync,
    debug = ToggleDebug,
    mode = SetStrategy,
    config = OpenSettings,
    settings = OpenSettings,
    options = OpenSettings,
}

SLASH_RESTEDXPWAYPOINT1 = "/rxpw"
SlashCmdList.RESTEDXPWAYPOINT = function(input)
    -- argument: the rest of the line (e.g. "all far" for /rxpw preview all far)
    local command, argument = (input or ""):lower():match("^%s*(%S*)%s*(.-)%s*$")
    local handler = commands[command] or RXPW.PrintHelp
    local ok, err = pcall(handler, argument ~= "" and argument or nil)
    if not ok then
        RXPW.Print("Internal error: %s", tostring(err))
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
        -- The settings page needs no dependency; it registers even if
        -- RestedXP or Waypoint UI is missing.
        if RXPW.SettingsPanel then RXPW.SettingsPanel.Initialize() end
        return
    end

    if event ~= "PLAYER_LOGIN" then return end
    self:UnregisterEvent("PLAYER_LOGIN")

    -- All non-load-on-demand addons are loaded by PLAYER_LOGIN.
    ApplyArrowDefault()
    if RXPW.WaypointSettings then RXPW.WaypointSettings.ApplyFirstRunDefault() end
    local rxp = RXPW.RXP.GetStatus()
    local wui = RXPW.WUI.GetStatus()

    RXPW.Print("v%s loaded (auto sync %s, strategy %s). Type /rxpw for commands.",
        RXPW.GetVersion() or "?", OnOff(RXPW.db.autoSync), RXPW.db.strategy)
    if not rxp.loaded then
        RXPW.PrintLine("RestedXP Guides (RXPGuides) is not loaded; sync is unavailable.")
    elseif not rxp.arrowAvailable then
        RXPW.PrintLine("RestedXP is loaded but its arrow data (RXPG_ARROW) was not found.")
    end
    if not wui.loaded then
        RXPW.PrintLine("Waypoint UI (WaypointUI) is not loaded; sync is unavailable.")
    elseif not wui.apiAvailable then
        RXPW.PrintLine("Waypoint UI is loaded but WaypointUIAPI.Navigation was not found.")
    end

    RXPW.Sync.Initialize()
end)
