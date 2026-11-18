--[[
  openHC IO — the controller's relays, contacts, IR and serial as Control4
  connections.

  package.sh appends this to control4-navigator-sink-lib's driver.lua, so the
  navigator half is the lib's, unchanged; this wraps its entry points and
  handles only the IO bindings.

  The box side is openHC's iod, reached the way any outside control system
  reaches it: MQTT on the box (Target IP Address : IO Port). State topics are
  retained, so subscribing IS the snapshot — a reconnect re-reports every relay
  and contact with no separate query.

    <prefix>/<id>/state/relay/N    ON | OFF      -> CLOSED / OPENED to the binding
    <prefix>/<id>/state/contact/N  ON | OFF      -> CLOSED / OPENED
    <prefix>/<id>/cmd/relay/N/set  <- ON | OFF   (idempotent in iod)
    <prefix>/<id>/cmd/ir/N/send    <- pronto hex
    <prefix>/<id>/cmd/serial/N/write <- bytes

  Lua 5.1 (no bit operators): MQTT 3.1.1, QoS 0 only, by hand.
]]--

local IO = {}   -- binding id -> { kind, index }  (index is iod's, 0-based)
for i = 0, 3 do IO[1 + i]  = { kind = "serial",  index = i } end
for i = 0, 7 do IO[11 + i] = { kind = "ir",      index = i } end
for i = 0, 3 do IO[21 + i] = { kind = "relay",   index = i } end
for i = 0, 3 do IO[31 + i] = { kind = "contact", index = i } end
local BINDING = {} -- "relay/0" -> binding id
for id, io in pairs(IO) do BINDING[io.kind .. "/" .. io.index] = id end

local gMqtt, gMqttUp, gBuf, gBase, gRetrying = nil, false, "", nil, false
local gState = {}  -- "relay/0" -> "ON" | "OFF", as iod last reported

-- ---- MQTT framing -----------------------------------------------------------
-- The MQTT 3.1.1 / QoS 0 framing is the shared control4-lua-mqtt lib (global C4MQTT),
-- concatenated ahead of this file by package.sh. We own only the transport (a
-- C4:CreateTCPClient to the box's broker) and the topic contract.

local function prefix() return Properties["IO Topic Prefix"] or "openhc" end

local function io_status(s) C4:UpdateProperty("IO Status", s) end

local function publish(topic, payload)
  if not (gMqttUp and gBase) then
    io_status("not connected; dropped " .. topic)
    return
  end
  gMqtt:Write(C4MQTT.publish(gBase .. "/" .. topic, payload))
end

-- For the layers appended after this one (audio.lua): publish under the box's base.
OHC_PUBLISH = publish

-- ---- iod -> Director ----------------------------------------------------------
local function notify(kind, index)
  local id = BINDING[kind .. "/" .. index]
  local s = gState[kind .. "/" .. index]
  if id and s then C4:SendToProxy(id, s == "ON" and "CLOSED" or "OPENED", {}, "NOTIFY") end
end

local function on_publish(topic, payload)
  local id, rest = topic:sub(#prefix() + 2):match("^([^/]+)/(.+)$")
  if not id then return end
  -- iod serves only its own box, so the first id seen is the box's.
  gBase = gBase or (prefix() .. "/" .. id)
  if gBase ~= prefix() .. "/" .. id then return end
  if rest == "status" then io_status(payload .. " (" .. id .. ")") return end
  local kind, index = rest:match("^state/(%a+)/(%d+)$")
  if kind == "relay" or kind == "contact" then
    gState[kind .. "/" .. index] = payload
    notify(kind, tonumber(index))
  elseif OHC_STATE then
    OHC_STATE(rest, payload) -- the rest of the box's state (audio.lua)
  end
end

local MQTT_HANDLERS = {
  connack = function(rc)
    if rc ~= 0 then
      io_status("refused (" .. rc .. ") - check IO Token")
    else
      gMqttUp = true
      io_status("connected " .. TargetIP)
      local p = prefix()
      gMqtt:Write(C4MQTT.subscribe(1, { p .. "/+/status", p .. "/+/state/#" }))
    end
  end,
  publish = on_publish,
}

local function on_bytes(data) gBuf = C4MQTT.parse(gBuf .. data, MQTT_HANDLERS) end

local mqtt_connect

local function retry(why)
  gMqttUp = false
  io_status(why)
  if gRetrying then return end
  gRetrying = true
  C4:SetTimer(5000, function() gRetrying = false; mqtt_connect() end)
end

mqtt_connect = function()
  if gMqtt then pcall(function() gMqtt:Close() end) end
  gMqttUp, gBuf, gBase = false, "", nil
  local token = Properties["IO Token"] or ""
  local connect = C4MQTT.connect("c4-" .. tostring(C4:GetDeviceID()),
    { keepalive = 60, user = token ~= "" and "control4" or nil, pass = token ~= "" and token or nil })
  gMqtt = C4:CreateTCPClient()
    :OnConnect(function(c) c:Write(connect); c:ReadAtLeast(1) end)
    :OnRead(function(c, data) on_bytes(data); c:ReadAtLeast(1) end)
    :OnDisconnect(function() retry("disconnected") end)
    :OnError(function(_, err) retry("error: " .. tostring(err)) end)
    :Connect(TargetIP, tonumber(Properties["IO Port"]) or 1883)
end

-- ---- Director -> iod ----------------------------------------------------------
local function describe(t)
  local parts = {}
  for k, v in pairs(t) do parts[#parts + 1] = tostring(k) .. "=" .. tostring(v):sub(1, 40) end
  return table.concat(parts, " ")
end

local function find_pronto(t)
  for _, v in pairs(t) do
    if type(v) == "string" and v:match("^%s*%x%x%x%x %x%x%x%x") then return v end
  end
end

-- What Director sends an IR_OUT / RS_232 provider is not yet captured on
-- hardware, so those take any Pronto-looking / data parameter; "Last IO
-- Command" shows what actually arrives.
local function io_command(io, cmd, p)
  local k, i = io.kind, io.index
  if k == "relay" then
    local set = "cmd/relay/" .. i .. "/set"
    if cmd == "OPEN" then publish(set, "OFF")
    elseif cmd == "CLOSE" then publish(set, "ON")
    elseif cmd == "TOGGLE" then publish(set, "TOGGLE")
    elseif cmd == "TRIGGER" then
      local was = gState["relay/" .. i] == "ON"
      publish(set, was and "OFF" or "ON")
      C4:SetTimer(tonumber(p.TIME) or 500, function() publish(set, was and "ON" or "OFF") end)
    elseif cmd:match("^GET") then notify(k, i) end
  elseif k == "contact" then
    if cmd:match("^GET") then notify(k, i) end
  elseif k == "ir" then
    local code = find_pronto(p)
    if code then publish("cmd/ir/" .. i .. "/send", code) end
  elseif k == "serial" then
    local data = p.DATA or p.data or p.STRING
    if data then publish("cmd/serial/" .. i .. "/write", data) end
  end
end

-- ---- the box's address ---------------------------------------------------------
-- Composer fills the Network connection from SDDP discovery (c4sddp on the box)
-- or the Network tab; Target IP Address follows it, so nothing is typed twice.
local NET = 6001

local function take_binding_address()
  local addr = C4:GetBindingAddress(NET)
  if addr and addr ~= "" and addr ~= Properties["Target IP Address"] then
    C4:UpdateProperty("Target IP Address", addr)
    return true
  end
end

local function show_web_ui()
  local ip = Properties["Target IP Address"] or ""
  C4:UpdateProperty("openHC Web UI", ip ~= "" and ("http://" .. ip .. "/") or "")
end

-- ---- entry points: IO bindings here, everything else to the navigator ----------
local navReceivedFromProxy, navOnBindingChanged = ReceivedFromProxy, OnBindingChanged
local navOnPropertyChanged, navOnDriverLateInit, navOnDriverDestroyed =
  OnPropertyChanged, OnDriverLateInit, OnDriverDestroyed

function ReceivedFromProxy(idBinding, strCommand, tParams)
  local io = IO[idBinding]
  if not io then return navReceivedFromProxy(idBinding, strCommand, tParams) end
  tParams = tParams or {}
  C4:UpdateProperty("Last IO Command", idBinding .. " " .. tostring(strCommand) .. " " .. describe(tParams))
  io_command(io, tostring(strCommand), tParams)
end

function OnBindingChanged(idBinding, class, bIsBound)
  local io = IO[idBinding]
  if not io then return navOnBindingChanged(idBinding, class, bIsBound) end
  if bIsBound then notify(io.kind, io.index) end
end

function OnNetworkBindingChanged(idBinding, bIsBound)
  if idBinding == NET and bIsBound and take_binding_address() then
    OnPropertyChanged("Target IP Address")
  end
end

function OnPropertyChanged(strProperty)
  navOnPropertyChanged(strProperty)
  if strProperty == "Target IP Address" then show_web_ui() end
  if strProperty == "Target IP Address" or strProperty == "IO Port"
    or strProperty == "IO Token" or strProperty == "IO Topic Prefix" then
    mqtt_connect()
  end
end

function OnDriverLateInit()
  take_binding_address()
  show_web_ui()
  navOnDriverLateInit()
  mqtt_connect()
  -- PINGREQ well inside the 60 s keepalive.
  C4:SetTimer(30000, function() if gMqttUp then gMqtt:Write(string.char(0xC0, 0)) end end, true)
end

function OnDriverDestroyed()
  navOnDriverDestroyed()
  if gMqtt then pcall(function() gMqtt:Close() end) end
end
