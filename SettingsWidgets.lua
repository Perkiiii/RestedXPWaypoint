-- Settings widgets reproducing Waypoint UI 1.7's settings controls with plain
-- WoW frames. Dimensions, colours and texture regions follow Waypoint UI's
-- Settings_Widgets.lua, Settings_Preload.lua and packages/uic-common. Its
-- artwork is referenced from the separately installed Waypoint UI at runtime
-- (never copied or bundled); without a verified Waypoint UI 1.7.x the same
-- layout is drawn with flat colours. No Waypoint UI code or module is used.
local addonName, RXPW = ...
local W = {}
RXPW.SettingsWidgets = W
local max, min, floor, exp = math.max, math.min, math.floor, math.exp
W.GOLD = { 1, 0.82, 0 }         -- Waypoint UI NORMAL_FONT_COLOR (255, 210, 0)
W.WHITE = { 1, 1, 1 }
W.GREY = { 216 / 255, 216 / 255, 216 / 255 }
local GOLD, WHITE, GREY = W.GOLD, W.WHITE, W.GREY

--------------------------------------------------------------------------------
-- Fonts: Waypoint UI's UIFontObjectNormalN (GameFontNormal's file, shadow 1,-1)
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
W.Font = Font

local function Text(parent, size, color, alpha, justify)
    local fs = parent:CreateFontString(nil, "OVERLAY")
    fs:SetFontObject(Font(size))
    color = color or WHITE
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

-- Anchors a region around its frame. Waypoint UI's Fill{ delta = -7 } is
-- 3.5 px outside every edge; the menu uses separate left/right/top/bottom.
-- Offsets of a scaled region are in its own units, so they are divided by
-- the scale Art() gives it (Waypoint UI outsets a separate unscaled frame).
local function Outset(region, frame, left, right, top, bottom, scale)
    region.outset = { frame, left, right, top, bottom or top }
    scale = scale or region.artScale or 1
    region:ClearAllPoints()
    region:SetPoint("TOPLEFT", frame, "TOPLEFT", -left / scale, top / scale)
    region:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", right / scale, -(bottom or top) / scale)
end

local function Sound(kit)
    if type(PlaySound) == "function" and SOUNDKIT and SOUNDKIT[kit] then pcall(PlaySound, SOUNDKIT[kit]) end
end
W.Sound = Sound

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

--------------------------------------------------------------------------------
-- Artwork: texture regions of the installed Waypoint UI (left, right, top,
-- bottom as fractions; slice margins left, right, top, bottom in texels).
--------------------------------------------------------------------------------

local TAB = "Interface\\AddOns\\WaypointUI\\Art\\Settings\\TabButton"
local CONTAINER = "Interface\\AddOns\\WaypointUI\\Art\\Settings\\Widget-Container"
local WIDGET = "Interface\\AddOns\\WaypointUI\\Art\\Settings\\Widget-Background"
local COMMON = "Interface\\AddOns\\WaypointUI\\packages\\uic-common\\resources\\common"

local function Region(file, l, r, t, b, size, inset, scale)
    return { file = file, coords = { l / size[1], r / size[1], t / size[2], b / size[2] },
        inset = inset, scale = scale or 1 }
end
local S256, S128, S512 = { 256, 128 }, { 128, 64 }, { 512, 512 }
local function C(l, r, t, b, inset, scale) return Region(COMMON, l, r, t, b, S512, inset, scale) end

local ART = {
    TabHighlighted = Region(TAB, 0, 64, 0, 64, S256, 16, 0.6),
    TabPushed = Region(TAB, 64, 128, 0, 64, S256, 16, 0.6),
    TabSelected = Region(TAB, 0, 64, 64, 128, S256, 16, 0.6),
    TabSelectedHighlighted = Region(TAB, 64, 128, 64, 128, S256, 16, 0.6),
    TabSelectedPushed = Region(TAB, 128, 192, 64, 128, S256, 16, 0.6),
    Container = Region(CONTAINER, 0, 64, 0, 64, S128, 18, 1),
    Subcontainer = Region(CONTAINER, 64, 128, 0, 64, S128, 18, 1),
    Widget = { file = WIDGET, inset = 14, scale = 0.5 },

    Check = C(4, 51, 192, 239), CheckDisabled = C(98, 145, 192, 239),
    Checked = C(51, 98, 192, 239), CheckedDisabled = C(145, 192, 192, 239),

    Gray = C(7, 100, 7, 48, 14, 0.7), GrayHighlighted = C(106, 199, 7, 48, 14, 0.7),
    GrayPushed = C(205, 298, 7, 48, 14, 0.7), GrayDisabled = C(304, 397, 7, 48, 14, 0.7),
    Red = C(7, 100, 54, 95, 14, 0.7), RedHighlighted = C(106, 199, 54, 95, 14, 0.7),
    RedPushed = C(205, 298, 54, 95, 14, 0.7), RedDisabled = C(304, 397, 54, 95, 14, 0.7),
    MenuArrow = C(344, 370, 186, 212),
    Menu = C(192, 319, 98, 192, { 35, 35, 22, 51 }, 0.9),
    MenuRow = C(401, 433, 102, 118, 4, 1),

    Input = C(7, 100, 242, 283, 10, 0.7), InputDisabled = C(106, 199, 242, 283, 10, 0.7),

    ScrollTrack = C(78, 90, 378, 499, 6, 0.3),
    ScrollThumb = C(4, 28, 376, 501, 12), ScrollThumbHighlighted = C(28, 52, 376, 501, 12),
    ScrollThumbPushed = C(52, 76, 376, 501, 12),

    RangeTrack = C(90, 144, 474, 499, { 15, 15, 13, 13 }, 1),
    RangeThumb = C(92, 128, 376, 412), RangeThumbHighlighted = C(128, 164, 376, 412),
    RangeThumbPushed = C(164, 200, 376, 412), RangeThumbDisabled = C(200, 236, 376, 412),
    StepLeft = C(92, 117, 415, 440), StepLeftHighlighted = C(115, 140, 415, 440),
    StepLeftPushed = C(138, 163, 415, 440), StepLeftDisabled = C(161, 186, 415, 440),
    StepRight = C(90, 115, 446, 471), StepRightHighlighted = C(113, 138, 446, 471),
    StepRightPushed = C(136, 161, 446, 471), StepRightDisabled = C(159, 184, 446, 471),
}
W.ART = ART

-- Flat stand-ins, used only when the verified Waypoint UI artwork is absent.
local FLAT = {
    TabHighlighted = { 0.24, 0.24, 0.24, 0.9 }, TabPushed = { 0.19, 0.19, 0.19, 0.9 },
    TabSelected = { 0.30, 0.22, 0.06, 0.95 }, TabSelectedHighlighted = { 0.36, 0.27, 0.08, 0.95 },
    TabSelectedPushed = { 0.27, 0.20, 0.05, 0.95 },
    Container = { 0.19, 0.19, 0.19, 0.92 }, Subcontainer = { 0.24, 0.24, 0.24, 0.9 },
    Widget = { 0.3, 0.3, 0.3, 0.45 },
    Check = { 0, 0, 0, 0.85 }, CheckDisabled = { 0.05, 0.05, 0.05, 0.6 },
    Checked = { 0, 0, 0, 0.85 }, CheckedDisabled = { 0.05, 0.05, 0.05, 0.6 },
    Gray = { 0.22, 0.22, 0.22, 1 }, GrayHighlighted = { 0.28, 0.28, 0.28, 1 },
    GrayPushed = { 0.15, 0.15, 0.15, 1 }, GrayDisabled = { 0.18, 0.18, 0.18, 0.7 },
    Red = { 0.45, 0.04, 0.04, 1 }, RedHighlighted = { 0.55, 0.06, 0.06, 1 },
    RedPushed = { 0.32, 0.02, 0.02, 1 }, RedDisabled = { 0.18, 0.18, 0.18, 0.7 },
    MenuArrow = { 0.8, 0.8, 0.8, 1 }, Menu = { 0.04, 0.04, 0.04, 0.96 }, MenuRow = { 1, 1, 1, 1 },
    Input = { 0, 0, 0, 0.85 }, InputDisabled = { 0.05, 0.05, 0.05, 0.6 },
    ScrollTrack = { 0.1, 0.1, 0.1, 0.9 }, ScrollThumb = { 0.35, 0.35, 0.35, 1 },
    ScrollThumbHighlighted = { 0.45, 0.45, 0.45, 1 }, ScrollThumbPushed = { 0.3, 0.3, 0.3, 1 },
    RangeTrack = { 0, 0, 0, 0.85 }, RangeThumb = { 0.7, 0.7, 0.7, 1 },
    RangeThumbHighlighted = { 0.85, 0.85, 0.85, 1 }, RangeThumbPushed = { 0.6, 0.6, 0.6, 1 },
    RangeThumbDisabled = { 0.35, 0.35, 0.35, 1 },
}
for _, side in ipairs({ "StepLeft", "StepRight" }) do
    FLAT[side], FLAT[side .. "Highlighted"] = { 0.6, 0.6, 0.6, 1 }, { 0.9, 0.9, 0.9, 1 }
    FLAT[side .. "Pushed"], FLAT[side .. "Disabled"] = { 0.5, 0.5, 0.5, 1 }, { 0.3, 0.3, 0.3, 1 }
end

local artAvailable
function W.HasArt()
    if artAvailable == nil then
        artAvailable = RXPW.WUI ~= nil and RXPW.WUI.HasVerifiedArt() == true
    end
    return artAvailable
end
function W.ResetArt() artAvailable = nil end

-- Applies a named region to a texture; nil hides it (Waypoint UI's TEXTURE_NIL).
local function Art(texture, name)
    texture.artName = name
    if not name then texture:Hide(); return end
    texture:Show()
    local spec = W.HasArt() and ART[name]
    if not spec then
        local c = FLAT[name] or { 0.3, 0.3, 0.3, 0.8 }
        texture:SetColorTexture(c[1], c[2], c[3], c[4])
        return
    end
    texture:SetTexture(spec.file)
    texture:SetVertexColor(1, 1, 1, 1)
    local inset = spec.inset
    if inset and texture.SetTextureSliceMargins then
        local l, r, t, b = inset, inset, inset, inset
        if type(inset) == "table" then l, r, t, b = inset[1], inset[2], inset[3], inset[4] end
        texture:SetTextureSliceMargins(l, t, r, b)
        if texture.SetTextureSliceMode and Enum and Enum.UITextureSliceMode then
            texture:SetTextureSliceMode(Enum.UITextureSliceMode.Stretched)
        end
        if texture.SetScale and texture.artScale ~= (spec.scale or 1) then
            texture:SetScale(spec.scale or 1)
            texture.artScale = spec.scale or 1
            local o = texture.outset
            if o then Outset(texture, o[1], o[2], o[3], o[4], o[5]) end
        end
    end
    local c = spec.coords
    if c then texture:SetTexCoord(c[1], c[2], c[3], c[4]) else texture:SetTexCoord(0, 1, 0, 1) end
end
W.Art = Art

--------------------------------------------------------------------------------
-- Button state (Waypoint UI ButtonMixin): NORMAL, HIGHLIGHTED, PUSHED
--------------------------------------------------------------------------------

local function GetState(self)
    if self.pushed then return "PUSHED" end
    if self.hovered then return "HIGHLIGHTED" end
    return "NORMAL"
end
W.GetState = GetState

-- update(self, state) runs on every hover/press/enable change.
local function Stateful(frame, update)
    frame.UpdateVisual = function(self) update(self, GetState(self)) end
    frame:HookScript("OnEnter", function(self) self.hovered = true; self:UpdateVisual() end)
    frame:HookScript("OnLeave", function(self) self.hovered, self.pushed = false, false; self:UpdateVisual() end)
    frame:HookScript("OnMouseDown", function(self)
        if self:IsEnabled() then self.pushed = true; self:UpdateVisual() end
    end)
    frame:HookScript("OnMouseUp", function(self) self.pushed = false; self:UpdateVisual() end)
    local setEnabled = frame.SetEnabled
    frame.SetEnabled = function(self, enabled)
        setEnabled(self, enabled and true or false)
        if not enabled then self.pushed = false end
        self:UpdateVisual()
    end
    return frame
end

local function SetEnabledLook(frame, enabled)
    if frame.SetEnabled then frame:SetEnabled(enabled and true or false) end
end

--------------------------------------------------------------------------------
-- Sidebar tab button (35 px high; text 12, left, 11.5 px padding)
--------------------------------------------------------------------------------

local TAB_HEIGHT = 35
local TAB_TEXT_INSET = 23 / 2

function W.TabButton(parent, label, onClick)
    local button = CreateFrame("Button", nil, parent)
    button:SetHeight(TAB_HEIGHT)
    button.background = button:CreateTexture(nil, "BACKGROUND")
    Outset(button.background, button, 3.5, 3.5, 3.5)
    button.text = Text(button, 12, WHITE, 0.5, "LEFT")
    if button.text.SetWordWrap then button.text:SetWordWrap(false) end
    button.text:SetText(label)
    button.label = label
    function button:SetSelected(selected)
        self.selected = selected and true or false
        self:UpdateVisual()
    end
    Stateful(button, function(self, state)
        local y = state == "PUSHED" and -1 or 0
        self.text:ClearAllPoints()
        self.text:SetPoint("LEFT", self, "LEFT", TAB_TEXT_INSET, y)
        self.text:SetPoint("RIGHT", self, "RIGHT", -TAB_TEXT_INSET, y)
        if self.selected then
            Art(self.background, state == "PUSHED" and "TabSelectedPushed"
                or state == "HIGHLIGHTED" and "TabSelectedHighlighted" or "TabSelected")
            self.text:SetAlpha(1)
        else
            Art(self.background, state == "PUSHED" and "TabPushed" or state == "HIGHLIGHTED" and "TabHighlighted" or nil)
            self.text:SetAlpha(state == "PUSHED" and 0.75 or state == "HIGHLIGHTED" and 1 or 0.5)
        end
    end)
    button:SetScript("OnClick", function(self)
        Sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
        onClick(self)
    end)
    button:UpdateVisual()
    return button
end

--------------------------------------------------------------------------------
-- Check button (25 x 25)
--------------------------------------------------------------------------------

function W.Checkbox(parent, onToggle)
    local box = CreateFrame("Button", nil, parent)
    box:SetSize(25, 25)
    box.texture = box:CreateTexture(nil, "ARTWORK")
    box.texture:SetAllPoints()
    -- Flat fallback only: Waypoint UI's art already contains the tick.
    box.check = box:CreateTexture(nil, "OVERLAY")
    box.check:SetTexture("Interface\\Buttons\\UI-CheckBox-Check")
    box.check:SetPoint("CENTER", 1, 0)
    box.check:SetSize(26, 26)
    function box:SetChecked(value)
        self.checked = value and true or false
        self:UpdateVisual()
    end
    function box:GetChecked() return self.checked end
    Stateful(box, function(self)
        local enabled = self:IsEnabled()
        if self.checked then Art(self.texture, enabled and "Checked" or "CheckedDisabled")
        else Art(self.texture, enabled and "Check" or "CheckDisabled") end
        self.check:SetShown(self.checked and not W.HasArt())
        self.check:SetAlpha(enabled and 1 or 0.5)
    end)
    box:SetScript("OnClick", function(self)
        local value = not self.checked
        Sound(value and "IG_MAINMENU_OPTION_CHECKBOX_ON" or "IG_MAINMENU_OPTION_CHECKBOX_OFF")
        onToggle(value)
    end)
    box:SetChecked(false)
    return box
end

--------------------------------------------------------------------------------
-- Text buttons (RedTextButton / GrayTextButton; 188 x 32 in settings rows)
--------------------------------------------------------------------------------

local function TextButton(parent, label, onClick, red, width)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(width or 188, 32)
    button.red = red
    button.texture = button:CreateTexture(nil, "BACKGROUND")
    button.texture:SetAllPoints()
    button.text = Text(button, 12, red and GOLD or GREY, 1, "CENTER")
    if button.text.SetWordWrap then button.text:SetWordWrap(false) end
    button.text:SetText(label)
    Stateful(button, function(self, state)
        local prefix = self.red and "Red" or "Gray"
        local enabled = self:IsEnabled()
        local y = state == "PUSHED" and enabled and -1 or 0
        self.text:ClearAllPoints()
        self.text:SetPoint("LEFT", self, "LEFT", 9.5, y)
        self.text:SetPoint("RIGHT", self, "RIGHT", -9.5, y)
        if not enabled then
            Art(self.texture, prefix .. "Disabled")
            self.text:SetTextColor(GREY[1], GREY[2], GREY[3], 0.5)
        else
            Art(self.texture, prefix .. (state == "NORMAL" and "" or state == "HIGHLIGHTED" and "Highlighted" or "Pushed"))
            local c = state ~= "NORMAL" and WHITE or (self.red and GOLD or GREY)
            self.text:SetTextColor(c[1], c[2], c[3], 1)
        end
    end)
    button:SetScript("OnClick", function(self)
        Sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
        onClick(self)
    end)
    -- 188 px like Waypoint UI, wider when the text needs it (never truncated
    -- unless the row has no more room: maxWidth).
    button.baseWidth = width or 188
    function button:Resize()
        local textWidth = self.text.GetUnboundedStringWidth and self.text:GetUnboundedStringWidth()
            or self.text:GetStringWidth() or 0
        local w = max(self.baseWidth, floor(textWidth + 32 + 0.5))
        if self.maxWidth then w = min(w, self.maxWidth) end
        self:SetWidth(w)
    end
    button:UpdateVisual()
    return button
end
W.Button = function(parent, label, onClick, width) return TextButton(parent, label, onClick, true, width) end
W.GrayButton = function(parent, label, onClick, width) return TextButton(parent, label, onClick, false, width) end

--------------------------------------------------------------------------------
-- Selection menu button and menu (UICCommon SelectionMenuButton/SelectionMenu)
--------------------------------------------------------------------------------

local openList
local function CloseList()
    if openList then openList:Hide() end
    openList = nil
end

local MENU_ROW, MENU_WIDTH, MENU_MAX_HEIGHT = 28, 175, 275
local DROPDOWN_MIN_WIDTH, DROPDOWN_HEIGHT = 125, 32

local function UpdateRow(row)
    local list = row:GetParent().list or row:GetParent()
    local selected = list.owner and list.owner.value == row.value
    local state = GetState(row)
    local alpha = state == "PUSHED" and 0.175 or state == "HIGHLIGHTED" and 0.25 or 0
    row.background:SetVertexColor(125 / 255, 125 / 255, 125 / 255, alpha)
    if not W.HasArt() then row.background:SetColorTexture(125 / 255, 125 / 255, 125 / 255, alpha) end
    if selected then row.text:SetTextColor(GOLD[1], GOLD[2], GOLD[3], 1)
    else row.text:SetTextColor(1, 1, 1, state == "NORMAL" and 0.75 or 1) end
    row.text:ClearAllPoints()
    local y = state == "PUSHED" and -1 or 0
    row.text:SetPoint("LEFT", row, "LEFT", 6.25 + (row.indent or 0), y)
    row.text:SetPoint("RIGHT", row, "RIGHT", -6.25, y)
end

function W.Dropdown(parent, listParent, options, onSelect)
    local button = CreateFrame("Button", nil, parent)
    button:SetSize(DROPDOWN_MIN_WIDTH, DROPDOWN_HEIGHT)
    button.texture = button:CreateTexture(nil, "BACKGROUND")
    button.texture:SetAllPoints()
    button.text = Text(button, 12, GREY, 1, "LEFT")
    if button.text.SetWordWrap then button.text:SetWordWrap(false) end
    button.arrow = button:CreateTexture(nil, "ARTWORK")
    button.arrow:SetSize(12, 12)
    Stateful(button, function(self, state)
        local enabled = self:IsEnabled()
        local y = state == "PUSHED" and enabled and -1 or 0
        Art(self.texture, not enabled and "GrayDisabled"
            or state == "NORMAL" and "Gray" or state == "HIGHLIGHTED" and "GrayHighlighted" or "GrayPushed")
        Art(self.arrow, "MenuArrow")
        if not W.HasArt() then
            self.arrow:SetTexture("Interface\\ChatFrame\\ChatFrameExpandArrow")
            if self.arrow.SetRotation then self.arrow:SetRotation(-math.pi / 2) end
        end
        self.arrow:SetAlpha(enabled and 1 or 0.5)
        self.arrow:ClearAllPoints()
        self.arrow:SetPoint("RIGHT", self, "RIGHT", -9.5, y)
        self.text:ClearAllPoints()
        self.text:SetPoint("LEFT", self, "LEFT", 9.5, y)
        self.text:SetPoint("RIGHT", self.arrow, "LEFT", -4, 0)
        local c = not enabled and GREY or state == "NORMAL" and GREY or WHITE
        self.text:SetTextColor(c[1], c[2], c[3], enabled and 1 or 0.5)
    end)

    -- Parented to the settings root (not the scroll child, which clips).
    local list = CreateFrame("Frame", nil, listParent)
    list:SetFrameStrata("FULLSCREEN_DIALOG")
    if list.SetToplevel then list:SetToplevel(true) end
    list:EnableMouse(true)
    list.background = list:CreateTexture(nil, "BACKGROUND")
    Outset(list.background, list, 33, 33, 20, 45)
    Art(list.background, "Menu")
    list.background:SetAlpha(0.925)
    list:Hide()
    list.rows = {}
    list.owner = button
    list.scroll = CreateFrame("ScrollFrame", nil, list)
    list.scroll:SetPoint("TOPLEFT", list, "TOPLEFT", 0, -3.5)
    list.scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT", 0, 3.5)
    list.body = CreateFrame("Frame", nil, list.scroll)
    list.body:SetSize(MENU_WIDTH, 1)
    list.body.list = list
    list.scroll:SetScrollChild(list.body)
    list.scroll:EnableMouseWheel(true)
    list.scroll:SetScript("OnMouseWheel", function(self, delta)
        local range = max(0, list.body:GetHeight() - self:GetHeight())
        self:SetVerticalScroll(min(range, max(0, self:GetVerticalScroll() - delta * MENU_ROW)))
    end)

    function button:SetOptions(newOptions)
        local signature = ""
        for _, option in ipairs(newOptions) do signature = signature .. tostring(option.value) .. ":" .. option.label .. "\n" end
        if self.optionsSignature == signature then return end
        self.optionsSignature = signature
        self.options = newOptions
        for _, row in ipairs(list.rows) do row:Hide() end
        for i, option in ipairs(newOptions) do
            local row = list.rows[i]
            if not row then
                row = CreateFrame("Button", nil, list.body)
                row:SetHeight(MENU_ROW)
                row.background = row:CreateTexture(nil, "BACKGROUND")
                row.background:SetAllPoints()
                Art(row.background, "MenuRow")
                row.text = Text(row, 14, WHITE, 0.75, "LEFT")
                if row.text.SetWordWrap then row.text:SetWordWrap(false) end
                Stateful(row, UpdateRow)
                row:SetScript("OnClick", function(self)
                    CloseList()
                    Sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
                    onSelect(self.value)
                end)
                list.rows[i] = row
            end
            row:Show()
            row:ClearAllPoints()
            row:SetPoint("TOPLEFT", list.body, "TOPLEFT", 0, -(i - 1) * MENU_ROW)
            row:SetPoint("TOPRIGHT", list.body, "TOPRIGHT", 0, -(i - 1) * MENU_ROW)
            row.text:SetText(option.label)
            row.value = option.value
            row:UpdateVisual()
        end
        local height = #newOptions * MENU_ROW
        list.body:SetHeight(height)
        list:SetHeight(min(height, MENU_MAX_HEIGHT) + 7)
        self:Resize()
    end

    -- Wide enough for the longest option (Waypoint UI: 125 px; never truncate).
    function button:Resize()
        local widest = 0
        for _, option in ipairs(self.options or {}) do
            self.text:SetText(option.label)
            widest = max(widest, self.text.GetUnboundedStringWidth and self.text:GetUnboundedStringWidth()
                or self.text:GetStringWidth() or 0)
        end
        self.idealWidth = max(DROPDOWN_MIN_WIDTH, floor(widest + 9.5 * 2 + 12 + 8 + 0.5))
        self:SetWidth(self.maxWidth and min(self.idealWidth, self.maxWidth) or self.idealWidth)
        self:SetValue(self.value)
    end

    function button:SetValue(value)
        self.value = value
        local label
        for _, o in ipairs(self.options or {}) do if o.value == value then label = o.label end end
        self.text:SetText(label or "")
        for _, row in ipairs(list.rows) do if row:IsShown() then row:UpdateVisual() end end
    end

    function button:Open()
        CloseList()
        local width = max(self:GetWidth(), MENU_WIDTH)
        list:SetWidth(width)
        list.body:SetWidth(width)
        list:ClearAllPoints()
        -- Below the button like Waypoint UI; above it near the screen bottom.
        local bottom = self.GetBottom and self:GetBottom()
        if bottom and bottom - list:GetHeight() - 51 < 0 and self:GetTop() then
            list:SetPoint("BOTTOM", self, "TOP", 0, 6 + 45)
        else
            list:SetPoint("TOP", self, "BOTTOM", 0, -6)
        end
        list.scroll:SetVerticalScroll(0)
        list:Show()
        openList = list
        for _, row in ipairs(list.rows) do if row:IsShown() then row:UpdateVisual() end end
    end
    button:SetScript("OnClick", function(self)
        Sound("IG_MAINMENU_OPTION_CHECKBOX_ON")
        if openList == self.list then CloseList() else self:Open() end
    end)
    button.list = list
    button.options = {}
    button:SetOptions(options)
    button:UpdateVisual()
    return button
end

function W.OutsideClick()
    if openList and not openList:IsMouseOver() and not openList.owner:IsMouseOver() then CloseList() end
end

--------------------------------------------------------------------------------
-- Range with value text (UICCommon RangeWithText, 188 x 19)
--------------------------------------------------------------------------------

local function Stepper(parent, increase, onStep)
    local b = CreateFrame("Button", nil, parent)
    b:SetSize(16, 16)
    b.texture = b:CreateTexture(nil, "ARTWORK")
    b.texture:SetAllPoints()
    local side = increase and "StepRight" or "StepLeft"
    Stateful(b, function(self, state)
        Art(self.texture, not self:IsEnabled() and side .. "Disabled"
            or side .. (state == "NORMAL" and "" or state == "HIGHLIGHTED" and "Highlighted" or "Pushed"))
    end)
    b:SetScript("OnClick", function()
        Sound("U_CHAT_SCROLL_BUTTON")
        onStep(increase and 1 or -1)
    end)
    b:UpdateVisual()
    return b
end

function W.Slider(parent, onChange)
    local frame = CreateFrame("Frame", nil, parent)
    frame:SetSize(188, 19)
    frame.text = Text(frame, 11, GOLD, 1, "RIGHT")
    local range = CreateFrame("Frame", nil, frame)
    range:SetPoint("TOPRIGHT"); range:SetPoint("BOTTOMRIGHT")
    -- 188 px like Waypoint UI; down to 140 px only when a row has no room.
    function frame:Resize()
        local width = min(188, max(140, self.maxWidth or 188))
        self:SetWidth(width)
        self.text:ClearAllPoints()
        self.text:SetPoint("TOPLEFT", self, "TOPLEFT", 0, 0)
        self.text:SetPoint("BOTTOMRIGHT", self, "BOTTOMLEFT", width * 0.34 - 5, 0)
        range:SetWidth(width * 0.66)
    end
    local slider = CreateFrame("Slider", nil, range)
    slider:SetOrientation("HORIZONTAL")
    slider:SetPoint("TOPLEFT", range, "TOPLEFT", 14, 0)
    slider:SetPoint("BOTTOMRIGHT", range, "BOTTOMRIGHT", -14, 0)
    slider:EnableMouse(true)
    slider.track = slider:CreateTexture(nil, "BACKGROUND")
    Outset(slider.track, slider, -3, -3, -3)
    Art(slider.track, "RangeTrack")
    slider.thumbTexture = slider:CreateTexture(nil, "OVERLAY")
    slider.thumbTexture:SetSize(16, 16)
    slider:SetThumbTexture(slider.thumbTexture)
    frame.slider = slider

    local function Step(direction)
        local d = frame.descriptor
        if not d or not slider:IsEnabled() then return end
        slider:SetValue(min(d.max, max(d.min, slider:GetValue() + direction * d.step)))
    end
    frame.backward = Stepper(range, false, Step)
    frame.backward:SetPoint("LEFT", range, "LEFT", 0, 0)
    frame.forward = Stepper(range, true, Step)
    frame.forward:SetPoint("RIGHT", range, "RIGHT", 0, 0)

    Stateful(slider, function(self, state)
        Art(self.thumbTexture, not self:IsEnabled() and "RangeThumbDisabled"
            or state == "NORMAL" and "RangeThumb" or state == "HIGHLIGHTED" and "RangeThumbHighlighted" or "RangeThumbPushed")
    end)
    slider:SetScript("OnValueChanged", function(_, value)
        if frame.refreshing or not frame.descriptor then return end
        local d = frame.descriptor
        local snapped = min(d.max, max(d.min, d.min + floor((value - d.min) / d.step + 0.5) * d.step))
        onChange(snapped)
    end)
    function frame:Apply(value, descriptor, formatted)
        self.refreshing = true
        self.descriptor = descriptor
        slider:SetMinMaxValues(descriptor.min, descriptor.max)
        slider:SetValueStep(descriptor.step)
        if slider.SetObeyStepOnDrag then slider:SetObeyStepOnDrag(true) end
        slider:SetValue(value)
        self.text:SetText(formatted)
        self.refreshing = false
    end
    function frame:SetEnabled(enabled)
        slider:SetEnabled(enabled)
        self.forward:SetEnabled(enabled)
        self.backward:SetEnabled(enabled)
        self.text:SetAlpha(enabled and 1 or 0.5)
    end
    function frame:IsEnabled() return slider:IsEnabled() end
    frame:Resize()
    slider:UpdateVisual()
    return frame
end

--------------------------------------------------------------------------------
-- Input (UICCommon Input, 188 x 32, text 14)
--------------------------------------------------------------------------------

function W.SoundInput(parent, onChange)
    local input = CreateFrame("EditBox", nil, parent)
    input:SetSize(188, 32)
    input:SetAutoFocus(false)
    input:SetFontObject(Font(14))
    if input.SetTextColor then input:SetTextColor(1, 1, 1, 1) end
    if input.SetTextInsets then input:SetTextInsets(8.75, 8.75, 0, 0) end
    if input.SetMaxLetters then input:SetMaxLetters(10) end
    input.texture = input:CreateTexture(nil, "BACKGROUND")
    input.texture:SetAllPoints()
    local setEnabled = input.SetEnabled
    function input:UpdateVisual() Art(self.texture, self:IsEnabled() and "Input" or "InputDisabled") end
    input.SetEnabled = function(self, enabled)
        if setEnabled then setEnabled(self, enabled and true or false) end
        if not enabled and self.ClearFocus then self:ClearFocus() end
        self:SetAlpha(enabled and 1 or 0.75)
        self:UpdateVisual()
    end
    input:SetScript("OnEnterPressed", function(self)
        local value = self:GetText()
        onChange(value == "" and "" or tonumber(value))
        self:ClearFocus()
    end)
    input:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    input:UpdateVisual()
    return input
end

--------------------------------------------------------------------------------
-- Scroll bar (UICCommon ScrollBar, 10 px; track 6 px) driving a scroll frame
-- with Waypoint UI's interpolated wheel scrolling (150 px per notch). The
-- OnUpdate exists only while an interpolation is running.
--------------------------------------------------------------------------------

local SCROLL_STEP, SCROLL_RATE = 150, 10

function W.ScrollBar(parent, scroll, onScroll)
    local bar = CreateFrame("Slider", nil, parent)
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(10)
    bar:EnableMouse(true)
    bar.track = bar:CreateTexture(nil, "BACKGROUND")
    bar.track:SetPoint("TOP"); bar.track:SetPoint("BOTTOM")
    bar.track:SetWidth(6)
    Art(bar.track, "ScrollTrack")
    bar.thumb = bar:CreateTexture(nil, "OVERLAY")
    bar.thumb:SetSize(10, 40)
    bar:SetThumbTexture(bar.thumb)
    bar:SetMinMaxValues(0, 0)
    bar:SetValueStep(1)
    bar:SetValue(0)
    Stateful(bar, function(self, state)
        Art(self.thumb, state == "PUSHED" and "ScrollThumbPushed"
            or state == "HIGHLIGHTED" and "ScrollThumbHighlighted" or "ScrollThumb")
    end)
    bar:UpdateVisual()

    local target
    local function Apply(value)
        scroll:SetVerticalScroll(value)
        bar.updating = true
        bar:SetValue(value)
        bar.updating = false
        if onScroll then onScroll(value) end
    end
    local function Animate(self, elapsed)
        local current = scroll:GetVerticalScroll()
        local delta = target - current
        if math.abs(delta) < 0.5 then
            self:SetScript("OnUpdate", nil)
            Apply(target)
            return
        end
        Apply(current + delta * (1 - exp(-SCROLL_RATE * elapsed)))
    end
    bar:SetScript("OnValueChanged", function(self, value)
        if self.updating then return end
        target = nil
        scroll:SetScript("OnUpdate", nil)
        scroll:SetVerticalScroll(value)
        if onScroll then onScroll(value) end
    end)
    function bar:GetRange() local _, hi = self:GetMinMaxValues() return hi or 0 end
    function bar:ScrollTo(value, instant)
        value = min(self:GetRange(), max(0, value))
        if instant then
            target = nil
            scroll:SetScript("OnUpdate", nil)
            Apply(value)
        else
            target = value
            scroll:SetScript("OnUpdate", Animate)
        end
    end
    function bar:Wheel(delta)
        self:ScrollTo((target or scroll:GetVerticalScroll()) - delta * SCROLL_STEP)
    end
    function bar:Update(contentHeight, viewHeight)
        local range = max(0, floor(contentHeight - viewHeight + 0.5))
        self:SetMinMaxValues(0, range)
        if scroll:GetVerticalScroll() > range then self:ScrollTo(range, true) end
        self:SetShown(range > 0)
        local track = self:GetHeight()
        if track and track > 0 and contentHeight > 0 then
            self.thumb:SetHeight(max(24, floor(track * min(1, viewHeight / contentHeight))))
        end
    end
    local function Wheel(_, delta) bar:Wheel(delta) end
    scroll:EnableMouseWheel(true)
    scroll:SetScript("OnMouseWheel", Wheel)
    bar:EnableMouseWheel(true)
    bar:SetScript("OnMouseWheel", Wheel)
    return bar
end

W.Text, W.Solid, W.Outset = Text, Solid, Outset
W.CloseList, W.SetEnabled = CloseList, SetEnabledLook
W.ShowTooltip, W.HideTooltip = ShowTooltip, HideTooltip
W.Stateful = Stateful
function W.IsListOpen() return openList ~= nil end
