--[[
  openHC Zigbee AP — present the box as a Control4 Zigbee access point (zap).

  The Control4 flow (RE'd — side-session-notes/control4-zigbee-ap-re.md): to make a
  controller a zap, the Director sends it the DEVICE commands ENABLE_ZAP /
  DISABLE_ZAP / ENABLE_ZAP_AS_COORDINATOR / GET_ZAP_INFO / GET_IS_IDENTIFIED /
  SET_ZSERVER_STATE / SET_ZSERVER_CHANNEL (c4soap sendAsyncDeviceCommand). The
  radio (listen on :7910, drive the EM357) is c4zapd on the box, already built;
  this driver only relays the Director's enable/disable to c4zapd and answers the
  status reads from c4zapd's retained state. No driver.xml declaration is needed —
  stock controllers handle these NATIVELY (empty <proxy>/<commands>), gated by
  controller-class hardware identity, which this driver already presents.

  Bridge contract with c4zapd (over the box's existing mosquitto, same base as iod):
    driver -> box   <base>/cmd/zigbee    {"op":"enable|disable|coordinator|zserver|channel", ...}
    box -> driver   <base>/state/zigbee  {"enabled":bool,"coordinator":0|1,"owner":N,"identified":bool}  (retained)

  Note: BOTH the ExecuteCommand entrypoint and the c4zapd cmd/state topic+payload
  are RE-inferred, not yet verified on hardware. Stock routes these in native code,
  so the Director MAY refuse to deliver them to a DriverWorks driver at all — then
  the handler never fires and c4zapd runs as its own standalone coordinator instead.
  Arbiter is the live test: ENABLE_ZAP -> this device with c4zapd listening on
  <box>:7910; watch for this handler firing vs "unknown method". One-line change if
  the entrypoint or contract differ.
]]--

local zState = { enabled = false, coordinator = 0, owner = 0, identified = false }

-- c4zapd publishes state/zigbee under the box base; io.lua routes non-relay/contact
-- state here via OHC_STATE (io.lua's chain is preserved).
local zPrevState = OHC_STATE
function OHC_STATE(rest, payload)
  if rest == "state/zigbee" then
    zState.enabled     = payload:match('"enabled"%s*:%s*true') ~= nil
    zState.identified  = payload:match('"identified"%s*:%s*true') ~= nil
    zState.coordinator = tonumber(payload:match('"coordinator"%s*:%s*(%d+)')) or zState.coordinator
    zState.owner       = tonumber(payload:match('"owner"%s*:%s*(%d+)')) or zState.owner
    if OHC_ZSTATUS then OHC_ZSTATUS() end
    return
  end
  if zPrevState then return zPrevState(rest, payload) end
end

-- Optional readable surface for installers (and the self-check).
OHC_ZSTATUS = function()
  if C4 and C4.UpdateProperty then
    C4:UpdateProperty("Last IO Command", string.format("zap enabled=%s identified=%s owner=%d",
      tostring(zState.enabled), tostring(zState.identified), zState.owner))
  end
end

local function zpublish(body) if OHC_PUBLISH then OHC_PUBLISH("cmd/zigbee", body) end end

-- The zap device-commands. Membership is also the live-test probe: if the Director
-- ever routes one of these to this DriverWorks ExecuteCommand, we record it in a
-- readonly property, so "did the Director accept a driver-asserted controller as a
-- zap?" is visible in Composer without watching the box's MQTT.
local ZAP_CMDS = { ENABLE_ZAP = true, ENABLE_ZAP_AS_COORDINATOR = true, DISABLE_ZAP = true,
  SET_ZSERVER_STATE = true, SET_ZSERVER_CHANNEL = true, GET_ZAP_INFO = true, GET_IS_IDENTIFIED = true }

-- Director -> this device (c4soap). Best-guess entrypoint; everything else (TEST_LINK)
-- falls through to the navigator lib's ExecuteCommand.
local zNavExecuteCommand = ExecuteCommand
function ExecuteCommand(strCommand, tParams)
  tParams = tParams or {}
  if ZAP_CMDS[strCommand] and C4 and C4.UpdateProperty then
    C4:UpdateProperty("Last IO Command", "zap " .. strCommand .. " " ..
      ((tParams.coordinator and ("coordinator=" .. tostring(tParams.coordinator) .. " ") or "") ..
       (tParams.idowner and ("idowner=" .. tostring(tParams.idowner)) or "")))
  end
  if strCommand == "ENABLE_ZAP" then
    zState.owner = tonumber(tParams.idowner) or zState.owner
    zpublish(string.format('{"op":"enable","coordinator":%d,"owner":%d}',
      tonumber(tParams.coordinator) or 0, zState.owner))
  elseif strCommand == "ENABLE_ZAP_AS_COORDINATOR" then
    zpublish('{"op":"enable","coordinator":1}')
  elseif strCommand == "DISABLE_ZAP" then
    zpublish('{"op":"disable"}')
  elseif strCommand == "SET_ZSERVER_STATE" then
    zpublish(string.format('{"op":"zserver","enable":%d}', tonumber(tParams.enable) or 0))
  elseif strCommand == "SET_ZSERVER_CHANNEL" then
    zpublish(string.format('{"op":"channel","channel":%d}', tonumber(tParams.channel) or 0))
  elseif strCommand == "GET_ZAP_INFO" then
    -- Broker keys on these element names (response.c4soap.zap.{coordinator,enabled,owner}).
    return string.format('<zap><coordinator>%d</coordinator><enabled>%s</enabled><owner>%d</owner></zap>',
      zState.coordinator, zState.enabled and "true" or "false", zState.owner)
  elseif strCommand == "GET_IS_IDENTIFIED" then
    return string.format('<network_status><identified>%s</identified></network_status>',
      zState.identified and "true" or "false")
  elseif zNavExecuteCommand then
    return zNavExecuteCommand(strCommand, tParams)
  end
end
