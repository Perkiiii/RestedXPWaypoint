-- Focused checks for the RestedXP Waypoint identity and saved settings.
local H = dofile(ADDON_ROOT .. "/tests/harness.lua")
local saved = { autoSync = false, debug = true, strategy = "native-first" }
local RXPW = H.load(ADDON_ROOT, saved)

H.check("all modules share the RXPW addon namespace", RXPW.Label and RXPW.RXP and RXPW.Nav
  and RXPW.WUI and RXPW.Sync and RXPW.Preview)
H.check("RXPWDB settings table and selections are preserved", RXPWDB == saved
  and RXPW.db == saved and RXPWDB.autoSync == false and RXPWDB.debug == true
  and RXPWDB.strategy == "native-first")
H.check("only the /rxpw slash command is registered", SLASH_RESTEDXPWAYPOINT1 == "/rxpw"
  and SlashCmdList.RESTEDXPWAYPOINT == H.slash
  and SLASH_RXPWAYPOINTBRIDGE1 == nil
  and SlashCmdList["RXPWAYPOINT" .. "BRIDGE"] == nil)
H.check("startup message uses the RestedXP Waypoint prefix",
  (H.chat[1] or ""):find("RestedXP Waypoint|r:", 1, true) ~= nil)
RXPW.Debug("prefix check")
H.check("debug message uses the RXPW [debug] prefix",
  (H.chat[#H.chat] or ""):find("RXPW|r |cff999999[debug]|r", 1, true) ~= nil)

H.slash("")
local help = table.concat(H.chat, "\n")
H.check("root command displays usage and all mode examples",
  help:find("Usage: /rxpw", 1, true) ~= nil
    and help:find("/rxpw mode coordinates", 1, true) ~= nil
    and help:find("/rxpw mode hybrid", 1, true) ~= nil
    and help:find("/rxpw mode native-first", 1, true) ~= nil)
H.check("help lists the requested preview examples",
  help:find("/rxpw preview all close", 1, true) ~= nil
    and help:find("/rxpw preview all far", 1, true) ~= nil
    and help:find("/rxpw preview next", 1, true) ~= nil
    and help:find("/rxpw preview flightmaster", 1, true) ~= nil
    and help:find("/rxpw preview off", 1, true) ~= nil)
H.check("new mode command preserves strategy dispatch", RXPW.db.strategy == "native-first")
H.slash("mode hybrid")
H.check("/rxpw dispatches mode changes through the new command", RXPW.db.strategy == "hybrid")
H.finish()
