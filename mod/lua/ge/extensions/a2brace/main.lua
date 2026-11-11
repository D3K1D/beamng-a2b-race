-- A2B Race: game-engine side.
--  * Talks to the A2B Race server plugin (BeamMP), or to a local copy of the same rules
--    (a2brace_core) in single-player, where you can race solo against the clock.
--  * Runs this player's part of a race: teleport + repair onto the starting grid at A,
--    hold the car during the countdown (engine revs, car can't move), GO, enforce the
--    one-life rule (reset / repair / teleport = back to A), detect the finish at B.
--  * Effects: winner's light show, light beams and confetti; losers blow up in order.
--  * Draws the A and B markers for your party and feeds the HUD app (A2BRaceState).
-- Works with any vehicle: sizes and positions come from each car's own bounding box.

local M = {}

local logTag = 'a2brace'
local VERSION = '0.1.1'

local FINISH_RADIUS = 12   -- metres (flat) around B that count as the finish
local FINISH_HEIGHT = 15   -- and within this height difference
local GRID_LEASH = 3       -- metres a car may creep from its grid slot before it's put back
local TELEPORT_JUMP = 30   -- a jump this much further than the car's speed explains = teleport
local RESET_GRACE = 1.5    -- seconds after our own teleport in which resets are ours
local SEND_BACK_DELAY = 0.2 -- let the game finish its own reset before we move the car
local PROGRESS_EVERY = 1   -- seconds between distance-to-B reports
local CELEBRATE_TIME = 15  -- seconds of winner effects

-- ---------------------------------------------------------------- state
local S = {
  now = 0,
  mp = nil,          -- true on a BeamMP server, false in single-player, nil before the first frame
  solo = nil,        -- single-player: local copy of the race rules
  inbox = {},        -- single-player: messages from the local rules, handled next frame
  handlerAdded = false,
  view = nil,        -- latest party/players state
  gotState = false,
  helloAt = -100, hellos = 0,
  lastCarId = nil,   -- your own car (not the walking character), for racing from on foot
  carSent = nil, carSentAt = -100,
  race = nil,        -- your part of the current race
  banner = nil,      -- { text, untilT, kind } big text for the HUD overlay
  sendBackAt = nil,  -- pending "back to A"
  sendBackReason = nil,
}

local function message(text, ttl)
  guihooks.trigger('Message', { ttl = ttl or 5, msg = text, category = 'a2brace', icon = 'flag' })
end

local function banner(text, ttl, kind)
  S.banner = { text = text, untilT = S.now + (ttl or 2), kind = kind or '' }
end

local function sound(event) pcall(function() Engine.Audio.playOnce('AudioGui', event) end) end

local function inMP()
  return MPCoreNetwork and MPCoreNetwork.isMPSession and MPCoreNetwork.isMPSession() and true or false
end

local function isUnicycle(veh) return veh and veh:getJBeamFilename() == 'unicycle' end

local function isMine(vehId)
  if S.mp and MPVehicleGE and MPVehicleGE.isOwn then return MPVehicleGE.isOwn(vehId) end
  return true
end

local function myPid() return S.view and S.view.me end

local function carKey(vehId)
  if S.mp and getServerVehicleID and vehId then return getServerVehicleID(vehId) end
end

local function vehFromKey(key)
  if not key then return nil end
  if not S.mp then return nil end
  local gid = getGameVehicleID and getGameVehicleID(key)
  return gid and gid ~= -1 and be:getObjectByID(gid) or nil
end

-- Length / width / height half-sizes of a car along its own axes, from its bounding box.
local function carBox(veh)
  local box = veh:getSpawnWorldOOBB()
  local c, h = vec3(box:getCenter()), box:getHalfExtents()
  local dir, up = vec3(veh:getDirectionVector()), vec3(veh:getDirectionVectorUp())
  local right = dir:cross(up)
  local hl, hw, hh = 0, 0, 0
  for i = 0, 2 do
    local axis, half = vec3(box:getAxis(i)), (i == 0 and h.x) or (i == 1 and h.y) or h.z
    hl, hw, hh = hl + math.abs(axis:dot(dir)) * half, hw + math.abs(axis:dot(right)) * half, hh + math.abs(axis:dot(up)) * half
  end
  return c, hl, hw, hh, dir, right, up
end

-- ---------------------------------------------------------------- transport
local onMessage -- defined below

local function send(event, data)
  data = data or {}
  if S.mp then
    if TriggerServerEvent then
      data.e = event
      TriggerServerEvent('a2b', jsonEncode(data))
    end
  elseif S.solo then
    S.solo.handle(0, event, data)
  end
end

local stopRace -- defined below

local function setMode(mp)
  if S.mp == mp then return end
  if S.race then stopRace() end
  S.mp, S.view, S.gotState, S.helloAt, S.hellos, S.inbox, S.solo = mp, nil, false, -100, 0, {}, nil
  S.carSent = nil
  if not mp then
    if not a2brace_core then extensions.load('a2brace_core') end
    S.solo = a2brace_core.new({
      send = function(pid, event, data) data.e = event; S.inbox[#S.inbox + 1] = data end,
      names = function() return { [0] = 'You' } end,
      log = function(text) log('E', logTag, text) end,
    })
    S.solo.state(0)
  end
end

local function updateTransport(dt)
  setMode(inMP())
  if S.mp then
    if not S.handlerAdded and AddEventHandler then
      AddEventHandler('a2b', function(data)
        local ok, m = pcall(jsonDecode, data)
        if ok and type(m) == 'table' and type(m.e) == 'string' then onMessage(m) end
      end, 'a2brace') -- named, so a Lua reload replaces the handler instead of adding another
      S.handlerAdded = true
    end
    if not S.gotState and S.now >= S.helloAt then
      S.helloAt, S.hellos = S.now + 5, S.hellos + 1
      send('hello', { version = VERSION })
    end
  elseif S.solo then
    S.solo.tick(dt)
    local inbox = S.inbox
    S.inbox = {}
    for _, m in ipairs(inbox) do onMessage(m) end
  end
end

-- ---------------------------------------------------------------- your car
local function trackCar()
  local veh = getPlayerVehicle(0)
  if veh and not isUnicycle(veh) and isMine(veh:getId()) then S.lastCarId = veh:getId() end
end

local function myCar()
  local veh = S.lastCarId and be:getObjectByID(S.lastCarId)
  if veh and not isUnicycle(veh) then return veh end
end

-- Tell the server how big your car is, so the grid has room for the biggest one.
local function reportCarSize()
  if S.now - S.carSentAt < 2 then return end
  S.carSentAt = S.now
  local veh = myCar()
  if not veh then return end
  local ok, _, hl, hw = pcall(carBox, veh)
  if not ok then return end
  local len, wid = math.floor(hl * 20 + 0.5) / 10, math.floor(hw * 20 + 0.5) / 10
  local sig = len .. 'x' .. wid
  if sig ~= S.carSent then
    S.carSent = sig
    send('car', { len = len, wid = wid })
  end
end

-- ---------------------------------------------------------------- race
local function setFreeze(veh, on)
  veh:queueLuaCommand('if controller and controller.setFreeze then controller.setFreeze(' .. (on and 1 or 0) .. ') end')
end

local function terrainHeight(pos)
  local ok, h = pcall(function() return core_terrain and core_terrain.getTerrainHeight(pos) end)
  return ok and type(h) == 'number' and h or nil
end

-- The drivable surface at a spot. Never below the terrain: a grid slot further back on a
-- hill, or a point picked slightly low, used to start the search underground and put the
-- car under the map. Roads and bridges just above that height count as the surface.
local function groundAt(pos)
  local base = pos.z
  local th = terrainHeight(pos)
  if th and th > base then base = th end
  local ok, sh = pcall(function() return be:getSurfaceHeightBelow(vec3(pos.x, pos.y, base + 3)) end)
  if ok and type(sh) == 'number' and sh > base - 30 and sh <= base + 3.01 then base = sh end
  return vec3(pos.x, pos.y, base)
end

-- Is the car under the map (below the terrain) or falling through it?
local function underMap(veh)
  local ctr, _, _, hh = carBox(veh)
  local th = terrainHeight(ctr)
  if th and ctr.z + hh < th - 0.5 then return true end -- even its roof is below the terrain
  local ok, vel = pcall(function() return veh:getVelocity() end)
  return ok and vel.z < -25 -- free fall through the world
end

-- Your slot on the grid: A is the front of the grid, rows go back from it, two cars per row.
local function slotTransform(m)
  local a = m.a
  local fwd = vec3(a.dx, a.dy, 0)
  if fwd:length() < 1e-3 then fwd = vec3(0, 1, 0) end
  fwd = fwd:normalized()
  local up = vec3(0, 0, 1)
  local right = fwd:cross(up)
  local i = (tonumber(m.slot) or 1) - 1
  local cols = tonumber(m.cols) or 1
  local row, col = math.floor(i / cols), i % cols
  local lateral = cols == 2 and ((col == 0) and -0.5 or 0.5) * m.colGap or 0
  local pos = vec3(a.x, a.y, a.z) - fwd * (row * m.rowGap) + right * lateral
  return groundAt(pos), quatFromDir(fwd, up)
end

-- Teleport (with full repair, like R) to your grid slot at A, and get in if you're walking.
local function sendBack(reason)
  local r = S.race
  local veh = r and be:getObjectByID(r.vehId)
  if not veh then return end
  r.graceUntil = S.now + RESET_GRACE
  r.lastPos, r.settled, r.gridPos = nil, false, nil
  -- Drop the car in from just above the ground (its own height above it), plus a little more
  -- after each failed try, so it can never start inside the ground.
  local okB, _, _, _, hh = pcall(carBox, veh)
  local lift = (okB and hh or 1) + 0.3 + (r.lift or 0)
  spawn.safeTeleport(veh, r.pos + vec3(0, 0, lift), r.rot, nil, nil, nil, true, true)
  local cur = getPlayerVehicle(0)
  if not cur or cur:getId() ~= r.vehId then
    if isUnicycle(cur) and gameplay_walk and gameplay_walk.getInVehicle then
      pcall(gameplay_walk.getInVehicle, veh)
    else
      be:enterVehicle(0, veh)
    end
  end
  if r.phase == 'grid' then setFreeze(veh, true) end
  if reason then
    message(reason, 4)
    banner('BACK TO START', 2, 'bad')
  end
end

local function requestSendBack(reason)
  if not S.sendBackAt then S.sendBackAt, S.sendBackReason = S.now + SEND_BACK_DELAY, reason end
end

stopRace = function()
  local r = S.race
  local veh = r and be:getObjectByID(r.vehId)
  if veh then setFreeze(veh, false) end
  S.race, S.sendBackAt = nil, nil
end

local function startGrid(m)
  trackCar()
  local veh = myCar()
  if not veh then
    send('out')
    message('You need a car to race. Spawn one and join the next race.', 8)
    return
  end
  local pos, rot = slotTransform(m)
  S.race = { phase = 'grid', vehId = veh:getId(), pos = pos, rot = rot,
    b = vec3(m.b.x, m.b.y, m.b.z), countdownEnd = S.now + (tonumber(m.countdown) or 10),
    shown = nil, freezeAt = -100, progressAt = -100, graceUntil = 0 }
  sendBack(nil)
  banner('GET READY', 1.5)
end

local function go()
  local r = S.race
  if not r or r.phase ~= 'grid' then return end
  r.phase = 'racing'
  local veh = be:getObjectByID(r.vehId)
  if veh then setFreeze(veh, false) end
  sound('event:UI_CountdownGo')
  banner('GO!', 1.5, 'go')
  pcall(function() core_groundMarkers.setPath(r.b) end) -- GPS to B (any route is allowed)
end

-- ---------------------------------------------------------------- effects
local function hsv(h, s, v)
  h = (h % 1) * 6
  local i, f = math.floor(h), h - math.floor(h)
  local p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
  if i == 0 then return v, t, p elseif i == 1 then return q, v, p elseif i == 2 then return p, v, t
  elseif i == 3 then return p, q, v elseif i == 4 then return t, p, v else return v, p, q end
end

-- Winner celebration, drawn by every player's game on the server so everyone can see it
-- from far away: strobe lights on the car, searchlight beams and a light pillar hundreds
-- of metres into the sky, fireworks bursting high above, and confetti around the car and
-- up the beams. Anchored to the winner's car, or to point B if that car can't be found.
local fx = {} -- [id] = { t, vehId, pos, lights = {}, confetti = {}, bursts = {}, nextBurst }
local fxCount = 0

local BEAMS = 12
local BEAM_LENGTH = 700
local PILLAR_HEIGHT = 900
local SKY_CONFETTI = 6
local SPARKS = 16

-- Evenly spread spark directions (Fibonacci sphere).
local SPARK_DIRS = {}
for i = 1, SPARKS do
  local z = 1 - 2 * (i - 0.5) / SPARKS
  local rr, a = math.sqrt(1 - z * z), i * 2.39996
  SPARK_DIRS[i] = { math.cos(a) * rr, math.sin(a) * rr, z }
end

local function deleteObj(o) pcall(function() o:delete() end) end

local function endCelebration(id)
  local c = fx[id]
  if not c then return end
  for _, l in ipairs(c.lights) do deleteObj(l) end
  for _, e in ipairs(c.confetti) do deleteObj(e) end
  fx[id] = nil
end

local function makeConfetti(name)
  local ok, e = pcall(function()
    local o = createObject('ParticleEmitterNode')
    o:setField('emitter', 0, 'BNGP_confetti')
    o:setField('dataBlock', 0, 'lightExampleEmitterNodeData1')
    o.canSave = false
    o:registerObject(name)
    return o
  end)
  return ok and e or nil
end

-- vehId: the winner's car here (may be nil); pos: fallback spot (point B).
local function celebrate(vehId, pos)
  local id = vehId and ('v' .. vehId) or 'pos'
  if fx[id] or (not vehId and not pos) then return end
  fxCount = fxCount + 1
  local tag = 'a2brace_fx_' .. fxCount .. '_'
  local c = { t = 0, vehId = vehId, pos = pos and vec3(pos.x, pos.y, pos.z), lights = {}, confetti = {}, bursts = {}, nextBurst = 0 }
  for i = 1, 4 do -- strobing coloured spot lights above the car, shining down on it
    local l = createObject('SpotLight')
    l.canSave = false
    l:setField('innerAngle', 0, '40')
    l:setField('outerAngle', 0, '90')
    l:setField('castShadows', 0, 'false')
    l:registerObject(tag .. 'light' .. i)
    c.lights[i] = l
  end
  for i = 1, 3 + SKY_CONFETTI do -- 3 around the car, the rest swirling up the light pillar
    local e = makeConfetti(tag .. 'confetti' .. i)
    if e then c.confetti[#c.confetti + 1] = e end
  end
  fx[id] = c
end

-- Where the celebration is: the car's box, or a car-sized box standing at point B.
local function anchor(c)
  if c.vehId then
    local veh = be:getObjectByID(c.vehId)
    if not veh then return nil end
    return carBox(veh)
  end
  local up = vec3(0, 0, 1)
  return c.pos + up * 0.8, 2.2, 1, 0.8, vec3(0, 1, 0), vec3(1, 0, 0), up
end

local LIGHT_CORNERS = { { 0.5, 0.6 }, { 0.5, -0.6 }, { -0.5, 0.6 }, { -0.5, -0.6 } }

local function updateFireworks(c, top, dt)
  -- Launch a new rocket every ~0.3 s; each rises for 0.7 s, then bursts 60-320 m up.
  if c.t >= c.nextBurst and c.t < CELEBRATE_TIME - 2.5 then
    c.nextBurst = c.t + 0.2 + math.random() * 0.25
    local a, d = math.random() * 2 * math.pi, math.random() * 60
    c.bursts[#c.bursts + 1] = { t = 0, from = top + vec3(math.cos(a) * 4, math.sin(a) * 4, 0),
      at = top + vec3(math.cos(a) * d, math.sin(a) * d, 60 + math.random() * 260),
      hue = math.random(), size = 30 + math.random() * 30 }
  end
  local keep = {}
  for _, b in ipairs(c.bursts) do
    b.t = b.t + dt
    if b.t < 0.7 then -- rocket trail
      local p = b.from + (b.at - b.from) * (b.t / 0.7)
      debugDrawer:drawSphere(p, 1.2, ColorF(1, 0.95, 0.8, 0.9))
      keep[#keep + 1] = b
    elseif b.t < 2.7 then -- burst: sparks fly out, fall and fade
      local age = b.t - 0.7
      local spread = b.size * (1 - math.exp(-age * 2.5))
      local alpha = math.max(0, 1 - age / 2)
      if age < 0.25 then debugDrawer:drawSphere(b.at, 10 * (1 - age * 3), ColorF(1, 1, 1, 0.8)) end
      for i, s in ipairs(SPARK_DIRS) do
        local r, g, bl = hsv(b.hue + (i % 2) * 0.08, 0.85, 1)
        local p = b.at + vec3(s[1], s[2], s[3]) * spread - vec3(0, 0, 6 * age * age)
        debugDrawer:drawSphere(p, 2.2 * (1 - age / 2.4), ColorF(r, g, bl, alpha))
      end
      keep[#keep + 1] = b
    end
  end
  c.bursts = keep
end

local function updateCelebrations(dt)
  for id, c in pairs(fx) do
    c.t = c.t + dt
    local ctr, hl, hw, hh, dir, right, up
    if c.t <= CELEBRATE_TIME then ctr, hl, hw, hh, dir, right, up = anchor(c) end
    if not ctr then
      endCelebration(id)
    else
      local ok = pcall(function()
        local top = ctr + up * hh
        local skyUp = vec3(0, 0, 1)
        -- Strobe lights: each corner its own colour, flashing in turn.
        for i, l in ipairs(c.lights) do
          local corner = LIGHT_CORNERS[i]
          local r, g, b = hsv(c.t * 0.7 + i / 4, 1, 1)
          l:setPosition(top + up * 3 + dir * (corner[1] * hl) + right * (corner[2] * hw))
          local rot = quatFromDir(-up, dir):toTorqueQuat()
          l:setField('rotation', 0, rot.x .. ' ' .. rot.y .. ' ' .. rot.z .. ' ' .. rot.w)
          l:setField('color', 0, string.format('%.3f %.3f %.3f 1', r, g, b))
          l:setField('range', 0, tostring(8 + hh * 2))
          l.intensity = 30
          l.isEnabled = math.floor(c.t * 10 + i) % 2 == 0
          l:postApply()
        end
        -- A colour-cycling light pillar straight up, and searchlight beams sweeping around it.
        local pr, pg, pb = hsv(c.t * 0.5, 0.6, 1)
        debugDrawer:drawCylinder(top, top + skyUp * PILLAR_HEIGHT, 2.5, ColorF(pr, pg, pb, 0.35))
        for i = 1, BEAMS do
          local ang = c.t * 1.2 + i * 2 * math.pi / BEAMS
          local tilt = 0.3 + 0.2 * math.sin(c.t * 1.7 + i)
          local d = (skyUp + vec3(math.cos(ang), math.sin(ang), 0) * tilt):normalized()
          local r, g, b = hsv(i / BEAMS + c.t * 0.3, 1, 1)
          debugDrawer:drawCylinder(top, top + d * BEAM_LENGTH, 1.3, ColorF(r, g, b, 0.5))
        end
        updateFireworks(c, top, dt)
        -- Confetti: 3 emitters around the roof, the rest spiralling up the pillar (8-80 m).
        for i, e in ipairs(c.confetti) do
          if c.t < CELEBRATE_TIME - 3 then
            local a = i * 2 * math.pi / 3 + c.t
            if i <= 3 then
              e:setPosition(top + up * 1.5 + (dir * math.cos(a) * hl + right * math.sin(a) * hw) * 0.6)
            else
              local k = i - 3
              local h = 8 + 72 * (k / SKY_CONFETTI) + 6 * math.sin(c.t + k)
              e:setPosition(top + vec3(math.cos(a + k) * 6, math.sin(a + k) * 6, h))
            end
          elseif not c.confettiDone then
            for _, o in ipairs(c.confetti) do deleteObj(o) end
            c.confetti, c.confettiDone = {}, true
            break
          end
        end
      end)
      if not ok then endCelebration(id) end
    end
  end
end

-- Your own car blows up for real (fire, parts fly off, it jumps); other players' cars only
-- catch fire on your screen: their owner's game does the real damage and BeamMP syncs it.
local BOOM_OWN = table.concat({
  'if fire and fire.explodeVehicle then fire.explodeVehicle() end',
  'for _, n in pairs(v.data.nodes) do obj:applyForceVectorTime(n.cid, vec3(0, 0, (n.nodeWeight or 1) * 9.81 * 7), 0.15) end',
  'if beamstate then if beamstate.breakAllBreakgroups then beamstate.breakAllBreakgroups() end',
  'if beamstate.deflateTires then beamstate.deflateTires() end end',
}, ' ')
local BOOM_VISUAL = 'if fire and fire.explodeVehicle then fire.explodeVehicle() end'

-- Sent to every player on the server: everyone sees the winner's celebration; the racing
-- party also gets the big result text.
local function onResult(m)
  local inParty = S.view and S.view.party and S.view.party.id == m.party
  local r = inParty and S.race or nil
  if r then
    r.phase = 'over'
    local veh = be:getObjectByID(r.vehId)
    if veh then setFreeze(veh, false) end
  end
  local won = m.winner == myPid()
  local winnerVeh = (won and r and be:getObjectByID(r.vehId)) or vehFromKey(m.key)
  celebrate(winnerVeh and winnerVeh:getId(), m.b)
  if won then
    sound('event:>UI>Missions>End_Gold')
    banner('YOU WIN!', 6, 'win')
    message('You won the race!', 6)
  elseif inParty then
    banner((m.name or '?') .. ' WINS', 4, 'lose')
    message((m.name or '?') .. ' won the race', 6)
  else
    message((m.name or '?') .. ' just won an A2B race! Look up.', 6)
  end
end

local function placeName(n)
  local suffix = 'th'
  if n % 100 < 11 or n % 100 > 13 then
    suffix = ({ [1] = 'st', [2] = 'nd', [3] = 'rd' })[n % 10] or 'th'
  end
  return n .. suffix
end

local function onBoom(m)
  local place = placeName(tonumber(m.place) or 2)
  if m.pid == myPid() then
    local r = S.race
    local veh = r and be:getObjectByID(r.vehId)
    if veh then veh:queueLuaCommand(BOOM_OWN) end
    banner(place .. ' - BOOM', 3, 'bad')
    message('You finished ' .. place .. '. Boom.', 5)
  else
    local veh = vehFromKey(m.key)
    if veh then veh:queueLuaCommand(BOOM_VISUAL) end
    message(place .. ': ' .. (m.name or '?') .. ' blew up', 4)
  end
end

onMessage = function(m)
  local e = m.e
  if e == 'state' then
    S.view, S.gotState = m, true
    local phase = m.party and m.party.phase or 'idle'
    if S.race then
      if phase == 'idle' then stopRace()                                 -- race cancelled / left the party
      elseif phase == 'done' and S.race.phase == 'over' then S.race = nil -- all explosions done
      end
    end
  elseif e == 'notice' then
    message(tostring(m.text), 5)
  elseif e == 'invited' then
    message(tostring(m.host) .. ' invited you to a race! Open the A2B Race app to accept.', 10)
    sound('event:>UI>Missions>Info_Open')
  elseif e == 'race' then
    startGrid(m)
  elseif e == 'go' then
    go()
  elseif e == 'cancel' then
    stopRace()
    banner('RACE STOPPED', 2)
  elseif e == 'result' then
    onResult(m)
  elseif e == 'boom' then
    onBoom(m)
  end
end

-- ---------------------------------------------------------------- one-life rule
-- R (reset), Insert (rewind), Home, the repair button and Ctrl+R all end in a reset of your
-- car; any of them during a race puts you back at A.
local function onResetEvent(vehId)
  local r = S.race
  if not r or (r.phase ~= 'grid' and r.phase ~= 'racing') then return end
  if not vehId then -- the key hook doesn't say which car: the one you're in
    local cur = getPlayerVehicle(0)
    vehId = cur and cur:getId()
  end
  if vehId ~= r.vehId then return end
  if S.now < (r.graceUntil or 0) then return end -- our own teleport
  requestSendBack('Reset = back to point A. One life!')
end

local function updateRace(dt)
  local r = S.race
  if not r then return end
  local veh = be:getObjectByID(r.vehId)
  if not veh then
    if r.phase == 'grid' or r.phase == 'racing' then
      send('out')
      message('Your race car is gone, so you are out of this race.', 6)
    end
    S.race = nil
    return
  end

  if S.sendBackAt and S.now >= S.sendBackAt then
    local reason = S.sendBackReason
    S.sendBackAt = nil
    if r.phase == 'grid' or r.phase == 'racing' then sendBack(reason) end
  end

  -- Once a teleport has settled: did it land at A? (The game's own reset can move the car
  -- after ours.) Retry a few times; then remember where the car stands on the grid.
  if (r.phase == 'grid' or r.phase == 'racing') and not r.settled and S.now >= r.graceUntil then
    r.settled = true
    local missed = (veh:getPosition() - r.pos):length() > 25
    local under = underMap(veh)
    if (missed or under) and (r.retries or 0) < 4 then
      r.retries = (r.retries or 0) + 1
      if under then r.lift = math.min(10, (r.lift or 0) + 2) end -- try again from higher up
      sendBack(nil)
      return
    end
    r.retries = 0
    r.gridPos = vec3(veh:getPosition())
  end
  -- Fell through the map at any point on the grid or right after being sent back: rescue.
  if r.settled and (r.phase == 'grid' or S.now - r.graceUntil < 3) and underMap(veh) then
    r.lift = math.min(10, (r.lift or 0) + 2)
    sendBack(nil)
    return
  end

  if r.phase == 'grid' then
    -- Hold the car (brakes on, gearbox disconnected: revving works) and count down.
    if S.now - r.freezeAt > 0.25 then r.freezeAt = S.now; setFreeze(veh, true) end
    local left = math.ceil(r.countdownEnd - S.now)
    if left >= 1 and left ~= r.shown then
      r.shown = left
      if left <= 3 then sound('event:UI_Countdown' .. (4 - left)) end
    end
    if r.gridPos and (veh:getPosition() - r.gridPos):length() > GRID_LEASH then
      requestSendBack(nil) -- crept off the grid (a car the freeze can't hold)
    end
    return
  end

  if r.phase ~= 'racing' then return end

  -- Driving a different car of yours (spawned or switched) = back to A in the race car.
  local cur = getPlayerVehicle(0)
  if cur and cur:getId() ~= r.vehId and not isUnicycle(cur) and isMine(cur:getId()) then
    requestSendBack('Switched cars = back to point A in your race car.')
  end

  local pos = veh:getPosition()
  -- Map teleports: the car jumped further than its speed explains.
  if r.lastPos and S.now >= r.graceUntil then
    local moved = (pos - r.lastPos):length()
    local speed = veh:getVelocity():length()
    if moved > TELEPORT_JUMP + speed * dt * 3 then requestSendBack('Teleport = back to point A.') end
  end
  r.lastPos = vec3(pos)

  local d = pos - r.b
  if S.now - r.progressAt >= PROGRESS_EVERY then
    r.progressAt = S.now
    send('progress', { d = math.floor(d:length()), key = carKey(r.vehId) })
  end
  if not r.finishSent and math.sqrt(d.x * d.x + d.y * d.y) < FINISH_RADIUS and math.abs(d.z) < FINISH_HEIGHT then
    r.finishSent = true
    send('finish', { key = carKey(r.vehId) })
  end
end

-- ---------------------------------------------------------------- markers
local function drawMarker(p, label, r, g, b, radius)
  local base = vec3(p.x, p.y, p.z)
  local up = vec3(0, 0, 1)
  debugDrawer:drawCylinder(base, base + up * 60, 0.6, ColorF(r, g, b, 0.35))
  debugDrawer:drawCylinder(base - up * 0.2, base + up * 0.3, radius, ColorF(r, g, b, 0.18))
  debugDrawer:drawTextAdvanced(base + up * 4, String(label), ColorF(1, 1, 1, 1), true, false,
    ColorI(math.floor(r * 255), math.floor(g * 255), math.floor(b * 255), 200))
end

S.showMarkers = true -- your own choice, from the app ("Show markers")

local function drawMarkers()
  local party = S.view and S.view.party
  if not party or not S.showMarkers then return end
  if party.a then drawMarker(party.a, 'A  START', 0.1, 0.9, 0.2, 4) end
  if party.b then drawMarker(party.b, 'B  FINISH', 0.95, 0.15, 0.15, FINISH_RADIUS) end
end

-- ---------------------------------------------------------------- UI calls
local function host() send('host') end
local function invite(pid) send('invite', { to = tonumber(pid) }) end
local function accept(partyId) send('accept', { party = tonumber(partyId) }) end
local function decline(partyId) send('decline', { party = tonumber(partyId) }) end
local function leave() send('leave') end
local function start() reportCarSize(); send('start') end
local function cancel() send('cancel') end

local function setShowMarkers(on) S.showMarkers = on and true or false end

-- which = 'A' or 'B'; source = 'car' (where you are now, facing your way), 'map'
-- (the waypoint you clicked on the big map; A then faces towards B) or 'clear' (remove it).
local function setPoint(which, source)
  local p
  if source == 'clear' then
    p = false
  elseif source == 'car' then
    local veh = getPlayerVehicle(0)
    if not veh then message('Get in a car (or walk) to the spot first.'); return end
    local pos = veh:getPosition()
    local dir = isUnicycle(veh) and core_camera.getForward() or veh:getDirectionVector()
    p = { x = pos.x, y = pos.y, z = pos.z, dx = dir.x, dy = dir.y }
  else
    local t = core_groundMarkers and core_groundMarkers.getTargetPos and core_groundMarkers.getTargetPos()
    if not t then
      message('Open the big map (M), click the spot so a route appears, then press "Map pin" again.', 8)
      return
    end
    p = { x = t.x, y = t.y, z = t.z }
    pcall(function() core_groundMarkers.setPath(nil) end) -- clear it, ready to pick the other point
  end
  send('points', which == 'A' and { a = p } or { b = p })
end

local function hasMapPin()
  return core_groundMarkers and core_groundMarkers.currentlyHasTarget and core_groundMarkers.currentlyHasTarget() or false
end

-- ---------------------------------------------------------------- per frame
local uiEvery, sinceUi = 0.1, 0

local function onUpdate(dtReal)
  S.now = S.now + dtReal
  local ok, err = pcall(function()
    updateTransport(dtReal)
    trackCar()
    if S.gotState then reportCarSize() end
    updateRace(dtReal)
    updateCelebrations(dtReal)
    drawMarkers()
  end)
  if not ok then log('E', logTag, tostring(err)) end

  sinceUi = sinceUi + dtReal
  if sinceUi < uiEvery then return end
  sinceUi = 0
  local r = S.race
  local b = S.banner
  if b and S.now > b.untilT then S.banner, b = nil, nil end
  guihooks.trigger('A2BRaceState', {
    version = VERSION,
    mode = S.mp and 'mp' or 'solo',
    ready = S.gotState,
    noServer = S.mp and not S.gotState and S.hellos >= 3 or false,
    view = S.view,
    race = r and { phase = r.phase, count = r.phase == 'grid' and math.max(0, math.ceil(r.countdownEnd - S.now)) or nil } or nil,
    banner = b and { text = b.text, kind = b.kind } or nil,
    mapPin = hasMapPin(),
    showMarkers = S.showMarkers,
    hasCar = myCar() ~= nil,
  })
end

local function cleanupEffects()
  for vehId in pairs(fx) do endCelebration(vehId) end
end

local function onClientEndMission()
  cleanupEffects()
  S.race, S.sendBackAt = nil, nil
end

local function onExtensionUnloaded()
  cleanupEffects()
  if S.race then stopRace() end
end

M.onUpdate = onUpdate
M.onExtensionUnloaded = onExtensionUnloaded
M.onClientEndMission = onClientEndMission
M.trackVehReset = onResetEvent      -- R / Insert / Home (fired just before the game's reset)
M.onVehicleResetted = onResetEvent  -- any reset or repair, including the radial menu and Ctrl+R

M.host = host
M.invite = invite
M.accept = accept
M.decline = decline
M.leave = leave
M.start = start
M.cancel = cancel
M.setPoint = setPoint
M.setShowMarkers = setShowMarkers

return M
