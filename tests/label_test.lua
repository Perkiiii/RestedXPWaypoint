-- Offline unit tests for LabelResolver.lua (run with: node tests/run.js).
local RXPW = { Label = {} }
local chunk = assert(loadfile(ADDON_ROOT .. "/LabelResolver.lua"))
chunk("RestedXPWaypoint", RXPW)
local L = RXPW.Label
local passes, fails = 0, 0
local function eq(name, got, want)
  if got ~= want then fails = fails + 1; print("FAIL " .. name .. ": got [" .. tostring(got) .. "] want [" .. tostring(want) .. "]")
  else passes = passes + 1; print("ok   " .. name .. " -> " .. tostring(got)) end
end
-- Cleaning
eq("chat bubble + RXP colour", L.Clean("|Tinterface/worldmap/chatbubble_64grey.blp:20|tTalk to |cRXP_FRIENDLY_Karos|r"), "Talk to Karos")
eq("buy line with item icon", L.Clean("|cRXP_BUY_Buy a|r |T135343:0|t[Scimitar] |cRXP_BUY_from him|r"), "Buy a [Scimitar] from him")
eq("npc id suffix", L.Clean("|Tinterface/worldmap/chatbubble_64grey.blp:20|tTalk to |cRXP_FRIENDLY_Elatrell Featherlight::251368|r."), "Talk to Elatrell Featherlight.")
-- v0.5.6: live progress is kept (the bridge refreshes the label when it changes).
eq("progress counter kept", L.Clean("Worg slain: 3/10"), "Worg slain: 3/10")
eq("progress paren kept", L.Clean("Kill Worgs (3/10)"), "Kill Worgs (3/10)")
eq("leading progress kept", L.Clean("1/15 Windstone Cluster"), "1/15 Windstone Cluster")
eq("keeps numbers in instruction", L.Clean("Kill 10 Worgs"), "Kill 10 Worgs")
eq("unresolved placeholder", L.Clean("Accept *quest*"), nil)
eq("literal backslash-n", L.Clean("Talk to Renferrel\nBuy a Scimitar"), "Talk to Renferrel")
eq("real newline", L.Clean("Collect Linen\n3/5 Linen Cloth"), "Collect Linen")
eq("hyperlink", L.Clean("Loot |cff1eff00|Hitem:123::|h[Thing]|h|r now"), "Loot [Thing] now")
eq("cn colour", L.Clean("|cnGREEN_FONT_COLOR:Go|r now"), "Go now")
eq("escaped pipe", L.Clean("A || B"), "A / B")
eq("whitespace", L.Clean("   Run   up  the hill   "), "Run up the hill")
eq("empty after clean", L.Clean("|T123:0|t"), nil)
eq("non-string", L.Clean(42), nil)
local long = "Kill |cRXP_ENEMY_Young Scavengers|r and |cRXP_ENEMY_Duskbats|r. Loot them until you have 60 copper worth of vendor items"
local s, c, sh = L.Clean(long)
eq("long shortened flag", sh, true); eq("long cleaned flag", c, true)
print("     long -> " .. s .. " (" .. #s .. " bytes)")
local cjk = string.rep("\228\184\173", 30) -- 30 CJK chars, 90 bytes, no spaces
local cs = L.Clean(cjk)
eq("utf8 safe cut", (#cs - 3) % 3, 0)

-- Resolver
local function step(index, ...) local st = { index = index, active = true, elements = {} }
  for _, e in ipairs({...}) do e.step = st; table.insert(st.elements, e) end; return st end
local function goto_(t) t = t or {}; t.tag = "goto"; t.arrow = true; t.textOnly = true; return t end

-- Karos step: goto, header, turnin(done), fp(done), fly
local g = goto_()
step(62, g, {text = "|Tinterface/worldmap/chatbubble_64grey.blp:20|tTalk to |cRXP_FRIENDLY_Karos|r", textOnly = true},
  {tag="turnin", text="Turn in Supplying the Sepulcher", completed=true}, {tag="fp", text="Get the Sepulcher flight path", completed=true},
  {tag="fly", text="Fly to the Undercity"}, {tag="target"})
-- v0.5.6: the first pending real instruction wins over the ">>" heading.
local r = L.Resolve(g); eq("karos instruction", r.label, "Fly to the Undercity"); eq("karos source", r.source, "following instruction")

-- Only a heading left (every instruction done): the heading, not "Step N"
local gh = goto_()
step(64, gh, {text = "Talk to |cRXP_FRIENDLY_Karos|r", textOnly = true}, {tag="turnin", text="Turn in X", completed=true, skip=true})
local rh = L.Resolve(gh); eq("heading fallback", rh.label, "Talk to Karos"); eq("heading source", rh.source, "following heading")

-- RestedXP's render flag: the guide window sets completed = true on text-only
-- lines it draws. A drawn heading still counts; a done instruction does not.
local gr = goto_({completed = true})
step(65, gr, {text = "Click on the |cRXP_PICK_Crystals|r", textOnly = true, completed = true},
  {text = "|cRXP_WARN_Expect to break about 10 stones|r.", textOnly = true, completed = true},
  {tag="complete", questId = 93552, obj = 1, text = "0/15 Windstone Cluster", textOnly = false})
eq("render flags: live objective progress", L.Resolve(gr).label, "0/15 Windstone Cluster")
gr.step.elements[4].text = "1/15 Windstone Cluster"
eq("render flags: progress updates", L.Resolve(gr).label, "1/15 Windstone Cluster")
gr.step.elements[4].completed = true; gr.step.elements[4].skip = true
eq("render flags: drawn heading after the objective is done", L.Resolve(gr).label, "Click on the Crystals")

-- No header: completed instructions are skipped
local g2 = goto_()
step(63, g2, {tag="turnin", text="Turn in X", completed=true}, {tag="fp", text="Get the Sepulcher flight path", completed=true}, {tag="fly", text="Fly to the Undercity"})
eq("skip completed", L.Resolve(g2).label, "Fly to the Undercity")

-- Route chain: intermediate points labelled by the chain's final text
local a, b, c = goto_(), goto_(), goto_({text = "Enter the crypt"})
step(70, a, b, c)
eq("route chain a", L.Resolve(a).label, "Enter the crypt"); eq("route chain source", L.Resolve(a).source, "route text of a later waypoint")
eq("route chain c own text", L.Resolve(c).source, "waypoint text")

-- Parent link wins over following lines
local obj = {tag="accept", text="Accept Dalaran's Intentions"}
local gp = goto_({parent = obj})
step(71, goto_(), {tag="turnin", text="Turn in Arugal's Folly"}, obj, gp, {tag="turnin", text="Turn in Something Else"})
eq("linked objective", L.Resolve(gp).label, "Accept Dalaran's Intentions")

-- Generated goto text ignored -> fallback
local gg = goto_({text = "Go to 45.6,42.6 (1421)"})
step(72, gg)
local rf = L.Resolve(gg); eq("generated text -> fallback", rf.label, "Step 72"); eq("fallback flag", rf.fallback, true)

-- Segment stops at next waypoint group: second location's instruction not used for first
local g3, g4 = goto_(), goto_()
step(73, g3, {tag="complete", text="Kill boars", completed=true}, g4, {tag="turnin", text="Turn in Boars"})
eq("no bleed into next segment", L.Resolve(g3).label, "Step 73")

-- *quest* placeholder filled from title
local g5 = goto_()
step(74, g5, {tag="accept", text="Accept *quest*", title="Rude Awakening"})
eq("quest placeholder", L.Resolve(g5).label, "Accept Rude Awakening")

-- rawtext preferred, format-string rawtext ignored
local g6 = goto_()
step(75, g6, {tag="complete", rawtext="Kill |cRXP_ENEMY_Worgs|r", text="Worg slain: 3/10"})
eq("rawtext", L.Resolve(g6).label, "Kill Worgs")
local g7 = goto_()
step(76, g7, {tag="complete", rawtext="Kill Worgs %d/%d", text="Worg slain: 3/10"})
eq("format rawtext ignored", L.Resolve(g7).label, "Worg slain: 3/10")

-- Warning only used as last resort
local g8 = goto_()
step(77, g8, {text="|cRXP_WARN_Be careful of the elite|r"}, {tag="complete", text="Collect 5 Quest Items"})
eq("warning deprioritised", L.Resolve(g8).label, "Collect 5 Quest Items")

-- Preceding text-only header when first waypoint
local g9 = goto_()
step(78, {text="Kill |cRXP_ENEMY_Young Scavengers|r", textOnly=true}, g9)
eq("preceding header", L.Resolve(g9).label, "Kill Young Scavengers")

-- arrowtext beats everything below title; corpse title
local g10 = goto_({text="Own text"}); local st = step(79, g10); st.arrowtext = "Arrow text"
eq("arrowtext", L.Resolve(g10).label, "Arrow text")
eq("corpse title", L.Resolve({title="Corpse", generated=1}).label, "Corpse")
eq("no step fallback", L.Resolve({}).label, "RestedXP")

print(string.format("%d passed, %d failed", passes, fails))

if fails > 0 then error(fails .. " test(s) failed", 0) end
