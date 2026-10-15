-- v0.6.1: service association, using RestedXP's draw-time flags.
local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
local R = H.load(ADDON_ROOT, { strategy = "hybrid" })
local check = H.check
local function service(g)
  return R.Nav.GetPresentation({ element = g }, {})
end
local g = H.goto_(85.52, 24.50, { zone = 2521, x = 42.76 })
local gate = { tag = "train", id = 2575, flags = 3, textOnly = true, reverse = true }
local pick = { tag = "collect", id = 2901, qty = 1, text = "Buy a |T134708:0|t[Mining Pick]" }
local pack = { tag = "collect", id = 277115, qty = 1, text = "Buy an |T133635:0|t[Apprentice's Mining Pack]" }
local step = H.newStep(50, { sticky = true }, gate, g,
  H.header("Talk to |cRXP_FRIENDLY_Uualia Suncrest::251537|r"), pick, pack,
  { tag = "target", textOnly = true })
H.setActiveSteps(step); H.point(g); H.advance(3)
check("Mining Pick purchase is Vendor, not the Mining-trained condition", service(g) and service(g).service == "Vendor")
check("purchase keeps coordinates and label", H.wui.nav.mapID == 2521 and H.wui.nav.x == 0.4276
  and H.wui.nav.y == 0.245 and H.wui.nav.name == "Buy a [Mining Pick]", H.wui.nav.name)
check("purchase uses existing bags and Merchant Blue", H.wui.nav.iconTexture:find("Bags$") ~= nil
  and math.abs(H.wui.nav.r - 75/255) < 1e-6)
pick.completed = true; pick.skip = true
H.advance(3)
check("second purchase stays Vendor", service(g).service == "Vendor" and H.wui.nav.name == "Buy an [Apprentice's Mining Pack]")

local function fixture(...)
  local p = H.goto_(60, 0)
  H.newStep(60, {}, p, ...)
  return p
end
check("genuine class trainer", service(fixture({ tag = "trainer", text = "Train class spells" })).service == "ClassTrainer")
check("genuine profession trainer", service(fixture({ tag = "train", text = "Train Mining" },
  { tag = "skill", textOnly = true })).service == "ProfessionTrainer")
check("vendor trash", service(fixture({ tag = "vendor", text = "Vendor trash" })).service == "Vendor")
check("generic collection is not a vendor", service(fixture({ tag = "collect", text = "Gather ore", id = 1 })) == nil)
check("arbitrary training/repair text is not a service", service(fixture(H.header("Train later and repair if needed"))) == nil)
check("generic collection blocks later unrelated trainer", service(fixture({ tag = "collect", text = "Gather ore" },
  { tag = "train", text = "Train spells" })) == nil)
check("completed training yields to purchase", service(fixture({ tag = "train", text = "Train spells", completed = true },
  { tag = "collect", text = "Buy a tool" })).service == "Vendor")
check("completed book use cannot suppress active training", service(fixture({ tag = "use", textOnly = true, skip = true },
  { tag = "trainer", text = "Train spells" })).service == "ClassTrainer")
check("first pending activity at shared location wins", service(fixture({ tag = "train", text = "Train spells" },
  { tag = "collect", text = "Buy a tool" })).service == "ClassTrainer")
for _, tag in ipairs({ "buy", "buyAll", "buyUntilBroke" }) do
  check("structured purchase " .. tag, service(fixture({ tag = tag, id = 1, textOnly = true })).service == "Vendor")
end
check("local purchase heading supports textless collection", service(fixture(H.header("|cRXP_BUY_Buy|r a tool"),
  { tag = "collect", id = 1, text = " " })).service == "Vendor")
check("unrelated purchase heading cannot classify explicit gathering", service(fixture(H.header("Buy supplies later"),
  { tag = "collect", text = "Gather ore", id = 1 })) == nil)
check("completed purchase cannot lend its heading to another collection", service(fixture(H.header("Buy a tool"),
  { tag = "collect", text = " ", completed = true }, { tag = "collect", text = " ", id = 1 })) == nil)

local a, b = H.goto_(40, 0), H.goto_(50, 0)
local train = { tag = "train", text = "Train spells" }
local buy = { tag = "collect", text = "Buy a tool" }
H.newStep(70, {}, a, train, b, buy)
-- The parser can retain the previous instruction as a completion dependency.
b.parent = train
check("waypoint A is trainer", service(a).service == "ClassTrainer")
check("waypoint B is purchase despite earlier training dependency", service(b).service == "Vendor")
local linked = H.goto_(55, 0)
H.newStep(71, {}, buy, linked); linked.parent = buy
check("validated parent supports instruction-before-waypoint", service(linked).service == "Vendor")
linked.parent = { tag = "vendor", text = "Vendor trash" }
check("invalid parent is conservative", service(linked) == nil)
local food = { tag = "collect", id = 159, text = "Buy water" }
H.newStep(72, {}, a, { tag = "vendor", text = "Vendor trash" }, b, food)
check("food elsewhere cannot override current vendor", service(a).service == "Vendor")
H.newStep(73, {}, a, { tag = "train", text = "Train spells" }, b, { tag = "use", textOnly = true })
check("unrelated use cannot suppress trainer", service(a).service == "ClassTrainer")
H.newStep(74, {}, a, { tag = "train", text = "Train spells" }, b, { tag = "skill", textOnly = true })
check("unrelated skill cannot turn class trainer into profession", service(a).service == "ClassTrainer")
H.newStep(75, {}, a, { tag = "trainer" }, b, { tag = "vendor", text = "Vendor trash" })
check("textless trainer still defines a block", service(a).service == "ClassTrainer")
H.newStep(76, {}, { tag = "skill", textOnly = true }, a, { tag = "train", text = "Train Mining" },
  b, { tag = "trainer", text = "Train spells" })
check("prefix skill applies to first trainer", service(a).service == "ProfessionTrainer")
check("prefix skill cannot leak across destinations", service(b).service == "ClassTrainer")
H.newStep(77, {}, a, { tag = "collect", text = "Gather ore", completed = true }, b,
  { tag = "vendor", text = "Vendor trash" })
check("completed actions preserve waypoint boundaries", service(a) == nil)
step.active = false
check("inactive step supplies no service", service(g) == nil)
step.active = true
for _, strategy in ipairs({ "coordinates", "hybrid", "native-first" }) do
  local target = { element = g, key = "purchase", mapID = 2521, x = 42.76, y = 24.5 }
  local decision = R.Nav.Decide(target, strategy)
  check(strategy .. " keeps purchase on coordinates", decision.mode == "coordinates")
  check(strategy .. " keeps Vendor presentation", R.Nav.GetPresentation(target, R.Nav.GetContextDecision(target, decision)).service == "Vendor")
end
check("explicit quest context keeps its quest presentation", R.Nav.GetPresentation({ element = g },
  { context = { questID = 1, ready = false, kind = "objective", source = "linked objective block" } }).status == "Incomplete")

H.point(g); H.advance(3)
R.Config.Set("serviceIcons", false); H.advance(3)
check("service icons off uses generic with Merchant Blue", H.wui.nav.iconTexture == nil and math.abs(H.wui.nav.r - 75/255) < 1e-6)
R.Config.Set("customColors", false); H.advance(3)
check("colours off uses WUI fallback", H.wui.nav.iconTexture == nil and H.wui.nav.r == nil)
R.Config.Set("serviceIcons", true); H.advance(3)
check("re-enabling icons keeps vendor and default tint", H.wui.nav.iconTexture:find("Bags$") ~= nil and H.wui.nav.r == nil)
R.Config.Set("customColors", true); H.advance(3)
check("re-enabling colours keeps vendor", math.abs(H.wui.nav.r - 75/255) < 1e-6)
H.slash("status")
check("status explains association", H.lastChat("Service source:") ~= nil)

-- A pending quest at another destination must not override this service.
for _, strategy in ipairs({ "coordinates", "hybrid", "native-first" }) do
  R.Config.Set("strategy", strategy)
  local questPoint, vendorPoint = H.goto_(40, 0), H.goto_(80, 0)
  local accept = { tag = "accept", questId = 900, title = "A quest", text = "Accept A quest" }
  local mixed = H.newStep(80, {}, questPoint, accept, vendorPoint,
    { tag = "vendor", text = "Vendor trash" })
  -- No parser parent: the accept's display text can be populated at runtime.
  H.setActiveSteps(mixed); H.point(vendorPoint); H.advance(3)
  check(strategy .. " mixed step keeps actual vendor destination and ownership",
    H.navAt(80) and H.wui.nav.mapID == vendorPoint.zone and H.wui.nav.y == 0
      and H.wui.nav.flags == R.OWNER_FLAG and H.wui.nav.name == "Vendor trash")
  check(strategy .. " unrelated acceptance cannot override Vendor icon and colour",
    H.wui.nav.iconTexture:find("Bags$") ~= nil and math.abs(H.wui.nav.r - 75/255) < 1e-6)
end
H.finish()
