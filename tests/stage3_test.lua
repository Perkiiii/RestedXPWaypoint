-- F4-F6: observable destinations and presentation, with deterministic WoW mocks.
local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
local check, advance = H.check, H.advance
local R = H.load(ADDON_ROOT, { strategy = "coordinates" })
local w = H.wui
local q = 98001
H.quests[q] = { title = "Crystals", poi = 40, ready = false,
 objectives = { { type = "object", numFulfilled = 1, numRequired = 15, finished = false } } }
local obj = H.complete(q, 1, { text = "1/15 Crystals" })
local a = H.goto_(40, 0)
local step = H.newStep(1, {}, a, obj)
H.setActiveSteps(step); H.point(a); advance(2)
local function actual(label, ready)
 local n = w.nav
 return H.navAt(40) and n.flags == "RestedXPWaypoint" and n.name == label
  and n.iconTexture == (ready and "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\QuestComplete" or "Interface\\AddOns\\WaypointUI\\Art\\Icons\\IncompleteQuest")
  and n.r == (ready and 1 or 200/255) and n.g == (ready and 209/255 or 200/255)
  and n.b == (ready and 0 or 200/255)
end
check("F4 initial presentation", actual("1/15 Crystals"))
obj.text = "2/15 Crystals"; H.fire("QUEST_LOG_UPDATE"); advance(2)
check("F4 normal progress", actual(obj.text))
local writes = w.writes
for i = 3, 5 do obj.text = i .. "/15 Crystals"; H.fire("QUEST_LOG_UPDATE") end
advance(2); check("F4 burst uses latest presentation once", actual(obj.text) and w.writes == writes + 1)
w.rejects = 1; obj.text = "6/15 Crystals"; H.fire("QUEST_LOG_UPDATE"); advance(0.6)
check("F4 rejected update leaves actual label unchanged", actual("5/15 Crystals"))
advance(8); check("F4 rejected rename recovers without another event", actual(obj.text))
w.errors = 1; obj.text = "7/15 Crystals"; H.fire("QUEST_LOG_UPDATE"); advance(8)
check("F4 thrown rename recovers without another event", actual(obj.text))
-- A persistent refusal is bounded, quiet in normal chat, and does not poison failedKey.
w.rejects = 100; obj.text = "7a/15 Crystals"; writes = w.writes
local failures = H.countChat("Automatic sync failed")
H.fire("QUEST_LOG_UPDATE"); advance(16)
check("F4 persistent rejection is rate limited", w.writes - writes <= 4 and w.nav.name == "7/15 Crystals"
 and H.countChat("Automatic sync failed") == failures)
w.rejects = 0; advance(8)
check("F4 persistent rejection recovers", actual(obj.text))
H.setExternalQuest(q); obj.text = "8/15 Crystals"; H.fire("QUEST_LOG_UPDATE"); writes = w.writes; advance(5)
check("F4 external supertracking protected", w.writes == writes and w.nav.name == "7a/15 Crystals")
C_SuperTrack.SetSuperTrackedUserWaypoint(true); advance(3)
check("F4 active bridge destination gets latest pending label", actual(obj.text))
-- Same label and icon, different colour; no label event required beyond quest event.
local oldTint = R.WUI.GetPresentationTint
R.WUI.GetPresentationTint = function() return {r=.1,g=.2,b=.3}, "test" end
H.fire("QUEST_LOG_UPDATE"); advance(2)
check("F4 colour-only update applied", w.nav.name == obj.text and w.nav.r == .1 and w.nav.g == .2 and w.nav.b == .3 and H.navAt(40))
R.WUI.GetPresentationTint = oldTint
H.quests[q].ready = true; H.fire("QUEST_LOG_UPDATE"); advance(2)
check("F4 icon-only update applied", actual(obj.text, true))
w.nav.name = "9/15 Crystals"; obj.text = w.nav.name; writes = w.writes
H.fire("QUEST_LOG_UPDATE"); advance(3)
check("F4 already displayed presentation needs no write", actual(obj.text, true) and w.writes == writes)
H.setManualWaypoint("Manual"); obj.text = "10/15 Crystals"; H.fire("QUEST_LOG_UPDATE"); writes = w.writes; advance(10)
check("F4 manual pin never reclaimed by recovery", w.nav.name == "Manual" and w.writes == writes)
H.slash("sync"); advance(2); check("F4 explicit sync resumes latest presentation", actual(obj.text, true))
C_Map.GetBestMapForUnit = function() return 1421 end
C_Map.GetPlayerMapPosition = function() return {GetXY=function() return .5,.5 end} end
GetPlayerFacing = function() return 0 end
H.slash("preview incomplete"); obj.text = "11/15 Crystals"; writes = w.writes; H.fire("QUEST_LOG_UPDATE"); advance(5)
check("F4 preview protected", w.nav.flags == "RestedXPWaypoint-Preview" and w.writes == writes)
H.slash("preview off"); advance(2); check("F4 preview exit uses latest presentation", actual(obj.text, true))

-- F5 explicit parent relationships across a consecutive group.
H.quests[q].ready = false
H.slash("mode native-first")
local p = H.complete(q, 1, {text="Collect Crystals"})
local points = {}
for i=1,4 do points[i]=H.goto_(40+i,0,{parent=p}) end
local s = H.newStep(2,{hidewindow=true,loop="",sticky=true},p,points[1],points[2],points[3],points[4])
H.setActiveSteps(s)
for i,e in ipairs(points) do
 H.point(e); writes=w.writes; advance(2)
 local t=R.RXP.GetTarget(); local d=R.Nav.Decide(t,"native-first")
 check("F5 shared parent point "..i, H.mode()=="native" and select(2,H.mode())==q
  and C_SuperTrack.GetSuperTrackedQuestID()==q and w.writes==writes
  and t.label=="Collect Crystals" and d.context and d.context.questID==q)
end
for _,count in ipairs({2,3}) do
 local ob=H.complete(q,1,{text="Collect Crystals"})
 local group={ob}
 for i=1,count do group[#group+1]=H.goto_(40+i,0,{parent=ob}) end
 local normal=H.newStep(2+count,{},(unpack or table.unpack)(group))
 H.setActiveSteps(normal)
 for i=2,#group do
  H.point(group[i]); writes=w.writes; advance(2)
  local t=R.RXP.GetTarget(); local d=R.Nav.Decide(t,"native-first")
  R.Sync.PrepareTarget(t,d)
  check("F5 normal group "..count.." point "..(i-1),H.mode()=="native" and select(2,H.mode())==q
   and C_SuperTrack.GetSuperTrackedQuestID()==q and w.writes==writes and t.label=="Collect Crystals"
   and d.context and d.context.questID==q and t.iconTexture:find("IncompleteQuest",1,true))
 end
end
local other=H.complete(98002,1,{text="Other objective"})
local b=H.goto_(50,0,{parent=other})
H.newStep(3,{},p,points[1],other,b)
local c=R.Nav.FindQuestTarget(b)
check("F5 different parent stays associated with its own quest", c and c.questID==98002)
local travel=H.goto_(55,0,{parent=p,text="Enter the cave"})
H.newStep(4,{},p,travel)
check("F5 explicit travel overrides parent eligibility", R.Nav.FindQuestTarget(travel)==nil and R.Label.Resolve(travel).label=="Enter the cave")
local bad=H.goto_(56,0,{parent=p}); H.newStep(5,{},bad)
check("F5 cross-step stale parent not accepted", R.Nav.FindQuestTarget(bad)==nil and R.Label.Resolve(bad).fallback)
s.active=nil; H.point(points[4]); writes=w.writes; advance(3)
check("F5 inactive step cannot recreate navigation", w.writes==writes)

local ti=H.turnin(q,"Crystals")
local ta=H.goto_(40,0,{parent=ti}); local tb=H.goto_(41,0,{parent=ti})
local turnStep=H.newStep(9,{},ti,ta,tb); H.setActiveSteps(turnStep); H.quests[q].ready=true
for _,e in ipairs({ta,tb}) do
 H.point(e); advance(2)
 local t=R.RXP.GetTarget(); local d=R.Nav.Decide(t,"native-first")
 check("F5 shared turnin parent",H.mode()=="native" and select(2,H.mode())==q
  and C_SuperTrack.GetSuperTrackedQuestID()==q and t.label=="Turn in Crystals" and d.context.questID==q)
end
-- F6 own travel protection in all modes, then eligible native turn-in.
H.quests[q].ready=true
for _,strategy in ipairs({"hybrid","native-first","coordinates"}) do
 H.slash("mode "..strategy)
 for i, radius in ipairs({false,20}) do
  local ti=H.turnin(q,"Crystals")
  local x=H.goto_(60+i,0,{text="Cross the bridge",parent=ti,radius=radius or nil})
  local ts=H.newStep(10+i,{sticky=true},ti,x)
  H.setActiveSteps(ts); H.point(x); advance(2)
  check("F6 "..strategy.." travel radius "..tostring(radius),H.mode()=="coordinates" and H.navAt(60+i) and w.nav.name=="Cross the bridge")
 end
 local enter=H.goto_(65,0,{text="Enter the cave"})
 local door=H.goto_(66,0,{text="Go through the doorway"})
 local dest=H.goto_(40,0)
 local ts=H.newStep(20,{},enter,door,dest,H.turnin(q,"Crystals"))
 H.setActiveSteps(ts)
 for _,e in ipairs({enter,door}) do H.point(e); advance(2); check("F6 intermediate "..strategy,H.mode()=="coordinates" and w.nav.name==e.text); e.skip=true end
 H.point(dest); advance(2)
 check("F6 final eligible destination "..strategy, strategy=="coordinates" and H.mode()=="coordinates" and H.navAt(40)
  or strategy~="coordinates" and H.mode()=="native" and select(2,H.mode())==q and C_SuperTrack.GetSuperTrackedQuestID()==q)
 local ti=H.turnin(q,"Crystals"); local direct=H.goto_(40,0,{parent=ti})
 ts=H.newStep(21,{},ti,direct); H.setActiveSteps(ts); H.point(direct); advance(2)
 check("F5/F6 direct parent-linked turnin "..strategy, strategy=="coordinates" and H.mode()=="coordinates" or strategy~="coordinates" and H.mode()=="native" and select(2,H.mode())==q)
end
H.finish()
