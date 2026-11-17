-- Self-check for io.lua against a stubbed Director: `./package.sh && lua test.lua`.
-- Feeds hand-encoded MQTT 3.1.1 bytes in and checks the bytes and notifies out.

Properties = { ["Target IP Address"] = "10.0.0.5", ["Target Port"] = "9010",
  ["IO Port"] = "1883", ["IO Token"] = "", ["IO Topic Prefix"] = "openhc",
  ["Send Project Token"] = "No" }

local writes, notifies, timers, mqtt = {}, {}, {}, nil

local function client()
  local c, h = {}, {}
  for _, ev in ipairs({ "OnConnect", "OnRead", "OnDisconnect", "OnError" }) do
    c[ev] = function(self, f) h[ev] = f; return self end
  end
  function c:Connect(ip, port) self.port = port; if port == 1883 then mqtt = self end; return self end
  function c:Write(b) if self.port == 1883 then writes[#writes + 1] = b end end
  function c:ReadAtLeast() end
  function c:Close() end
  c.h = h
  return c
end

C4 = {
  CreateTCPClient = client,
  UpdateProperty = function() end,
  SetTimer = function(_, ms, f, rep) timers[#timers + 1] = { ms = ms, f = f, rep = rep } end,
  SendToProxy = function(_, id, cmd) notifies[#notifies + 1] = id .. " " .. cmd end,
  GetDeviceID = function() return 42 end,
  url = function() error("token minting is off in this test") end,
}

dofile("build/driver.lua")
OnDriverLateInit()

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

-- Retained state, split across two reads -> CLOSED to relay 1, OPENED to contact 2.
local function pub(topic, payload) local b = str(topic) .. payload; return "\48" .. string.char(#b) .. b end
local bytes = pub("openhc/ea3/state/relay/0", "ON") .. pub("openhc/ea3/state/contact/1", "OFF")
mqtt.h.OnRead(mqtt, bytes:sub(1, 7))
mqtt.h.OnRead(mqtt, bytes:sub(8))
assert(notifies[1] == "21 CLOSED" and notifies[2] == "32 OPENED", table.concat(notifies, ","))

-- Director -> relay: OPEN relay 1 publishes OFF to the box the state came from.
ReceivedFromProxy(21, "OPEN", {})
assert(last() == pub("openhc/ea3/cmd/relay/0/set", "OFF"), hex(last()))

-- TRIGGER on a closed relay: open now, close again after TIME.
ReceivedFromProxy(21, "TRIGGER", { TIME = "250" })
assert(last() == pub("openhc/ea3/cmd/relay/0/set", "OFF"))
timers[#timers].f()
assert(timers[#timers].ms == 250 and last() == pub("openhc/ea3/cmd/relay/0/set", "ON"))

-- IR: the Pronto-looking parameter goes to ir/N/send.
ReceivedFromProxy(13, "SEND_IR", { CODE = "0000 006D 0000 0002 0010 0010" })
assert(last() == pub("openhc/ea3/cmd/ir/2/send", "0000 006D 0000 0002 0010 0010"))

-- Non-IO bindings still reach the navigator half (it answers this one).
local sent
C4.SendToProxy = function(_, id, cmd) sent = id .. " " .. cmd end
ReceivedFromProxy(5001, "GET_CONTROLLER_DISABLED", {})
assert(sent == "5001 CONTROLLER_DISABLED", tostring(sent))

print("io.lua: ok")
