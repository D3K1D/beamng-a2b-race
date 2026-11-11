-- A2B Race BeamMP server plugin.
-- Keeps every party and race on the server, so all players agree on who is in which party,
-- when the countdown ends and who won. The rules live in lib/core.lua (the same file the
-- client mod uses for single-player solo races).
--
-- All traffic is one small BeamMP event in each direction: "a2b" with JSON {e = event, ...}.

local PLUGIN_DIR = "Resources/Server/A2BRace"
local TICK_MS = 100

local Core = dofile(PLUGIN_DIR .. "/lib/core.lua")

-- The BeamMP launcher aborts on an event over 500 bytes that contains the text "Zp"
-- (see CarRadio protocol/multiplayer.md). Player names could contain it, so escape it:
-- "Zp" is the same text to any JSON reader.
local function encode(t)
  return (Util.JsonEncode(t):gsub("Zp", "Z\\u0070"))
end

local function names()
  local t = {}
  for pid, name in pairs(MP.GetPlayers() or {}) do t[tonumber(pid)] = name end
  return t
end

local core = Core.new({
  send = function(pid, event, data)
    data.e = event
    MP.TriggerClientEvent(pid, "a2b", encode(data))
  end,
  names = names,
  log = function(text) print("[A2BRace] " .. text) end,
})

function A2B_onMessage(pid, data)
  if type(data) ~= "string" or #data > 2000 then return end
  local ok, m = pcall(Util.JsonDecode, data)
  if not ok or type(m) ~= "table" or type(m.e) ~= "string" then return end
  if m.e == "hello" then core.state(pid) else core.handle(pid, m.e, m) end
end

function A2B_onJoin(pid) core.joined() end
function A2B_onLeave(pid) core.dropped(pid) end
function A2B_onTick() core.tick(TICK_MS / 1000) end

MP.RegisterEvent("a2b", "A2B_onMessage")
MP.RegisterEvent("onPlayerJoin", "A2B_onJoin")
MP.RegisterEvent("onPlayerDisconnect", "A2B_onLeave")
MP.RegisterEvent("a2b_tick", "A2B_onTick")
MP.CreateEventTimer("a2b_tick", TICK_MS)
print("[A2BRace] ready")
