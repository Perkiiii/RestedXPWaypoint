-- Installed Skyborne fixtures plus instruction-scoping and action regressions.
local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
local R = H.load(ADDON_ROOT, { strategy = "coordinates", debug = true })
local OWN = "Interface\\AddOns\\RestedXPWaypoint\\Art\\Icons\\"
H.quests[92514] = { title = "Welcome to Shen'dar Village", objectives = {
    { type = "event", finished = true, numFulfilled = 1, numRequired = 1 },
    { type = "event", finished = false, numFulfilled = 0, numRequired = 1 },
} }
local function npc() return H.header("|Tinterface/worldmap/chatbubble_64grey.blp:20|tTalk to |cRXP_FRIENDLY_Coriella Calmbreeze::254089|r.") end
local function objective(text, extra)
    local e = H.complete(92514, 2, extra)
    e.text = text
    return e
end
local function fixture(index, ...)
    local g = H.goto_(86.04, 43.24, { zone = 2521, x = 43.02 })
    local s = H.newStep(index, {}, g, ...)
    H.setActiveSteps(s)
    return g, s
end
local function presentation(g)
    local t = { element = g }
    return R.Nav.GetPresentation(t, R.Nav.GetContextDecision(t, { mode = "coordinates" }))
end
local function serviceIs(name, g)
    local p = presentation(g)
    return p and p.service == name
end

local g = fixture(90, npc(), objective("0/1 Speak with the Innkeeper"), { tag = "target", textOnly = true })
H.point(g); H.advance(3)
H.check("Skyborne 90: Innkeeper overrides objective icon", H.wui.nav.iconTexture == OWN .. "Innkeeper")
local d = R.Nav.GetContextDecision({ element = g }, { mode = "coordinates" })
H.check("quest association is preserved", d.context and d.context.questID == 92514 and d.context.kind == "objective")
H.slash("status")
H.check("status explains evidence", H.lastChat("Icon reason: Innkeeper action detected: explicit Innkeeper conversation") ~= nil)
local writes = H.wui.writes
g = fixture(91, npc(), { tag = "home", text = "Set your Hearthstone to Shen'dar Village" },
    -- Actual parser output for .bindlocation 16624 (not tag=bindlocation).
    { tag = "home", textOnly = true, location = "Shen'dar Village", flags = 0 }, { tag = "target", textOnly = true })
H.point(g); H.advance(3)
H.check("Skyborne 91: same-coordinate binding keeps Innkeeper", H.wui.nav.iconTexture == OWN .. "Innkeeper")
H.check("same-coordinate transition refreshes the changed instruction once", H.wui.writes == writes + 1)
H.check("Innkeeper tint remains Hearth Teal", math.abs(H.wui.nav.r - 0x48 / 255) < 1e-6
    and math.abs(H.wui.nav.g - 0xBE / 255) < 1e-6 and math.abs(H.wui.nav.b - 0xCF / 255) < 1e-6)
H.advance(3)
H.check("stable binding action does not repeatedly write", H.wui.writes == writes + 1)

for _, text in ipairs({ "0/1 Speak with the Innkeeper", "0/1 |cRXP_FRIENDLY_Talk to the Innkeeper|r.",
    "Speak to an Innkeeper!", "Set your Hearthstone to Shen'dralar Village", "Make this inn your home",
    "Bind your Hearthstone to Goldshire", "Change your Hearthstone to Stormwind" }) do
    g = fixture(92, npc(), objective(text))
    H.check("specific action: " .. text, serviceIs("Innkeeper", g))
end
for _, text in ipairs({ "0/1 Speak with Illaya Amberwind", "Use your Hearthstone to Goldshire",
    "Travel to the inn", "Collect a Hearthstone", "Speak with the Innkeeper's assistant",
    "Ask about setting your Hearthstone", "Speak with the Innkeeper about the stolen relic",
    "Kill enemies near the inn", "Return the Hearthstone to the Innkeeper" }) do
    g = fixture(93, npc(), objective(text))
    local p = presentation(g)
    H.check("ordinary objective: " .. text, p and p.status == "Incomplete" and not p.service)
end
g = fixture(94, npc(), { tag = "home", textOnly = true, location = "Goldshire" })
H.check("bindlocation condition alone is not an Innkeeper visit", not serviceIs("Innkeeper", g))
g = fixture(95, npc(), { tag = "hs", text = "Use your Hearthstone to Goldshire" })
H.check("hearthstone teleport is not binding", not serviceIs("Innkeeper", g))
g = fixture(96, npc(), { text = "Hearth to Goldshire" }) -- functions.hs initially returns {text}.
H.check("untagged teleport is not binding", not serviceIs("Innkeeper", g))
g = fixture(97, H.header("Talk to the Innkeeper"), H.accept(90001, "Make this inn your home"))
H.check("quest pickup remains available quest", presentation(g).status == "Available")
H.quests[90002] = { title = "Set your Hearthstone to Goldshire", ready = true }
g = fixture(98, npc(), H.turnin(90002, "Set your Hearthstone to Goldshire"), { tag = "home", text = "Set your Hearthstone to Goldshire" })
H.check("quest turn-in remains quest", presentation(g).status == "Complete")
g = fixture(99, npc(), objective("Speak with the blacksmith"), { tag = "home", text = "Set your Hearthstone to Goldshire" })
H.check("later binding cannot override earlier objective", not serviceIs("Innkeeper", g))
g = fixture(100, H.header("Talk to the Innkeeper"), { tag = "vendor", text = "Vendor and repair" })
H.check("Innkeeper heading does not override vendor action", serviceIs("Repair", g))
g = fixture(101, npc(), { tag = "fly", text = "Fly to Goldshire" }, { tag = "home", text = "Set your Hearthstone to Goldshire" })
H.check("first flight action retains priority", serviceIs("FlightMaster", g))
local later = H.goto_(90, 0)
g = fixture(102, npc(), objective("Speak with the blacksmith"), later, { tag = "home", text = "Set your Hearthstone to Goldshire" })
H.check("other waypoint's binding cannot leak backwards", not serviceIs("Innkeeper", g))
H.check("later waypoint owns its binding", serviceIs("Innkeeper", later))
g = fixture(103, npc(), objective("Speak with the Innkeeper", { skip = true }), objective("Speak with Illaya Amberwind"))
H.check("completed Innkeeper instruction ignored", not serviceIs("Innkeeper", g))
local action = objective("Speak with the Innkeeper")
g = H.goto_(92, 0, { parent = action })
local s = H.newStep(104, {}, action, g)
H.setActiveSteps(s)
H.check("validated parent-linked action supported", serviceIs("Innkeeper", g))
H.finish()
