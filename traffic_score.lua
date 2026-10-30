--------------------------------------------------------------------------------
-- TRAFFIC SCORE v2  |  local CSP app (apps/lua/TrafficScore)
-- Transparent app windows (NO_BACKGROUND): drag/resize them with CSP's normal app controls
--------------------------------------------------------------------------------

local CFG = {
  minSpeed       = 100,
  maxMult        = 10,
  scoreRate      = 0.10,
  timeGain       = 0.12,
  nearMissGap    = 1.6,
  nearMissBase   = 120,
  comboWindow    = 4.0,
  comboMultStep  = 0.5,
  collisionCool  = 1.0,
  leaderboardMax = 8,
  staleAfter     = 8.0,
  broadcastEvery = 1.0,
  humansCountAsTraffic = false,
  baseW          = 520,
}

local sim = ac.getSim()

-- state -----------------------------------------------------------------------
local score, best = 0, 0
local timeBonus, combo, comboTimer = 0, 0, 0
local mult, speedMult, proxMult = 1, 1, 1
local runTime = 0
local lastCollision = -10
local popups = {}
local nearState = {}
local players = {}
local sendTimer = 0
local flash, bump = 0, 0
local scoreShown = 0
local myName = 'Driver'

-- colors ----------------------------------------------------------------------
local C = {
  panel  = rgbm(0.07, 0.08, 0.11, 0.78),
  accent = rgbm(0.10, 0.85, 1.00, 1),
  gold   = rgbm(0.99, 0.75, 0.15, 1),
  green  = rgbm(0.25, 1.00, 0.45, 1),
  red    = rgbm(1.00, 0.22, 0.22, 1),
  orange = rgbm(1.00, 0.55, 0.10, 1),
  purple = rgbm(0.58, 0.25, 0.95, 1),
  white  = rgbm(1, 1, 1, 1),
  grey   = rgbm(0.70, 0.73, 0.80, 1),
  dark   = rgbm(0.16, 0.09, 0.02, 1),
}

local function withAlpha(c, a) return rgbm(c.r, c.g, c.b, a) end
local function clamp(x, a, b) return math.max(a, math.min(b, x)) end
local function lerp(a, b, t) return a + (b - a) * t end
local function mix(c1, c2, t) return rgbm(lerp(c1.r, c2.r, t), lerp(c1.g, c2.g, t), lerp(c1.b, c2.b, t), lerp(c1.mult or 1, c2.mult or 1, t)) end

local function fmt(n)
  local s = tostring(math.floor(n))
  local r = s:reverse():gsub('(%d%d%d)', '%1,'):reverse()
  if r:sub(1, 1) == ',' then r = r:sub(2) end
  return r
end
local function fmtTime(t)
  t = math.floor(t)
  return string.format('%02d:%02d', math.floor(t / 60), t % 60)
end

local function pushPopup(text, color, life)
  table.insert(popups, 1, { text = text, color = color, t = 0, life = life or 2.2 })
  if #popups > 4 then table.remove(popups) end
end

-- online leaderboard sync (no sender object needed) --------------------------------
local scoreEvent = ac.OnlineEvent({
  ac.StructItem.key('traffic_score_v2'),
  name  = ac.StructItem.string(24),
  score = ac.StructItem.int32(),
  best  = ac.StructItem.int32(),
}, function(data)
  local nm = tostring(data.name)
  if nm == '' or nm == myName then return end
  players[nm] = { name = nm, score = data.score, best = data.best, t = os.clock() }
end)

local function broadcast()
  local n = ac.getDriverName(0)
  if n and n ~= '' then myName = n end
  scoreEvent({ name = myName, score = math.floor(score), best = math.floor(best) })
end

local function isTraffic(other)
  if other.isAIControlled then return true end
  if CFG.humansCountAsTraffic then return true end
  local name = ac.getDriverName(other.index) or ''
  return name == '' or name:sub(1, 7) == 'Traffic'
end

local function resetRun(reason, color)
  if score > 1 then pushPopup(reason .. '  -' .. fmt(score), color, 2.8)
  else pushPopup(reason, color, 2.2) end
  score, timeBonus, combo, comboTimer, mult, speedMult, proxMult, runTime = 0, 0, 0, 0, 1, 1, 1, 0
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
  if not driving then nearState = {} end

  if driving and car.collisionDepth > 0 and (now - lastCollision) > CFG.collisionCool then
    lastCollision = now
    local hitCar = false
    for i = 1, sim.carsCount - 1 do
      local o = ac.getCar(i)
      if o and (o.position - car.position):lengthSquared() < 36 then hitCar = true break end
    end
    resetRun(hitCar and 'COLLISION' or 'CRASHED', C.red)
  end

  if driving and speed >= CFG.minSpeed then
    runTime = runTime + dt
    timeBonus = math.min(CFG.maxMult - 1, timeBonus + dt * CFG.timeGain * (speed / 100))
    if comboTimer > 0 then
      comboTimer = comboTimer - dt
      if comboTimer <= 0 then combo = 0 end
    end
    speedMult = 1 + timeBonus
    proxMult = 1 + combo * CFG.comboMultStep
    mult = clamp(speedMult + proxMult - 1, 1, CFG.maxMult)
    score = score + dt * speed * mult * CFG.scoreRate

    for i = 1, sim.carsCount - 1 do
      local o = ac.getCar(i)
      if o and isTraffic(o) then
        local rel = o.position - car.position
        if rel:lengthSquared() < 900 then
          local dz = rel:dot(car.look)
          local dx = rel:dot(car.side)
          local gap = math.abs(dx) - 1.9
          local inZone = math.abs(dz) < 5.0 and gap < CFG.nearMissGap
          local s0 = nearState[i]
          if inZone then
            nearState[i] = (s0 == nil) and gap or math.min(s0, gap)
          elseif s0 ~= nil and (math.abs(dz) > 6.5 or math.abs(dx) > 6) then
            local g = clamp(s0, 0, CFG.nearMissGap)
            local closeness = 1 - g / CFG.nearMissGap
            combo = combo + 1
            comboTimer = CFG.comboWindow
            proxMult = 1 + combo * CFG.comboMultStep
            mult = clamp(speedMult + proxMult - 1, 1, CFG.maxMult)
            local bonus = CFG.nearMissBase * (0.5 + closeness * 2.5) * mult * (speed / 120)
            score = score + bonus
            bump = 1
            local label, col
            if g < 0.35 then label, col = 'INSANE NEAR MISS', C.red
            elseif g < 0.8 then label, col = 'GREAT NEAR MISS', C.gold
            else label, col = 'NEAR MISS', C.green end
            pushPopup(string.format('%s  +%s  x%d', label, fmt(bonus), combo), col)
            nearState[i] = nil
          end
        else
          nearState[i] = nil
        end
      end
    end
  end

  if score > best then best = score end
  sendTimer = sendTimer + dt
  if sendTimer >= CFG.broadcastEvery then sendTimer = 0 broadcast() end

  for i = #popups, 1, -1 do
    popups[i].t = popups[i].t + dt
    if popups[i].t > popups[i].life then table.remove(popups, i) end
  end
  flash = math.max(0, flash - dt * 1.6)
  bump = math.max(0, bump - dt * 3)
  scoreShown = lerp(scoreShown, score, clamp(dt * 8, 0, 1))
  if math.abs(scoreShown - score) < 0.5 then scoreShown = score end
end

-- drawing helpers (design units * k, relative to origin o) ------------------------
local function pt(o, k, x, y) return vec2(o.x + x * k, o.y + y * k) end

local function paraPath(o, k, x, y, w, h, sk)
  ui.pathClear()
  ui.pathLineTo(pt(o, k, x + sk, y))
  ui.pathLineTo(pt(o, k, x + w, y))
  ui.pathLineTo(pt(o, k, x + w - sk, y + h))
  ui.pathLineTo(pt(o, k, x, y + h))
end
local function para(o, k, x, y, w, h, sk, col)
  paraPath(o, k, x, y, w, h, sk)
  ui.pathFillConvex(col)
end
local function paraLine(o, k, x, y, w, h, sk, col, th)
  paraPath(o, k, x, y, w, h, sk)
  ui.pathStroke(col, true, th * k)
end

-- text: align 'l' (default), 'c' or 'r' around x; y is the top
local function txt(o, k, str, size, x, y, col, align)
  local m = ui.measureDWriteText(str, size * k)
  local px = x * k
  if align == 'c' then px = px - m.x / 2 elseif align == 'r' then px = px - m.x end
  ui.dwriteDrawText(str, size * k, vec2(o.x + px, o.y + y * k), col)
end

local function drawChip(o, k, x, y, w, h, value, label, col, glow)
  para(o, k, x, y, w, h, 12, C.panel)
  para(o, k, x, y, w, 3, 12, withAlpha(col, 0.9))
  paraLine(o, k, x, y, w, h, 12, withAlpha(col, 0.25 + 0.45 * glow), 1.5)
  txt(o, k, value, 22, x + w / 2, y + 5, C.white, 'c')
  txt(o, k, label, 11, x + w / 2, y + h - 17, withAlpha(col, 0.95), 'c')
end

-- score HUD -------------------------------------------------------------------
local function drawScoreHUD()
  local car = ac.getCar(0)
  if car == nil then return end
  -- fit the whole HUD into whatever space the window has (any size, nothing cut off)
  local aw, ah = ui.availableSpaceX(), ui.availableSpaceY()
  local k = clamp(math.min(aw / CFG.baseW, ah / 310), 0.2, 6) * 0.97
  local o = ui.getCursor() + vec2(math.max(0, (aw - CFG.baseW * k) / 2), 0)
  ui.dummy(vec2(CFG.baseW * k, 310 * k))
  do
    local speed = car.speedKmh
    local active = speed >= CFG.minSpeed
    local t = os.clock()
    local pulse = 0.5 + 0.5 * math.sin(t * 6)
    local hot = clamp((mult - 5) / 5, 0, 1)

    -- row 1: chips + total badge
    drawChip(o, k, 0,   0, 132, 50, string.format('%.1fX', speedMult), 'SPEED',     C.accent, active and pulse or 0)
    drawChip(o, k, 138, 0, 150, 50, string.format('%.1fX', proxMult),  'PROXIMITY', C.orange, bump)
    drawChip(o, k, 294, 0, 108, 50, 'x' .. combo,                      'COMBO',     C.gold,   combo > 0 and pulse or 0)

    local shake = (mult >= 9) and math.sin(t * 60) * 1.5 or 0
    local bx = 408 + shake
    para(o, k, bx, 0, 112, 50, 12, C.purple)
    para(o, k, bx, 0, 112, 22, 12, rgbm(1, 1, 1, 0.16))
    paraLine(o, k, bx, 0, 112, 50, 12, rgbm(1, 1, 1, 0.35 + 0.4 * hot * pulse), 1.5)
    txt(o, k, string.format('%.1fX', mult), 26 + bump * 4, bx + 56, 6, C.white, 'c')
    txt(o, k, 'TOTAL', 10, bx + 56, 35, rgbm(1, 1, 1, 0.8), 'c')

    -- row 2: big gold points bar + timer pill
    local barCol = C.gold
    if not active then barCol = rgbm(0.45, 0.47, 0.52, 1) end
    if flash > 0 then barCol = mix(barCol, C.red, clamp(flash * 1.4, 0, 1)) end
    para(o, k, 0, 58, 404, 62, 14, barCol)
    para(o, k, 0, 58, 404, 28, 14, rgbm(1, 1, 1, 0.20))
    paraLine(o, k, 0, 58, 404, 62, 14, rgbm(1, 1, 1, 0.45), 1.5)
    if active then
      txt(o, k, fmt(scoreShown) .. ' PTS', 36 + bump * 5, 202, 68, flash > 0.3 and C.white or C.dark, 'c')
    else
      txt(o, k, 'REACH ' .. CFG.minSpeed .. ' KM/H TO SCORE', 20, 202, 77, rgbm(1, 1, 1, 0.55 + 0.4 * pulse), 'c')
      if score > 0 then txt(o, k, fmt(scoreShown) .. ' PTS', 12, 202, 62, rgbm(1, 1, 1, 0.7), 'c') end
    end

    para(o, k, 410, 58, 110, 62, 14, C.panel)
    paraLine(o, k, 410, 58, 110, 62, 14, withAlpha(C.accent, 0.4), 1.5)
    txt(o, k, fmtTime(runTime), 24, 465, 66, C.white, 'c')
    txt(o, k, string.format('%d KM/H', math.floor(speed)), 12, 465, 98, active and C.green or C.red, 'c')

    -- multiplier meter + combo timer
    para(o, k, 0, 128, 520, 7, 3, rgbm(1, 1, 1, 0.10))
    local frac = clamp((mult - 1) / (CFG.maxMult - 1), 0, 1)
    if frac > 0.02 then
      local mc = mix(mix(C.accent, C.orange, clamp(frac * 2, 0, 1)), C.red, clamp(frac * 2 - 1, 0, 1))
      para(o, k, 0, 128, 520 * frac, 7, 3, mc)
    end
    if combo > 0 then
      para(o, k, 0, 138, 520 * clamp(comboTimer / CFG.comboWindow, 0, 1), 3, 2, C.gold)
    end

    -- popups
    local y = 150
    for _, p in ipairs(popups) do
      local a = 1
      if p.t < 0.15 then a = p.t / 0.15 end
      if p.t > p.life - 0.5 then a = (p.life - p.t) / 0.5 end
      local ease = 1 - (1 - clamp(p.t / 0.22, 0, 1)) ^ 3
      local size = 20
      local m = ui.measureDWriteText(p.text, size * k)
      local w = m.x / k + 44
      local x = 260 - w / 2 + (1 - ease) * -60
      para(o, k, x, y, w, 34, 10, rgbm(0.05, 0.05, 0.07, 0.8 * a))
      para(o, k, x, y, 7, 34, 10, withAlpha(p.color, a))
      paraLine(o, k, x, y, w, 34, 10, withAlpha(p.color, 0.5 * a), 1.2)
      txt(o, k, p.text, size, x + w / 2 + 3, y + 6, withAlpha(p.color, a), 'c')
      y = y + 40
    end
  end
end

-- leaderboard HUD -------------------------------------------------------------
local function drawBoardHUD()
  local now = os.clock()
  local rows = { { name = myName, best = best, me = true } }
  for _, p in pairs(players) do
    if (now - p.t) < CFG.staleAfter then rows[#rows + 1] = { name = p.name, best = p.best, me = false } end
  end
  table.sort(rows, function(a, b) return a.best > b.best end)
  local count = math.min(#rows, CFG.leaderboardMax)
  local rowH = 32
  local aw, ah = ui.availableSpaceX(), ui.availableSpaceY()
  local k = clamp(math.min(aw / 280, ah / (46 + count * rowH)), 0.2, 6) * 0.97
  local o = ui.getCursor() + vec2(math.max(0, (aw - 280 * k) / 2), 0)
  ui.dummy(vec2(280 * k, (46 + count * rowH) * k))
  do
    para(o, k, 0, 0, 280, 36, 12, C.purple)
    para(o, k, 0, 0, 280, 15, 12, rgbm(1, 1, 1, 0.16))
    txt(o, k, 'LEADERBOARD', 17, 24, 8, C.white)
    txt(o, k, 'BEST', 11, 262, 13, rgbm(1, 1, 1, 0.8), 'r')
    for i = 1, count do
      local r = rows[i]
      local y = 42 + (i - 1) * rowH
      para(o, k, 0, y, 280, rowH - 4, 10, r.me and rgbm(0.35, 0.28, 0.05, 0.85) or C.panel)
      paraLine(o, k, 0, y, 280, rowH - 4, 10, r.me and withAlpha(C.gold, 0.8) or rgbm(1, 1, 1, 0.12), 1.2)
      local medal = (i == 1 and C.gold) or (i == 2 and rgbm(0.82, 0.83, 0.9, 1)) or (i == 3 and rgbm(0.82, 0.5, 0.25, 1)) or C.grey
      para(o, k, 4, y + 3, 26, rowH - 10, 7, withAlpha(medal, 0.9))
      txt(o, k, tostring(i), 15, 17, y + 4, C.dark, 'c')
      local nm = r.name
      if #nm > 14 then nm = nm:sub(1, 13) .. '.' end
      txt(o, k, nm, 15, 42, y + 4, r.me and C.white or C.grey)
      txt(o, k, fmt(r.best), 15, 262, y + 4, r.me and C.gold or C.white, 'r')
    end
  end
end

function script.windowMain(dt) drawScoreHUD() end
function script.windowLeaderboard(dt) drawBoardHUD() end
