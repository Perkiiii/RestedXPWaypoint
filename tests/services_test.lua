-- Regression tests for v0.5.6: service icons (flight master, class trainer,
-- profession trainer, food and drink, repair) on RestedXP coordinate waypoints.
-- Fixtures follow the installed Forever guides. Mocked APIs; not proof of
-- in-game behaviour. Run with: node tests/run.js
local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
H.verbose = true
local check, advance, point, newStep, goto_ = H.check, H.advance, H.point, H.newStep, H.goto_
local quests, wui = H.quests, H.wui

-- Item classes (GetItemInfoInstant): 159 Refreshing Spring Water = Consumable/Food & Drink,
-- 769 Chunk of Boar Meat = Trade Goods (cooking ingredient).
local itemClass = { [159] = { 0, 5 }, [4540] = { 0, 5 }, [769] = { 7, 8 } }
C_Item = { GetItemInfoInstant = function(id)
  local c = itemClass[id]
  if not c then return nil end
  return id, "", "", "", 0, c[1], c[2]
end }

local RXPW = H.load(ADDON_ROOT, { debug = true, strategy = "native-first" })
local slash = H.slash
local OWN = "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\"

local function talk(name) return H.header("|Tinterface/worldmap/chatbubble_64grey.blp:20|tTalk to |cRXP_FRIENDLY_" .. name .. "|r") end
local function cond(tag) return { tag = tag, textOnly = true } end
local function visit(stepIndex, dist, ...)
  local g = goto_(dist, 0)
  local s = newStep(stepIndex, {}, g, ...)
  H.setActiveSteps(s)
  point(g); advance(2)
  return s
end

-- Flight master: .goto / >>Talk to Karos / .fp Sepulcher / .fly Undercity / .target   (Horde-01-14_Undead.lua, !Undead)
visit(1, 20, talk("Karos"), { tag = "fp", text = "Get the Sepulcher flight path" }, { tag = "fly", text = "Fly to the Undercity" }, cond("target"))
check("flight master step: flight master icon", H.mode() == "coordinates" and wui.nav.iconTexture == OWN .. "FlightMaster", wui.nav.iconTexture)
local function colourIs(hex)
  local r, g, b = tonumber(hex:sub(1, 2), 16) / 255, tonumber(hex:sub(3, 4), 16) / 255, tonumber(hex:sub(5, 6), 16) / 255
  return wui.nav and wui.nav.r and math.abs(wui.nav.r - r) < 1e-6 and math.abs(wui.nav.g - g) < 1e-6 and math.abs(wui.nav.b - b) < 1e-6
end
check("flight master marker: Discovery Green #70D65A", colourIs("70D65A"), wui.nav.r)
check("label is still RestedXP's instruction", wui.nav.name == "Get the Sepulcher flight path", wui.nav.name)
check("icon decision logged", H.lastChat("icon FlightMaster %(step 1 %.fp%)") ~= nil)

-- Class trainer: .goto / >>Talk to Aarnor / .trainer >>Train your class spells / .target / .money / .xp   (RestedXP-Skyborne.lua)
visit(2, 22, talk("Aarnor Galestrike::254082"), { tag = "trainer", text = "Train your class spells" }, cond("target"), cond("money"), cond("xp"))
check("class trainer step: class trainer icon", wui.nav.iconTexture == OWN .. "ClassTrainer", wui.nav.iconTexture)
check("class trainer marker: Arcane Purple #AB79F4", colourIs("AB79F4"), wui.nav.r)

-- Profession trainer: .goto / >>Talk to Dwukk / .train 2018 >> Train Blacksmithing / .target / .skill blacksmithing,1,1
visit(3, 24, talk("Dwukk"), { tag = "train", id = 2018, text = "Train |T136241:0|t[Blacksmithing]" }, cond("target"), cond("skill"))
check("profession trainer step (.train + .skill): profession trainer icon", wui.nav.iconTexture == OWN .. "ProfessionTrainer", wui.nav.iconTexture)
check("profession trainer marker: Artisan Copper #C57A55", colourIs("C57A55"), wui.nav.r)

-- Learning from a book is not a trainer: .goto / .itemcount / .train 2575 >>Use Mining for Dummies / .use
visit(4, 26, cond("itemcount"), { tag = "train", id = 2575, text = "Use |T4625105:0|t[Mining for Dummies]" }, cond("use"))
check("book step (.train + .use): default icon", wui.nav.iconTexture == OWN .. "DefaultWaypoint", wui.nav.iconTexture)
check("default icon: no r/g/b; Waypoint UI tints it with the marker colour", wui.nav.r == nil and wui.nav.g == nil
  and wui.nav.b == nil and wui.nav.requestRecolor == true)

-- Food and drink: .goto / >>Talk to Uualia / >>Buy Refreshing Spring Water / .vendor 251537 >>Vendor trash / *note / .collect 159,20 / .target
visit(5, 28, talk("Uualia Suncrest::251537"), H.header("|cRXP_BUY_Buy|r |T132794:0|t[Refreshing Spring Water] |cRXP_BUY_from her|r"),
  { tag = "vendor", id = 251537, text = "|cRXP_WARN_Vendor trash|r" }, H.star("Don't sell |T133970:0|t[Stringy Meat]"),
  { tag = "collect", id = 159, qty = 20, text = " " }, cond("target"))
check("vendor buying food/drink: food and drink icon", wui.nav.iconTexture == OWN .. "FoodAndDrink", wui.nav.iconTexture)
check("food marker: Tavern Gold #F3C24F", colourIs("F3C24F"), wui.nav.r)

-- Vendor collecting a cooking ingredient (trade goods) and no repair text: default icon
visit(6, 30, talk("Butcher"), { tag = "vendor", text = "Vendor trash" }, { tag = "collect", id = 769, qty = 10, text = " " })
check("vendor with a non-food item (sell junk): general vendor bags icon", wui.nav.iconTexture == OWN .. "Bags", wui.nav.iconTexture)

-- Repair: .vendor >> vendor trash, repair
visit(7, 32, talk("Smith"), { tag = "vendor", text = "vendor trash, repair" })
check("vendor that repairs: repair icon", wui.nav.iconTexture == OWN .. "Repair", wui.nav.iconTexture)
check("repair marker: Steel Silver #B9C9D5", colourIs("B9C9D5"), wui.nav.r)

-- Food purchase wins over a repair mention in the same vendor step
visit(8, 34, talk("Innkeeper"), { tag = "vendor", text = "|cRXP_WARN_Vendor and repair if needed|r" }, { tag = "collect", id = 4540, qty = 10, text = " " })
check("vendor buying food that also repairs: food and drink icon", wui.nav.iconTexture == OWN .. "FoodAndDrink", wui.nav.iconTexture)

-- Food bought already (collect complete): the repair mention decides
local s9 = visit(9, 36, talk("Innkeeper"), { tag = "vendor", text = "Vendor and repair" }, { tag = "collect", id = 4540, qty = 10, text = " ", completed = true })
check("food already bought: repair icon", wui.nav.iconTexture == OWN .. "Repair", wui.nav.iconTexture)

-- Quest instructions take precedence: Undead Karos step (.turnin 6321 / .accept 6323) before .fp
quests[6321] = { title = "Supplying the Sepulcher", ready = true, poi = 900 }
visit(10, 38, talk("Karos"), H.turnin(6321, "Supplying the Sepulcher"), H.accept(6323, "Ride to the Undercity"),
  { tag = "fp", text = "Get the Sepulcher flight path" })
check("quest first: quest icon, not the flight master icon", wui.nav.iconTexture ~= OWN .. "FlightMaster"
  and wui.nav.iconTexture ~= nil and wui.nav.iconTexture:find("Quest") ~= nil, wui.nav.iconTexture)

-- Turn-in finished, the flight path remains: flight master icon (silent update at the same spot)
quests[6321] = nil
local s10 = RXPW.RXP.GetTarget().element.step
s10.elements[3].completed = true
s10.elements[4].completed = true
local writes = wui.writes
H.fire("QUEST_TURNED_IN"); advance(2)
check("after the quest work, the flight master icon appears in place", wui.nav.iconTexture == OWN .. "FlightMaster" and wui.writes == writes + 1,
  wui.nav.iconTexture)

-- Innkeeper: .goto / >>Talk to Coriella / .home >>Set your Hearthstone to Shen'dar Village / .bindlocation / .target   (RestedXP-Skyborne.lua)
visit(14, 46, talk("Coriella Calmbreeze::254089"), { tag = "home", text = "Set your Hearthstone to Shen'dar Village" }, cond("bindlocation"), cond("target"))
check("innkeeper step (.home): innkeeper icon", wui.nav.iconTexture == OWN .. "Innkeeper", wui.nav.iconTexture)
check("innkeeper marker: Hearth Teal #48BECF", colourIs("48BECF"), wui.nav.r)

-- Stable master: .goto / >>Talk to the stable master / .stable
visit(15, 48, talk("Stable Master"), { tag = "stable", text = "Stable your pet" }, cond("target"))
check("stable step (.stable): stable master icon", wui.nav.iconTexture == OWN .. "StableMaster", wui.nav.iconTexture)
check("stable marker: Saddle Brown #997B59", colourIs("997B59"), wui.nav.r)

-- General vendor: .vendor >> Vendor Trash (no food purchase, no repair)
visit(16, 50, talk("Uualia Suncrest::251537"), { tag = "vendor", text = "Vendor Trash" }, cond("target"))
check("general vendor: bags icon", wui.nav.iconTexture == OWN .. "Bags", wui.nav.iconTexture)
check("vendor marker: Merchant Blue #4B95E4", colourIs("4B95E4"), wui.nav.r)

-- Banker: .bankdeposit (same bags icon)
visit(17, 52, talk("Banker"), { tag = "bankdeposit", text = "Deposit the following items into your bank" })
check("banker (.bankdeposit): bags icon", wui.nav.iconTexture == OWN .. "Bags", wui.nav.iconTexture)
check("banker marker: Merchant Blue (shared) #4B95E4", colourIs("4B95E4"), wui.nav.r)
visit(18, 54, talk("Banker"), { tag = "bankwithdraw", text = "Withdraw the following items" })
check("banker (.bankwithdraw): bags icon", wui.nav.iconTexture == OWN .. "Bags", wui.nav.iconTexture)

-- Grind: .xp 2 >> Grind to level 2 (a #loop patrol step, like the Forever guides)
local g1 = H.lowPrioPoint(56, 0)
local grindStep = newStep(19, { loop = "" }, g1, H.loopPoint(58, 0), { tag = "xp", level = 2, xp = 0, text = "Grind to level 2" })
H.setActiveSteps(grindStep); point(g1); advance(2)
check("grind step (.xp target): grind icon", wui.nav.iconTexture == OWN .. "Grind", wui.nav.iconTexture)
check("grind marker: Combat Red #D95451", colourIs("D95451"), wui.nav.r)

-- ".xp <6,1" is a hidden level condition (skip-step, textOnly + reverseLogic), not grinding
visit(20, 60, talk("Aarnor"), { tag = "xp", level = 6, xp = 0, textOnly = true, skipstep = "1", reverseLogic = true })
check("xp condition is not a grind step", wui.nav.iconTexture == OWN .. "DefaultWaypoint", wui.nav.iconTexture)

-- Accept before the flight path (no quest context; the step's first instruction decides)
quests[6323] = nil
visit(13, 44, talk("Karos"), H.accept(6323, "Ride to the Undercity"), { tag = "fp", text = "Get the Sepulcher flight path" })
check("accept first: available-quest icon, not the flight master icon", wui.nav.iconTexture ~= nil
  and wui.nav.iconTexture == OWN .. "QuestAvailable", wui.nav.iconTexture)

-- Travel step: default icon
visit(11, 40, talk("nobody"))
check("plain text step: default icon", wui.nav.iconTexture == OWN .. "DefaultWaypoint" and wui.nav.r == nil, wui.nav.iconTexture)

-- Status line, and other strategies
visit(12, 42, talk("Karos"), { tag = "fly", text = "Fly to the Undercity" })
local before = #H.chat
slash("status")
local text = table.concat(H.chat, "\n", before + 1)
check("status shows the service icon", text:find("Marker icon: service FlightMaster | FlightMaster (step 12 .fly)", 1, true) ~= nil
  and text:find("Marker texture: " .. OWN .. "FlightMaster", 1, true) ~= nil, text)
-- v0.5.6: presentation does not depend on the navigation strategy.
slash("mode coordinates"); advance(2)
check("coordinates strategy: same service icon and colour", wui.nav.iconTexture == OWN .. "FlightMaster" and colourIs("70D65A"), wui.nav.iconTexture)
slash("mode hybrid"); advance(2)
check("hybrid strategy: same service icon and colour", wui.nav.iconTexture == OWN .. "FlightMaster" and colourIs("70D65A"), wui.nav.iconTexture)

H.finish()
