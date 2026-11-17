--[[
  openHC audio — Control4 room volume and mute on the box's audio outputs.

  package.sh appends this after io.lua. The audio itself needs no Lua:
  Director streams Digital Media to the box's audio client (c4-audio-client on
  :6100) through the Digital Audio Client input, one zone per output. This
  layer only carries volume.

  Volume has one owner on the box: openHC's audiod, whose per-output level is
  also what its AirPlay/Spotify sliders and web UI set. The client's zones sit
  at 100 (c4zones writes them so), and the driver drives audiod over the same
  MQTT link io.lua already holds:

    <base>/state/audio/map           which outputs the box has, HDMI last (JSON)
    <base>/state/audio/level/<id>    0-100 -> VOLUME_LEVEL_CHANGED
    <base>/cmd/audio/level/<id>      <- 0-100

  Outputs map onto connections the same way c4zones maps them onto ports:
  the non-HDMI outputs in order to Audio Output 1-3 (4000-4002), HDMI to 4072.
  Mute is level 0 with the level remembered (audiod has no mute of its own).

  Which proxy commands Director sends a controller's own outputs is not yet
  captured on hardware; this takes the amp set (SET_VOLUME_LEVEL, PULSE_*,
  START_/STOP_VOL_*, MUTE_*) with OUTPUT = the connection id, and "Last IO
  Command" shows what actually arrives.
]]--

local PROXY, HDMI, FIRST, MAX_PLAIN, STEP = 5001, 4072, 4000, 3, 2

local gOutputs = {}               -- connection id -> audiod output id
local gLevel, gMuted, gRamp = {}, {}, {}

local function map_outputs(outputs)
  local m, plain = {}, 0
  for _, o in ipairs(outputs or {}) do
    if o.id == "hdmi" then
      m[HDMI] = o.id
    elseif o.id and plain < MAX_PLAIN then
      m[FIRST + plain] = o.id
      plain = plain + 1
    end
  end
  return m
end

local function binding_of(id)
  for b, i in pairs(gOutputs) do if i == id then return b end end
end

local function report(b)
  C4:SendToProxy(PROXY, "VOLUME_LEVEL_CHANGED", { OUTPUT = b, LEVEL = gLevel[b] or 0 }, "NOTIFY")
  C4:SendToProxy(PROXY, "MUTE_CHANGED", { OUTPUT = b, MUTE = gMuted[b] and "True" or "False" }, "NOTIFY")
end

local function level_to_box(b, level)
  OHC_PUBLISH("cmd/audio/level/" .. gOutputs[b], tostring(level))
end

local function set_level(b, level)
  level = math.max(0, math.min(100, math.floor(tonumber(level) or 0)))
  gLevel[b], gMuted[b] = level, false
  level_to_box(b, level)
  report(b)
end

local function set_mute(b, on)
  gMuted[b] = on
  level_to_box(b, on and 0 or (gLevel[b] or 0))
  report(b)
end

local function stop_ramp(b)
  if gRamp[b] then pcall(function() gRamp[b]:Cancel() end) end
  gRamp[b] = nil
end

local COMMANDS = {
  SET_VOLUME_LEVEL = function(b, p) set_level(b, p.LEVEL) end,
  PULSE_VOL_UP     = function(b) set_level(b, (gLevel[b] or 0) + STEP) end,
  PULSE_VOL_DOWN   = function(b) set_level(b, (gLevel[b] or 0) - STEP) end,
  START_VOL_UP     = function(b)
    stop_ramp(b)
    gRamp[b] = C4:SetTimer(250, function() set_level(b, (gLevel[b] or 0) + STEP) end, true)
  end,
  START_VOL_DOWN   = function(b)
    stop_ramp(b)
    gRamp[b] = C4:SetTimer(250, function() set_level(b, (gLevel[b] or 0) - STEP) end, true)
  end,
  STOP_VOL_UP      = function(b) stop_ramp(b) end,
  STOP_VOL_DOWN    = function(b) stop_ramp(b) end,
  MUTE_ON          = function(b) set_mute(b, true) end,
  MUTE_OFF         = function(b) set_mute(b, false) end,
  MUTE_TOGGLE      = function(b) set_mute(b, not gMuted[b]) end,
}

-- ---- box -> Director (state topics io.lua does not handle itself) --------------
local prevState = OHC_STATE
function OHC_STATE(rest, payload)
  if rest == "state/audio/map" then
    local ok, t = pcall(C4.JsonDecode, C4, payload)
    if ok and type(t) == "table" then gOutputs = map_outputs(t.outputs) end
  else
    local id = rest:match("^state/audio/level/(.+)$")
    local b = id and binding_of(id)
    local l = b and tonumber(payload)
    if l then
      -- Level 0 while muted is our own mute coming back; anything else is the
      -- level (a slider elsewhere unmutes, as it would on an amp).
      if not (gMuted[b] and l == 0) then gLevel[b], gMuted[b] = l, false end
      report(b)
    end
  end
  if prevState then prevState(rest, payload) end
end

-- ---- Director -> box -----------------------------------------------------------
local prevReceivedFromProxy = ReceivedFromProxy
function ReceivedFromProxy(idBinding, strCommand, tParams)
  local b = tParams and tonumber(tParams.OUTPUT)
  local run = idBinding == PROXY and COMMANDS[strCommand]
  if run and b and gOutputs[b] then
    C4:UpdateProperty("Last IO Command", "audio " .. strCommand .. " OUTPUT=" .. b .. " (" .. gOutputs[b] .. ")")
    return run(b, tParams)
  end
  return prevReceivedFromProxy(idBinding, strCommand, tParams)
end
