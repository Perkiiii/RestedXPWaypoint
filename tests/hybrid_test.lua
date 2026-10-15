-- Offline integration tests for hybrid navigation (run with: node tests/run.js).
local ROOT = ADDON_ROOT
local fails, passes = 0, 0
local function check(name, cond, detail)
  if cond then passes = passes + 1; print("ok   " .. name)
  else fails = fails + 1; print("FAIL " .. name .. (detail ~= nil and (" -- " .. tostring(detail)) or "")) end
end

----------------------------------------------------------------------- mocks
local now = 0
function GetTime() return now end
function wipe(t) for k in pairs(t) do t[k] = nil end return t end
Enum = { SuperTrackingType = { Quest = 0, UserWaypoint = 1 } }
local timers, ticker = {}, nil
C_Timer = {
  After = function(d, fn) table.insert(timers, { at = now + d, fn = fn }) end,
  NewTicker = function(i, fn) ticker = { i = i, fn = fn, next = now + i, Cancel = function(self) ticker = nil end }; return ticker end,
}
local frames = {}
function CreateFrame()
  local f = { events = {} }
  function f:RegisterEvent(e) self.events[e] = true end
  function f:UnregisterEvent(e) self.events[e] = nil end
  function f:SetScript(_, fn) self.onEvent = fn end
  table.insert(frames, f); return f
end
local function fire(event, ...) for _, f in ipairs(frames) do if f.events[event] and f.onEvent then f.onEvent(f, event, ...) end end end
local chat = {}
DEFAULT_CHAT_FRAME = { AddMessage = function(_, m) table.insert(chat, m) end }
SlashCmdList = {}
C_AddOns = { IsAddOnLoaded = function() return true end, GetAddOnMetadata = function(a) return a == "RXPWaypointBridge" and "0.4.0" or "x" end }
C_Map = { GetMapInfo = function(id) return { name = "Map" .. id } end, CanSetUserWaypointOnMap = function() return true end }

-- WoW supertracking (mock assumes one supertracked target at a time)
local st = { quest = nil, user = false, setQuestCalls = 0 }
C_SuperTrack = {
  SetSuperTrackedQuestID = function(q) st.setQuestCalls = st.setQuestCalls + 1; if q == 0 then st.quest = nil else st.quest = q; st.user = false end end,
  GetSuperTrackedQuestID = function() return st.quest or 0 end,
  SetSuperTrackedUserWaypoint = function(v) st.user = v; if v then st.quest = nil end end,
  GetHighestPrioritySuperTrackingType = function() if st.quest then return 0 elseif st.user then return 1 end end,
  ClearAllSuperTracked = function() st.quest = nil; st.user = false end,
}
-- Quest log: [id] = { title, ready, poi = native distance or nil }
local quests = {}
C_QuestLog = {
  IsOnQuest = function(q) return quests[q] ~= nil end,
  ReadyForTurnIn = function(q) return quests[q] and quests[q].ready or false end,
  IsComplete = function(q) return quests[q] and quests[q].ready or false end,
  GetTitleForQuestID = function(q) return quests[q] and quests[q].title end,
}
C_Navigation = { GetDistance = function()
  if st.quest and quests[st.quest] then return quests[st.quest].poi or 0 end
  if st.user then return 30 end
  return 0 end }
-- HereBeDragons: player at (0,0); element world pos = (wx, wy)
local HBD = { GetPlayerWorldPosition = function() return 0, 0, 0 end,
  GetWorldDistance = function(_, i, x1, y1, x2, y2) return math.sqrt((x2-x1)^2 + (y2-y1)^2) end }
LibStub = setmetatable({}, { __call = function(_, name) if name == "HereBeDragons-2.0" then return HBD end end })

-- Waypoint UI public API
local wui = { nav = nil, writes = 0, clears = 0 }
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

-- RestedXP arrow + guide data
RXPG_ARROW = { element = nil, IsShown = function() return true end }
local function newStep(index, ...)
  local s = { index = index, active = true, elements = {} }
  for _, e in ipairs({ ... }) do e.step = s; table.insert(s.elements, e) end
  return s
end
local function goto_(x, y, extra)
  local e = { tag = "goto", arrow = true, textOnly = true, zone = 1421, x = x, y = y, wx = x, wy = y, instance = 0 }
  for k, v in pairs(extra or {}) do e[k] = v end
  return e
end
local function turnin(q, title) return { tag = "turnin", questId = q, title = title, text = "Turn in " .. title } end
local function header(t) return { text = t, textOnly = true } end
local function point(e) RXPG_ARROW.element = e end

----------------------------------------------------------------------- load addon
local ns = {}
for _, f in ipairs({ "Core.lua", "LabelResolver.lua", "RXPAdapter.lua", "NavigationResolver.lua", "WaypointAdapter.lua", "Sync.lua" }) do
  assert(loadfile(ROOT .. "/" .. f))("RXPWaypointBridge", ns)
end
RXPWaypointBridgeDB = { debug = true }
fire("ADDON_LOADED", "RXPWaypointBridge")
fire("PLAYER_LOGIN")
local slash = SlashCmdList.RXPWAYPOINTBRIDGE

local function advance(seconds)
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
local function mode() local s = ns.Sync.GetState(); return s.mode, s.questID end
local function lastChat(pattern) for i = #chat, 1, -1 do if chat[i]:find(pattern) then return chat[i] end end end
local function failureText() return (ns.Sync.GetState().lastFailure or {}).text or "" end

------------------------------------------------------------------- scenarios
-- 1. Coordinates strategy (default): travel then turn-in stays on coordinates
check("default strategy is coordinates", ns.db.strategy == "coordinates")
local A = goto_(10, 10); newStep(1, A, header("Follow the road"))
point(A); advance(1)
check("travel waypoint synced as coordinates", wui.writes == 1 and mode() == "coordinates" and wui.nav.x == 0.1, wui.writes)
local Q1 = 101; quests[Q1] = { title = "Infestation Investigation", ready = true, poi = 22 }
local C = goto_(20, 0); local stepC = newStep(2, C, header("Talk to Karos"), turnin(Q1, "Infestation Investigation"), { tag = "accept", questId = 102, text = "Accept Ride" })
point(C); advance(1)
check("turn-in uses coordinates under coordinates strategy", wui.writes == 2 and mode() == "coordinates" and st.setQuestCalls == 0)
check("label is the step instruction", wui.nav.name == "Talk to Karos", wui.nav and wui.nav.name)

-- 2. Switch to hybrid: immediate re-evaluation, coordinates -> native
slash("mode hybrid")
check("strategy saved", RXPWaypointBridgeDB.strategy == "hybrid")
check("bridge waypoint cleared before supertracking", wui.nav == nil and wui.clears == 1)
check("quest not yet set during the clear delay", st.setQuestCalls == 0)
advance(0.3)
check("quest supertracked after the delay (survives ClearAllSuperTracked)", st.quest == Q1, st.quest)
advance(1)
local m, q = mode()
check("native mode verified", m == "native" and q == Q1 and not ns.Sync.GetState().pending, m)
check("transition recorded", (ns.Sync.GetState().lastTransition or {}).text == "coordinates -> native quest 101")

-- 3. Idempotent under quest-log spam
local calls, writes = st.setQuestCalls, wui.writes
for i = 1, 10 do fire("QUEST_LOG_UPDATE"); advance(0.2) end
advance(1)
check("no re-supertracking on repeated quest events", st.setQuestCalls == calls and wui.writes == writes)

-- RestedXP supertracking the same quest is not an outside change
C_SuperTrack.SetSuperTrackedQuestID(Q1); fire("SUPER_TRACKING_CHANGED"); advance(2)
check("RestedXP re-supertracking our quest is not an outside change", ns.Sync.GetState().external == nil, ns.Sync.GetState().external)

-- 4. Turn-in done -> next instruction is an accept -> back to coordinates at same spot
stepC.elements[3].completed = true; quests[Q1] = nil; st.quest = nil
fire("QUEST_TURNED_IN"); advance(1)
check("native -> coordinates after turn-in", mode() == "coordinates" and wui.nav ~= nil and wui.nav.x == 0.2, mode())
check("transition native -> coordinates recorded", (ns.Sync.GetState().lastTransition or {}).text == "native quest 101 -> coordinates")

-- 5. Intermediate waypoints never go native
local Q2 = 201; quests[Q2] = { title = "Cave Delivery", ready = true, poi = 38 }
local a = goto_(30, 0, { radius = 8 }); local b = goto_(35, 0, { radius = 8 }); local c = goto_(40, 0)
newStep(3, a, b, c, header("Talk to the hermit"), turnin(Q2, "Cave Delivery"))
calls = st.setQuestCalls
point(a); advance(1)
check("cave entrance (radius) stays coordinates", mode() == "coordinates" and wui.nav.x == 0.3 and st.setQuestCalls == calls)
a.skip = true; point(b); advance(1)
check("tunnel (radius) stays coordinates", mode() == "coordinates" and wui.nav.x == 0.35 and st.setQuestCalls == calls)
b.skip = true; point(c); advance(2)
check("final turn-in goto goes native", mode() == "native" and st.quest == Q2, mode())
-- a pass-through goto directly in front of a ready turn-in (and one linked to it) stays coordinates
local Q2b = 202; quests[Q2b] = { title = "Radius Case", ready = true, poi = 45 }
local r1 = goto_(45, 0, { radius = 10 }); newStep(30, r1, turnin(Q2b, "Radius Case"))
point(r1); advance(2)
check("radius goto right before a turn-in stays coordinates", mode() == "coordinates" and lastChat("pass%-through") ~= nil, mode())
local tParent = turnin(Q2b, "Radius Case")
local r2 = goto_(46, 0, { radius = 10, parent = tParent }); newStep(31, tParent, r2)
point(r2); advance(2)
check("radius goto linked to a turn-in stays coordinates", mode() == "coordinates", mode())
local r3 = goto_(47, 0, { parent = tParent }); newStep(32, tParent, r3)
point(r3); advance(2)
check("final goto linked to a turn-in goes native", mode() == "native" and st.quest == Q2b, mode())

-- 6. Multiple turn-ins at one destination: first pending, then the next (native -> native)
local Q3, Q4 = 301, 302
quests[Q3] = { title = "First", ready = true, poi = 49 }; quests[Q4] = { title = "Second", ready = true, poi = 50 }
local m1 = goto_(50, 0); local stepM = newStep(4, m1, header("Talk to Renferrel"), turnin(Q3, "First"), turnin(Q4, "Second"))
point(m1); advance(2)
check("first pending turn-in chosen", st.quest == Q3 and select(2, mode()) == Q3, st.quest)
stepM.elements[3].completed = true; quests[Q3] = nil; st.quest = nil
fire("QUEST_TURNED_IN"); advance(2)
check("native -> native for the next turn-in", st.quest == Q4 and select(2, mode()) == Q4, st.quest)

-- 7. Ambiguous / non-turn-in associations stay coordinates
local d1 = goto_(60, 0); newStep(5, d1, { tag = "accept", questId = 401, text = "Accept X" }, turnin(Q4, "Second"))
point(d1); advance(2)
check("next instruction is an accept -> coordinates", mode() == "coordinates" and st.quest ~= Q4, mode())
local parentObj = { tag = "complete", questId = 402, text = "Kill boars" }
local d2 = goto_(62, 0, { parent = parentObj }); newStep(6, parentObj, d2, turnin(Q4, "Second"))
point(d2); advance(2)
check("goto linked to a non-turn-in -> coordinates", mode() == "coordinates")
local d3 = goto_(64, 0); newStep(7, d3, { tag = "complete", questId = 403, text = "Kill wolves", completed = true }, goto_(66, 0), turnin(Q4, "Second"))
point(d3); advance(2)
check("turn-in behind a later waypoint is not used", mode() == "coordinates")

-- 8. Unavailable quests stay coordinates
local Q5 = 501
local u1 = goto_(70, 0); newStep(8, u1, turnin(Q5, "Not Accepted"))
point(u1); advance(2)
check("quest not in log -> coordinates", mode() == "coordinates" and lastChat("not in the quest log") ~= nil)
quests[Q5] = { title = "Unfinished", ready = false, poi = 70 }
fire("QUEST_LOG_UPDATE"); advance(2)
check("quest not ready -> coordinates", mode() == "coordinates" and lastChat("not ready for turn%-in") ~= nil)
quests[Q5].ready = true
fire("QUEST_LOG_UPDATE"); advance(2)
check("quest becoming ready switches to native without the arrow moving", mode() == "native" and st.quest == Q5, mode())

-- 9. Native verification failure (no native target) -> fallback, no retry loop
local Q6 = 601; quests[Q6] = { title = "No POI", ready = true, poi = nil }
local f1 = goto_(80, 0); newStep(9, f1, turnin(Q6, "No POI"))
point(f1); advance(2)
check("no native target -> coordinate fallback", mode() == "coordinates" and wui.nav and wui.nav.x == 0.8, mode())
check("fallback reason recorded", failureText():find("no native navigation target") ~= nil, failureText())
calls = st.setQuestCalls
for i = 1, 5 do fire("QUEST_LOG_UPDATE"); advance(1) end
check("failed native not retried on quest events", st.setQuestCalls == calls)

-- 10. Inconsistent native target -> fallback
local Q7 = 701; quests[Q7] = { title = "Elsewhere", ready = true, poi = 400 }
local g1 = goto_(90, 0); newStep(10, g1, turnin(Q7, "Elsewhere"))
point(g1); advance(2)
check("native target far from RestedXP's destination -> fallback", mode() == "coordinates" and failureText():find("at least") ~= nil, failureText())

-- 11. Manual waypoint respected: no mode change at same destination, resume on new destination
local Q8 = 801; quests[Q8] = { title = "Later", ready = false, poi = 12 }
local h1 = goto_(12, 0); newStep(11, h1, turnin(Q8, "Later"))
point(h1); advance(2)
check("not-ready turn-in on coordinates", mode() == "coordinates")
wui.nav = { name = "Repair", mapID = 1421, x = 0.5, y = 0.5, flags = nil }; st.user = true; st.quest = nil
fire("USER_WAYPOINT_UPDATED"); advance(2)
quests[Q8].ready = true; calls, writes = st.setQuestCalls, wui.writes
fire("QUEST_LOG_UPDATE"); advance(2)
check("mode change held while a manual waypoint is tracked", st.setQuestCalls == calls and wui.writes == writes and wui.nav.name == "Repair")
local h2 = goto_(14, 0); newStep(12, h2, header("Walk on"))
point(h2); advance(2)
check("bridge resumes on the next RestedXP destination", wui.nav.flags == "RXPWaypointBridge" and wui.nav.x == 0.14)

-- 12. Same-coordinate label change still works (v0.3 regression)
local s1 = goto_(16, 0); newStep(13, s1, header("Talk to Karos"))
point(s1); advance(2)
writes = wui.writes
local s2 = goto_(16, 0); newStep(14, s2, header("Get the flight path"))
point(s2); advance(2)
check("same coordinates, new label -> one silent rename", wui.writes == writes + 1 and wui.nav.name == "Get the flight path")

-- 13. Stale transition callbacks are ignored
local Q9 = 901; quests[Q9] = { title = "Stale", ready = true, poi = 18 }
local t1 = goto_(18, 0); newStep(15, t1, turnin(Q9, "Stale"))
point(t1); advance(0.5)
local midPending = ns.Sync.GetState().pending
local t2 = goto_(25, 0); newStep(16, t2, header("Travel to town"))
point(t2); advance(2)
check("transition was in progress when RestedXP moved on", midPending == true, midPending)
check("travel after an interrupted native transition ends on coordinates", mode() == "coordinates" and wui.nav.x == 0.25, mode())
check("stale native quest not left supertracked", st.quest ~= Q9, st.quest)

-- 14. Strategy back to coordinates while native -> coordinates immediately
local Q10 = 1001; quests[Q10] = { title = "Back", ready = true, poi = 28 }
local k1 = goto_(28, 0); newStep(17, k1, turnin(Q10, "Back"))
point(k1); advance(2)
check("native before strategy switch", mode() == "native")
slash("mode coordinates")
check("coordinates strategy restores coordinates at once", mode() == "coordinates" and wui.nav and wui.nav.x == 0.28 and st.quest == nil)

-- 15. Manual sync in hybrid chooses native for an eligible turn-in, works with auto sync off
slash("mode hybrid"); advance(2)
slash("off")
local Q11 = 1101; quests[Q11] = { title = "Manual", ready = true, poi = 33 }
local n1 = goto_(33, 0); newStep(18, n1, turnin(Q11, "Manual"))
point(n1)
slash("sync"); advance(2)
check("manual sync in hybrid uses native quest navigation", st.quest == Q11 and lastChat("native quest navigation for Manual") ~= nil)
slash("on"); advance(2)

-- 16. Status prints without errors
local before = #chat
slash("status")
local okStatus = true
for i = before + 1, #chat do if chat[i]:find("Internal error") then okStatus = false end end
check("status command runs", okStatus and #chat > before + 5)

print(string.format("%d passed, %d failed", passes, fails))
if fails > 0 then
  print("--- recent chat ---"); for i = math.max(1, #chat - 30), #chat do print(chat[i]) end
end

if fails > 0 then error(fails .. " test(s) failed", 0) end
