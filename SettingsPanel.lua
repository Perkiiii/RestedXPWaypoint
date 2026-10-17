-- One settings category laid out like Waypoint UI's own settings frame
-- (Code/Settings/Settings_UI.lua and Settings_Widgets.lua): a 212 px sidebar
-- with a divider, and one page per tab, each with its own scroll frame, shown
-- and hidden by SelectTab exactly as Waypoint UI's OpenTabByIndex does.
-- Preferences stay with their owner: RXPW.Config, RestedXP's arrow option, or
-- Waypoint UI's optional public Settings API (WaypointSettingsAdapter.lua).
local addonName, RXPW = ...
local Panel = {}
RXPW.SettingsPanel = Panel
local W = RXPW.SettingsWidgets
local Text, Art, Outset = W.Text, W.Art, W.Outset
local GOLD, WHITE = W.GOLD, W.WHITE
local CloseList, HideTooltip, ShowTooltip = W.CloseList, W.HideTooltip, W.ShowTooltip
Panel.CloseList = CloseList
local NAME = "RestedXP Waypoint"
local LOGO_TEXTURE = "Interface\\AddOns\\" .. addonName .. "\\Art\\Logo"
local floor, max, min = math.floor, math.max, math.min

Panel.tabs = { "General", "Waypoint", "Appearance", "Map", "Audio", "About" }
local FOOTER = { About = true }

-- Waypoint UI geometry (values from its source).
local SIDEBAR_WIDTH = 212        -- Sidebar
local SIDEBAR_INSET = 22.5       -- Sidebar.Content: Fill{ delta = 45 }
local TAB_HEIGHT, TAB_SPACING = 35, 3
local DIVIDER_COLOR = { 142.5 / 255, 142.5 / 255, 142.5 / 255, 0.2375 }
local CONTENT_INSET = 17.5       -- Content.Container: 100% - 35
local SCROLLBAR_GAP = 22         -- Tab content: 100% - (17 + 5)
local SCROLLBAR_INSET = 17.5     -- ScrollBar height: 100% - 35
local PAGE_TOP, PAGE_SPACING, PAGE_BOTTOM = 22, 10, 32
local OVERSCROLL = 240           -- ScrollContainer content: Fit{ delta = 240 }
local TITLE_HEIGHT, TITLE_X = 32, 15
local CONTAINER_PAD, CONTAINER_TAIL = 12.5, 7
local ROW_MARGIN, ROW_MIN, ROW_SPACING = 20, 17, 10
local INFO_X, INFO_SPACING, ACTION_X, INDENT = 10, 5, 2, 15
-- Placement relative to Blizzard's settings canvas (Settings.lua OnShow).
local CANVAS_LEFT, CANVAS_TOP, CANVAS_BOTTOM = 16, 10, 6

local canvas, root, sidebar, contentArea
local pages, tabButtons, controls = {}, {}, {}
local sharedRows, sharedGroups = {}, {}
local built = false
local activeTab
local building, container
Panel.controls = controls
Panel.pages = pages
Panel.tabButtons = tabButtons

--------------------------------------------------------------------------------
-- Pages and blocks. A page is a column of blocks (header, title, containers);
-- a container holds rows. Layout() measures text, so descriptions wrap.
--------------------------------------------------------------------------------

local function NewPage(name)
    local page = { name = name, blocks = {} }
    page.frame = CreateFrame("Frame", nil, contentArea)
    page.frame:SetAllPoints(contentArea)
    page.scroll = CreateFrame("ScrollFrame", nil, page.frame)
    page.scroll:SetPoint("TOPLEFT", page.frame, "TOPLEFT", 0, 0)
    page.scroll:SetPoint("BOTTOMRIGHT", page.frame, "BOTTOMRIGHT", -SCROLLBAR_GAP, 0)
    if page.scroll.SetClipsChildren then page.scroll:SetClipsChildren(true) end
    page.content = CreateFrame("Frame", nil, page.scroll)
    page.content:SetSize(400, 1)
    page.scroll:SetScrollChild(page.content)
    page.scrollbar = W.ScrollBar(page.frame, page.scroll, function() CloseList() end)
    page.scrollbar:SetPoint("TOPRIGHT", page.frame, "TOPRIGHT", 0, -SCROLLBAR_INSET)
    page.scrollbar:SetPoint("BOTTOMRIGHT", page.frame, "BOTTOMRIGHT", 0, SCROLLBAR_INSET)
    page.scroll:SetScript("OnSizeChanged", function()
        if page.frame:IsShown() then Panel.LayoutPage(page) end
    end)
    -- Waypoint UI's tab intro: invisible for 0.1 s, then fade in over 0.2 s.
    if page.frame.CreateAnimationGroup then
        local group = page.frame:CreateAnimationGroup()
        local hold = group:CreateAnimation("Alpha")
        hold:SetFromAlpha(0); hold:SetToAlpha(0); hold:SetDuration(0.1); hold:SetOrder(1)
        local fade = group:CreateAnimation("Alpha")
        fade:SetFromAlpha(0); fade:SetToAlpha(1); fade:SetDuration(0.2); fade:SetOrder(2)
        page.intro = group
    end
    page.frame:Hide()
    pages[name] = page
    return page
end

local function AddBlock(block)
    building.blocks[#building.blocks + 1] = block
    block.page = building
    return block
end

-- ContainerWithTitle: gold 14 pt title in a 32 px strip, then the rounded
-- container 12.5 px around its rows; 7 px below it.
local function Container(title, options)
    options = options or {}
    local frame = CreateFrame("Frame", nil, building.content)
    frame.title = Text(frame, 14, GOLD, 1, "LEFT")
    frame.title:SetPoint("LEFT", frame, "TOPLEFT", TITLE_X, -TITLE_HEIGHT / 2)
    frame.title:SetText(title)
    frame.main = CreateFrame("Frame", nil, frame)
    frame.main:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -TITLE_HEIGHT)
    frame.main:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, -TITLE_HEIGHT)
    frame.background = frame.main:CreateTexture(nil, "BACKGROUND")
    Outset(frame.background, frame.main, 3.5, 3.5, 3.5)
    Art(frame.background, options.nested and "Subcontainer" or "Container")
    if options.transparent then frame.background:SetAlpha(0) end
    local block = { kind = "container", frame = frame, title = title, rows = {}, transparent = options.transparent }
    function block:Layout(width)
        frame.title:SetWidth(max(1, width - TITLE_X * 2))
        local inner = width - CONTAINER_PAD * 2
        local y, any = 0, false
        for _, row in ipairs(self.rows) do
            local visible = row.visible ~= false
            row.frame:SetShown(visible)
            if visible then
                if any then y = y + ROW_SPACING end
                local h = row:Layout(inner)
                row.frame:ClearAllPoints()
                row.frame:SetPoint("TOPLEFT", frame.main, "TOPLEFT", CONTAINER_PAD, -(CONTAINER_PAD + y))
                row.frame:SetSize(inner, h)
                y, any = y + h, true
            end
        end
        local mainHeight = y + CONTAINER_PAD * 2
        frame.main:SetHeight(mainHeight)
        return TITLE_HEIGHT + mainHeight + CONTAINER_TAIL
    end
    container = block
    Panel.containers = Panel.containers or {}
    Panel.containers[#Panel.containers + 1] = block
    return AddBlock(block)
end

-- ElementBase: label (12) and faded description (11) on the left, the control
-- right-aligned; 10 px above and below; hover shows Widget-Background.
local function Row(id, label, description, control, options)
    options = options or {}
    local frame = CreateFrame("Frame", nil, container.frame.main)
    frame.hover = frame:CreateTexture(nil, "BACKGROUND")
    Outset(frame.hover, frame, 5, 5, 5)
    Art(frame.hover, "Widget")
    frame.hover:Hide()
    frame.label = Text(frame, 12, WHITE, 1)
    frame.label:SetText(label)
    frame.desc = Text(frame, 11, WHITE, 0.5)
    local item = { kind = "row", frame = frame, control = control, id = id, label = label,
        description = description, indent = options.indent or 0, tooltip = options.tooltip,
        stacked = options.stacked }
    if options.icon then
        frame.icon = frame:CreateTexture(nil, "ARTWORK")
        frame.icon:SetSize(16, 16)
    end
    local function Hover()
        if frame:IsMouseOver() then
            if not container.transparent and not options.transparent then frame.hover:Show() end
            if item.tooltip then ShowTooltip(frame, label, item.tooltip) end
        end
    end
    local function Unhover()
        if not frame:IsMouseOver() then frame.hover:Hide(); HideTooltip() end
    end
    frame:EnableMouse(true)
    frame:SetScript("OnEnter", Hover)
    frame:SetScript("OnLeave", Unhover)
    if control then
        control:SetParent(frame)
        control:HookScript("OnEnter", Hover)
        control:HookScript("OnLeave", Unhover)
    end
    function item:SetDescription(text)
        self.description = text
    end
    function item:Layout(width)
        local indent = self.indent * INDENT
        local x = INFO_X + indent
        local available = width - indent
        local infoWidth = floor(available * 0.55) - ROW_MARGIN
        if self.stacked then
            infoWidth = available - INFO_X * 2
        elseif control then
            local actionWidth = floor(available * 0.45) - ROW_MARGIN
            control.maxWidth = max(actionWidth, available - INFO_X - 120 - ACTION_X)
            if control.Resize then control:Resize() end
            -- Never let a wide control overlap the text: the text wraps instead.
            infoWidth = min(infoWidth, available - INFO_X - control:GetWidth() - ACTION_X - 12)
            control:ClearAllPoints()
            control:SetPoint("RIGHT", frame, "RIGHT", -ACTION_X, 0)
        elseif self.wide then
            infoWidth = available - INFO_X * 2
        end
        local textX = x
        if frame.icon then
            frame.icon:ClearAllPoints()
            textX = x + 22
        end
        infoWidth = max(60, infoWidth - (textX - x))
        frame.label:ClearAllPoints()
        frame.label:SetPoint("TOPLEFT", frame, "TOPLEFT", textX, -ROW_MARGIN / 2)
        frame.label:SetWidth(infoWidth)
        local height = frame.label:GetStringHeight()
        local hasDescription = self.description ~= nil and self.description ~= ""
        frame.desc:SetShown(hasDescription)
        if hasDescription then
            frame.desc:SetText(self.description)
            frame.desc:ClearAllPoints()
            frame.desc:SetPoint("TOPLEFT", frame.label, "BOTTOMLEFT", 0, -INFO_SPACING)
            frame.desc:SetWidth(infoWidth)
            height = height + INFO_SPACING + frame.desc:GetStringHeight()
        end
        if self.stacked and control then
            -- Text across the row, the button below it (fallback actions).
            control.maxWidth = infoWidth
            if control.Resize then control:Resize() end
            control:ClearAllPoints()
            control:SetPoint("TOPLEFT", frame, "TOPLEFT", textX, -(ROW_MARGIN / 2 + height + ROW_SPACING))
            height = height + ROW_SPACING + control:GetHeight()
        end
        height = max(ROW_MIN, height)
        if frame.icon then frame.icon:SetPoint("TOPLEFT", frame, "TOPLEFT", x, -ROW_MARGIN / 2 + 1) end
        return height + ROW_MARGIN
    end
    if id then controls[id] = control or item end
    container.rows[#container.rows + 1] = item
    return item
end

-- Text element (Waypoint UI "Text" widget): label and description only.
local function TextRow(label, description, wide)
    local item = Row(nil, label, description)
    item.wide = wide
    return item
end

-- Element Button: label and description, red text button on the right.
local function Action(id, label, description, buttonText, onClick)
    local button = W.Button(building.content, buttonText, onClick)
    Row(id, label, description, button)
    return button
end

--------------------------------------------------------------------------------
-- Branding: compact header on General, Waypoint UI-style title on About.
--------------------------------------------------------------------------------

local LOGO_SIZE = 48
local FALLBACK_TEXT = "These options belong to Waypoint UI. This Waypoint UI version has no public settings API, "
    .. "so they are changed in its own menu. Waypoint UI cannot be asked to open a particular tab: it opens "
    .. "where you last left it (General the first time); then select %s."

local function Header()
    local frame = CreateFrame("Frame", nil, building.content)
    frame.logo = frame:CreateTexture(nil, "ARTWORK")
    frame.logo:SetTexture(LOGO_TEXTURE)
    frame.logo:SetSize(LOGO_SIZE, LOGO_SIZE)
    frame.logo:SetPoint("LEFT", frame, "LEFT", TITLE_X - 4, 0)
    frame.name = Text(frame, 16, WHITE, 1)
    frame.name:SetPoint("BOTTOMLEFT", frame.logo, "RIGHT", 10, 1)
    frame.name:SetText(NAME)
    frame.version = Text(frame, 11, WHITE, 0.5)
    frame.version:SetPoint("TOPLEFT", frame.logo, "RIGHT", 10, -3)
    Panel.header = frame
    return AddBlock({ kind = "header", frame = frame, Layout = function(_, width)
        frame.name:SetWidth(max(80, width - LOGO_SIZE - 40))
        frame.version:SetWidth(max(80, width - LOGO_SIZE - 40))
        return LOGO_SIZE + 4
    end })
end

local function Title()
    local frame = CreateFrame("Frame", nil, building.content)
    frame.icon = frame:CreateTexture(nil, "BACKGROUND")
    frame.icon:SetTexture(LOGO_TEXTURE)
    frame.icon:SetSize(138, 138)
    frame.icon:SetPoint("CENTER")
    frame.icon:SetAlpha(0.0975)
    if frame.icon.SetGradient and type(CreateColor) == "function" then
        pcall(frame.icon.SetGradient, frame.icon, "VERTICAL", CreateColor(1, 1, 1, 0), CreateColor(1, 1, 1, 1))
    end
    frame.title = Text(frame, 18, WHITE, 1, "CENTER")
    frame.title:SetText(NAME)
    frame.subtitle = Text(frame, 12, WHITE, 0.75, "CENTER")
    Panel.title = frame
    return AddBlock({ kind = "title", frame = frame, Layout = function(_, width)
        local textWidth = min(255, width - 20)
        frame.title:SetWidth(textWidth); frame.subtitle:SetWidth(textWidth)
        local h1, h2 = frame.title:GetStringHeight(), frame.subtitle:GetStringHeight()
        local top = (225 - (h1 + 11 + h2)) / 2
        frame.title:ClearAllPoints(); frame.title:SetPoint("TOP", frame, "TOP", 0, -top)
        frame.subtitle:ClearAllPoints(); frame.subtitle:SetPoint("TOP", frame.title, "BOTTOM", 0, -11)
        return 225
    end })
end

--------------------------------------------------------------------------------
-- Connection status rows: icon and label left, status text right.
--------------------------------------------------------------------------------

local STATUS_ICONS = {
    check = "Interface\\AddOns\\" .. addonName .. "\\Art\\Icons\\StatusCheck",
    cross = "Interface\\AddOns\\" .. addonName .. "\\Art\\Icons\\StatusCross",
    pause = "Interface\\AddOns\\" .. addonName .. "\\Art\\Icons\\StatusPause",
    warning = "Interface\\AddOns\\" .. addonName .. "\\Art\\Icons\\StatusWarning",
}
local STATUS_STYLES = {
    connected = { icon = "check", color = { 0.32, 0.86, 0.36 }, text = "Connected" },
    active = { icon = "check", color = { 0.32, 0.86, 0.36 }, text = "Active" },
    disconnected = { icon = "cross", color = { 0.96, 0.32, 0.27 }, text = "Disconnected" },
    disabled = { icon = "pause", color = { 0.62, 0.62, 0.62 }, text = "Disabled" },
    paused = { icon = "pause", color = { 1, 0.69, 0.14 }, text = "Paused" },
    error = { icon = "warning", color = { 0.96, 0.32, 0.27 }, text = "Error" },
}
Panel.STATUS_STYLES = STATUS_STYLES

local function StatusRow(id, label)
    local value = CreateFrame("Frame", nil, building.content)
    value:SetSize(150, 17)
    value.text = Text(value, 12, WHITE, 1, "RIGHT")
    value.text:SetPoint("RIGHT", value, "RIGHT", 0, 0)
    function value:Resize() self:SetWidth(max(60, floor((self.text:GetStringWidth() or 0) + 1))) end
    local item = Row(nil, label, nil, value, { icon = true })
    item.value = value
    function item:SetStatus(state, text, detail)
        local style = STATUS_STYLES[state] or STATUS_STYLES.error
        local c = style.color
        self.state, self.statusText = state, text or style.text
        self.frame.icon:SetTexture(STATUS_ICONS[style.icon])
        self.frame.icon:SetVertexColor(c[1], c[2], c[3], 1)
        value.text:SetText(self.statusText)
        value.text:SetTextColor(c[1], c[2], c[3], 1)
        self.detail = detail
        self.tooltip = detail -- compact rows; the explanation is on hover
    end
    controls[id] = item
    return item
end

--------------------------------------------------------------------------------
-- Layout
--------------------------------------------------------------------------------

function Panel.LayoutPage(page)
    if not built or not page then return false end
    local width = page.scroll:GetWidth()
    if not width or width < 100 then return false end
    page.content:SetWidth(width)
    local y, any = PAGE_TOP, false
    for _, block in ipairs(page.blocks) do
        local visible = block.visible ~= false
        if visible and block.rows then -- a container with nothing to show is hidden
            visible = false
            for _, row in ipairs(block.rows) do if row.visible ~= false then visible = true end end
        end
        block.frame:SetShown(visible)
        if visible then
            if any then y = y + PAGE_SPACING end
            local h = block:Layout(width)
            block.frame:ClearAllPoints()
            block.frame:SetPoint("TOPLEFT", page.content, "TOPLEFT", 0, -y)
            block.frame:SetPoint("TOPRIGHT", page.content, "TOPRIGHT", 0, -y)
            block.frame:SetHeight(h)
            y, any = y + h, true
        end
    end
    local view = page.scroll:GetHeight() or 0
    -- Like Waypoint UI, a long page can scroll its end well up into view; a
    -- page whose blocks fit needs no scroll bar for its bottom padding.
    local height = y > view and y + PAGE_BOTTOM + OVERSCROLL or min(y + PAGE_BOTTOM, view)
    page.content:SetHeight(height)
    page.height = height
    page.scrollbar:Update(height, view)
    return true
end

local function Layout()
    local page = activeTab and pages[activeTab]
    if page and not Panel.LayoutPage(page) and C_Timer and not Panel.layoutQueued then
        -- The canvas has no size until the client's next layout pass.
        Panel.layoutQueued = true
        C_Timer.After(0, function()
            Panel.layoutQueued = false
            if canvas:IsShown() then Panel.LayoutPage(pages[activeTab]) end
        end)
    end
end
Panel.Layout = Layout

--------------------------------------------------------------------------------
-- Contents
--------------------------------------------------------------------------------

local function Set(key, value)
    if RXPW.Config.Get(key) ~= value then RXPW.Config.Set(key, value) end
    Panel.Refresh()
end

local function Build()
    local UI = { Container = Container, Row = Row, Text = TextRow, Action = Action, Status = StatusRow,
        Header = Header, Title = Title, Set = Set, controls = controls, root = root,
        Checkbox = W.Checkbox, Button = W.Button, Dropdown = W.Dropdown }
    function UI.Tab(name) building = pages[name]; container = nil end
    function UI.content() return building.content end
    function UI.Check(key, label, description, onToggle)
        local box = W.Checkbox(building.content, onToggle or function(value) Set(key, value) end)
        Row(key, label, description, box)
        return box
    end
    Panel.sharedNotices, Panel.fallbacks = {}, {}
    -- Waypoint UI-owned rows from SettingsSchema; a "group" starts a container.
    function UI.Shared(tab, defaultGroup)
        local group
        for _, spec in ipairs(RXPW.SettingsSchema[tab] or {}) do
            if spec.group or not container then
                Container(spec.group or defaultGroup or tab)
                group = { block = container, entries = {} }
                sharedGroups[#sharedGroups + 1] = group
            end
            local key = spec.key
            local function change(value)
                local ok, reason = RXPW.WaypointSettings.Set(key, value)
                if not ok then RXPW.Print("%s: %s", spec.label, reason or "Unavailable") end
                Panel.Refresh()
            end
            local control
            if spec.type == "boolean" then control = W.Checkbox(building.content, change)
            elseif spec.type == "number" then control = W.Slider(building.content, change)
            elseif spec.type == "sound" then control = W.SoundInput(building.content, change)
            else control = W.Dropdown(building.content, root, {}, change) end
            local row = Row(key, spec.label, nil, control, { indent = spec.indent })
            local entry = { key = key, spec = spec, row = row, control = control }
            sharedRows[#sharedRows + 1] = entry
            if group then group.entries[#group.entries + 1] = entry end
        end
    end
    -- Shown only while the public provider is connected.
    function UI.SharedNotice(label, description)
        local item = TextRow(label or "Shared Preferences", description or "")
        item.fixedDescription = description ~= nil
        Panel.sharedNotices[#Panel.sharedNotices + 1] = item
        return item
    end
    -- Shown instead of a tab's Waypoint UI-owned rows when they cannot be
    -- edited here: one button that opens Waypoint UI's own settings. Its public
    -- API (OpenSettingsUI) cannot select a tab, so the text says which to pick.
    function UI.Fallback(id, title)
        local button = W.Button(building.content, "Open Waypoint UI \226\128\148 " .. title .. " Settings",
            function() CloseList(); RXPW.WUI.OpenSettings() end)
        local item = Row(id, "Edited in Waypoint UI", string.format(FALLBACK_TEXT, title), button, { stacked = true })
        item.button = button
        Panel.fallbacks[#Panel.fallbacks + 1] = item
        return button
    end
    RXPW.SettingsTabs.Build(UI, Panel)
end

-- Shows exactly one page. Visibility and the selected look change first, so a
-- later refresh problem can never leave the previous page on screen.
function Panel.SelectTab(name)
    local page = pages[name]
    if not built or not page then return false end
    CloseList()
    HideTooltip()
    for tab, p in pairs(pages) do
        local selected = tab == name
        if selected and not p.frame:IsShown() and p.intro then p.intro:Play() end
        p.frame:SetShown(selected)
        tabButtons[tab]:SetSelected(selected)
    end
    activeTab = name
    Panel.activeTab = name
    local ok, err = pcall(Panel.Refresh)
    if not ok then
        RXPW.Debug("Settings refresh failed: %s", tostring(err))
        Layout()
    end
    return true
end

function Panel.GetPage(name) return pages[name or activeTab] end

-- Scrolls the active page by wheel notches (Waypoint UI: 150 px each).
function Panel.Scroll(delta, instant)
    local page = pages[activeTab]
    if not page then return end
    if instant then page.scrollbar:ScrollTo(page.scroll:GetVerticalScroll() - delta * 150, true)
    else page.scrollbar:Wheel(delta) end
end

-- Restore Defaults always asks first (StaticPopup; else a second click).
local CONFIRM_TEXT = "Restore RestedXP Waypoint's settings to their defaults?\n\n"
    .. "Automatic sync on, Hybrid, Hide RestedXP Arrow on, icons, colours and new-step sound on, debug off. "
    .. "Automatic navigation may resume or change. Waypoint UI's settings are unchanged."

function Panel.ConfirmRestore()
    if type(StaticPopup_Show) == "function" and type(StaticPopupDialogs) == "table" then
        StaticPopupDialogs.RESTEDXPWAYPOINT_RESTORE_DEFAULTS = StaticPopupDialogs.RESTEDXPWAYPOINT_RESTORE_DEFAULTS or {
            text = CONFIRM_TEXT,
            button1 = _G.OKAY or "Okay",
            button2 = _G.CANCEL or "Cancel",
            OnAccept = function() RXPW.Config.RestoreDefaults(); Panel.Refresh() end,
            timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
        }
        StaticPopup_Show("RESTEDXPWAYPOINT_RESTORE_DEFAULTS")
        return
    end
    local button = controls.restore
    if button.confirmUntil and GetTime() < button.confirmUntil then
        button.confirmUntil = nil
        button.text:SetText("Restore Defaults")
        RXPW.Config.RestoreDefaults()
        Panel.Refresh()
    else
        button.confirmUntil = GetTime() + 5
        button.text:SetText("Click again to confirm")
    end
end

--------------------------------------------------------------------------------
-- Refresh: every control from the shared state, then the visible page.
--------------------------------------------------------------------------------


function Panel.Refresh()
    if not built then return end
    RXPW.SettingsTabs.Refresh(Panel, controls)
    local available = RXPW.WaypointSettings.Connect()
    Panel.sharedAvailable = available
    for _, notice in ipairs(Panel.sharedNotices) do
        notice.visible = available
        if not notice.fixedDescription then notice:SetDescription("Changes apply immediately in both menus.") end
    end
    for _, item in ipairs(Panel.fallbacks) do
        item.visible = not available
        W.SetEnabled(item.button, RXPW.WUI.CanOpenSettings())
        item.tooltip = not RXPW.WUI.CanOpenSettings() and "Waypoint UI is not available." or nil
    end
    for _, entry in ipairs(sharedRows) do
        local key, c = entry.key, entry.control
        local d, reason = RXPW.WaypointSettings.Describe(key)
        local value = RXPW.WaypointSettings.Get(key)
        -- Without the provider the rows are not shown at all (see UI.Fallback).
        entry.row.visible = available and (not d or d.visible ~= false)
        local usable = d ~= nil and d.enabled ~= false and value ~= nil
        W.SetEnabled(c, usable)
        entry.row.tooltip = not usable and (reason or "This option is unavailable in the current Waypoint UI configuration.") or nil
        if d and value ~= nil then
            if d.type == "boolean" then c:SetChecked(value)
            elseif d.type == "number" then c:Apply(value, d, RXPW.WaypointSettings.Format(key, value))
            elseif d.type == "sound" then
                if not c.HasFocus or not c:HasFocus() then c:SetText(tostring(value)) end
            elseif d.type == "select" then
                c:SetOptions(d.options); c:SetValue(value)
            end
        elseif entry.spec.type == "select" then
            c:SetOptions({ { value = -1, label = "Unavailable" } }); c:SetValue(-1)
        elseif entry.spec.type == "number" then c.text:SetText("Unavailable")
        elseif entry.spec.type == "sound" then c:SetText("")
        else c:SetChecked(false) end
    end
    Layout()
end

-- Status only (sync start/stop/pause): no control or layout work beyond it.
function Panel.RefreshStatus()
    if not built or not canvas:IsShown() then return end
    RXPW.SettingsTabs.RefreshStatus(Panel, controls)
    if activeTab == "General" then Layout() end
end

--------------------------------------------------------------------------------
-- Frame construction (first show) and registration
--------------------------------------------------------------------------------

local function BuildFrames()
    if built then return end
    W.ResetArt()
    -- Size from Blizzard's settings canvas if the panel has not anchored us.
    local settingsCanvas = _G.SettingsPanel and SettingsPanel.Container and SettingsPanel.Container.SettingsCanvas
    if settingsCanvas and (canvas:GetWidth() or 0) < 50 then canvas:SetAllPoints(settingsCanvas) end

    root = CreateFrame("Frame", nil, canvas)
    if RXPW.IsLoaded("ElvUI") then
        root:SetAllPoints(canvas)
    else
        root:SetPoint("TOPLEFT", canvas, "TOPLEFT", -CANVAS_LEFT, CANVAS_TOP)
        root:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", 0, CANVAS_BOTTOM)
    end
    Panel.root = root

    sidebar = CreateFrame("Frame", nil, root)
    sidebar:SetPoint("TOPLEFT", root, "TOPLEFT", 0, 0)
    sidebar:SetPoint("BOTTOMLEFT", root, "BOTTOMLEFT", 0, 0)
    sidebar:SetWidth(SIDEBAR_WIDTH)
    local divider = sidebar:CreateTexture(nil, "ARTWORK")
    divider:SetColorTexture(DIVIDER_COLOR[1], DIVIDER_COLOR[2], DIVIDER_COLOR[3], DIVIDER_COLOR[4])
    divider:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", 0, 0)
    divider:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", 0, 0)
    divider:SetWidth(2)
    Panel.sidebar, Panel.divider = sidebar, divider

    contentArea = CreateFrame("Frame", nil, root)
    contentArea:SetPoint("TOPLEFT", root, "TOPLEFT", SIDEBAR_WIDTH + CONTENT_INSET, 0)
    contentArea:SetPoint("BOTTOMRIGHT", root, "BOTTOMRIGHT", -CONTENT_INSET, 0)
    Panel.contentArea = contentArea

    built = true
    for _, name in ipairs(Panel.tabs) do NewPage(name) end
    Build()

    local index = 0
    for _, name in ipairs(Panel.tabs) do
        local button = W.TabButton(sidebar, name, function() Panel.SelectTab(name) end)
        button:ClearAllPoints()
        if FOOTER[name] then
            button:SetPoint("BOTTOMLEFT", sidebar, "BOTTOMLEFT", SIDEBAR_INSET, SIDEBAR_INSET)
            button:SetPoint("BOTTOMRIGHT", sidebar, "BOTTOMRIGHT", -SIDEBAR_INSET, SIDEBAR_INSET)
        else
            local y = -SIDEBAR_INSET - index * (TAB_HEIGHT + TAB_SPACING)
            button:SetPoint("TOPLEFT", sidebar, "TOPLEFT", SIDEBAR_INSET, y)
            button:SetPoint("TOPRIGHT", sidebar, "TOPRIGHT", -SIDEBAR_INSET, y)
            index = index + 1
        end
        tabButtons[name] = button
    end

    -- Close an open list when clicking elsewhere; refresh status when a
    -- dependency loads. Registered only while the page is shown.
    canvas:SetScript("OnEvent", function(_, event)
        if event == "GLOBAL_MOUSE_DOWN" then W.OutsideClick()
        elseif event == "ADDON_LOADED" then W.ResetArt(); Panel.RefreshStatus() end
    end)
    root:SetScript("OnSizeChanged", function() Layout() end)
    Panel.SelectTab("General")
end

local function OnShow()
    BuildFrames()
    if canvas.RegisterEvent then
        pcall(canvas.RegisterEvent, canvas, "GLOBAL_MOUSE_DOWN")
        pcall(canvas.RegisterEvent, canvas, "ADDON_LOADED")
    end
    RXPW.WaypointSettings.ApplyFirstRunDefault()
    Panel.Refresh()
end

local function OnHide()
    CloseList()
    HideTooltip()
    if canvas.UnregisterEvent then
        pcall(canvas.UnregisterEvent, canvas, "GLOBAL_MOUSE_DOWN")
        pcall(canvas.UnregisterEvent, canvas, "ADDON_LOADED")
    end
end

-- Called once at ADDON_LOADED (Core.lua). Registers exactly one category.
function Panel.Initialize()
    if Panel.registered ~= nil then return Panel.registered end
    Panel.registered = false
    canvas = CreateFrame("Frame")
    canvas.name = NAME -- InterfaceOptions_AddCategory fallback
    canvas:Hide()
    canvas:SetScript("OnShow", OnShow)
    canvas:SetScript("OnHide", OnHide)
    -- Settings apply immediately, so there is nothing to commit. OnDefault is
    -- deliberately not provided: Blizzard's "Defaults > All Settings" must not
    -- silently reset the navigation strategy; Restore Defaults is on the page.
    canvas.OnCommit = function() end
    canvas.OnRefresh = function() if built then Panel.Refresh() end end
    Panel.canvas = canvas

    local S = _G.Settings
    if type(S) == "table" and type(S.RegisterCanvasLayoutCategory) == "function"
        and type(S.RegisterAddOnCategory) == "function" then
        local ok, category = pcall(S.RegisterCanvasLayoutCategory, canvas, NAME)
        if ok and category then
            pcall(S.RegisterAddOnCategory, category)
            Panel.category = category
            Panel.registered = true
        end
    elseif type(InterfaceOptions_AddCategory) == "function" then
        Panel.registered = pcall(InterfaceOptions_AddCategory, canvas) and true or false
    end

    RXPW.WaypointSettings.RegisterListener(function()
        if built and canvas:IsShown() then Panel.Refresh() end
    end)
    RXPW.Config.RegisterListener(function()
        if built and canvas:IsShown() then Panel.Refresh() end
    end)
    if RXPW.Sync.RegisterStatusListener then RXPW.Sync.RegisterStatusListener(Panel.RefreshStatus) end
    return Panel.registered
end

-- Opens the page. Returns false when no settings API exists.
function Panel.Open()
    if not Panel.registered then return false end
    if type(InCombatLockdown) == "function" and InCombatLockdown() then
        RXPW.Print("The settings page cannot be opened during combat; try again afterwards.")
        return true
    end
    local S = _G.Settings
    if Panel.category and type(S) == "table" and type(S.OpenToCategory) == "function" then
        local id = Panel.category.GetID and Panel.category:GetID() or Panel.category.ID
        return (pcall(S.OpenToCategory, id))
    end
    if type(InterfaceOptionsFrame_OpenToCategory) == "function" then
        -- Classic clients often need two calls to land on the category.
        pcall(InterfaceOptionsFrame_OpenToCategory, canvas)
        pcall(InterfaceOptionsFrame_OpenToCategory, canvas)
        return true
    end
    return false
end
