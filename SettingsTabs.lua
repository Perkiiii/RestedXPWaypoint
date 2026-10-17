-- Tab contents and refresh logic; widgets and layout belong to the controller.
local _, RXPW = ...
local Tabs = {}
RXPW.SettingsTabs = Tabs
local W = RXPW.SettingsWidgets

local function StrategyOption(value)
    for _, option in ipairs(RXPW.Config.STRATEGY_OPTIONS) do
        if option.value == value then return option end
    end
end

function Tabs.Build(UI, Panel)
    local c = UI.controls
    local function openAction(id)
        c[id] = UI.Action(id, "Waypoint UI Settings", "Opens Waypoint UI's own settings page.", "Open",
            function() W.CloseList(); RXPW.WUI.OpenSettings() end)
    end

    UI.Tab("General")
    UI.Header()
    UI.Container("Synchronization")
    UI.Check("autoSync", "Enable Automatic Synchronization", "Follow RestedXP's chosen destination.")
    local options = {}
    for i, option in ipairs(RXPW.Config.STRATEGY_OPTIONS) do options[i] = { value = option.value, label = option.label } end
    local strategy = UI.Dropdown(UI.content(), UI.root, options, function(value) UI.Set("strategy", value) end)
    Panel.strategyRow = UI.Row("strategy", "Navigation Strategy", nil, strategy)
    Panel.arrowRow = UI.Row("hideArrow", "Hide RestedXP Arrow", "Uses RestedXP's own arrow option.",
        UI.Checkbox(UI.content(), function(value)
            if RXPW.RXP.SetArrowHidden(value) then RXPW.Print("RestedXP's waypoint arrow is now %s.", value and "hidden" or "shown") end
            Panel.Refresh()
        end))
    UI.Container("Connection Status")
    UI.Status("statusRXP", "RestedXP Guides")
    UI.Status("statusWUI", "Waypoint UI")
    UI.Status("statusSync", "Synchronization")

    UI.Tab("Waypoint")
    UI.Container("Waypoint UI")
    Panel.integration = UI.SharedNotice("Shared Preferences",
        "Shared settings use Waypoint UI's authoritative preferences. Changes apply immediately in both menus.")
    c.openWaypoint = UI.Fallback("openWaypoint", "Waypoint")
    UI.Shared("Waypoint")

    UI.Tab("Appearance")
    UI.Container("RestedXP Waypoint Icons")
    UI.Check("questIcons", "Quest-Specific Icons", "Context icons for the bridge's quest destinations.")
    UI.Check("serviceIcons", "Service Icons", "Icons for flight masters, trainers, vendors and other services.")
    UI.Check("customColors", "Custom Waypoint Colours", "Context colours for bridge markers. Native quest markers keep Waypoint UI's appearance.")
    UI.Container("Waypoint UI Appearance")
    UI.SharedNotice()
    c.openAppearance = UI.Fallback("openAppearance", "Appearance")
    UI.Shared("Appearance")

    UI.Tab("Map")
    UI.Container("Waypoint UI")
    UI.SharedNotice()
    Panel.mapNotice = UI.Text("Map Pin Compatibility",
        "MapPinEnhanced is loaded: Waypoint UI disables its pin replacement regardless of the saved preference.")
    c.openMap = UI.Fallback("openMap", "Map")
    UI.Shared("Map", "Map Pins")

    UI.Tab("Audio")
    UI.Container("RestedXP Waypoint Audio")
    UI.Check("stepSound", "Play Sound on New RestedXP Step", "Allow the existing navigation creation sound once per genuine guide step. Waypoint UI's global sound preference still applies; marker appearance and proximity sounds are separate.")
    UI.Container("Waypoint UI Audio")
    UI.SharedNotice()
    UI.SharedNotice("Sound IDs", "Enter a numeric FileDataID, or leave blank to mute, then press Enter. Waypoint UI's own menu offers sound preview and reset controls.")
    c.openAudio = UI.Fallback("openAudio", "Audio")
    UI.Shared("Audio")

    UI.Tab("About")
    UI.Title()
    UI.Container("Addon Information", { transparent = true })
    UI.Text("RestedXP Waypoint", "An unofficial WoW Forever companion. RestedXP plans the route; Waypoint UI renders navigation.", true)
    UI.Text("Author", "Perkiiii", true)
    UI.Text("Credits", "AdaptiveX / Waypoint UI and the RestedXP team.", true)
    UI.Text("Links", "github.com/Perkiiii/RestedXPWaypoint\ngithub.com/Adaptvx/Waypoint-UI\nrestedxp.com", true)
    UI.Container("Diagnostics")
    UI.Check("debug", "Enable Debug Messages", "Print navigation decisions and diagnostic information to chat.")
    c.status = UI.Action("printStatus", "Print Status", "Writes the connection and navigation report to chat.", "Print Status",
        function() RXPW.PrintStatus() end)
    c.inspect = UI.Action("inspectStep", "Inspect Current Step", "Writes RestedXP's current step analysis to chat.", "Inspect",
        function() RXPW.PrintInspect() end)
    UI.Container("Additional Controls")
    openAction("openWaypointUI")
    c.restore = UI.Action("restoreDefaults", "Restore RestedXP Defaults", "Restores RestedXP Waypoint preferences and hides RestedXP's arrow. Waypoint UI preferences are preserved.",
        "Restore Defaults", function() Panel.ConfirmRestore() end)
    UI.Text("Development Previews", "Available through /rxpw preview; /rxpw preview off ends a preview.", true)
end

-- Connection status from the live dependency and synchronization state.
function Tabs.GetConnectionStatus()
    local rxp, wui, sync = RXPW.RXP.GetStatus(), RXPW.WUI.GetStatus(), RXPW.Sync.GetState()
    local result = {}
    if not rxp.loaded then result.rxp = { "disconnected", nil, "RestedXP Guides is not loaded." }
    elseif not rxp.arrowAvailable then result.rxp = { "error", "Arrow Unavailable", "RestedXP's waypoint arrow was not found." }
    else result.rxp = { "connected" } end
    if not wui.loaded then result.wui = { "disconnected", nil, "Waypoint UI is not loaded." }
    elseif not wui.apiAvailable then result.wui = { "error", "API Unavailable", "Waypoint UI's navigation API was not found." }
    else result.wui = { "connected" } end
    if not RXPW.db.autoSync then
        result.sync = { "disabled", nil, "Automatic synchronization is turned off." }
    elseif sync.running and sync.overrideActive then
        result.sync = { "paused", nil, "Manual navigation is respected; RestedXP resumes after it is cleared." }
    elseif sync.running then
        result.sync = { "active", nil, "Following RestedXP. Manual navigation is respected." }
    elseif RXPW.Preview and RXPW.Preview.IsActive() then
        result.sync = { "paused", nil, "A development preview is active (/rxpw preview off)." }
    elseif result.rxp[1] ~= "connected" or result.wui[1] ~= "connected" then
        result.sync = { "error", "Unavailable", "Requires RestedXP Guides and Waypoint UI." }
    else
        result.sync = { "paused", nil, "Waiting to start." }
    end
    return result
end

function Tabs.RefreshStatus(Panel, controls)
    local status = Tabs.GetConnectionStatus()
    controls.statusRXP:SetStatus(status.rxp[1], status.rxp[2], status.rxp[3])
    controls.statusWUI:SetStatus(status.wui[1], status.wui[2], status.wui[3])
    controls.statusSync:SetStatus(status.sync[1], status.sync[2], status.sync[3])
end

function Tabs.Refresh(Panel, controls)
    for _, key in ipairs({ "autoSync", "questIcons", "serviceIcons", "customColors", "debug", "stepSound" }) do
        controls[key]:SetChecked(RXPW.Config.Get(key))
    end
    local strategy = RXPW.Config.Get("strategy")
    controls.strategy:SetValue(strategy)
    local option = StrategyOption(strategy)
    Panel.strategyRow:SetDescription(option and option.description)
    local hidden = RXPW.RXP.IsArrowHidden()
    controls.hideArrow:SetChecked(hidden == true)
    W.SetEnabled(controls.hideArrow, hidden ~= nil)
    Panel.arrowRow.tooltip = hidden == nil and "RestedXP Guides is not available." or nil
    Tabs.RefreshStatus(Panel, controls)
    -- Only relevant next to the editable map rows.
    Panel.mapNotice.visible = RXPW.IsLoaded("MapPinEnhanced") and RXPW.WaypointSettings.Connect()
    local version = "Version " .. tostring(RXPW.GetVersion() or "?")
    Panel.header.version:SetText(version .. " - Unofficial RestedXP companion for Waypoint UI")
    Panel.title.subtitle:SetText(version)
    W.SetEnabled(controls.openWaypointUI, RXPW.WUI.CanOpenSettings())
end
