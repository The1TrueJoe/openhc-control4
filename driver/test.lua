-- Self-check for io.lua against a stubbed Director: `./package.sh && lua test.lua`.
-- Feeds hand-encoded MQTT 3.1.1 bytes in and checks the bytes and notifies out,
-- and the dynamic IO bindings the driver adds from iod's /api/io.

Properties = { ["Target IP Address"] = "", ["Target Port"] = "9010",
  ["IO Port"] = "1883", ["IO Token"] = "", ["IO Topic Prefix"] = "openhc",
  ["Send Project Token"] = "No" }

local writes, notifies, timers, mqtt = {}, {}, {}, nil
local dyn, persist, urlReq = {}, {}, nil   -- dynamic bindings, PersistData, pending C4:url()

local function client()
  local c, h = {}, {}
  for _, ev in ipairs({ "OnConnect", "OnRead", "OnDisconnect", "OnError" }) do
    c[ev] = function(self, f) h[ev] = f; return self end
  end
  function c:Connect(ip, port) self.port, self.ip = port, ip; if port == 1883 then mqtt = self end; return self end
  function c:Write(b) if self.port == 1883 then writes[#writes + 1] = b end end
  function c:ReadAtLeast() end
  function c:Close() end
  c.h = h
  return c
end

C4 = {
  CreateTCPClient = client,
  UpdateProperty = function(_, k, v) Properties[k] = v end,
  -- Discovery/Network tab identifies the box: the driver takes that address.
  GetBindingAddress = function(_, id) return id == 6001 and "10.0.0.9" or "" end,
  SetTimer = function(_, ms, f, rep) timers[#timers + 1] = { ms = ms, f = f, rep = rep } end,
  SendToProxy = function(_, id, cmd) notifies[#notifies + 1] = id .. " " .. cmd end,
  GetDeviceID = function() return 42 end,
  -- Dynamic IO bindings.
  AddDynamicBinding = function(_, id, typ, prov, name, class, hidden, auto)
    dyn[id] = { typ = typ, prov = prov, name = name, class = class }
  end,
  RemoveDynamicBinding = function(_, id) dyn[id] = nil end,
  PersistSetValue = function(_, k, v) persist[k] = v end,
  PersistGetValue = function(_, k) return persist[k] end,
  JsonDecode = function(_, s) return (loadstring or load)("return " .. s)() end,
}

-- C4:url() — fluent, per-call callback (like the navigator half's token mint).
-- fetch_geometry is the only user here (token mint is off), so capture its OnDone.
C4.url = function()
  local u = {}
  function u:SetOptions() return self end
  function u:OnDone(f) self.done = f; return self end
  function u:Get(url) urlReq = { done = self.done, url = url }; return self end
  function u:Post() return self end
  return u
end

dofile("build/driver.lua")

-- A reload restores bindings from persisted counts BEFORE the box is reachable,
-- so Composer reconnects whatever was bound. Here: an earlier, smaller geometry.
persist["io_geom"] = "0,2,2,2"
OnDriverInit()
assert(dyn[11] and dyn[21] and dyn[31] and dyn[22], "restored 2 IR/relay/contact")
assert(dyn[1] == nil and dyn[23] == nil and dyn[13] == nil, "nothing beyond the persisted counts")

OnDriverLateInit()   -- takes 10.0.0.9 from binding 6001, then queries /api/io

assert(Properties["Target IP Address"] == "10.0.0.9")
assert(Properties["openHC Web UI"] == "http://10.0.0.9/")

-- iod answers GET :7070/api/io with this board's geometry; the driver adds a
-- dynamic CONTROL binding per port (serial/IR/relay/contact) and persists counts.
assert(urlReq and urlReq.url == "http://10.0.0.9:7070/api/io", tostring(urlReq and urlReq.url))
urlReq.done(nil, { { code = 200, body =
  '{relays={count=4},contacts={count=4},serials={{},{}},ir={out=4}}' } }, 0, nil)

-- Live geometry grows the restored set (2 -> 4 relays/contacts, +serial, +IR).
assert(dyn[21] and dyn[21].class == "RELAY" and dyn[21].prov == true, "relay 1 -> binding 21")
assert(dyn[24] and dyn[24].class == "RELAY", "relay 4 -> binding 24")
assert(dyn[31] and dyn[31].class == "CONTACT_SENSOR", "contact 1 -> binding 31")
assert(dyn[1]  and dyn[1].class  == "RS_232", "serial 1 -> binding 1")
assert(dyn[2]  and dyn[2].class  == "RS_232" and dyn[3] == nil, "only 2 serials")
assert(dyn[11] and dyn[11].class == "IR_OUT" and dyn[14] and dyn[15] == nil, "4 IR outs")
-- Persisted as serial,ir,relay,contact so a reload restores before the box is up.
assert(persist["io_geom"] == "2,4,4,4", tostring(persist["io_geom"]))

local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function str(s) return string.char(math.floor(#s / 256), #s % 256) .. s end
local function last() return writes[#writes] end

-- CONNECT on connect: protocol MQTT v4, clean session, keepalive 60, id "c4-42".
mqtt.h.OnConnect(mqtt)
assert(hex(last()) == "101100044d5154540402003c0005" .. hex("c4-42"), hex(last()))

-- CONNACK accepted -> SUBSCRIBE to status + state.
mqtt.h.OnRead(mqtt, "\32\2\0\0")
assert(last() == "\130" .. string.char(2 + 2 + 15 + 1 + 2 + 16 + 1) .. "\0\1"
  .. str("openhc/+/status") .. "\0" .. str("openhc/+/state/#") .. "\0", hex(last()))

-- Retained state (iod numbers from 1): relay/1 -> binding 21, contact/2 -> 32.
local function pub(topic, payload) local b = str(topic) .. payload; return "\48" .. string.char(#b) .. b end
local bytes = pub("openhc/ea3/state/relay/1", "ON") .. pub("openhc/ea3/state/contact/2", "OFF")
mqtt.h.OnRead(mqtt, bytes:sub(1, 7))
mqtt.h.OnRead(mqtt, bytes:sub(8))
assert(notifies[1] == "21 CLOSED" and notifies[2] == "32 OPENED", table.concat(notifies, ","))

-- Director -> relay: OPEN relay 1 (binding 21) publishes OFF to relay/1.
ReceivedFromProxy(21, "OPEN", {})
assert(last() == pub("openhc/ea3/cmd/relay/1/set", "OFF"), hex(last()))

-- TRIGGER on a closed relay: open now, close again after TIME.
ReceivedFromProxy(21, "TRIGGER", { TIME = "250" })
assert(last() == pub("openhc/ea3/cmd/relay/1/set", "OFF"))
timers[#timers].f()
assert(timers[#timers].ms == 250 and last() == pub("openhc/ea3/cmd/relay/1/set", "ON"))

-- IR: binding 13 is IR output 3 (label 3); the Pronto parameter goes to ir/3/send.
ReceivedFromProxy(13, "SEND_IR", { CODE = "0000 006D 0000 0002 0010 0010" })
assert(last() == pub("openhc/ea3/cmd/ir/3/send", "0000 006D 0000 0002 0010 0010"))

-- Audio: audiod's retained output map (HDMI last) lands Audio Output 1-3 and
-- HDMI (4072) on its outputs; room volume becomes audiod's level for that output.
C4.JsonDecode = function() return { outputs = {
  { id = "analog1" }, { id = "analog2" }, { id = "coax" }, { id = "hdmi" } } } end
local reports = {}
C4.SendToProxy = function(_, id, cmd, p) reports[#reports + 1] = cmd .. " " .. tostring(p and (p.LEVEL or p.MUTE)) end
mqtt.h.OnRead(mqtt, pub("openhc/ea3/state/audio/map", "{}"))
ReceivedFromProxy(5001, "SET_VOLUME_LEVEL", { OUTPUT = "4072", LEVEL = "40" })
assert(last() == pub("openhc/ea3/cmd/audio/level/hdmi", "40"), hex(last()))
ReceivedFromProxy(5001, "PULSE_VOL_UP", { OUTPUT = "4001" })
assert(last() == pub("openhc/ea3/cmd/audio/level/analog2", "2"))
-- Mute is level 0 with the level kept: audiod echoing 0 back stays muted, unmute restores 40.
ReceivedFromProxy(5001, "MUTE_ON", { OUTPUT = "4072" })
assert(last() == pub("openhc/ea3/cmd/audio/level/hdmi", "0"))
mqtt.h.OnRead(mqtt, pub("openhc/ea3/state/audio/level/hdmi", "0"))
assert(reports[#reports] == "MUTE_CHANGED True", reports[#reports])
ReceivedFromProxy(5001, "MUTE_OFF", { OUTPUT = "4072" })
assert(last() == pub("openhc/ea3/cmd/audio/level/hdmi", "40"))
-- A level set on the box (an AirPlay slider) is reported to Director.
mqtt.h.OnRead(mqtt, pub("openhc/ea3/state/audio/level/coax", "55"))
assert(reports[#reports - 1] == "VOLUME_LEVEL_CHANGED 55", reports[#reports - 1])

-- Non-IO bindings still reach the navigator half (it answers this one).
local sent
C4.SendToProxy = function(_, id, cmd) sent = id .. " " .. cmd end
ReceivedFromProxy(5001, "GET_CONTROLLER_DISABLED", {})
assert(sent == "5001 CONTROLLER_DISABLED", tostring(sent))

print("io.lua: ok")
