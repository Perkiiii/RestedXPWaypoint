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
-- Widget mock (v0.6.0 settings page): enough state to build and drive the
-- panel offline (sizes, shown state, scripts, text, textures, slider/scroll
-- values). Unknown methods are no-ops; this proves no rendering or layout.
local frames = {}
local Widget = {}
local function newWidget(kind, parent)
  local w = setmetatable({ kind = kind, shown = true, width = 0, height = 0, alpha = 1, enabled = true,
    scripts = {}, hooks = {}, points = {}, children = {}, regions = {}, parent = parent, level = 1 }, Widget)
  if parent and parent.children then table.insert(parent.children, w); w.level = (parent.level or 0) + 1 end
  return w
end
Widget.__index = Widget
-- Methods whose effect the tests do not observe.
for _, name in ipairs({ "SetFontObject", "SetJustifyH", "SetJustifyV", "SetWordWrap", "SetFont", "SetShadowOffset",
  "SetShadowColor", "SetRotation", "SetFrameStrata", "SetToplevel", "EnableMouse", "EnableMouseWheel",
  "SetOrientation", "SetThumbTexture", "SetValueStep", "SetObeyStepOnDrag", "SetClipsChildren", "SetOwner",
  "AddLine", "SetDrawLayer", "SetBlendMode" }) do
  Widget[name] = function() end
end
function Widget:SetSize(w, h) self.width, self.height = w, h end
function Widget:SetWidth(w) self.width = w; if self.scripts.OnSizeChanged then self.scripts.OnSizeChanged(self, w, self.height) end end
function Widget:SetHeight(h) self.height = h end
function Widget:GetWidth() return self.width end
function Widget:GetHeight() return self.height end
function Widget:SetPoint(...) table.insert(self.points, { ... }) end
function Widget:ClearAllPoints() self.points = {} end
function Widget:SetAllPoints(other) self.points = { { "ALL", other } }; if other and other.width then self.width, self.height = other.width, other.height end end
function Widget:SetParent(p) self.parent = p end
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
function Widget:IsMouseOver() return self.mouseOver or false end
function Widget:GetFrameLevel() return self.level end
function Widget:SetFrameLevel(l) self.level = l end
function Widget:CreateTexture() local t = newWidget("Texture", self); table.insert(self.regions, t); return t end
function Widget:CreateFontString() local t = newWidget("FontString", self); table.insert(self.regions, t); return t end
function Widget:SetTexture(path) self.texture = path end
function Widget:GetTexture() return self.texture end
function Widget:SetColorTexture(r, g, b, a) self.color = { r, g, b, a } end
function Widget:SetVertexColor(r, g, b) self.vertex = { r, g, b } end
function Widget:SetText(t) self.text = t end
function Widget:GetText() return self.text end
function Widget:SetTextColor(r, g, b, a) self.textColor = { r, g, b, a } end
function Widget:GetStringWidth() return #(tostring(self.text or "")) * 6 end
function Widget:GetStringHeight()
  local width = self.width > 0 and self.width or 300
  return math.max(1, math.ceil(#(tostring(self.text or "")) * 6 / width)) * 13
end
function Widget:SetMinMaxValues(lo, hi) self.min, self.max = lo, hi end
function Widget:GetMinMaxValues() return self.min or 0, self.max or 0 end
function Widget:SetValue(v)
  v = math.max(self.min or 0, math.min(self.max or v, v))
  if v ~= self.value then self.value = v; if self.scripts.OnValueChanged then self.scripts.OnValueChanged(self, v) end end
end
function Widget:GetValue() return self.value or 0 end
function Widget:SetScrollChild(c) self.scrollChild = c end
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
C_AddOns = { IsAddOnLoaded = function() return true end, GetAddOnMetadata = function(a) return H.versions[a] or "x" end }
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
  for _, f in ipairs({ "Core.lua", "LabelResolver.lua", "RXPAdapter.lua", "NavigationResolver.lua", "WaypointAdapter.lua", "Sync.lua", "Preview.lua", "SettingsPanel.lua" }) do
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
