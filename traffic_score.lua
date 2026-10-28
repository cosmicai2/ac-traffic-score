--------------------------------------------------------------------------------
-- TRAFFIC SCORE  |  Assetto Corsa + CSP + AssettoServer
-- Dynamic score counter (speed x time x no-collision x near-miss) + live leaderboard
-- Needs: Custom Shaders Patch (online Lua scripts) and EnableClientMessages: true
--------------------------------------------------------------------------------

local CFG = {
  minSpeed       = 100,    -- km/h needed before scoring starts
  maxMult        = 10,     -- hard cap on the multiplier
  scoreRate      = 0.10,   -- points per second = speed(km/h) * mult * scoreRate
  timeGain       = 0.12,   -- multiplier gained per second at 100 km/h (scales with speed)
  nearMissGap    = 1.6,    -- metres of clearance (side to side) that counts as a near miss
  nearMissBase   = 120,    -- base bonus points for a near miss
  comboWindow    = 4.0,    -- seconds to chain near misses
  comboMultStep  = 0.5,    -- multiplier added per combo level
  collisionCool  = 1.0,    -- seconds between collision detections
  leaderboardMax = 8,      -- rows shown
  staleAfter     = 8.0,    -- seconds before a silent player disappears from the board
  broadcastEvery = 1.0,    -- seconds between score broadcasts
  -- set true if you want other human players to count as "traffic" for near misses
  humansCountAsTraffic = false,
}

local sim = ac.getSim()

-- state -----------------------------------------------------------------------
local score, best = 0, 0
local timeBonus, combo, comboTimer = 0, 0, 0
local mult = 1
local lastCollision = -10
local popups = {}                 -- {text, color, t, life}
local nearState = {}              -- [carIndex] = minimal gap while inside zone
local players = {}                -- [senderIndex] = {name, score, best, t}
local sendTimer = 0
local flash = 0                   -- red flash after crash
local scoreShown = 0              -- smoothed number for the animated counter
local lastScoreKey = 0

-- colors ----------------------------------------------------------------------
local C = {
  bg     = rgbm(0.04, 0.05, 0.08, 0.72),
  accent = rgbm(0.10, 0.85, 1.00, 1),
  gold   = rgbm(1.00, 0.80, 0.15, 1),
  green  = rgbm(0.25, 1.00, 0.45, 1),
  red    = rgbm(1.00, 0.20, 0.20, 1),
  orange = rgbm(1.00, 0.55, 0.10, 1),
  white  = rgbm(1, 1, 1, 1),
  grey   = rgbm(0.65, 0.68, 0.75, 1),
}

local function withAlpha(c, a) return rgbm(c.r, c.g, c.b, a) end
local function clamp(x, a, b) return math.max(a, math.min(b, x)) end
local function lerp(a, b, t) return a + (b - a) * t end

local function pushPopup(text, color, life)
  table.insert(popups, 1, { text = text, color = color, t = 0, life = life or 2.2 })
  if #popups > 4 then table.remove(popups) end
end

-- online leaderboard sync -----------------------------------------------------
local scoreEvent = ac.OnlineEvent({
  ac.StructItem.key('traffic_score_v1'),
  score = ac.StructItem.int32(),
  best  = ac.StructItem.int32(),
}, function(data, sender)
  if sender == nil then return end
  players[sender.index] = {
    name  = ac.getDriverName(sender.index) or ('Car ' .. sender.index),
    score = data.score,
    best  = data.best,
    t     = os.clock(),
  }
end)

local function broadcast()
  scoreEvent({ score = math.floor(score), best = math.floor(best) })
end

-- helpers -----------------------------------------------------------------------
local function isTraffic(other)
  if other.isAIControlled then return true end
  if CFG.humansCountAsTraffic then return true end
  local name = ac.getDriverName(other.index) or ''
  -- AssettoServer names AI cars "<NamePrefix> <id>" (NamePrefix is "Traffic" in extra_cfg.yml)
  return name == '' or name:sub(1, 7) == 'Traffic'
end

local function resetRun(reason, color)
  if score > 1 then
    pushPopup(reason .. '  -' .. math.floor(score), color, 2.8)
  else
    pushPopup(reason, color, 2.2)
  end
  score, timeBonus, combo, comboTimer, mult = 0, 0, 0, 0, 1
  flash = 1
  nearState = {}
  broadcast()
end

-- main update -----------------------------------------------------------------
function script.update(dt)
  local car = ac.getCar(0)
  if car == nil then return end

  local now = os.clock()
  local speed = car.speedKmh
  local inPit = car.isInPit or car.isInPitlane
  local driving = (not inPit) and (not sim.isPaused) and (not sim.isReplayActive)

  if not driving then
    nearState = {}
  end

  -- collision ---------------------------------------------------------------
  if driving and car.collisionDepth > 0 and (now - lastCollision) > CFG.collisionCool then
    lastCollision = now
    -- is a car close by? then it is a car hit, otherwise a wall/barrier
    local hitCar = false
    for i = 1, sim.carsCount - 1 do
      local o = ac.getCar(i)
      if o and (o.position - car.position):lengthSquared() < 36 then
        hitCar = true
        break
      end
    end
    resetRun(hitCar and 'COLLISION' or 'CRASHED', C.red)
  end

  -- scoring --------------------------------------------------------------------
  if driving and speed >= CFG.minSpeed then
    timeBonus = math.min(CFG.maxMult - 1, timeBonus + dt * CFG.timeGain * (speed / 100))
    if comboTimer > 0 then
      comboTimer = comboTimer - dt
      if comboTimer <= 0 then combo = 0 end
    end
    mult = clamp(1 + timeBonus + combo * CFG.comboMultStep, 1, CFG.maxMult)
    score = score + dt * speed * mult * CFG.scoreRate

    -- near miss detection ----------------------------------------------------
    for i = 1, sim.carsCount - 1 do
      local o = ac.getCar(i)
      if o and isTraffic(o) then
        local rel = o.position - car.position
        if rel:lengthSquared() < 900 then -- only cars within 30 m
          local dz = rel:dot(car.look)
          local dx = rel:dot(car.side)
          local gap = math.abs(dx) - 1.9           -- approx. body-to-body clearance
          local inZone = math.abs(dz) < 5.0 and gap < CFG.nearMissGap
          local st = nearState[i]
          if inZone then
            nearState[i] = (st == nil) and gap or math.min(st, gap)
          elseif st ~= nil and (math.abs(dz) > 6.5 or math.abs(dx) > 6) then
            -- car left the zone with no collision -> pay out
            local g = clamp(st, 0, CFG.nearMissGap)
            local closeness = 1 - g / CFG.nearMissGap        -- 0..1, closer = higher
            combo = combo + 1
            comboTimer = CFG.comboWindow
            mult = clamp(1 + timeBonus + combo * CFG.comboMultStep, 1, CFG.maxMult)
            local bonus = CFG.nearMissBase * (0.5 + closeness * 2.5) * mult * (speed / 120)
            score = score + bonus
            local label, col
            if g < 0.35 then label, col = 'INSANE NEAR MISS', C.red
            elseif g < 0.8 then label, col = 'GREAT NEAR MISS', C.gold
            else label, col = 'NEAR MISS', C.green end
            pushPopup(string.format('%s  +%d  x%d', label, math.floor(bonus), combo), col)
            nearState[i] = nil
          end
        else
          nearState[i] = nil
        end
      end
    end
  end

  -- best + broadcast --------------------------------------------------------
  if score > best then best = score end
  sendTimer = sendTimer + dt
  if sendTimer >= CFG.broadcastEvery then
    sendTimer = 0
    broadcast()
  end

  -- popup + flash animation ----------------------------------------------------
  for i = #popups, 1, -1 do
    popups[i].t = popups[i].t + dt
    if popups[i].t > popups[i].life then table.remove(popups, i) end
  end
  flash = math.max(0, flash - dt * 1.6)
  scoreShown = lerp(scoreShown, score, clamp(dt * 8, 0, 1))
  if math.abs(scoreShown - score) < 0.5 then scoreShown = score end
end

-- drawing ---------------------------------------------------------------------
local function text(str, size, pos, color)
  ui.dwriteDrawText(str, size, pos, color)
end

local function textCentered(str, size, cx, y, color)
  local m = ui.measureDWriteText(str, size)
  ui.dwriteDrawText(str, size, vec2(cx - m.x / 2, y), color)
end

local function drawScoreWindow()
  local car = ac.getCar(0)
  if car == nil then return end
  local W, H = 440, 250
  local scr = ac.getUI().windowSize
  ui.transparentWindow('traffic_score_main', vec2(scr.x / 2 - W / 2, 40), vec2(W, H), function()
    local o = ui.windowPos()
    local cx = o.x + W / 2
    local speed = car.speedKmh
    local active = speed >= CFG.minSpeed

    -- panel
    local pulse = 0.5 + 0.5 * math.sin(os.clock() * 6)
    ui.drawRectFilled(o, o + vec2(W, 150), C.bg, 14)
    if flash > 0 then
      ui.drawRectFilled(o, o + vec2(W, 150), withAlpha(C.red, flash * 0.45), 14)
    end
    local edge = active and withAlpha(C.accent, 0.55 + 0.35 * pulse) or withAlpha(C.grey, 0.4)
    ui.drawRect(o, o + vec2(W, 150), edge, 14, ui.CornerFlags.All, 2)

    -- header
    textCentered('TRAFFIC SCORE', 14, cx, o.y + 8, C.grey)
    -- score
    local scoreCol = active and C.white or C.grey
    textCentered(string.format('%d', math.floor(scoreShown)), 54, cx, o.y + 26, scoreCol)

    -- multiplier + bar
    local multCol = mult >= 8 and C.red or (mult >= 5 and C.orange or (mult >= 3 and C.gold or C.accent))
    text(string.format('x%.1f', mult), 26, vec2(o.x + 18, o.y + 100), multCol)
    local bx, by, bw = o.x + 100, o.y + 112, W - 220
    ui.drawRectFilled(vec2(bx, by), vec2(bx + bw, by + 12), rgbm(1, 1, 1, 0.12), 6)
    local frac = (mult - 1) / (CFG.maxMult - 1)
    ui.drawRectFilled(vec2(bx, by), vec2(bx + bw * frac, by + 12), multCol, 6)
    if combo > 0 then
      local cf = clamp(comboTimer / CFG.comboWindow, 0, 1)
      ui.drawRectFilled(vec2(bx, by + 16), vec2(bx + bw * cf, by + 19), C.gold, 2)
    end

    -- speed + best
    text(string.format('%d km/h', math.floor(speed)), 18, vec2(o.x + W - 112, o.y + 98), active and C.green or C.red)
    text('BEST ' .. math.floor(best), 13, vec2(o.x + W - 112, o.y + 122), C.grey)

    if not active then
      textCentered('REACH ' .. CFG.minSpeed .. ' KM/H TO SCORE', 13, cx, o.y + 132, withAlpha(C.red, 0.6 + 0.4 * pulse))
    end

    -- popup notifications stacked below the panel
    local y = o.y + 160
    for _, p in ipairs(popups) do
      local a = 1
      if p.t < 0.15 then a = p.t / 0.15 end
      if p.t > p.life - 0.5 then a = (p.life - p.t) / 0.5 end
      local scale = (p.t < 0.2) and (1.35 - 0.35 * (p.t / 0.2)) or 1
      local m = ui.measureDWriteText(p.text, 20 * scale)
      ui.drawRectFilled(vec2(cx - m.x / 2 - 12, y - 2), vec2(cx + m.x / 2 + 12, y + m.y + 4),
        rgbm(0, 0, 0, 0.55 * a), 8)
      ui.dwriteDrawText(p.text, 20 * scale, vec2(cx - m.x / 2, y), withAlpha(p.color, a))
      y = y + m.y + 10
    end
  end)
end

local function drawLeaderboardWindow()
  local W = 270
  local rowH = 24
  local rows = {}
  local now = os.clock()
  local myIdx = 0

  rows[#rows + 1] = { name = ac.getDriverName(0) or 'You', score = score, best = best, me = true }
  for idx, p in pairs(players) do
    if idx ~= myIdx and (now - p.t) < CFG.staleAfter then
      rows[#rows + 1] = { name = p.name, score = p.score, best = p.best, me = false }
    end
  end
  table.sort(rows, function(a, b) return a.best > b.best end)

  local count = math.min(#rows, CFG.leaderboardMax)
  local H = 52 + count * rowH
  local scr = ac.getUI().windowSize
  ui.transparentWindow('traffic_score_board', vec2(scr.x - W - 24, 120), vec2(W, H), function()
    local o = ui.windowPos()
    ui.drawRectFilled(o, o + vec2(W, H), C.bg, 12)
    ui.drawRect(o, o + vec2(W, H), withAlpha(C.accent, 0.45), 12, ui.CornerFlags.All, 2)
    text('LEADERBOARD', 15, vec2(o.x + 14, o.y + 8), C.accent)
    text('BEST', 11, vec2(o.x + W - 66, o.y + 12), C.grey)
    for i = 1, count do
      local r = rows[i]
      local y = o.y + 36 + (i - 1) * rowH
      if r.me then
        ui.drawRectFilled(vec2(o.x + 6, y - 2), vec2(o.x + W - 6, y + rowH - 4), withAlpha(C.accent, 0.18), 6)
      end
      local medal = (i == 1 and C.gold) or (i == 2 and rgbm(0.8, 0.8, 0.85, 1)) or (i == 3 and rgbm(0.8, 0.5, 0.25, 1)) or C.grey
      text(tostring(i), 14, vec2(o.x + 14, y), medal)
      local nm = r.name
      if #nm > 14 then nm = nm:sub(1, 13) .. '.' end
      text(nm, 14, vec2(o.x + 38, y), r.me and C.white or C.grey)
      local v = tostring(math.floor(r.best))
      local m = ui.measureDWriteText(v, 14)
      text(v, 14, vec2(o.x + W - 14 - m.x, y), r.me and C.gold or C.white)
    end
  end)
end

function script.drawUI(dt)
  drawScoreWindow()
  drawLeaderboardWindow()
end
