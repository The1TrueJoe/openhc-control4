--[[
  openHC IO — the controller's relays, contacts, IR and serial as Control4
  connections, added DYNAMICALLY from what the box reports.

  One driver, one SDDP type (openhc:device) serves every openHC model: an EA1
  with no relays and an EA3 with four look the same in the project until the box
  is paired, then each shows exactly the IO it has. There is no hardcoded
  superset and no per-model driver.

  package.sh appends this to control4-navigator-sink-lib's driver.lua, so the
  navigator half is the lib's, unchanged; this wraps its entry points and owns
  the IO bindings.

  Geometry comes from iod's REST surface once the box's address is known:

      GET http://<box>:7070/api/io
        { "relays": {"count":R}, "contacts": {"count":C},
          "serials": [ ... S ... ], "ir": {"out":I, ...} }

  For each the driver calls C4:AddDynamicBinding (type CONTROL, provider), then
  persists the counts so the bindings — and any Composer connections to them —
  come back on the next load before the box is reachable.

  The box side is openHC's iod, reached over MQTT on the box (Target IP Address :
  IO Port). Everything iod carries is numbered from 1 (the number printed on the
  back of the box): relay/1 is the first relay, and iod REJECTS relay/0. State
  topics are retained, so subscribing IS the snapshot.

    <prefix>/<id>/state/relay/N     ON | OFF     -> CLOSED / OPENED to the binding
    <prefix>/<id>/state/contact/N   ON | OFF     -> CLOSED / OPENED
    <prefix>/<id>/cmd/relay/N/set   <- ON | OFF   (idempotent in iod)
    <prefix>/<id>/cmd/ir/N/send     <- pronto hex
    <prefix>/<id>/cmd/serial/N/write <- bytes

  Lua 5.1 (no bit operators): MQTT 3.1.1, QoS 0 only, by hand (shared C4MQTT lib).
]]--

-- Binding-id scheme (Control4 ids, fixed): serial 1-4, IR 11-18, relay 21-24,
-- contact 31-34. For each kind, binding = base + (label - 1); label is iod's
-- 1-based panel number. `provider` is the controller's side of the connection.
local SCHEME = {
  serial  = { base = 1,  max = 4, class = "RS_232",         name = "Serial %d" },
  ir      = { base = 11, max = 8, class = "IR_OUT",         name = "IR Output %d" },
  relay   = { base = 21, max = 4, class = "RELAY",          name = "Relay %d" },
  contact = { base = 31, max = 4, class = "CONTACT_SENSOR", name = "Contact %d" },
}
local ORDER = { "serial", "ir", "relay", "contact" }

local IO = {}       -- binding id -> { kind, label }   (label is iod's, 1-based)
local BINDING = {}  -- "relay/1" -> binding id
local gApplied = {} -- kind -> how many bindings currently added
for _, k in ipairs(ORDER) do gApplied[k] = 0 end

local gMqtt, gMqttUp, gBuf, gBase, gRetrying = nil, false, "", nil, false
local gState = {}  -- "relay/1" -> "ON" | "OFF", as iod last reported

-- ---- dynamic IO bindings -----------------------------------------------------
-- Grow or shrink the IO bindings to a geometry { serial=, ir=, relay=, contact= }.
-- Hardware does not change at runtime, so in practice this only ever adds.
local function apply_geometry(geom)
  for _, kind in ipairs(ORDER) do
    local s = SCHEME[kind]
    local want = math.max(0, math.min(tonumber(geom[kind]) or 0, s.max))
    local have = gApplied[kind]
    for i = have, want - 1 do          -- add
      local label, id = i + 1, s.base + i
      C4:AddDynamicBinding(id, "CONTROL", true, string.format(s.name, label), s.class, false, false)
      IO[id] = { kind = kind, label = label }
      BINDING[kind .. "/" .. label] = id
    end
    for i = want, have - 1 do          -- remove (board swapped for a smaller one)
      local label, id = i + 1, s.base + i
      C4:RemoveDynamicBinding(id)
      IO[id] = nil
      BINDING[kind .. "/" .. label] = nil
    end
    gApplied[kind] = want
  end
end

-- Persist the counts so bindings (and their Composer connections) survive a
-- reload even while the box is unreachable. "serial,ir,relay,contact".
local function persist_geometry(geom)
  C4:PersistSetValue("io_geom", table.concat(
    { geom.serial or 0, geom.ir or 0, geom.relay or 0, geom.contact or 0 }, ","))
end

local function restore_geometry()
  local s = C4:PersistGetValue("io_geom")
  if type(s) ~= "string" or s == "" then return end
  local a, b, c, d = s:match("^(%d+),(%d+),(%d+),(%d+)$")
  if a then apply_geometry({ serial = a, ir = b, relay = c, contact = d }) end
end

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

local function show_web_ui()
  local ip = Properties["Target IP Address"] or ""
  C4:UpdateProperty("openHC Web UI", ip ~= "" and ("http://" .. ip .. "/") or "")
end

-- Ask iod what IO this board has, then add exactly those bindings. iod's REST is
-- on :7070; a fluent C4:url() keeps its own callback, so it does not collide
-- with the navigator half's token mint.
local function fetch_geometry()
  local ip = Properties["Target IP Address"] or ""
  if ip == "" then return end
  local headers = {}
  local tok = Properties["IO Token"] or ""
  if tok ~= "" then headers["Authorization"] = "Bearer " .. tok end
  C4:url()
    :SetOptions({ timeout = 10, fail_on_error = false })
    :OnDone(function(_, responses, errCode, errMsg)
      local r = responses and responses[#responses]
      if not (r and r.code == 200 and r.body) then
        io_status("io query failed: " .. tostring(r and r.code or errMsg or errCode))
        return
      end
      local ok, j = pcall(C4.JsonDecode, C4, r.body)
      if not (ok and type(j) == "table") then
        io_status("io query: bad JSON")
        return
      end
      local geom = {
        relay   = (type(j.relays) == "table")   and tonumber(j.relays.count)   or 0,
        contact = (type(j.contacts) == "table") and tonumber(j.contacts.count) or 0,
        serial  = (type(j.serials) == "table")  and #j.serials                 or 0,
        ir      = (type(j.ir) == "table")       and tonumber(j.ir.out)         or 0,
      }
      persist_geometry(geom)
      apply_geometry(geom)
    end)
    :Get("http://" .. ip .. ":7070/api/io", headers)
end

-- ---- entry points: IO bindings here, everything else to the navigator ----------
local navReceivedFromProxy, navOnBindingChanged = ReceivedFromProxy, OnBindingChanged
local navOnPropertyChanged, navOnDriverInit, navOnDriverLateInit, navOnDriverDestroyed =
  OnPropertyChanged, OnDriverInit, OnDriverLateInit, OnDriverDestroyed

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
  if strProperty == "Target IP Address" then show_web_ui(); fetch_geometry() end
  if strProperty == "Target IP Address" or strProperty == "IO Port"
    or strProperty == "IO Token" or strProperty == "IO Topic Prefix" then
    mqtt_connect()
  end
end

-- Dynamic bindings must be re-added on init, BEFORE OnDriverLateInit, so
-- Composer reconnects whatever was bound to them. Restore from persisted counts;
-- the live fetch in late-init then corrects them if the hardware changed.
function OnDriverInit()
  navOnDriverInit()
  restore_geometry()
end

function OnDriverLateInit()
  take_binding_address()
  show_web_ui()
  navOnDriverLateInit()
  mqtt_connect()
  fetch_geometry()
  -- PINGREQ well inside the 60 s keepalive.
  C4:SetTimer(30000, function() if gMqttUp then gMqtt:Write(string.char(0xC0, 0)) end end, true)
end

function OnDriverDestroyed()
  navOnDriverDestroyed()
  if gMqtt then pcall(function() gMqtt:Close() end) end
end
