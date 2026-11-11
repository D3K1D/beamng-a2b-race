-- A2B Race: parties and races (the rules). Pure Lua with no game or server APIs, so the
-- very same file runs on the BeamMP server (Resources/Server/A2BRace/lib/core.lua) and in
-- the game for single-player solo races (extension "a2brace_core").
--
-- env = {
--   send(pid, event, table)   deliver a message to one player
--   names() -> { [pid] = name }  players currently connected
--   log(text)
-- }
-- Players send: host, invite{to}, accept{party}, decline{party}, leave, points{a?,b?},
--   start, cancel, car{len,wid}, progress{d,key}, finish{key}, out
-- Players receive: state, invited{party,host}, notice{text}, race{...}, go, result{...},
--   boom{pid,name,place,key}, cancel

local M = {}

local COUNTDOWN = 10         -- seconds on the starting grid
local FIRST_BOOM_DELAY = 2.5 -- seconds after the win before second place blows up
local BOOM_GAP = 1.5         -- seconds between explosions (2nd, 3rd, ... last)
local MIN_RACE_TIME = 3      -- a finish this soon after GO is ignored

local function num(x, lim)
  x = tonumber(x)
  if not x or x ~= x or math.abs(x) > (lim or 1e6) then return nil end
  return x
end

-- A map point {x,y,z}; point A also has a facing {dx,dy}, or auto = face towards B.
local function point(p, withDir)
  if type(p) ~= 'table' then return nil end
  local x, y, z = num(p.x), num(p.y), num(p.z)
  if not (x and y and z) then return nil end
  local r = { x = x, y = y, z = z }
  if withDir then
    local dx, dy = num(p.dx, 2) or 0, num(p.dy, 2) or 0
    local l = math.sqrt(dx * dx + dy * dy)
    if l < 1e-3 then r.auto = true; dx, dy = 0, 1 else dx, dy = dx / l, dy / l end
    r.dx, r.dy = dx, dy
  end
  return r
end

local function carKey(k) return type(k) == 'string' and k:match('^%d+%-%d+$') or nil end

function M.new(env)
  local C = {}
  local parties = {}  -- [partyId] = { id, host, order = {pid...}, a, b, race }
  local memberOf = {} -- [pid] = partyId
  local invites = {}  -- [pid] = { [partyId] = true }
  local cars = {}     -- [pid] = { len, wid } of the car they drive
  local nextId = 1

  local known = {} -- last seen names, for players who just disconnected
  local function name(pid)
    local n = env.names()[pid]
    if n then known[pid] = n end
    return n or known[pid] or ('Player ' .. tostring(pid))
  end

  local function view(pid)
    local v = { me = pid, players = {}, invites = {} }
    for id, nm in pairs(env.names()) do
      if id ~= pid then v.players[#v.players + 1] = { pid = id, name = nm, party = memberOf[id] } end
    end
    table.sort(v.players, function(x, y) return x.name < y.name end)
    for partyId in pairs(invites[pid] or {}) do
      local p = parties[partyId]
      if p then v.invites[#v.invites + 1] = { party = partyId, host = name(p.host) } end
    end
    local p = parties[memberOf[pid]]
    if p then
      local members, invited = {}, {}
      for _, id in ipairs(p.order) do
        members[#members + 1] = { pid = id, name = name(id), host = id == p.host,
          racing = p.race and p.race.racers[id] or false }
      end
      for id, ps in pairs(invites) do if ps[p.id] then invited[#invited + 1] = id end end
      v.party = { id = p.id, host = p.host, members = members, invited = invited, a = p.a, b = p.b,
        phase = p.race and p.race.phase or 'idle' }
    end
    return v
  end

  local function syncAll()
    for pid, n in pairs(env.names()) do known[pid] = n; env.send(pid, 'state', view(pid)) end
  end

  local function notice(pid, text) env.send(pid, 'notice', { text = text }) end
  local function noticeParty(p, text) for _, id in ipairs(p.order) do notice(id, text) end end

  local function hostedParty(pid)
    local p = parties[memberOf[pid]]
    if p and p.host == pid then return p end
  end

  local function racing(r) return r and (r.phase == 'countdown' or r.phase == 'racing') end

  local function endRace(p)
    p.race = nil
  end

  -- A racer stops racing (left the party, lost their car, disconnected).
  local function dropRacer(p, pid)
    local r = p.race
    if not r or not r.racers[pid] then return end
    r.racers[pid] = nil
    r.count = r.count - 1
    if racing(r) and r.count <= 0 then endRace(p) end
  end

  local function leave(pid)
    local p = parties[memberOf[pid]]
    if not p then return end
    memberOf[pid] = nil
    for i, id in ipairs(p.order) do if id == pid then table.remove(p.order, i) break end end
    dropRacer(p, pid)
    if #p.order == 0 then
      parties[p.id] = nil
      for _, ps in pairs(invites) do ps[p.id] = nil end
    else
      if p.host == pid then
        p.host = p.order[1]
        notice(p.host, 'You are now the race host')
      end
      noticeParty(p, name(pid) .. ' left the party')
    end
  end

  local function join(pid, p)
    leave(pid)
    memberOf[pid] = p.id
    p.order[#p.order + 1] = pid
    noticeParty(p, name(pid) .. ' joined the party')
  end

  local handlers = {}

  function handlers.host(pid)
    local p = parties[memberOf[pid]]
    if p and p.host == pid then return end
    leave(pid)
    p = { id = nextId, host = pid, order = { pid } }
    nextId = nextId + 1
    parties[p.id] = p
    memberOf[pid] = p.id
  end

  function handlers.invite(pid, d)
    local p = hostedParty(pid)
    local to = num(d.to)
    if not p or not to or to == pid or not env.names()[to] or memberOf[to] == p.id then return end
    invites[to] = invites[to] or {}
    invites[to][p.id] = true
    env.send(to, 'invited', { party = p.id, host = name(pid) })
    notice(pid, 'Invited ' .. name(to))
  end

  function handlers.accept(pid, d)
    local id = num(d.party)
    local p = id and parties[id]
    if not p or not (invites[pid] and invites[pid][id]) then return end
    invites[pid][id] = nil
    if memberOf[pid] == id then return end
    local old = parties[memberOf[pid]]
    if old and racing(old.race) and old.race.racers[pid] then
      notice(pid, 'Finish or leave your current race first')
      invites[pid][id] = true
      return
    end
    join(pid, p)
  end

  function handlers.decline(pid, d)
    local id = num(d.party)
    if id and invites[pid] then invites[pid][id] = nil end
  end

  function handlers.leave(pid) leave(pid) end

  function handlers.points(pid, d)
    local p = hostedParty(pid)
    if not p then return end
    if p.race and p.race.phase ~= 'done' then notice(pid, 'Wait for the race to finish'); return end
    if d.a ~= nil then p.a = point(d.a, true) end
    if d.b ~= nil then p.b = point(d.b, false) end
  end

  function handlers.car(pid, d)
    local len, wid = num(d.len, 60), num(d.wid, 20)
    if len and wid and len > 0 and wid > 0 then cars[pid] = { len = len, wid = wid } end
  end

  function handlers.start(pid)
    local p = hostedParty(pid)
    if not p then return end
    if not (p.a and p.b) then notice(pid, 'Set point A and point B first'); return end
    if p.race and p.race.phase ~= 'done' then return end
    -- Grid spacing from the biggest car in the party, so trucks and buses fit too.
    local len, wid = 4.5, 2
    for _, id in ipairs(p.order) do
      local c = cars[id]
      if c then len, wid = math.max(len, c.len), math.max(wid, c.wid) end
    end
    local a = p.a
    if a.auto then -- picked on the map: face towards B
      local dx, dy = p.b.x - a.x, p.b.y - a.y
      local l = math.sqrt(dx * dx + dy * dy)
      if l > 1e-3 then a = { x = a.x, y = a.y, z = a.z, dx = dx / l, dy = dy / l } end
    end
    local r = { phase = 'countdown', t = 0, racers = {}, count = #p.order, progress = {}, keys = {} }
    p.race = r
    local cols = #p.order > 1 and 2 or 1
    for i, id in ipairs(p.order) do
      r.racers[id] = true
      env.send(id, 'race', { slot = i, cols = cols, rowGap = len + 4, colGap = wid + 2.5, a = a, b = p.b,
        countdown = COUNTDOWN })
    end
  end

  function handlers.cancel(pid)
    local p = hostedParty(pid)
    if not p or not p.race or p.race.phase == 'done' then return end
    for id in pairs(p.race.racers) do env.send(id, 'cancel', {}) end
    endRace(p)
    noticeParty(p, 'The host stopped the race')
  end

  function handlers.progress(pid, d)
    local p = parties[memberOf[pid]]
    local r = p and p.race
    if not r or r.phase ~= 'racing' or not r.racers[pid] then return end
    r.progress[pid] = num(d.d) or r.progress[pid]
    r.keys[pid] = carKey(d.key) or r.keys[pid]
  end

  function handlers.out(pid)
    local p = parties[memberOf[pid]]
    if p and racing(p.race) and p.race.racers[pid] then
      dropRacer(p, pid)
      noticeParty(p, name(pid) .. ' is out of the race (no car)')
    end
  end

  function handlers.finish(pid, d)
    local p = parties[memberOf[pid]]
    local r = p and p.race
    if not r or r.phase ~= 'racing' or not r.racers[pid] or r.t < MIN_RACE_TIME then return end
    r.keys[pid] = carKey(d.key) or r.keys[pid]
    r.phase, r.t, r.winner = 'boom', 0, pid
    -- Everyone else is ranked by how close they were to B; 2nd place blows up first.
    local losers = {}
    for id in pairs(r.racers) do if id ~= pid then losers[#losers + 1] = id end end
    table.sort(losers, function(x, y) return (r.progress[x] or 1e9) < (r.progress[y] or 1e9) end)
    r.losers, r.nextBoom = losers, 1
    local order = { { pid = pid, name = name(pid) } }
    for _, id in ipairs(losers) do order[#order + 1] = { pid = id, name = name(id) } end
    for _, id in ipairs(p.order) do
      env.send(id, 'result', { winner = pid, name = name(pid), key = r.keys[pid], order = order })
    end
  end

  -- Messages from players. Every change is followed by a fresh state for everyone.
  function C.handle(pid, event, d)
    local h = handlers[event]
    if not h or not env.names()[pid] then return end
    local ok, err = pcall(h, pid, type(d) == 'table' and d or {})
    if not ok then env.log('error in ' .. event .. ': ' .. tostring(err)) end
    if event ~= 'progress' and event ~= 'car' then syncAll() end
  end

  function C.state(pid) env.send(pid, 'state', view(pid)) end

  function C.joined() syncAll() end

  function C.dropped(pid)
    leave(pid)
    invites[pid], cars[pid] = nil, nil
    syncAll()
  end

  -- Countdown and the explosion sequence. Call regularly with elapsed seconds.
  function C.tick(dt)
    for _, p in pairs(parties) do
      local r = p.race
      if r then
        r.t = r.t + dt
        if r.phase == 'countdown' and r.t >= COUNTDOWN then
          r.phase, r.t = 'racing', 0
          for id in pairs(r.racers) do env.send(id, 'go', {}) end
          syncAll()
        elseif r.phase == 'boom' then
          local due = FIRST_BOOM_DELAY + (r.nextBoom - 1) * BOOM_GAP
          if r.t >= due then
            local id = r.losers[r.nextBoom]
            if id then
              for _, m in ipairs(p.order) do
                env.send(m, 'boom', { pid = id, name = name(id), place = r.nextBoom + 1, key = r.keys[id] })
              end
              r.nextBoom = r.nextBoom + 1
            else
              r.phase = 'done'
              syncAll()
            end
          end
        end
      end
    end
  end

  return C
end

return M
