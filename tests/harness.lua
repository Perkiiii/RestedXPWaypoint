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
local timers, ticker = {}, nil
C_Timer = {
  After = function(d, fn) table.insert(timers, { at = now + d, fn = fn }) end,
  NewTicker = function(i, fn) ticker = { i = i, fn = fn, next = now + i, Cancel = function() ticker = nil end }; return ticker end,
}
local frames = {}
function CreateFrame()
  local f = { events = {} }
  function f:RegisterEvent(e) self.events[e] = true end
  function f:UnregisterEvent(e) self.events[e] = nil end
  function f:SetScript(_, fn) self.onEvent = fn end
  table.insert(frames, f); return f
end
function H.fire(event, ...) for _, f in ipairs(frames) do if f.events[event] and f.onEvent then f.onEvent(f, event, ...) end end end
H.chat = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(H.chat, m) end }
SlashCmdList = {}
C_AddOns = { IsAddOnLoaded = function() return true end, GetAddOnMetadata = function(a) return a == "RXPWaypointBridge" and "0.5.3" or "x" end }
C_Map = { GetMapInfo = function(id) return { name = "Map" .. id } end, CanSetUserWaypointOnMap = function() return true end }

local st = { quest = nil, user = false, setQuestCalls = 0 }
H.st = st
C_SuperTrack = {
  SetSuperTrackedQuestID = function(q) if q == 0 then st.releaseCalls = (st.releaseCalls or 0) + 1; st.quest = nil else st.setQuestCalls = st.setQuestCalls + 1; st.quest = q; st.user = false end end,
  GetSuperTrackedQuestID = function() return st.quest or 0 end,
  SetSuperTrackedUserWaypoint = function(v) st.user = v; if v then st.quest = nil end end,
  GetHighestPrioritySuperTrackingType = function() if st.quest then return 0 elseif st.user then return 1 end end,
  ClearAllSuperTracked = function() st.quest = nil; st.user = false end,
}
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
LibStub = setmetatable({}, { __call = function(_, name) if name == "HereBeDragons-2.0" then return HBD end end })

----------------------------------------------------------------------- Waypoint UI
local wui = { nav = nil, writes = 0, clears = 0 }
H.wui = wui
WaypointUIAPI = { Navigation = {
  NewUserNavigation = function(o)
    wui.writes = wui.writes + 1
    wui.nav = { name = o.name, mapID = o.mapID, x = o.x / 100, y = o.y / 100, flags = o.flags, stripCoordinates = o.stripCoordinates }
    C_SuperTrack.SetSuperTrackedUserWaypoint(true); return wui.nav end,
  GetUserNavigation = function() return wui.nav end,
  IsUserNavigationTracked = function() return wui.nav ~= nil and st.user end,
  IsPathStepWaypointTracked = function() return false end,
  IsUserNavigationFlagged = function(f) return wui.nav ~= nil and wui.nav.flags == f end,
  ClearUserNavigation = function()
    wui.clears = wui.clears + 1; wui.nav = nil
    -- Waypoint UI's USER_WAYPOINT_UPDATED handler: a removed supertracked waypoint -> ClearAllSuperTracked
    if st.user then C_Timer.After(0.05, function() C_SuperTrack.ClearAllSuperTracked() end) end
  end,
} }
function H.setManualWaypoint(name)
  wui.nav = { name = name, mapID = 1421, x = 0.5, y = 0.5, flags = nil }; st.user = true; st.quest = nil
  H.fire("USER_WAYPOINT_UPDATED")
end

----------------------------------------------------------------------- RestedXP
-- Element shapes follow RXPGuides v4.11.23 (functions.lua / GuideLoader.lua).
RXPG_ARROW = { element = nil, IsShown = function() return true end }
function H.point(e) RXPG_ARROW.element = e end
-- RXPFrame.activeSteps (GuideWindow.lua): sticky steps still running + the current step.
RXPFrame = { activeSteps = {} }
function H.setActiveSteps(...)
  for _, s in ipairs(RXPFrame.activeSteps) do s.active = nil end
  RXPFrame.activeSteps = { ... }
  for _, s in ipairs(RXPFrame.activeSteps) do s.active = true end
end
-- newStep(index, opts, ...): opts may set loop = "" (#loop).
function H.newStep(index, opts, ...)
  local s = { index = index, active = true, elements = {} }
  for k, v in pairs(opts or {}) do s[k] = v end
  for _, e in ipairs({ ... }) do e.step = s; table.insert(s.elements, e) end
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
  H.ns = {}
  for _, f in ipairs({ "Core.lua", "LabelResolver.lua", "RXPAdapter.lua", "NavigationResolver.lua", "WaypointAdapter.lua", "Sync.lua" }) do
    assert(loadfile(root .. "/" .. f))("RXPWaypointBridge", H.ns)
  end
  RXPWaypointBridgeDB = savedVariables
  H.fire("ADDON_LOADED", "RXPWaypointBridge")
  H.fire("PLAYER_LOGIN")
  H.slash = SlashCmdList.RXPWAYPOINTBRIDGE
  return H.ns
end

function H.advance(seconds)
  local stop = now + seconds
  while true do
    local nextAt = stop
    if ticker and ticker.next < nextAt then nextAt = ticker.next end
    for _, t in ipairs(timers) do if t.at < nextAt then nextAt = t.at end end
    now = nextAt
    for i = #timers, 1, -1 do local t = timers[i]; if t.at <= now then table.remove(timers, i); t.fn() end end
    if ticker and ticker.next <= now then ticker.next = now + ticker.i; ticker.fn() end
    if now >= stop then break end
  end
end

-- True when Waypoint UI's navigation points at the goto created with this dist.
function H.navAt(dist) return wui.nav ~= nil and math.abs(wui.nav.x * 200 - dist) < 1e-6 end
function H.mode() local s = H.ns.Sync.GetState(); return s.mode, s.questID, s.kind end
function H.lastChat(pattern) for i = #H.chat, 1, -1 do if H.chat[i]:find(pattern) then return H.chat[i] end end end
function H.countChat(pattern) local n = 0 for _, m in ipairs(H.chat) do if m:find(pattern) then n = n + 1 end end return n end
function H.failureText() return (H.ns.Sync.GetState().lastFailure or {}).text or "" end
function H.transitionText() return (H.ns.Sync.GetState().lastTransition or {}).text or "" end

function H.finish()
  print(string.format("%d passed, %d failed", H.passes, H.fails))
  if H.fails > 0 then
    print("--- recent chat ---"); for i = math.max(1, #H.chat - 30), #H.chat do print(H.chat[i]) end
    error(H.fails .. " test(s) failed", 0)
  end
end

return H
