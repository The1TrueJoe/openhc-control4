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

-- MAX_PLAIN = how many non-HDMI audio outputs this model has (OHC_AUDIO_PLAIN,
-- baked per model by gen.py); they occupy 4000..4000+N-1, HDMI is 4072.
local PROXY, HDMI, FIRST, MAX_PLAIN, STEP = 5003, 4072, 4000, OHC_AUDIO_PLAIN or 3, 2

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

-- ---- the stream: audio3server on this Director -> the box's client ----------------
-- Director routes a room to this avswitch (SET_INPUT) but never addcli's a
-- DriverWorks client itself — it does that only for real Control4 controllers. The
-- driver runs on the Director, so it does it: a stream on the local audio3server,
-- the box's zone for the output subscribed, played; removed when the room goes OFF.
-- Zones follow c4zones: non-HDMI outputs 6200.., HDMI 6203.
-- ponytail: the media is ShairBridge's PCM (AirPlay through Control4), the one source
-- wired so far; other Digital Media sources need their URL from the session.
OHC_A3_URL = "c4audio://director:6733?fmt=s16le&fmt.channels=2&fmt.sample_rate=44100"
local gSid

local function zone_of(output)
  output = tonumber(output) or FIRST
  if output >= 7000 then output = output - 3000 end   -- a Room Selection names its output
  return output == HDMI and 6203 or 6200 + (output - FIRST)
end

-- Run audio3server commands in order; each is a function of the stream id so far.
local function a3(cmds, done)
  local i, sid, buf = 0, gSid, ""
  local function step(c)
    i = i + 1
    if not cmds[i] then c:Close(); if done then done(sid) end; return end
    c:Write("o" .. i .. " " .. cmds[i](sid) .. "\r\n")
  end
  C4:CreateTCPClient()
    :OnConnect(function(c) step(c); c:ReadAtLeast(1) end)
    :OnRead(function(c, data)
      buf = buf .. data
      for line in buf:gmatch("([^\r\n]*)\r?\n") do
        sid = sid or line:match("^o1 ADDSTR STREAM=(%d+)")
        if line:match("^o" .. i .. " OK") or line:match("^o" .. i .. " NO") or line:match("^o" .. i .. " BAD") then
          step(c)
        end
      end
      buf = buf:match("[^\n]*$")
      c:ReadAtLeast(1)
    end)
    :Connect("127.0.0.1", 6000)
end

local function stop_stream()
  if gSid then local sid = gSid; gSid = nil; a3({ function() return "REMSTR " .. sid end }) end
end

local function start_stream(output)
  local ip = Properties["Target IP Address"] or ""
  if ip == "" then return end
  stop_stream()
  a3({ function() return "ADDSTR" end,
       function(sid) return "ADDMED " .. sid .. " " .. OHC_A3_URL end,
       function(sid) return "ADDCLI " .. sid .. " " .. ip .. " " .. zone_of(output) end,
       function(sid) return "SETSTA " .. sid .. " PLAY" end },
     function(sid) gSid = sid; C4:UpdateProperty("Last IO Command", "audio stream " .. tostring(sid) .. " -> " .. ip .. ":" .. zone_of(output)) end)
end

-- ---- Director -> box -----------------------------------------------------------
local prevReceivedFromProxy = ReceivedFromProxy
function ReceivedFromProxy(idBinding, strCommand, tParams)
  -- The audio avswitch has one input (the 3003 client) wired to every output. Confirm
  -- the switch (Director waits for it) and start the stream to the box.
  if idBinding == PROXY and strCommand == "SET_INPUT" then
    C4:SendToProxy(PROXY, "INPUT_OUTPUT_CHANGED", { INPUT = tParams.INPUT, OUTPUT = tParams.OUTPUT }, "NOTIFY")
    start_stream(tParams.OUTPUT)
    return
  end
  if idBinding == PROXY and (strCommand == "OFF" or strCommand == "DISCONNECT_OUTPUT") then
    stop_stream()
    return
  end
  if idBinding == PROXY and (strCommand == "ON" or strCommand == "CONNECT_OUTPUT") then
    return   -- nothing to power or patch on the box
  end
  local b = tParams and tonumber(tParams.OUTPUT)
  local run = idBinding == PROXY and COMMANDS[strCommand]
  if run and b and gOutputs[b] then
    C4:UpdateProperty("Last IO Command", "audio " .. strCommand .. " OUTPUT=" .. b .. " (" .. gOutputs[b] .. ")")
    return run(b, tParams)
  end
  return prevReceivedFromProxy(idBinding, strCommand, tParams)
end
