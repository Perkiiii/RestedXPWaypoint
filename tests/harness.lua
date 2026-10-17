-- Shared offline test harness: mocks WoW, RestedXP and Waypoint UI, then loads
-- the addon files in .toc order. Used by native_first_test.lua.
-- Mocks are simplifications; they do not prove WoW Forever behaviour.
-- In particular WoW supertracking is assumed to track one target at a time.
local H = { passes = 0, fails = 0 }

function H.check(name, cond, detail)
  if cond then H.passes = H.passes + 1; print("ok   " .. name)
  else
    H.fails = H.fails + 1; print("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or ""))
    if H.verbose then for i = math.max(1, #H.chat - 6), #H.chat do print("       | " .. H.chat[i]) end end
  end
end

----------------------------------------------------------------------- WoW
local now = 0
function GetTime() return now end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
Enum = { SuperTrackingType = { Quest = 0, UserWaypoint = 1 } }
local timers, tickers = {}, {}
C_Timer = {
  After = function(d, fn) table.insert(timers, { at = now + d, fn = fn }) end,
  NewTicker = function(i, fn)
    local ticker = { i = i, fn = fn, next = now + i }
    function ticker:Cancel() self.cancelled = true end
    table.insert(tickers, ticker)
    return ticker
  end,
}
-- Widget mock (settings page). Besides state (sizes, shown state, scripts,
-- text, textures, slider/scroll values) it resolves anchors into rectangles,
-- clips scroll children, orders frames by strata/level/creation and hit-tests
-- the cursor, so H.ui.click() delivers a click to whatever frame is really on
-- top at that point, like the client. It still proves no pixels: fonts are
-- approximated (0.5 x size per character) and textures are not drawn.
local frames = {}
local Widget = {}
local creation = 0
local MOUSE_DEFAULT = { Button = true, CheckButton = true, Slider = true, EditBox = true }
local function newWidget(kind, parent)
  creation = creation + 1
  local w = setmetatable({ kind = kind, shown = true, width = 0, height = 0, alpha = 1, enabled = true,
    scripts = {}, hooks = {}, points = {}, children = {}, regions = {}, parent = parent, level = 1,
    order = creation, mouse = MOUSE_DEFAULT[kind] or false }, Widget)
  if parent and parent.children then table.insert(parent.children, w); w.level = (parent.level or 0) + 1 end
  return w
end
Widget.__index = Widget
-- Methods whose effect the tests do not observe.
for _, name in ipairs({ "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetShadowOffset",
  "SetShadowColor", "SetRotation", "SetToplevel", "EnableMouseWheel", "SetSnapToPixelGrid", "SetTexelSnappingBias",
  "SetAutoFocus", "ClearFocus", "SetTextInsets", "SetOrientation", "SetValueStep", "SetObeyStepOnDrag", "SetOwner",
  "AddLine", "SetDrawLayer", "SetBlendMode", "SetScale", "SetGradient", "SetMaxLetters", "SetNumeric" }) do
  Widget[name] = function() end
end
function Widget:SetFont(_, size) self.fontSize = size end
function Widget:SetFontObject(font) self.font = font end
function Widget:EnableMouse(v) self.mouse = v and true or false end
function Widget:IsMouseEnabled() return self.mouse end
function Widget:SetFrameStrata(s) self.strata = s end
function Widget:GetFrameStrata() local w = self while w do if w.strata then return w.strata end w = w.parent end return "MEDIUM" end
function Widget:SetClipsChildren(v) self.clips = v and true or false end
function Widget:SetThumbTexture(t) self.thumb = t end
function Widget:SetTexCoord(...) self.texCoord = { ... } end
function Widget:SetTextureSliceMargins(...) self.sliceMargins = { ... } end
function Widget:SetTextureSliceMode(m) self.sliceMode = m end
function Widget:SetSize(w, h) self.width, self.height = w, h end
function Widget:SetWidth(w) self.width = w; if self.scripts.OnSizeChanged then self.scripts.OnSizeChanged(self, w, self.height) end end
function Widget:SetHeight(h) self.height = h end
function Widget:SetPoint(...) table.insert(self.points, { ... }) end
function Widget:ClearAllPoints() self.points = {} end
function Widget:SetAllPoints(other) self.points = { { "ALL", other } }; if other and other.width then self.width, self.height = other.width, other.height end end
local function Relevel(w, level)
  w.level = level
  for _, c in ipairs(w.children) do Relevel(c, level + 1) end
end
function Widget:SetParent(p)
  if self.parent and self.parent.children then
    for i, c in ipairs(self.parent.children) do if c == self then table.remove(self.parent.children, i) break end end
  end
  self.parent = p
  if p and p.children then table.insert(p.children, self); Relevel(self, (p.level or 0) + 1) end
end
function Widget:GetParent() return self.parent end
function Widget:IsShown() return self.shown end
function Widget:IsVisible()
  local w = self
  while w do if not w.shown then return false end; w = w.parent end
  return true
end
function Widget:Show() if not self.shown then self.shown = true; if self.scripts.OnShow then self.scripts.OnShow(self) end end end
function Widget:Hide() if self.shown then self.shown = false; if self.scripts.OnHide then self.scripts.OnHide(self) end end end
function Widget:SetShown(v) if v then self:Show() else self:Hide() end end
function Widget:SetAlpha(a) self.alpha = a end
function Widget:GetAlpha() return self.alpha end
function Widget:SetEnabled(v) self.enabled = v and true or false end
function Widget:Enable() self.enabled = true end
function Widget:Disable() self.enabled = false end
function Widget:IsEnabled() return self.enabled end
function Widget:SetScript(name, fn) self.scripts[name] = fn; if name == "OnEvent" then self.onEvent = fn end end
function Widget:GetScript(name) return self.scripts[name] end
function Widget:HookScript(name, fn)
  local old = self.scripts[name]
  self.scripts[name] = function(...) if old then old(...) end fn(...) end
end
function Widget:RegisterEvent(e) self.events = self.events or {}; self.events[e] = true end
function Widget:UnregisterEvent(e) if self.events then self.events[e] = nil end end
function Widget:GetFrameLevel() return self.level end
function Widget:SetFrameLevel(l) Relevel(self, l) end
function Widget:CreateTexture() local t = newWidget("Texture", self); table.insert(self.regions, t); return t end
function Widget:CreateFontString() local t = newWidget("FontString", self); table.insert(self.regions, t); return t end
function Widget:SetTexture(path) self.texture = path end
function Widget:GetTexture() return self.texture end
function Widget:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
function Widget:SetVertexColor(r, g, b, a) self.vertex = { r, g, b, a } end
function Widget:SetText(t) self.text = t end
function Widget:GetText() return self.text end
function Widget:SetTextColor(r, g, b, a) self.textColor = { r, g, b, a } end
local function FontSize(w) return (w.font and w.font.fontSize) or w.fontSize or 12 end
function Widget:GetStringWidth() return #(tostring(self.text or "")) * FontSize(self) * 0.5 end
function Widget:GetUnboundedStringWidth() return self:GetStringWidth() end
function Widget:SetMinMaxValues(lo, hi) self.min, self.max = lo, hi end
function Widget:GetMinMaxValues() return self.min or 0, self.max or 0 end
function Widget:SetValue(v)
  v = math.max(self.min or 0, math.min(self.max or v, v))
  if v ~= self.value then self.value = v; if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v, true) end end
end
function Widget:GetValue() return self.value or 0 end
function Widget:GetValueStep() return self.step or 1 end
function Widget:SetScrollChild(c) self.scrollChild = c; c.scrollParent = self end
function Widget:SetVerticalScroll(v) self.scroll = v end
function Widget:GetVerticalScroll() return self.scroll or 0 end
function Widget:Click() if self.enabled and self.scripts.OnClick then self.scripts.OnClick(self, "LeftButton") end end
function CreateFrame(kind, _, parent)
  local f = newWidget(kind or "Frame", parent)
  f.events = {}
  table.insert(frames, f); return f
end
function CreateFont(name)
  local font = setmetatable({ name = name }, Widget)
  _G[name] = font
  return font
end

-- Geometry. Rectangles are { l, b, r, t } in canvas units, y up (as in WoW).
-- A frame with no anchors and no parent sits at the origin; any other frame
-- without anchors is not laid out (the client does not draw it either).
local Geometry = {}
local resolving = {}
local function Edge(rect, point)
  local x = point:find("LEFT") and rect[1] or point:find("RIGHT") and rect[3] or (rect[1] + rect[3]) / 2
  local y = point:find("TOP") and rect[4] or point:find("BOTTOM") and rect[2] or (rect[2] + rect[4]) / 2
  return x, y
end
-- Rectangles are cached until anything that affects geometry changes.
local geomVersion, rectCache = 0, setmetatable({}, { __mode = "k" })
for _, name in ipairs({ "SetPoint", "ClearAllPoints", "SetAllPoints", "SetSize", "SetWidth", "SetHeight",
  "SetParent", "SetVerticalScroll", "SetScrollChild", "SetText", "SetFont", "SetFontObject" }) do
  local original = Widget[name]
  Widget[name] = function(...) geomVersion = geomVersion + 1; return original(...) end
end
local RectUncached
function Geometry.Rect(w)
  local cached = rectCache[w]
  if cached and cached.version == geomVersion then return cached.rect end
  local rect = RectUncached(w)
  rectCache[w] = { version = geomVersion, rect = rect }
  return rect
end
function RectUncached(w)
  if resolving[w] then return nil end
  if w.scrollParent then -- scroll child: TOPLEFT follows the scroll frame and its offset
    local s = Geometry.Rect(w.scrollParent)
    if not s then return nil end
    local top = s[4] + (w.scrollParent.scroll or 0)
    return { s[1], top - w.height, s[1] + w.width, top }
  end
  if #w.points == 0 then
    if w.kind == "FontString" and w.parent then return nil end
    if not w.parent or w.parent == UIParent then return { 0, 0, w.width, w.height } end
    return nil
  end
  resolving[w] = true
  local fix = {}
  local ok = true
  for _, p in ipairs(w.points) do
    if p[1] == "ALL" then
      local r = Geometry.Rect(p[2] or w.parent)
      if not r then ok = false break end
      fix.l, fix.b, fix.r, fix.t = r[1], r[2], r[3], r[4]
    else
      local point, rel, relPoint, x, y = p[1], p[2], p[3], p[4], p[5]
      if type(rel) == "number" then rel, relPoint, x, y = nil, point, rel, relPoint
      elseif type(relPoint) == "number" then relPoint, x, y = point, relPoint, x end
      if type(rel) == "string" then rel = _G[rel] end
      rel = rel or w.parent
      local r = rel and Geometry.Rect(rel)
      if not r then ok = false break end
      local ax, ay = Edge(r, relPoint or point)
      ax, ay = ax + (x or 0), ay + (y or 0)
      if point:find("LEFT") then fix.l = ax elseif point:find("RIGHT") then fix.r = ax else fix.cx = ax end
      if point:find("TOP") then fix.t = ay elseif point:find("BOTTOM") then fix.b = ay else fix.cy = ay end
    end
  end
  resolving[w] = nil
  if not ok then return nil end
  local width = w.width
  local height = w.height
  if w.kind == "FontString" and width == 0 then width = w:GetStringWidth() end
  local l, r, b, t = fix.l, fix.r, fix.b, fix.t
  if l and not r then r = l + width elseif r and not l then l = r - width
  elseif not l then l = (fix.cx or 0) - width / 2; r = l + width end
  if w.kind == "FontString" and height == 0 then height = Geometry.StringHeight(w, r - l) end
  if b and not t then t = b + height elseif t and not b then b = t - height
  elseif not b then b = (fix.cy or 0) - height / 2; t = b + height end
  return { l, b, r, t }
end
function Widget:GetWidth()
  local r = #self.points > 0 and Geometry.Rect(self)
  return r and (r[3] - r[1]) or self.width
end
function Widget:GetHeight()
  local r = #self.points > 0 and Geometry.Rect(self)
  return r and (r[4] - r[2]) or self.height
end
function Widget:GetStringHeight() return Geometry.StringHeight(self, self:GetWidth()) end
function Geometry.StringHeight(self, width)
  if not width or width <= 0 then width = 300 end
  local lines = 0
  for line in (tostring(self.text or "") .. "\n"):gmatch("([^\n]*)\n") do
    lines = lines + math.max(1, math.ceil(#line * FontSize(self) * 0.5 / width))
  end
  return math.max(1, lines) * math.floor(FontSize(self) * 1.1 + 0.5)
end
function Widget:GetLeft() local r = Geometry.Rect(self) return r and r[1] end
function Widget:GetRight() local r = Geometry.Rect(self) return r and r[3] end
function Widget:GetTop() local r = Geometry.Rect(self) return r and r[4] end
function Widget:GetBottom() local r = Geometry.Rect(self) return r and r[2] end
function Widget:GetCenter() local r = Geometry.Rect(self) if r then return (r[1] + r[3]) / 2, (r[2] + r[4]) / 2 end end

local STRATA = { BACKGROUND = 1, LOW = 2, MEDIUM = 3, HIGH = 4, DIALOG = 5, FULLSCREEN = 6,
  FULLSCREEN_DIALOG = 7, TOOLTIP = 8 }
-- Visible part of a frame after every clipping ancestor (scroll frames clip).
function Geometry.Visible(w)
  if not w:IsVisible() then return nil end
  local r = Geometry.Rect(w)
  if not r then return nil end
  local p = w.parent
  while p do
    if p.kind == "ScrollFrame" or p.clips then
      local c = Geometry.Rect(p)
      if not c then return nil end
      r = { math.max(r[1], c[1]), math.max(r[2], c[2]), math.min(r[3], c[3]), math.min(r[4], c[4]) }
      if r[1] >= r[3] or r[2] >= r[4] then return nil end
    end
    p = p.parent
  end
  return r
end
local function Above(a, b)
  local sa, sb = STRATA[a:GetFrameStrata()] or 3, STRATA[b:GetFrameStrata()] or 3
  if sa ~= sb then return sa > sb end
  if a.level ~= b.level then return a.level > b.level end
  return a.order > b.order
end
H.ui = { cursor = nil }
function H.ui.rect(w) return Geometry.Rect(w) end
function H.ui.visibleRect(w) return Geometry.Visible(w) end
-- True when the frame is shown, laid out and not entirely clipped away.
function H.ui.rendered(w) return Geometry.Visible(w) ~= nil end
function H.ui.hit(x, y)
  local best
  for _, f in ipairs(frames) do
    if f.mouse and f.alpha > 0 then
      local r = Geometry.Visible(f)
      if r and x >= r[1] and x <= r[3] and y >= r[2] and y <= r[4] and (not best or Above(f, best)) then best = f end
    end
  end
  return best
end
local hovered
function H.ui.moveTo(x, y)
  H.ui.cursor = { x, y }
  local target = H.ui.hit(x, y)
  if target ~= hovered then
    local old = hovered
    hovered = target
    if old and old.scripts.OnLeave then old.scripts.OnLeave(old) end
    if target and target.scripts.OnEnter then target.scripts.OnEnter(target) end
  end
  return target
end
-- Point inside the visible part of a frame (its centre unless given offsets).
function H.ui.pointOf(w, fx, fy)
  local r = Geometry.Visible(w)
  if not r then return nil end
  return r[1] + (r[3] - r[1]) * (fx or 0.5), r[2] + (r[4] - r[2]) * (fy or 0.5)
end
-- A real click at a frame's centre: the frame that receives it is whichever is
-- on top there. Returns the receiving frame (nil when nothing takes the mouse).
function H.ui.click(w, fx, fy)
  local x, y = H.ui.pointOf(w, fx, fy)
  if not x then return nil end
  local target = H.ui.moveTo(x, y)
  H.fire("GLOBAL_MOUSE_DOWN", "LeftButton")
  if not target then return nil end
  if target.scripts.OnMouseDown then target.scripts.OnMouseDown(target, "LeftButton") end
  if target.enabled and (target.kind == "Button" or target.kind == "CheckButton") and target.scripts.OnClick then
    target.scripts.OnClick(target, "LeftButton", true)
  end
  if target.scripts.OnMouseUp then target.scripts.OnMouseUp(target, "LeftButton") end
  return target
end
function H.ui.wheel(w, delta)
  local x, y = H.ui.pointOf(w)
  if not x then return nil end
  local p = H.ui.hit(x, y)
  while p and not p.scripts.OnMouseWheel do p = p.parent end
  if p then p.scripts.OnMouseWheel(p, delta) end
  return p
end
function Widget:IsMouseOver()
  if self.mouseOver ~= nil then return self.mouseOver end
  local c = H.ui.cursor
  if not c then return false end
  local r = Geometry.Visible(self)
  return r ~= nil and c[1] >= r[1] and c[1] <= r[3] and c[2] >= r[2] and c[2] <= r[4]
end
-- Runs OnUpdate scripts (only used for short-lived animations) for `seconds`.
function H.ui.update(seconds, step)
  step = step or 1 / 60
  local t = 0
  while t < seconds do
    for _, f in ipairs(frames) do
      if f.scripts.OnUpdate and f:IsVisible() then f.scripts.OnUpdate(f, step) end
    end
    t = t + step
  end
end
GameFontNormal = setmetatable({ GetFont = function() return "Fonts\\FRIZQT__.TTF", 12, "" end }, Widget)
GameFontHighlight = setmetatable({}, Widget)
GameTooltip = setmetatable({ shown = false, width = 0, height = 0, scripts = {}, points = {}, children = {}, regions = {} }, Widget)
-- Settings API (modern client): one entry per registered category.
H.settings = { categories = {}, addOnCategories = {}, opened = {} }
Settings = {
  RegisterCanvasLayoutCategory = function(frame, name)
    local category = { frame = frame, name = name, id = 1000 + #H.settings.categories }
    function category:GetID() return self.id end
    table.insert(H.settings.categories, category)
    return category
  end,
  RegisterAddOnCategory = function(category) table.insert(H.settings.addOnCategories, category) end,
  OpenToCategory = function(id)
    table.insert(H.settings.opened, id)
    for _, c in ipairs(H.settings.categories) do
      if c.id == id then c.frame.width, c.frame.height = 640, 520; c.frame:Show() end
    end
  end,
}
SettingsPanel = nil
-- StaticPopup: the last shown dialog; tests accept or cancel it.
StaticPopupDialogs = {}
H.popups = {}
function StaticPopup_Show(name) table.insert(H.popups, name); return StaticPopupDialogs[name] end
function H.acceptPopup(name) local d = StaticPopupDialogs[name]; if d and d.OnAccept then d.OnAccept() end end
function InCombatLockdown() return H.inCombat or false end
function H.fire(event, ...) for _, f in ipairs(frames) do if f.events[event] and f.onEvent then f.onEvent(f, event, ...) end end end
H.chat = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(H.chat, m) end }
SlashCmdList = {}
-- The runner supplies the actual TOC version, just as WoW supplies metadata.
H.versions = { RestedXPWaypoint = assert(ADDON_VERSION, "Runner must provide the TOC version"), WaypointUI = "1.7.3" }
-- Every addon is loaded except the optional ones that change behaviour.
C_AddOns = { IsAddOnLoaded = function(a) return a ~= "ElvUI" and a ~= "MapPinEnhanced" end, GetAddOnMetadata = function(a) return H.versions[a] or "x" end }
C_Map = { GetMapInfo = function(id) return { name = "Map" .. id } end, CanSetUserWaypointOnMap = function() return true end }

local st = { quest = nil, user = false, setQuestCalls = 0 }
H.st = st
H.operations = {}
local writer = "bridge"
local function record(kind, value)
  table.insert(H.operations, { time = now, writer = writer, kind = kind, value = value })
end
C_SuperTrack = {
  SetSuperTrackedQuestID = function(q)
    record("quest", q)
    if q == 0 then st.releaseCalls = (st.releaseCalls or 0) + 1; st.quest = nil
    else st.setQuestCalls = st.setQuestCalls + 1; st.quest = q; st.user = false end
    H.fire("SUPER_TRACKING_CHANGED")
  end,
  GetSuperTrackedQuestID = function() return st.quest or 0 end,
  SetSuperTrackedUserWaypoint = function(v)
    st.user = v; if v then st.quest = nil end
    H.fire("SUPER_TRACKING_CHANGED")
  end,
  GetHighestPrioritySuperTrackingType = function() if st.quest then return 0 elseif st.user then return 1 end end,
  IsSuperTrackingAnything = function() return st.quest ~= nil or st.user end,
  ClearAllSuperTracked = function() st.quest = nil; st.user = false; H.fire("SUPER_TRACKING_CHANGED") end,
}
-- Secure post-hook and stack provenance model. The source is intentionally
-- separate from quest ID / event timing, just as it is in the client.
local selectionStack
function debugstack() return H.selectionStack or selectionStack or "[Interface/AddOns/Blizzard_QuestLog/QuestLog.lua]:123: in function 'SelectQuest'" end
function hooksecurefunc(object, method, callback)
  local original = object[method]
  object[method] = function(...)
    local result = original(...)
    callback(...)
    return result
  end
end
C_Map.GetUserWaypoint = function() return st.waypoint end
-- quests[id] = { title, ready, poi = native distance (yd) or nil, objectives = { {type, finished, numFulfilled, numRequired}, ... } }
local quests = {}
H.quests = quests
H.noObjectivesAPI = false
C_QuestLog = {
  IsOnQuest = function(q) return quests[q] ~= nil end,
  ReadyForTurnIn = function(q) return quests[q] and quests[q].ready or false end,
  IsComplete = function(q) return quests[q] and quests[q].ready or false end,
  GetTitleForQuestID = function(q) return quests[q] and quests[q].title end,
  GetQuestObjectives = function(q) if H.noObjectivesAPI then return nil end return quests[q] and quests[q].objectives end,
}
C_Navigation = { GetDistance = function()
  if st.quest and quests[st.quest] then return quests[st.quest].poi or 0 end
  if st.user then return 30 end
  return 0 end }
-- HereBeDragons: player at (0,0); an element's world position is (wx, wy) in yards.
local HBD = { GetPlayerWorldPosition = function() return 0, 0, 0 end,
  GetWorldDistance = function(_, i, x1, y1, x2, y2) return math.sqrt((x2-x1)^2 + (y2-y1)^2) end }
-- AceAddon-3.0 registry: RestedXP's addon object (settings.profile, arrowFrame,
-- DrawArrow, UpdateMap) is created with the RestedXP mocks below.
H.aceAddons = {}
local AceAddon = { GetAddon = function(_, name) return H.aceAddons[name] end }
LibStub = setmetatable({}, { __call = function(_, name)
  if name == "HereBeDragons-2.0" then return HBD end
  if name == "AceAddon-3.0" then return AceAddon end
end })

----------------------------------------------------------------------- Waypoint UI
-- Waypoint UI 1.7.3 side effects modelled for Stage 4 (MapPin.NewUserNavigation):
-- every call, renames included, resets the in-world marker (markerResets);
-- with wui.pathfinding the path is rebuilt (pathBuilds) and the native waypoint
-- becomes a path-step waypoint (IsPathStepWaypointTracked). Counters only: no
-- rendering, timing or FPS is modelled.
local wui = { nav = nil, writes = 0, clears = 0, markerResets = 0, pathBuilds = 0,
  audioOptions = {}, markerIntroEvents = 0 }
H.wui = wui
WaypointUIAPI = { Navigation = {
  NewUserNavigation = function(o)
    wui.writes = wui.writes + 1
    table.insert(wui.audioOptions, o.suppressAudio)
    record("navigation", { name = o.name, flags = o.flags, mapID = o.mapID, x = o.x, y = o.y })
    if wui.rejects and wui.rejects > 0 then wui.rejects = wui.rejects - 1; return nil end
    if wui.errors and wui.errors > 0 then wui.errors = wui.errors - 1; error("temporary failure") end
    wui.nav = { name = o.name, mapID = o.mapID, x = o.x / 100, y = o.y / 100, flags = o.flags, stripCoordinates = o.stripCoordinates,
      iconTexture = o.iconTexture, iconType = o.iconType, r = o.r, g = o.g, b = o.b, requestRecolor = o.requestRecolor,
      suppressAudio = o.suppressAudio }
    if not o.suppressAudio then wui.audible = (wui.audible or 0) + 1 end
    wui.markerResets = wui.markerResets + 1
    -- One potential intro per reset; real waypoint/pinpoint choice and sound
    -- delivery depend on visibility, animation and the player's audio settings.
    wui.markerIntroEvents = wui.markerIntroEvents + 1
    st.waypoint = { uiMapID = o.mapID, position = { x = o.x / 100, y = o.y / 100 } }
    if wui.pathfinding then
      wui.pathBuilds = wui.pathBuilds + 1
      wui.pathStep = { uiMapID = o.mapID, position = { x = o.x / 100 + 0.01, y = o.y / 100 } }
      st.waypoint = wui.pathStep
    end
    C_SuperTrack.SetSuperTrackedUserWaypoint(true)
    H.fire("USER_WAYPOINT_UPDATED")
    return wui.nav end,
  GetUserNavigation = function() return wui.nav end,
  IsUserNavigationTracked = function()
    local n, p = wui.nav, st.waypoint
    return n ~= nil and st.user and p ~= nil and n.mapID == p.uiMapID
      and math.abs(n.x - p.position.x) < 0.00001 and math.abs(n.y - p.position.y) < 0.00001
  end,
  IsPathStepWaypointTracked = function()
    return wui.pathfinding == true and wui.nav ~= nil and st.user and st.waypoint ~= nil and st.waypoint == wui.pathStep
  end,
  IsUserNavigationFlagged = function(f) return wui.nav ~= nil and wui.nav.flags == f end,
  ClearUserNavigation = function(preserveWaypoint, suppressAdvance)
    record("clear", wui.nav and wui.nav.flags)
    wui.clears = wui.clears + 1; wui.nav = nil
    wui.lastClear = { preserveWaypoint = preserveWaypoint, suppressAdvance = suppressAdvance }
    if wui.onClear then wui.onClear() end
    if preserveWaypoint then return end
    st.waypoint = nil
    H.fire("USER_WAYPOINT_UPDATED")
    -- Waypoint UI's USER_WAYPOINT_UPDATED handler: a removed supertracked waypoint -> ClearAllSuperTracked
    if st.user then C_Timer.After(0.05, function()
      -- Like the installed handler, inspect state at delivery time. A newer
      -- pin or quest must not be erased by an old waypoint-removed event.
      if st.waypoint == nil and st.user then C_SuperTrack.ClearAllSuperTracked() end
    end) end
  end,
} }
function H.setManualWaypoint(name, source)
  writer = source or "player"
  record("navigation", { name = name })
  wui.nav = { name = name, mapID = 1421, x = 0.5, y = 0.5, flags = nil }; st.user = true; st.quest = nil
  st.waypoint = { uiMapID = 1421, position = { x = 0.5, y = 0.5 } }
  H.fire("USER_WAYPOINT_UPDATED")
  H.fire("SUPER_TRACKING_CHANGED")
  writer = "bridge"
end
-- Waypoint UI's saved session after /reload (WaypointDB_Local.mapPinSessionData
-- .userNavigation, MapPinUtil.CreatePinData fields, x/y normalised 0-1): the
-- table is restored on load as-is, without NewUserNavigation. WoW keeps the
-- native user waypoint; whether it is still supertracked depends on Waypoint
-- UI's ADDONS_UNLOADING handling (tracked = true/false). Call before H.load.
function H.restoreSession(nav, tracked)
  wui.nav = {
    name = nav.name, mapID = nav.mapID or 1421, x = nav.x or 0.5, y = nav.y or 0.5,
    fromWUI = true, flags = nav.flags, iconTexture = nav.iconTexture,
    iconType = nav.iconTexture and "TEXTURE" or nil, r = nav.r, g = nav.g, b = nav.b, requestRecolor = nav.requestRecolor,
    stripCoordinates = nav.stripCoordinates, superTracked = tracked and true or false,
  }
  st.waypoint = { uiMapID = wui.nav.mapID, position = { x = wui.nav.x, y = wui.nav.y } }
  st.user = tracked and true or false
end
function H.setExternalQuest(questID, source)
  writer = source or "player"
  selectionStack = source == "RestedXP" and "[Interface/AddOns/RXPGuides/functions.lua]:1850: in function <...>" or nil
  C_SuperTrack.SetSuperTrackedQuestID(questID)
  selectionStack = nil
  writer = "bridge"
end

----------------------------------------------------------------------- RestedXP
-- Element shapes follow RXPGuides v4.11.23 (functions.lua / GuideLoader.lua).
RXPG_ARROW = { element = nil, shown = true }
function RXPG_ARROW:IsShown() return self.shown end
function RXPG_ARROW:Hide() self.shown = false end
function RXPG_ARROW:Show() self.shown = true end
-- RestedXP's addon object: the "Hide waypoint arrow" option is
-- settings.profile.disableArrow; DrawArrow and UpdateMap calls are counted.
H.rxp = { drawArrow = 0, updateMap = 0 }
H.aceAddons.RXPGuides = {
  settings = { profile = { disableArrow = false } },
  arrowFrame = RXPG_ARROW,
  DrawArrow = function() H.rxp.drawArrow = H.rxp.drawArrow + 1 end,
  UpdateMap = function(reset) H.rxp.updateMap = H.rxp.updateMap + 1; H.rxp.lastUpdateReset = reset end,
}
function H.point(e) RXPG_ARROW.element = e end
-- RXPFrame.activeSteps (GuideWindow.lua): sticky steps still running + the current step.
RXPFrame = { activeSteps = {} }
function H.setActiveSteps(...)
  for _, s in ipairs(RXPFrame.activeSteps) do s.active = nil end
  RXPFrame.activeSteps = { ... }
  for _, s in ipairs(RXPFrame.activeSteps) do s.active = true end
end
-- newStep(index, opts, ...): opts may set loop = "" (#loop).
-- Like RestedXP's guide window drawing the step (GuideWindow.lua ~1316-1328):
-- every text-only or text-less element of a drawn step gets completed = true
-- (headers, "*" notes, .mob, every .goto). #hidewindow steps are not drawn.
-- opts.raw = true keeps the parser's flags (no render).
function H.render(s)
  if s.hidewindow then return s end
  for _, e in ipairs(s.elements) do
    if e.textOnly or not e.text then e.completed = true end
  end
  return s
end
function H.newStep(index, opts, ...)
  local s = { index = index, active = true, elements = {} }
  local raw = opts and opts.raw
  for k, v in pairs(opts or {}) do if k ~= "raw" then s[k] = v end end
  for _, e in ipairs({ ... }) do e.step = s; table.insert(s.elements, e) end
  if not raw then H.render(s) end
  return s
end
-- .goto zone,x,y[,radius[,optional]]. dist = world distance (yd) from the player
-- along the world x axis; the map coordinate is dist / 2 so it stays within 0-100.
function H.goto_(dist, y, extra)
  local e = { tag = "goto", arrow = true, textOnly = true, zone = 1421, x = dist / 2, y = y, wx = dist, wy = y, instance = 0 }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end
-- ".goto x,y,40,0": radius 40, optional -> hidePin; ",0" -> lowPrio, no radius.
function H.loopPoint(x, y) return H.goto_(x, y, { radius = 40, hidePin = true }) end
function H.lowPrioPoint(x, y) return H.goto_(x, y, { lowPrio = true }) end
function H.turnin(q, title) return { tag = "turnin", questId = q, title = title, text = "Turn in " .. title } end
function H.complete(q, obj, extra)
  local e = { tag = "complete", questId = q, obj = obj, dynamicText = true, text = " ", textOnly = false }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end
function H.header(t) return { text = t, textOnly = true } end
function H.mob(name) return { tag = "mob", text = name, textOnly = true } end
function H.accept(q, title) return { tag = "accept", questId = q, title = title, text = "Accept " .. title } end
function H.plusObjective(text) return { text = text } end -- "+text" line: objective without a quest
function H.placeholder() return { text = "1" } end         -- "+1" line (GuideLoader: { text = line:sub(2) })
function H.star(t) return { text = t, textOnly = true, hideTooltip = true } end -- "*text" line
function H.usespell(id) return { tag = "usespell", text = "-", spellId = id } end

----------------------------------------------------------------------- load + drive
function H.load(root, savedVariables)
  H.RXPW = {}
  for _, f in ipairs({ "Core.lua", "LabelResolver.lua", "RXPAdapter.lua", "NavigationResolver.lua", "WaypointAdapter.lua", "Sync.lua", "Preview.lua", "SettingsSchema.lua", "WaypointSettingsAdapter.lua", "SettingsWidgets.lua", "SettingsTabs.lua", "SettingsPanel.lua" }) do
    assert(loadfile(root .. "/" .. f))("RestedXPWaypoint", H.RXPW)
  end
  RXPWDB = savedVariables
  H.fire("ADDON_LOADED", "RestedXPWaypoint")
  H.fire("PLAYER_LOGIN")
  H.slash = SlashCmdList.RESTEDXPWAYPOINT
  return H.RXPW
end

function H.advance(seconds)
  local stop = now + seconds
  while true do
    local nextAt = stop
    for _, ticker in ipairs(tickers) do
      if not ticker.cancelled and ticker.next < nextAt then nextAt = ticker.next end
    end
    for _, t in ipairs(timers) do if t.at < nextAt then nextAt = t.at end end
    now = nextAt
    -- FIFO for equal-time callbacks, then tickers in creation order.
    local i = 1
    while i <= #timers do
      local t = timers[i]
      if t.at <= now then table.remove(timers, i); t.fn() else i = i + 1 end
    end
    for _, ticker in ipairs(tickers) do
      if not ticker.cancelled and ticker.next <= now then ticker.next = now + ticker.i; ticker.fn() end
    end
    if now >= stop then break end
  end
end

-- True when Waypoint UI's navigation points at the goto created with this dist.
function H.navAt(dist) return wui.nav ~= nil and math.abs(wui.nav.x * 200 - dist) < 1e-6 end
function H.mode() local s = H.RXPW.Sync.GetState(); return s.mode, s.questID, s.kind end
function H.lastChat(pattern) for i = #H.chat, 1, -1 do if H.chat[i]:find(pattern) then return H.chat[i] end end end
function H.countChat(pattern) local n = 0 for _, m in ipairs(H.chat) do if m:find(pattern) then n = n + 1 end end return n end
function H.failureText() return (H.RXPW.Sync.GetState().lastFailure or {}).text or "" end
function H.transitionText() return (H.RXPW.Sync.GetState().lastTransition or {}).text or "" end

function H.finish()
  print(string.format("%d passed, %d failed", H.passes, H.fails))
  if H.fails > 0 then
    print("--- recent chat ---"); for i = math.max(1, #H.chat - 30), #H.chat do print(H.chat[i]) end
    error(H.fails .. " test(s) failed", 0)
  end
end

return H
