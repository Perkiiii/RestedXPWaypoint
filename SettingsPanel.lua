-- RestedXP Waypoint
-- SettingsPanel: the single page under Options > AddOns > RestedXP Waypoint
-- (v0.6.0).
--
-- Design follows Waypoint UI's own settings (1.7.3): white 12pt labels with an
-- inline half-transparent 11pt description, gold 14pt section headers over a
-- thin divider, a 55% / 45% label / control split, generous spacing and flat
-- custom controls. The page itself has no background shading of its own: one
-- uniform colour (Blizzard's settings background), no cards, no row hover.
-- Waypoint UI's private UI kit and art are NOT used:
-- every control here is a plain Frame/Button/ScrollFrame/Slider with colour
-- textures, so nothing depends on Blizzard widget templates whose presence in
-- the Forever client is unverified. Unlike Waypoint UI there is no sidebar:
-- all sections are on one vertically scrolling page.
--
-- Registration: Settings.RegisterCanvasLayoutCategory + RegisterAddOnCategory
-- (what Waypoint UI uses in this client), with InterfaceOptions_AddCategory as
-- a guarded fallback. The page is built on first show, so loading costs one
-- empty frame.
--
-- State: the panel keeps no settings of its own. Every control reads
-- RXPW.Config.Get / RXPWDB and writes through RXPW.Config.Set, the same path
-- as the /rxpw commands; a Config listener refreshes the page after changes
-- from either side. Preview buttons call Preview.lua's API (one preview state).

local addonName, RXPW = ...
local Panel = {}
RXPW.SettingsPanel = Panel

local NAME = "RestedXP Waypoint"
local LOGO_TEXTURE = "Interface\\AddOns\\" .. addonName .. "\\Art\\Logo"
local LOGO_SIZE = 80

local format = string.format
local floor = math.floor
local max, min = math.max, math.min
local type = type
local ipairs = ipairs

-- Layout tokens (Waypoint UI: ElementBase MARGIN 20, SPACING 5, INDENT 15,
-- CONTENT_SPACING 10, label column 55%, 14pt gold headers, 32px header strip).
local PAGE_PAD = 20        -- left/right page margin
local TOP_PAD = 16
local BOTTOM_PAD = 32
local SECTION_INDENT = 12  -- row inset below a section header
local ROW_PAD = 9          -- vertical padding inside a row
local TEXT_SPACING = 4     -- label to description
local SECTION_GAP = 22     -- space above a section header
local HEADER_HEIGHT = 26
local LABEL_SHARE = 0.55
local CONTROL_MAX = 230
local BUTTON_HEIGHT = 26
local BUTTON_GAP = 8
local SCROLL_STEP = 60
local SCROLLBAR_WIDTH = 6

local GOLD = { 1, 0.82, 0 }
local WHITE = { 1, 1, 1 }
local DIM = 0.55           -- description alpha (Waypoint UI uses 0.5)
local GREEN = { 0.35, 0.85, 0.35 }
local RED = { 0.9, 0.3, 0.3 }

local STRATEGY_TEXT = {
    coordinates = { label = "RestedXP Coordinates",
        desc = "Always follow RestedXP's exact waypoint coordinates. Quest and service context still determine how the waypoint appears." },
    hybrid = { label = "Hybrid",
        desc = "Follow RestedXP's route while using native Blizzard quest tracking for eligible turn-ins." },
    ["native-first"] = { label = "Native First",
        desc = "Prefer native Blizzard quest navigation when appropriate, while preserving important RestedXP intermediate and travel waypoints." },
}

local PREVIEW_LABELS = {
    available = "Available Quest", incomplete = "Incomplete Quest", complete = "Complete Quest",
    flightmaster = "Flight Master", classtrainer = "Class Trainer", professiontrainer = "Profession Trainer",
    food = "Food & Drink", repair = "Repair", innkeeper = "Innkeeper", stable = "Stable Master",
    vendor = "Vendor", banker = "Banker", grind = "Grind", default = "Default Waypoint",
}

local NATIVE_NOTE = "Applies to the custom waypoints RestedXP Waypoint creates. While native quest tracking is "
    .. "active (Hybrid or Native First), Waypoint UI draws Blizzard's own quest marker, which this setting does not change."

--------------------------------------------------------------------------------
-- Fonts (Waypoint UI: GameFontNormal's file, no outline, 1px black shadow)
--------------------------------------------------------------------------------

local fonts = {}
local function Font(size)
    if fonts[size] then return fonts[size] end
    local object
    if type(CreateFont) == "function" then
        object = CreateFont("RestedXPWaypointSettingsFont" .. size)
        local file = GameFontNormal and GameFontNormal.GetFont and GameFontNormal:GetFont()
        if object and file then
            object:SetFont(file, size, "")
            object:SetShadowOffset(1, -1)
            object:SetShadowColor(0, 0, 0, 1)
        end
    end
    fonts[size] = object or GameFontHighlight
    return fonts[size]
end

local function Text(parent, size, color, alpha, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(Font(size))
    fs:SetTextColor(color[1], color[2], color[3], alpha or 1)
    fs:SetJustifyH(justify or "LEFT")
    if fs.SetWordWrap then fs:SetWordWrap(true) end
    return fs
end

local function Solid(parent, layer, r, g, b, a)
    local t = parent:CreateTexture(nil, layer or "BACKGROUND")
    t:SetColorTexture(r, g, b, a)
    return t
end

-- 1px border made of four textures.
local function Border(frame, r, g, b, a)
    local top = Solid(frame, "BORDER", r, g, b, a)
    top:SetPoint("TOPLEFT"); top:SetPoint("TOPRIGHT"); top:SetHeight(1)
    local bottom = Solid(frame, "BORDER", r, g, b, a)
    bottom:SetPoint("BOTTOMLEFT"); bottom:SetPoint("BOTTOMRIGHT"); bottom:SetHeight(1)
    local left = Solid(frame, "BORDER", r, g, b, a)
    left:SetPoint("TOPLEFT"); left:SetPoint("BOTTOMLEFT"); left:SetWidth(1)
    local right = Solid(frame, "BORDER", r, g, b, a)
    right:SetPoint("TOPRIGHT"); right:SetPoint("BOTTOMRIGHT"); right:SetWidth(1)
end

local function Sound(kit)
    if type(PlaySound) == "function" and SOUNDKIT and SOUNDKIT[kit] then pcall(PlaySound, SOUNDKIT[kit]) end
end

local function ShowTooltip(owner, title, body)
    if not (GameTooltip and body) then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, GOLD[1], GOLD[2], GOLD[3])
    GameTooltip:AddLine(body, 1, 1, 1, true)
    GameTooltip:Show()
end

local function HideTooltip()
    if GameTooltip then GameTooltip:Hide() end
end

local function SetEnabledLook(frame, enabled)
    if frame.SetEnabled then frame:SetEnabled(enabled) end
    frame:SetAlpha(enabled and 1 or 0.4)
end

--------------------------------------------------------------------------------
-- Controls (flat, Waypoint UI-like). Each returns a frame with :Refresh().
--------------------------------------------------------------------------------

local CHECK_TEXTURE = "Interface\\Buttons\\UI-CheckBox-Check"

local function Checkbox(parent, onToggle)
    local box = CreateFrame("Button", nil, parent)
    box:SetSize(22, 22)
    Solid(box, "BACKGROUND", 0, 0, 0, 0.45):SetAllPoints()
    Border(box, 1, 1, 1, 0.22)
    local hover = Solid(box, "HIGHLIGHT", 1, 1, 1, 0.08)
    hover:SetAllPoints()
    local check = box:CreateTexture(nil, "OVERLAY")
    check:SetTexture(CHECK_TEXTURE)
    check:SetPoint("CENTER", 1, 0)
    check:SetSize(24, 24)
    box.check = check
    function box:SetChecked(value)
        self.checked = value and true or false
        self.check:SetShown(self.checked)
    end
    function box:GetChecked() return self.checked end
    box:SetScript("OnClick", function(self)
        local value = not self.checked
        Sound(value and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
        onToggle(value)
    end)
    box:SetChecked(false)
    return box
end

local function FlatButton(parent, label, onClick, width)
    local button = CreateFrame("Button", nil, parent)
    button:SetHeight(BUTTON_HEIGHT)
    Solid(button, "BACKGROUND", 1, 1, 1, 0.07):SetAllPoints()
    Border(button, 1, 1, 1, 0.16)
    local hover = Solid(button, "HIGHLIGHT", 1, 1, 1, 0.09)
    hover:SetAllPoints()
    local text = Text(button, 12, GOLD, 1, "CENTER")
    text:SetPoint("CENTER")
    text:SetText(label)
    button.text = text
    button:SetWidth(width or max(110, floor((text.GetStringWidth and text:GetStringWidth() or 80) + 28)))
    button:SetScript("OnEnter", function(self) self.text:SetTextColor(1, 1, 1) end)
    button:SetScript("OnLeave", function(self) self.text:SetTextColor(GOLD[1], GOLD[2], GOLD[3]) end)
    button:SetScript("OnMouseDown", function(self) if self:IsEnabled() then self.text:SetPoint("CENTER", 0, -1) end end)
    button:SetScript("OnMouseUp", function(self) self.text:SetPoint("CENTER") end)
    button:SetScript("OnClick", function(self)
        Sound("U_CHAT_SCROLL_BUTTON")
        onClick(self)
    end)
    return button
end

-- Two or more equal buttons; one is selected.
local function Segmented(parent, options, onSelect)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetHeight(BUTTON_HEIGHT)
    frame.buttons = {}
    for i, option in ipairs(options) do
        local b = CreateFrame("Button", nil, frame)
        b.value = option.value
        b.bg = Solid(b, "BACKGROUND", 1, 1, 1, 0.07)
        b.bg:SetAllPoints()
        Border(b, 1, 1, 1, 0.16)
        Solid(b, "HIGHLIGHT", 1, 1, 1, 0.09):SetAllPoints()
        b.text = Text(b, 12, WHITE, 1, "CENTER")
        b.text:SetPoint("CENTER")
        b.text:SetText(option.label)
        b:SetScript("OnClick", function(self)
            Sound("U_CHAT_SCROLL_BUTTON")
            onSelect(self.value)
        end)
        frame.buttons[i] = b
    end
    function frame:Arrange(width)
        local n = #self.buttons
        local each = floor((width - (n - 1) * 4) / n)
        for i, b in ipairs(self.buttons) do
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", self, "TOPLEFT", (i - 1) * (each + 4), 0)
            b:SetSize(each, BUTTON_HEIGHT)
        end
        self:SetWidth(width)
    end
    function frame:SetValue(value)
        self.value = value
        for _, b in ipairs(self.buttons) do
            local on = b.value == value
            b.bg:SetColorTexture(on and GOLD[1] or 1, on and GOLD[2] or 1, on and GOLD[3] or 1, on and 0.28 or 0.07)
            b.text:SetTextColor(on and GOLD[1] or 1, on and GOLD[2] or 1, on and GOLD[3] or 1, on and 1 or 0.75)
        end
    end
    return frame
end

-- Custom dropdown: a button plus a list shown above the settings page. The
-- list is parented to the canvas (not the scroll child, which clips).
local openList

local function CloseList()
    if openList then openList:Hide() end
    openList = nil
end
Panel.CloseList = CloseList

local function Dropdown(parent, listParent, options, onSelect)
    local button = CreateFrame("Button", nil, parent)
    button:SetHeight(BUTTON_HEIGHT)
    Solid(button, "BACKGROUND", 0, 0, 0, 0.45):SetAllPoints()
    Border(button, 1, 1, 1, 0.18)
    Solid(button, "HIGHLIGHT", 1, 1, 1, 0.07):SetAllPoints()
    button.text = Text(button, 12, WHITE, 1, "LEFT")
    button.text:SetPoint("LEFT", 10, 0)
    button.text:SetPoint("RIGHT", -24, 0)
    if button.text.SetWordWrap then button.text:SetWordWrap(false) end
    local arrow = button:CreateTexture(nil, "OVERLAY")
    arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
    arrow:SetSize(14, 14)
    arrow:SetPoint("RIGHT", -6, 0)
    if arrow.SetRotation then arrow:SetRotation(-math.pi / 2) end
    button.options = options

    local list = CreateFrame("Frame", nil, listParent)
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    if list.SetToplevel then list:SetToplevel(true) end
    list:EnableMouse(true)
    Solid(list, "BACKGROUND", 0.05, 0.05, 0.05, 0.96):SetAllPoints()
    Border(list, 1, 1, 1, 0.18)
    list:Hide()
    list.rows = {}
    local ROW = 22
    for i, option in ipairs(options) do
        local row = CreateFrame("Button", nil, list)
        row:SetHeight(ROW)
        row:SetPoint("TOPLEFT", 1, -1 - (i - 1) * ROW)
        row:SetPoint("TOPRIGHT", -1, -1 - (i - 1) * ROW)
        Solid(row, "HIGHLIGHT", 1, 1, 1, 0.1):SetAllPoints()
        local x = 10
        if option.icon then
            local icon = row:CreateTexture(nil, "ARTWORK")
            icon:SetTexture(option.icon)
            icon:SetSize(16, 16)
            icon:SetPoint("LEFT", 8, 0)
            if option.tint then icon:SetVertexColor(option.tint.r, option.tint.g, option.tint.b) end
            x = 30
        end
        row.text = Text(row, 12, WHITE, 0.8, "LEFT")
        row.text:SetPoint("LEFT", x, 0)
        row.text:SetText(option.label)
        row.value = option.value
        row:SetScript("OnClick", function(self)
            CloseList()
            Sound("U_CHAT_SCROLL_BUTTON")
            onSelect(self.value)
        end)
        list.rows[i] = row
    end
    list:SetHeight(#options * ROW + 2)
    button.list = list

    function button:SetValue(value)
        self.value = value
        for _, o in ipairs(self.options) do
            if o.value == value then self.text:SetText(o.label) end
        end
        for _, row in ipairs(self.list.rows) do
            local on = row.value == value
            row.text:SetTextColor(on and GOLD[1] or 1, on and GOLD[2] or 1, on and GOLD[3] or 1, on and 1 or 0.8)
        end
    end
    list.owner = button
    function button:Open()
        CloseList()
        self.list:ClearAllPoints()
        -- Open upwards when the list would run off the bottom of the screen.
        local bottom = self.GetBottom and self:GetBottom()
        if bottom and bottom - self.list:GetHeight() < 20 then
            self.list:SetPoint("BOTTOMLEFT", self, "TOPLEFT", 0, 4)
        else
            self.list:SetPoint("TOPLEFT", self, "BOTTOMLEFT", 0, -4)
        end
        self.list:SetWidth(max(self:GetWidth(), 180))
        self.list:Show()
        openList = self.list
    end
    button:SetScript("OnClick", function(self)
        if openList == self.list then CloseList() else self:Open() end
    end)
    return button
end

--------------------------------------------------------------------------------
-- Page structure: header, then sections of rows, notes and button rows.
-- Layout() positions every item for the current width (descriptions wrap).
--------------------------------------------------------------------------------

local canvas, scroll, content, scrollbar
local items = {}
local controls = {}
local built = false
Panel.controls = controls

local function Add(item)
    items[#items + 1] = item
    return item
end

-- Row: label + description (left 55%), control (right).
local function Row(id, label, description, control, tooltip)
    local frame = CreateFrame("Frame", nil, content)
    frame.label = Text(frame, 12, WHITE, 1)
    frame.label:SetText(label)
    frame.desc = description and Text(frame, 11, WHITE, DIM) or nil
    if frame.desc then frame.desc:SetText(description) end
    local item = { kind = "row", frame = frame, control = control, id = id, tooltip = tooltip, label = label }
    if control then
        control:SetParent(frame)
        local function Hover()
            if item.tooltip and frame:IsMouseOver() then ShowTooltip(frame, label, item.tooltip) end
        end
        local function Unhover()
            if not frame:IsMouseOver() then HideTooltip() end
        end
        frame:EnableMouse(true)
        frame:SetScript("OnEnter", Hover)
        frame:SetScript("OnLeave", Unhover)
        control:HookScript("OnEnter", Hover)
        control:HookScript("OnLeave", Unhover)
    end
    function item:Measure(width)
        local labelWidth = floor(width * LABEL_SHARE) - 10
        frame.label:ClearAllPoints()
        frame.label:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -ROW_PAD)
        frame.label:SetWidth(labelWidth)
        local height = frame.label:GetStringHeight()
        if frame.desc then
            frame.desc:ClearAllPoints()
            frame.desc:SetPoint("TOPLEFT", frame.label, "BOTTOMLEFT", 0, -TEXT_SPACING)
            frame.desc:SetWidth(labelWidth)
            height = height + TEXT_SPACING + frame.desc:GetStringHeight()
        end
        local controlHeight = 0
        if control then
            local controlWidth = min(CONTROL_MAX, floor(width * (1 - LABEL_SHARE)) - 16)
            if control.Arrange then control:Arrange(controlWidth)
            elseif control.wide then control:SetWidth(controlWidth) end
            control:ClearAllPoints()
            control:SetPoint("RIGHT", frame, "RIGHT", -8, 0)
            controlHeight = control:GetHeight()
        end
        return max(height, controlHeight) + ROW_PAD * 2
    end
    if id then controls[id] = control end
    return Add(item)
end

local function Note(text, color, alpha)
    local frame = CreateFrame("Frame", nil, content)
    frame.text = Text(frame, 11, color or WHITE, alpha or DIM)
    frame.text:SetText(text)
    local item = { kind = "note", frame = frame }
    function item:Measure(width)
        frame.text:ClearAllPoints()
        frame.text:SetPoint("TOPLEFT", frame, "TOPLEFT", 8, -4)
        frame.text:SetWidth(width - 16)
        return frame.text:GetStringHeight() + 8
    end
    return Add(item)
end

-- Buttons left to right, wrapping to the next line when the width runs out.
local function ButtonRow(buttons)
    local frame = CreateFrame("Frame", nil, content)
    for _, b in ipairs(buttons) do b:SetParent(frame) end
    local item = { kind = "buttons", frame = frame }
    function item:Measure(width)
        local x, y = 8, -6
        for _, b in ipairs(buttons) do
            local w = b:GetWidth()
            if x > 8 and x + w > width - 8 then
                x, y = 8, y - BUTTON_HEIGHT - BUTTON_GAP
            end
            b:ClearAllPoints()
            b:SetPoint("TOPLEFT", frame, "TOPLEFT", x, y)
            x = x + w + BUTTON_GAP
        end
        return -y + BUTTON_HEIGHT + 6
    end
    return Add(item)
end

local sectionTitles = {}

local function Section(title)
    sectionTitles[#sectionTitles + 1] = title
    local frame = CreateFrame("Frame", nil, content)
    frame.title = Text(frame, 14, GOLD, 1)
    frame.title:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 4, 6)
    frame.title:SetText(title)
    local line = Solid(frame, "ARTWORK", 0.56, 0.56, 0.56, 0.24)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 0, 0)
    line:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
    local item = { kind = "section", frame = frame, title = title }
    function item:Measure() return HEADER_HEIGHT end
    return Add(item)
end

-- Read-only views for diagnostics and the offline tests.
function Panel.GetSections()
    local list = {}
    for i, title in ipairs(sectionTitles) do list[i] = title end
    return list
end

function Panel.GetContentHeight()
    return content and content:GetHeight() or 0
end

function Panel.GetScrollRange()
    if not scrollbar then return 0, 0 end
    return scrollbar:GetMinMaxValues()
end

local function Layout()
    if not built then return end
    local width = content:GetWidth()
    if not width or width < 200 then return end
    local outer = width - PAGE_PAD * 2
    local inner = outer - SECTION_INDENT * 2
    local y = -TOP_PAD
    local section
    for _, item in ipairs(items) do
        if item.kind == "section" then
            section = item
            y = y - SECTION_GAP
            item.frame:ClearAllPoints()
            item.frame:SetPoint("TOPLEFT", content, "TOPLEFT", PAGE_PAD, y)
            item.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAGE_PAD, y)
            item.frame:SetHeight(HEADER_HEIGHT)
            y = y - HEADER_HEIGHT - 10
        elseif item.kind == "header" then
            local h = item:Measure(outer)
            item.frame:ClearAllPoints()
            item.frame:SetPoint("TOPLEFT", content, "TOPLEFT", PAGE_PAD, y)
            item.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", -PAGE_PAD, y)
            item.frame:SetHeight(h)
            y = y - h
        else
            local left = PAGE_PAD + (section and SECTION_INDENT or 0)
            local w = section and inner or outer
            local h = item:Measure(w)
            item.frame:ClearAllPoints()
            item.frame:SetPoint("TOPLEFT", content, "TOPLEFT", left, y)
            item.frame:SetPoint("TOPRIGHT", content, "TOPRIGHT", -left, y)
            item.frame:SetHeight(h)
            y = y - h - 2
        end
    end
    content:SetHeight(-y + BOTTOM_PAD)
    Panel.UpdateScroll()
end
Panel.Layout = Layout

function Panel.UpdateScroll()
    if not scroll then return end
    local range = max(0, content:GetHeight() - scroll:GetHeight())
    scrollbar:SetMinMaxValues(0, range)
    if scroll:GetVerticalScroll() > range then scroll:SetVerticalScroll(range) end
    scrollbar:SetValue(scroll:GetVerticalScroll())
    scrollbar:SetShown(range > 0)
    local track = scrollbar:GetHeight()
    if track and track > 0 and content:GetHeight() > 0 then
        scrollbar.thumb:SetHeight(max(24, floor(track * scroll:GetHeight() / content:GetHeight())))
    end
end

--------------------------------------------------------------------------------
-- Contents
--------------------------------------------------------------------------------

local function Set(key, value)
    if RXPW.Config.Get(key) ~= value then RXPW.Config.Set(key, value) end
    Panel.Refresh()
end

local previewSelection = { key = "flightmaster", distance = "close" }
Panel.previewSelection = previewSelection

local function BuildHeader()
    local frame = CreateFrame("Frame", nil, content)
    frame.title = Text(frame, 20, GOLD, 1)
    frame.title:SetPoint("TOPLEFT", 4, -2)
    frame.title:SetText(NAME)
    -- Logo top-right (Art/Logo.blp: 128x128, drawn at LOGO_SIZE; built by
    -- tools/build_logo.py), with the version centred underneath.
    frame.logo = frame:CreateTexture(nil, "ARTWORK")
    frame.logo:SetTexture(LOGO_TEXTURE)
    frame.logo:SetSize(LOGO_SIZE, LOGO_SIZE)
    frame.logo:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -8, 0)
    frame.version = Text(frame, 11, WHITE, 0.45, "CENTER")
    frame.version:SetPoint("TOP", frame.logo, "BOTTOM", 0, -3)
    frame.subtitle = Text(frame, 12, WHITE, 0.75)
    frame.subtitle:SetPoint("TOPLEFT", frame.title, "BOTTOMLEFT", 0, -6)
    frame.subtitle:SetText("RestedXP navigation, powered by Waypoint UI.")
    frame.status = {}
    local anchor = frame.subtitle
    for i, name in ipairs({ "RestedXP", "Waypoint UI", "Sync" }) do
        local dot = Solid(frame, "ARTWORK", 1, 1, 1, 1)
        dot:SetSize(7, 7)
        if i == 1 then
            dot:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 1, -12)
        else
            dot:SetPoint("LEFT", anchor, "RIGHT", 16, 0)
        end
        local label = Text(frame, 11, WHITE, 0.8)
        label:SetPoint("LEFT", dot, "RIGHT", 6, 0)
        frame.status[i] = { dot = dot, label = label, name = name }
        anchor = label
    end
    local item = { kind = "header", frame = frame }
    function item:Measure() return LOGO_SIZE + 20 end
    Panel.header = frame
    return Add(item)
end

local function Build()
    BuildHeader()

    Section("General")
    Row("autoSync", "Enable Automatic Synchronization",
        "Automatically keeps Waypoint UI synchronized with your current RestedXP destination.",
        Checkbox(content, function(value) Set("autoSync", value) end),
        "Same as /rxpw on and /rxpw off. Turning it off leaves the current Waypoint UI destination in place.")

    Section("Navigation")
    local strategyOptions = {}
    for _, value in ipairs(RXPW.Config.STRATEGIES) do
        strategyOptions[#strategyOptions + 1] = { value = value, label = STRATEGY_TEXT[value].label }
    end
    local strategy = Dropdown(content, canvas, strategyOptions, function(value) Set("strategy", value) end)
    strategy.wide = true
    Panel.strategyRow = Row("strategy", "Navigation Strategy", STRATEGY_TEXT.coordinates.desc, strategy,
        "Same as /rxpw mode coordinates, hybrid or native-first. Route and travel waypoints always follow RestedXP.")
    Panel.arrowRow = Row("hideArrow", "Hide RestedXP Arrow",
        "Hide RestedXP's on-screen waypoint arrow and follow Waypoint UI's marker instead.",
        Checkbox(content, function(value)
            if RXPW.RXP.SetArrowHidden(value) then
                RXPW.Print("RestedXP's waypoint arrow is now %s.", value and "hidden" or "shown")
            end
            Panel.Refresh()
        end),
        "This is RestedXP's own \"Hide waypoint arrow\" option (Options > AddOns > RestedXP Guides > Features), "
            .. "saved in your RestedXP profile; both checkboxes always show the same value. RestedXP keeps choosing "
            .. "waypoints while its arrow is hidden, so synchronization is unaffected. Restore Defaults does not change it.")
    Note("Manual waypoints are respected. RestedXP Waypoint will not intentionally override navigation selected by you or another addon.")

    Section("Waypoint Appearance")
    Row("questIcons", "Quest-Specific Icons",
        "Display context-sensitive quest icons for objectives, available quests and completed quests.",
        Checkbox(content, function(value) Set("questIcons", value) end),
        "Off: Waypoint UI's generic waypoint icon is shown instead. " .. NATIVE_NOTE)
    Row("serviceIcons", "Service Icons",
        "Display dedicated icons for flight masters, trainers, vendors, innkeepers, repair services and other recognized destinations.",
        Checkbox(content, function(value) Set("serviceIcons", value) end),
        "Off: Waypoint UI's generic waypoint icon is shown instead. Coordinates and labels never change.")
    Row("customColors", "Custom Waypoint Colours",
        "Use RestedXP Waypoint's context-sensitive colours for quests, services and other recognized destinations.",
        Checkbox(content, function(value) Set("customColors", value) end),
        "Off: Waypoint UI's own colour for custom waypoints is used (including any colour you chose in Waypoint UI). "
            .. "Service icons are drawn for tinting and look neutral grey without these colours. " .. NATIVE_NOTE)
    Note("Waypoint size, beams, animations and other visual effects can be configured directly in Waypoint UI.")
    controls.openWaypointUI = FlatButton(content, "Open Waypoint UI Settings", function()
        CloseList()
        RXPW.WUI.OpenSettings()
    end)
    ButtonRow({ controls.openWaypointUI })

    Section("Waypoint Preview")
    local previewOptions = {}
    for _, entry in ipairs(RXPW.Preview.GetEntries()) do
        local icon, tint = RXPW.Preview.GetEntryArt(entry.key)
        previewOptions[#previewOptions + 1] = { value = entry.key, label = PREVIEW_LABELS[entry.key] or entry.label,
                                                icon = icon, tint = tint }
    end
    local previewControl = CreateFrame("Frame", nil, content)
    previewControl:SetHeight(BUTTON_HEIGHT)
    previewControl.wide = true
    local swatch = previewControl:CreateTexture(nil, "ARTWORK")
    swatch:SetSize(24, 24)
    swatch:SetPoint("LEFT", 0, 0)
    previewControl.swatch = swatch
    local previewDropdown = Dropdown(previewControl, canvas, previewOptions, function(value)
        previewSelection.key = value
        Panel.Refresh()
    end)
    previewDropdown:SetPoint("LEFT", swatch, "RIGHT", 8, 0)
    previewDropdown:SetPoint("RIGHT", previewControl, "RIGHT", 0, 0)
    previewControl.dropdown = previewDropdown
    previewControl.HookScript = function(self, ...) return previewDropdown:HookScript(...) end
    controls.previewIconDropdown = previewDropdown
    Row("previewIcon", "Preview Icon", "Choose the marker to place a short distance in front of you.", previewControl)
    local distance = Segmented(content, { { value = "close", label = "Close" }, { value = "far", label = "Far" } },
        function(value) previewSelection.distance = value; Panel.Refresh() end)
    Row("previewDistance", "Preview Distance", "Close shows the marker up close; Far places it four times as far away.", distance)
    controls.previewShow = FlatButton(content, "Show Preview", function()
        CloseList(); RXPW.Preview.Show(previewSelection.key, previewSelection.distance); Panel.Refresh()
    end)
    controls.previewNext = FlatButton(content, "Next Icon", function()
        CloseList(); RXPW.Preview.Next(previewSelection.distance); Panel.Refresh()
    end)
    controls.previewAll = FlatButton(content, "Preview All", function()
        CloseList(); RXPW.Preview.ShowAll(previewSelection.distance); Panel.Refresh()
    end)
    controls.previewStop = FlatButton(content, "Stop Preview", function()
        CloseList(); RXPW.Preview.Off(); Panel.Refresh()
    end)
    ButtonRow({ controls.previewShow, controls.previewNext, controls.previewAll, controls.previewStop })
    Panel.previewStatus = Note("", WHITE, 0.8)
    Note("While a preview is shown, automatic synchronization pauses; Stop Preview resumes it.")

    Section("Advanced")
    Row("debug", "Enable Debug Messages",
        "Print detailed navigation decisions, synchronization events and diagnostic information in chat.",
        Checkbox(content, function(value) Set("debug", value) end), "Same as /rxpw debug.")
    controls.status = FlatButton(content, "Print Status", function() CloseList(); RXPW.PrintStatus() end)
    controls.inspect = FlatButton(content, "Inspect Current Step", function() CloseList(); RXPW.PrintInspect() end)
    ButtonRow({ controls.status, controls.inspect })
    Note("Status and inspection output is printed to the chat window (same as /rxpw status and /rxpw inspect).")
    controls.restore = FlatButton(content, "Restore Defaults", function() CloseList(); Panel.ConfirmRestore() end)
    ButtonRow({ controls.restore })
    Note("Restores only RestedXP Waypoint's settings. Automatic navigation may resume or change; Waypoint UI's settings are unchanged.")
end

-- Restore Defaults always asks first (StaticPopup; else a second click).
local CONFIRM_TEXT = "Restore RestedXP Waypoint's settings to their defaults?\n\n"
    .. "Automatic sync on, RestedXP Coordinates, icons and colours on, debug off. "
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
-- Refresh: every control from the shared state
--------------------------------------------------------------------------------

local function StatusDot(entry, ok, text)
    local c = ok and GREEN or RED
    entry.dot:SetColorTexture(c[1], c[2], c[3], 1)
    entry.label:SetText(format("%s: %s", entry.name, text))
end

function Panel.Refresh()
    if not built then return end
    local Config = RXPW.Config
    local rxp, wui = RXPW.RXP.GetStatus(), RXPW.WUI.GetStatus()
    local sync = RXPW.Sync.GetState()
    local preview = RXPW.Preview.GetState()

    local header = Panel.header
    header.version:SetText("v" .. tostring(RXPW.GetVersion() or "?"))
    StatusDot(header.status[1], rxp.loaded and rxp.arrowAvailable, rxp.loaded and (rxp.arrowAvailable and "detected" or "no arrow data") or "not loaded")
    StatusDot(header.status[2], wui.loaded and wui.apiAvailable, wui.loaded and (wui.apiAvailable and "detected" or "API missing") or "not loaded")
    StatusDot(header.status[3], sync.running, sync.running and "running"
        or preview.active and "paused for preview" or Config.Get("autoSync") and "unavailable" or "off")

    controls.autoSync:SetChecked(Config.Get("autoSync"))
    controls.strategy:SetValue(Config.Get("strategy"))
    local text = STRATEGY_TEXT[Config.Get("strategy")]
    if text then Panel.strategyRow.frame.desc:SetText(text.desc) end
    controls.questIcons:SetChecked(Config.Get("questIcons"))
    controls.serviceIcons:SetChecked(Config.Get("serviceIcons"))
    controls.customColors:SetChecked(Config.Get("customColors"))
    controls.debug:SetChecked(Config.Get("debug"))
    -- RestedXP's own option, read live (nil: RestedXP or its settings missing).
    local arrowHidden = RXPW.RXP.IsArrowHidden()
    controls.hideArrow:SetChecked(arrowHidden == true)
    SetEnabledLook(controls.hideArrow, arrowHidden ~= nil)
    Panel.arrowRow.frame.desc:SetText(arrowHidden == nil
        and "Unavailable: RestedXP Guides is not loaded, or its settings could not be read."
        or "Hide RestedXP's on-screen waypoint arrow and follow Waypoint UI's marker instead.")
    SetEnabledLook(controls.openWaypointUI, RXPW.WUI.CanOpenSettings())

    -- Preview: an active preview is shown as the current selection.
    if preview.active and preview.key then previewSelection.key = preview.key end
    if preview.active and preview.distance then previewSelection.distance = preview.distance end
    local dropdown = controls.previewIconDropdown
    dropdown:SetValue(previewSelection.key)
    local icon, tint = RXPW.Preview.GetEntryArt(previewSelection.key)
    local swatch = controls.previewIcon.swatch
    swatch:SetTexture(icon)
    swatch:SetShown(icon ~= nil)
    if icon then
        local c = Config.Get("customColors") and tint
        swatch:SetVertexColor(c and c.r or 1, c and c.g or 1, c and c.b or 1)
    end
    controls.previewDistance:SetValue(previewSelection.distance)
    local available = wui.apiAvailable
    for _, id in ipairs({ "previewShow", "previewNext", "previewAll" }) do SetEnabledLook(controls[id], available) end
    SetEnabledLook(controls.previewStop, preview.active or preview.orphan)
    local status
    if not available then
        status = "|cffff6060Preview needs Waypoint UI's navigation API.|r"
    elseif preview.active then
        status = format("|cff70d65aPreview active:|r %s (%s)%s", PREVIEW_LABELS[preview.key] or tostring(preview.key),
            tostring(preview.distance), preview.cycling and ", cycling through all icons" or "")
    elseif preview.orphan then
        status = "A leftover preview marker from before the reload is shown; Stop Preview removes it."
    else
        status = "No preview is shown."
    end
    Panel.previewStatus.frame.text:SetText(status)
    Layout()
end

--------------------------------------------------------------------------------
-- Canvas, scrolling and registration
--------------------------------------------------------------------------------

local function BuildCanvas()
    if built then return end
    -- Size from Blizzard's settings canvas if the panel has not anchored us.
    local settingsCanvas = _G.SettingsPanel and SettingsPanel.Container and SettingsPanel.Container.SettingsCanvas
    if settingsCanvas and (canvas:GetWidth() or 0) < 50 then canvas:SetAllPoints(settingsCanvas) end

    scroll = CreateFrame("ScrollFrame", nil, canvas)
    scroll:SetPoint("TOPLEFT", canvas, "TOPLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", -(SCROLLBAR_WIDTH + 8), 4)
    if scroll.SetClipsChildren then scroll:SetClipsChildren(true) end
    content = CreateFrame("Frame", nil, scroll)
    content:SetSize(600, 1)
    scroll:SetScrollChild(content)

    scrollbar = CreateFrame("Slider", nil, canvas)
    scrollbar:SetOrientation("VERTICAL")
    scrollbar:SetPoint("TOPRIGHT", canvas, "TOPRIGHT", -4, -8)
    scrollbar:SetPoint("BOTTOMRIGHT", canvas, "BOTTOMRIGHT", -4, 8)
    scrollbar:SetWidth(SCROLLBAR_WIDTH)
    scrollbar:EnableMouse(true)
    Solid(scrollbar, "BACKGROUND", 1, 1, 1, 0.06):SetAllPoints()
    local thumb = scrollbar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(1, 1, 1, 0.3)
    thumb:SetSize(SCROLLBAR_WIDTH, 40)
    scrollbar:SetThumbTexture(thumb)
    scrollbar.thumb = thumb
    scrollbar:SetMinMaxValues(0, 0)
    scrollbar:SetValueStep(1)
    scrollbar:SetValue(0)
    scrollbar:SetScript("OnValueChanged", function(_, value)
        CloseList()
        scroll:SetVerticalScroll(value)
    end)

    local function Wheel(_, delta)
        local _, range = scrollbar:GetMinMaxValues()
        scrollbar:SetValue(min(range or 0, max(0, scroll:GetVerticalScroll() - delta * SCROLL_STEP)))
    end
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", Wheel)
    scrollbar:EnableMouseWheel(true)
    scrollbar:SetScript("OnMouseWheel", Wheel)
    Panel.Scroll = function(delta) Wheel(nil, delta) end
    scroll:SetScript("OnSizeChanged", function(self, width)
        content:SetWidth(width or self:GetWidth())
        Layout()
    end)

    -- Close an open list when clicking elsewhere.
    canvas:SetScript("OnEvent", function(_, event)
        -- The owner button toggles the list itself (its OnClick follows).
        if event == "GLOBAL_MOUSE_DOWN" and openList and not openList:IsMouseOver()
            and not openList.owner:IsMouseOver() then
            CloseList()
        end
    end)

    built = true
    Build()
    content:SetWidth(max(scroll:GetWidth() or 0, 400))
end

local function OnShow()
    BuildCanvas()
    if canvas.RegisterEvent then pcall(canvas.RegisterEvent, canvas, "GLOBAL_MOUSE_DOWN") end
    local width = scroll:GetWidth()
    if width and width > 0 then content:SetWidth(width) end
    Panel.Refresh()
end

local function OnHide()
    CloseList()
    if canvas.UnregisterEvent then pcall(canvas.UnregisterEvent, canvas, "GLOBAL_MOUSE_DOWN") end
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

    RXPW.Config.RegisterListener(function()
        if built and canvas:IsShown() then Panel.Refresh() end
    end)
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
