-- Self-check for io.lua against a stubbed Director: `./package.sh && lua test.lua`.
-- Loads the generated EA3 driver (static geometry: 3 serial, 6 IR, 1 relay,
-- 1 contact) and checks the MQTT bytes and notifies, with iod's 1-based topics.

Properties = { ["Target IP Address"] = "", ["Target Port"] = "9010",
  ["IO Port"] = "1883", ["IO Token"] = "", ["Topic Prefix"] = "openhc",
  ["Send Project Token"] = "No" }

local writes, notifies, timers, mqtt = {}, {}, {}, nil

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
  GetBindingAddress = function(_, id) return id == 6001 and "10.0.0.9" or "" end,
  SetTimer = function(_, ms, f, rep) timers[#timers + 1] = { ms = ms, f = f, rep = rep } end,
  SendToProxy = function(_, id, cmd) notifies[#notifies + 1] = id .. " " .. cmd end,
  GetDeviceID = function() return 42 end,
  AddVariable = function(_, k, v) Vars = Vars or {}; Vars[k] = v; return true end,
  SetVariable = function(_, k, v) Vars[k] = v end,
  url = function() error("token minting is off in this test") end,
}

dofile("build/ea3/driver.lua")
OnDriverLateInit()   -- takes 10.0.0.9 from binding 6001; dashboard link wired

assert(Properties["Target IP Address"] == "10.0.0.9")
assert(Properties["openHC Web UI"] == "http://10.0.0.9/", tostring(Properties["openHC Web UI"]))

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

-- Retained state (iod numbers from 1): relay/1 -> binding 21, contact/1 -> 31.
local function pub(topic, payload) local b = str(topic) .. payload; return "\48" .. string.char(#b) .. b end
local bytes = pub("openhc/ea3/state/relay/1", "ON") .. pub("openhc/ea3/state/contact/1", "OFF")
mqtt.h.OnRead(mqtt, bytes:sub(1, 7))
mqtt.h.OnRead(mqtt, bytes:sub(8))
assert(notifies[1] == "21 CLOSED" and notifies[2] == "31 OPENED", table.concat(notifies, ","))

-- Director -> relay: OPEN relay 1 (binding 21) publishes OFF to relay/1.
ReceivedFromProxy(21, "OPEN", {})
assert(last() == pub("openhc/ea3/cmd/relay/1/set", "OFF"), hex(last()))

-- TRIGGER on a closed relay: open now, close again after TIME.
ReceivedFromProxy(21, "TRIGGER", { TIME = "250" })
assert(last() == pub("openhc/ea3/cmd/relay/1/set", "OFF"))
timers[#timers].f()
assert(timers[#timers].ms == 250 and last() == pub("openhc/ea3/cmd/relay/1/set", "ON"))

-- IR: binding 16 is IR output 6 (EA3 has 6); binding 17 does not exist here.
ReceivedFromProxy(16, "SEND_IR", { CODE = "0000 006D 0000 0002 0010 0010" })
assert(last() == pub("openhc/ea3/cmd/ir/6/send", "0000 006D 0000 0002 0010 0010"))
local before = last()
ReceivedFromProxy(17, "SEND_IR", { CODE = "0000 006D" })  -- no 7th IR on EA3: routed to the navigator, not IR
assert(last() == before, "EA3 has no IR 7")

-- Serial 3 (binding 3) exists (EA3 has 3 combo serials); serial 4 does not.
ReceivedFromProxy(3, "SEND_STRING", { STRING = "hi" })
assert(last() == pub("openhc/ea3/cmd/serial/3/write", "hi"))

-- Audio: audiod's retained output map (HDMI last). EA3 has 2 non-HDMI outs
-- (OHC_AUDIO_PLAIN=2): analog -> 4000, coax -> 4001, HDMI -> 4072.
C4.JsonDecode = function() return { outputs = {
  { id = "analog" }, { id = "coax" }, { id = "hdmi" } } } end
local reports = {}
C4.SendToProxy = function(_, id, cmd, p) reports[#reports + 1] = cmd .. " " .. tostring(p and (p.LEVEL or p.MUTE)) end
mqtt.h.OnRead(mqtt, pub("openhc/ea3/state/audio/map", "{}"))
ReceivedFromProxy(5003, "SET_VOLUME_LEVEL", { OUTPUT = "4072", LEVEL = "40" })
assert(last() == pub("openhc/ea3/cmd/audio/level/hdmi", "40"), hex(last()))
ReceivedFromProxy(5003, "PULSE_VOL_UP", { OUTPUT = "4001" })
assert(last() == pub("openhc/ea3/cmd/audio/level/coax", "2"))

-- Non-IO bindings still reach the navigator half (it answers this one).
local sent
C4.SendToProxy = function(_, id, cmd) sent = id .. " " .. cmd end
ReceivedFromProxy(5001, "GET_CONTROLLER_DISABLED", {})
assert(sent == "5001 CONTROLLER_DISABLED", tostring(sent))

-- Zigbee AP (zigbee.lua): c4zapd state in -> status reads out; ENABLE_ZAP bridges to cmd/zigbee.
C4.SendToProxy = function() end
mqtt.h.OnRead(mqtt, pub("openhc/ea3/state/zigbee",
  '{"enabled":true,"coordinator":0,"owner":15,"identified":true}'))
assert(ExecuteCommand("GET_ZAP_INFO", {}) ==
  "<zap><coordinator>0</coordinator><enabled>true</enabled><owner>15</owner></zap>",
  tostring(ExecuteCommand("GET_ZAP_INFO", {})))
assert(ExecuteCommand("GET_IS_IDENTIFIED", {}) ==
  "<network_status><identified>true</identified></network_status>")
ExecuteCommand("ENABLE_ZAP", { coordinator = "0", idowner = "15" })
assert(last() == pub("openhc/ea3/cmd/zigbee", '{"op":"enable","coordinator":0,"owner":15}'), hex(last()))
assert(Properties["Last IO Command"] == "zap ENABLE_ZAP coordinator=0 idowner=15",
  tostring(Properties["Last IO Command"]))
ExecuteCommand("DISABLE_ZAP", {})
assert(last() == pub("openhc/ea3/cmd/zigbee", '{"op":"disable"}'))

print("io.lua: ok (ea3 static geometry)")
print("zigbee.lua: ok (ea3 zap bridge)")

-- The Setup tab's address (www/setup.html reads it over the REST API).
assert(Vars.OPENHC_ADDRESS == "10.0.0.9", tostring(Vars.OPENHC_ADDRESS))
print("OPENHC_ADDRESS ok")

-- The audio avswitch confirms an input switch, or Director never starts the stream.
-- ... and the driver starts the stream itself on the Director's audio3server.
local confirm, a3c
C4.SendToProxy = function(_, id, cmd) confirm = id .. " " .. cmd end
local mk = C4.CreateTCPClient
C4.CreateTCPClient = function()
  a3c = mk(); a3c.w = {}; a3c.Write = function(self, b) self.w[#self.w + 1] = b end; return a3c
end
ReceivedFromProxy(5003, "SET_INPUT", { INPUT = "3003", OUTPUT = "4000" })
assert(confirm == "5003 INPUT_OUTPUT_CHANGED", tostring(confirm))
assert(a3c.ip == "127.0.0.1" and a3c.port == 6000)
a3c.h.OnConnect(a3c)
assert(a3c.w[1] == "o1 ADDSTR\r\n", a3c.w[1])
a3c.h.OnRead(a3c, "o1 ADDSTR STREAM=7\r\no1 OK ADDSTR\r\n")
assert(a3c.w[2] == "o2 ADDMED 7 " .. OHC_A3_URL .. "\r\n", a3c.w[2])
a3c.h.OnRead(a3c, "o2 ADDMED MID=7:1\r\no2 OK ADDMED\r\n")
assert(a3c.w[3] == "o3 ADDCLI 7 10.0.0.9 6200\r\n", a3c.w[3])
a3c.h.OnRead(a3c, "o3 OK ADDCLI\r\n* SYS STREAM=7:1 x\r\no4 OK SETSTA\r\n")
assert(a3c.w[4] == "o4 SETSTA 7 PLAY\r\n", a3c.w[4])
ReceivedFromProxy(5003, "OFF", {})
a3c.h.OnConnect(a3c)
assert(a3c.w[1] == "o1 REMSTR 7\r\n", a3c.w[1])
print("SET_INPUT stream ok")
