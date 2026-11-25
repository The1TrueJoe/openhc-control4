--[[
  openHC audio — the box's audio is a second device, run by Control4's own driver.

  Director only streams Digital Media to a device whose driver can tell it the
  audio client's address and port (OnAVAddLocationInfo), and only Control4's
  compiled controller drivers can; a DriverWorks (Lua) driver never can. So this
  driver adds the box's audio as a child device using the stock driver for the
  same model (gen.py bakes OHC_AUDIO_C4I: control4_ea3.c4i on an EA-3, ...),
  falling back to the Triad One (one output) on a Director that no longer ships
  that model's driver. Then:

    - points the child's network connection at the box's IP (Director's own
      identify call, POST /api/v1/items/<id>/identification), so its outputs
      resolve to <box>:6200.. — the ports c4zones gives the box's zones;
    - makes the child's first output the room's Audio End-Point if the room
      has none (the child's own outputs can be bound anywhere after that).

  Every source (TuneIn, My Music, ShairBridge, ...) then plays natively,
  managed by Director's queue. Volume is the child's: Control4's driver sets it
  on the box's audio client.
]]--

local FALLBACK_C4I = "control4_tr1.c4i"
local ROOM_AUDIO_END_POINT = 2
local CHILD_KEY = "OHC_AUDIO_CHILD"   -- persisted: "<protocol id> <proxy id>"

local gAdding = false

local function child()
  local p, x = tostring(C4:PersistGetValue(CHILD_KEY) or ""):match("^(%d+) (%d+)$")
  p, x = tonumber(p), tonumber(x)
  if p and C4:GetDeviceDisplayName(p) then return p, x end
end

local function status(s) C4:UpdateProperty("Audio Device", s) end

-- Director's REST API on this controller, as the navigator half mints its token.
local function rest_post(path, body, done)
  C4:url()
    :SetOptions({ timeout = 15, fail_on_error = false })
    :OnDone(function(_, rs)
      local r = rs and rs[#rs]
      local tok = r and r.code == 200 and r.body and r.body:match('"token"%s*:%s*"([^"]+)"')
      if not tok then return done(nil, "no token (" .. tostring(r and r.code) .. ")") end
      C4:url()
        :SetOptions({ timeout = 30, fail_on_error = false })
        :OnDone(function(_, rs2)
          local r2 = rs2 and rs2[#rs2]
          done(r2 and r2.code, r2 and r2.body)
        end)
        :Post("http://127.0.0.1:3000" .. path, body,
              { ["Content-Type"] = "application/json", ["Authorization"] = "Bearer " .. tok })
    end)
    :Post("http://127.0.0.1:3000/api/v1/localjwt", "{}", {
      ["Content-Type"] = "application/json",
      ["X-SSL-CERT-VERIFY"] = "SUCCESS",
      ["X-SSL-CERT-CLIENT_S_DN"] = "CN=Composer_tech@control4.com_dev,O=Control4",
    })
end

local function child_addr(p)
  local nb = C4:GetNetworkBindingsByDevice(p)
  nb = nb and nb.networkbindings
  local b = nb and nb[1]
  return b and b.addr or ""
end

-- Point the child at the box, unless it already is.
local function identify(p)
  local ip = Properties["Target IP Address"] or ""
  if ip == "" or child_addr(p) == ip then return end
  rest_post("/api/v1/items/" .. p .. "/identification", '{"address":"' .. ip .. '"}', function(code, body)
    status((code == 200 and "at " .. ip or "identify failed: " .. tostring(code) .. " " .. tostring(body)) ..
           " (device " .. p .. ")")
  end)
end

local function bind_room(proxy)
  local room = C4:RoomGetId()
  local bound = C4:GetBoundProviderDevice(room, ROOM_AUDIO_END_POINT)
  if not bound or bound == 0 then C4:Bind(proxy, 7000, room, ROOM_AUDIO_END_POINT, "AUDIO_SELECTION") end
end

local function add(c4i)
  gAdding = true
  status("adding " .. c4i)
  local name = C4:GetDeviceDisplayName(C4:GetDeviceID()) .. " Audio"
  C4:AddDevice(c4i, C4:RoomGetId(), name, function(id, t)
    if not id or id == 0 then
      if c4i ~= FALLBACK_C4I then return add(FALLBACK_C4I) end
      gAdding = false
      return status("could not add " .. c4i)
    end
    local proxy
    for _, n in ipairs(t and t.ChildNodes or {}) do
      if n.Name == "proxy" then proxy = tonumber(n.Value) end
    end
    gAdding = false
    C4:RenameDevice(id, name)   -- AddDevice names only the proxy
    C4:PersistSetValue(CHILD_KEY, id .. " " .. tostring(proxy or id))
    status("added " .. c4i .. " (device " .. id .. ")")
    if proxy then bind_room(proxy) end
    identify(id)
  end)
end

-- Called at late init and whenever the box's address changes.
function OHC_AUDIO_CHILD()
  if not OHC_AUDIO_C4I or gAdding then return end
  local p = child()
  if p then identify(p) else add(OHC_AUDIO_C4I) end
end
