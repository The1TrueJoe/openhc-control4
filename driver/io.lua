--[[
  openHC IO — the controller's relays, contacts, IR and serial as Control4
  connections. STATIC, per model.

  One driver per openHC model (openhc-ea3, openhc-hc800, openhc-iox, …), each
  built with its own IO geometry. package.sh prepends the model's counts as

      OHC_IO_GEOM = { serial = N, ir = N, relay = N, contact = N }

  and this file turns them into the fixed binding set. No runtime discovery, no
  dynamic bindings — the connections also sit statically in that model's
  driver.xml, generated from the same table (gen.py).

  package.sh appends this to control4-navigator-sink-lib's driver.lua, so the
  navigator half is the lib's, unchanged; this wraps its entry points and owns
  the IO bindings. On models with no navigator (IOX, CA1) the lib is still the
  base, but no on-screen connections are declared.

  The box side is openHC's iod, over MQTT on the box (Target IP Address : IO
  Port). Everything iod carries is numbered from 1 — the number on the back of
  the box: relay/1 is the first relay, and iod REJECTS relay/0. State topics are
  retained, so subscribing IS the snapshot.

    <prefix>/<id>/state/relay/N     ON | OFF     -> CLOSED / OPENED to the binding
    <prefix>/<id>/state/contact/N   ON | OFF     -> CLOSED / OPENED
    <prefix>/<id>/cmd/relay/N/set   <- ON | OFF   (idempotent in iod)
    <prefix>/<id>/cmd/ir/N/send     <- pronto hex
    <prefix>/<id>/cmd/serial/N/write <- bytes

  Lua 5.1 (no bit operators): MQTT 3.1.1, QoS 0 only, by hand (shared C4MQTT lib).
]]--

-- Binding-id scheme (Control4 ids, fixed): serial 1-4, IR 11-18, relay 21-24,
-- contact 31-34. binding = base + (label - 1); label is iod's 1-based number.
local SCHEME = {
  { kind = "serial",  base = 1  },
  { kind = "ir",      base = 11 },
  { kind = "relay",   base = 21 },
  { kind = "contact", base = 31 },
}

local GEOM = OHC_IO_GEOM or { serial = 0, ir = 0, relay = 0, contact = 0 }
local IO = {}       -- binding id -> { kind, label }   (label is iod's, 1-based)
local BINDING = {}  -- "relay/1" -> binding id
for _, s in ipairs(SCHEME) do
  for i = 0, (tonumber(GEOM[s.kind]) or 0) - 1 do
    local label, id = i + 1, s.base + i
    IO[id] = { kind = s.kind, label = label }
    BINDING[s.kind .. "/" .. label] = id
  end
end

local gMqtt, gMqttUp, gBuf, gBase, gRetrying = nil, false, "", nil, false
local gState = {}  -- "relay/1" -> "ON" | "OFF", as iod last reported

-- ---- MQTT framing -----------------------------------------------------------
-- The MQTT 3.1.1 / QoS 0 framing is the shared control4-lua-mqtt lib (global C4MQTT),
-- concatenated ahead of this file by package.sh. We own only the transport (a
-- C4:CreateTCPClient to the box's broker) and the topic contract.

local function prefix() return Properties["Topic Prefix"] or "openhc" end

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
local function notify(kind, label)
  local id = BINDING[kind .. "/" .. label]
  local s = gState[kind .. "/" .. label]
  if id and s then C4:SendToProxy(id, s == "ON" and "CLOSED" or "OPENED", {}, "NOTIFY") end
end

local function on_publish(topic, payload)
  local id, rest = topic:sub(#prefix() + 2):match("^([^/]+)/(.+)$")
  if not id then return end
  -- iod serves only its own box, so the first id seen is the box's.
  gBase = gBase or (prefix() .. "/" .. id)
  if gBase ~= prefix() .. "/" .. id then return end
  if rest == "status" then io_status(payload .. " (" .. id .. ")") return end
  local kind, label = rest:match("^state/(%a+)/(%d+)$")
  if kind == "relay" or kind == "contact" then
    gState[kind .. "/" .. label] = payload
    notify(kind, tonumber(label))
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
  local k, l = io.kind, io.label
  if k == "relay" then
    local set = "cmd/relay/" .. l .. "/set"
    if cmd == "OPEN" then publish(set, "OFF")
    elseif cmd == "CLOSE" then publish(set, "ON")
    elseif cmd == "TOGGLE" then publish(set, "TOGGLE")
    elseif cmd == "TRIGGER" then
      local was = gState["relay/" .. l] == "ON"
      publish(set, was and "OFF" or "ON")
      C4:SetTimer(tonumber(p.TIME) or 500, function() publish(set, was and "ON" or "OFF") end)
    elseif cmd:match("^GET") then notify(k, l) end
  elseif k == "contact" then
    if cmd:match("^GET") then notify(k, l) end
  elseif k == "ir" then
    local code = find_pronto(p)
    if code then publish("cmd/ir/" .. l .. "/send", code) end
  elseif k == "serial" then
    local data = p.DATA or p.data or p.STRING
    if data then publish("cmd/serial/" .. l .. "/write", data) end
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

-- The box's dashboard is on :80; wire the LINK property once the address is
-- known (SDDP, the Network tab, or typed) so the installer gets a live link.
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
  if bIsBound then notify(io.kind, io.label) end
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
    or strProperty == "IO Token" or strProperty == "Topic Prefix" then
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
