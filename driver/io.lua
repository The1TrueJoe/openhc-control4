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
local function u16(n) return string.char(math.floor(n / 256) % 256, n % 256) end
local function mstr(s) return u16(#s) .. s end

local function packet(hdr, body)
  local n, len = #body, ""
  repeat
    local d = n % 128
    n = math.floor(n / 128)
    if n > 0 then d = d + 128 end
    len = len .. string.char(d)
  until n == 0
  return string.char(hdr) .. len .. body
end

local function prefix() return Properties["IO Topic Prefix"] or "openhc" end

local function io_status(s) C4:UpdateProperty("IO Status", s) end

local function publish(topic, payload)
  if not (gMqttUp and gBase) then
    io_status("not connected; dropped " .. topic)
    return
  end
  gMqtt:Write(packet(0x30, mstr(gBase .. "/" .. topic) .. payload))
end

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
  end
end

local function on_bytes(data)
  gBuf = gBuf .. data
  while #gBuf >= 2 do
    local mult, len, pos = 1, 0, 2
    repeat
      if pos > #gBuf then return end
      local d = gBuf:byte(pos)
      len = len + (d % 128) * mult
      mult = mult * 128
      pos = pos + 1
    until d < 128
    if #gBuf < pos - 1 + len then return end
    local first = gBuf:byte(1)
    local body = gBuf:sub(pos, pos + len - 1)
    gBuf = gBuf:sub(pos + len)
    local typ, qos = math.floor(first / 16), math.floor(first / 2) % 4
    if typ == 2 then -- CONNACK
      if body:byte(2) ~= 0 then
        io_status("refused (" .. body:byte(2) .. ") - check IO Token")
      else
        gMqttUp = true
        io_status("connected " .. TargetIP)
        local p = prefix()
        gMqtt:Write(packet(0x82, u16(1) .. mstr(p .. "/+/status") .. "\0" .. mstr(p .. "/+/state/#") .. "\0"))
      end
    elseif typ == 3 then -- PUBLISH
      local tl = body:byte(1) * 256 + body:byte(2)
      on_publish(body:sub(3, 2 + tl), body:sub(3 + tl + (qos > 0 and 2 or 0)))
    end
  end
end

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
  local body = mstr("MQTT") .. string.char(4, token ~= "" and 0xC2 or 0x02) .. u16(60)
    .. mstr("c4-" .. tostring(C4:GetDeviceID()))
  if token ~= "" then body = body .. mstr("control4") .. mstr(token) end
  gMqtt = C4:CreateTCPClient()
    :OnConnect(function(c) c:Write(packet(0x10, body)); c:ReadAtLeast(1) end)
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

function OnPropertyChanged(strProperty)
  navOnPropertyChanged(strProperty)
  if strProperty == "Target IP Address" or strProperty == "IO Port"
    or strProperty == "IO Token" or strProperty == "IO Topic Prefix" then
    mqtt_connect()
  end
end

function OnDriverLateInit()
  navOnDriverLateInit()
  mqtt_connect()
  -- PINGREQ well inside the 60 s keepalive.
  C4:SetTimer(30000, function() if gMqttUp then gMqtt:Write(string.char(0xC0, 0)) end end, true)
end

function OnDriverDestroyed()
  navOnDriverDestroyed()
  if gMqtt then pcall(function() gMqtt:Close() end) end
end
