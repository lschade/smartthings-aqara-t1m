-- Aqara Ceiling Light T1M (CL-L02D) - SmartThings Edge Driver
--
-- Zigbee model: lumi.light.acn032
-- Manufacturer: LUMI (this unit reports "Aqara")
--
-- The device exposes two independent light endpoints:
--   * Endpoint 0x01 -> SmartThings component "main"      (tunable white panel)
--   * Endpoint 0x02 -> SmartThings component "outerRing" (RGB ambient ring)
--
-- Custom handling in this driver:
--   * RGB ring color only accepts CIE XY (MoveToColor), not Hue/Saturation.
--   * Brightness must be sent with transition time 0, otherwise the firmware
--     ramps and the app slider jitters.
--   * Power-on behavior (state after a power outage) lives in Aqara's private
--     cluster 0xFCC0 / attribute 0x0517 and is exposed per endpoint as the
--     custom capability oceanfuture23754.poweronstate.

local capabilities = require "st.capabilities"
local ZigbeeDriver = require "st.zigbee"
local defaults = require "st.zigbee.defaults"
local clusters = require "st.zigbee.zcl.clusters"
local cluster_base = require "st.zigbee.cluster_base"
local data_types = require "st.zigbee.data_types"
local log = require "log"

local MAIN_ENDPOINT = 0x01
local RING_ENDPOINT = 0x02

-- Aqara private cluster / manufacturer code
local LUMI_MFG_CODE = 0x115F
local POWER_ON_CLUSTER_ID = 0xFCC0
local POWER_ON_STATE_ATTR_ID = 0x0517
local POWER_ON_CODES = { on = 0x00, previous = 0x01, off = 0x02 }
local POWER_ON_STATES = { [0x00] = "on", [0x01] = "previous", [0x02] = "off" }

local power_on_state = capabilities["oceanfuture23754.poweronstate"]

-- Route a SmartThings UI component to its Zigbee endpoint.
local function component_to_endpoint(device, component_id)
  if component_id == "outerRing" then
    return RING_ENDPOINT
  end
  return MAIN_ENDPOINT
end

-- Route an incoming Zigbee endpoint back to a SmartThings UI component.
local function endpoint_to_component(device, ep)
  if ep == RING_ENDPOINT then
    return "outerRing"
  end
  return "main"
end

local function device_init(driver, device)
  -- These must be registered at runtime; they are NOT valid top-level
  -- fields on the driver template.
  device:set_component_to_endpoint_fn(component_to_endpoint)
  device:set_endpoint_to_component_fn(endpoint_to_component)
end

local function read_power_on_state(device)
  for _, ep in ipairs({ MAIN_ENDPOINT, RING_ENDPOINT }) do
    device:send(cluster_base.read_manufacturer_specific_attribute(
      device, POWER_ON_CLUSTER_ID, POWER_ON_STATE_ATTR_ID, LUMI_MFG_CODE):to_endpoint(ep))
  end
end

local function do_refresh(driver, device)
  device:refresh()
  read_power_on_state(device)
end

local function do_configure(driver, device)
  -- Standard binding + reporting configuration for the device's endpoints.
  device:configure()

  -- Read the panel's physical mireds range so the colorTemperature slider is
  -- correct (T1M panel is ~2703-6536 K but we use the reported values).
  device:send(clusters.ColorControl.attributes.ColorTempPhysicalMinMireds:read(device):to_endpoint(MAIN_ENDPOINT))
  device:send(clusters.ColorControl.attributes.ColorTempPhysicalMaxMireds:read(device):to_endpoint(MAIN_ENDPOINT))

  -- Read the current power-on behavior for both endpoints so the app shows the
  -- value that is actually stored on the device.
  read_power_on_state(device)

  log.info("Aqara T1M configured (main ep 0x01, ring ep 0x02)")
end

-- The T1M firmware ramps brightness over ~1.5 s and reports intermediate
-- levels, which makes the app slider jump around. The default handler uses a
-- non-zero transition; send the level with transition time 0 instead.
local function set_level(driver, device, command)
  local level = command.args.level or 0
  if level < 0 then
    level = 0
  elseif level > 100 then
    level = 100
  end

  local zb_level = math.floor(level * 254 / 100 + 0.5)
  local ep = component_to_endpoint(device, command.component or "main")

  device:send(clusters.Level.commands.MoveToLevelWithOnOff(device, zb_level, 0):to_endpoint(ep))
  device:emit_event_for_endpoint(ep, capabilities.switchLevel.level(level))
end

-- Convert SmartThings hue (0-100) + saturation (0-100) to CIE XY (0-1).
local function hs_to_xy(hue, saturation)
  hue = math.max(0, math.min(100, tonumber(hue) or 0))
  saturation = math.max(0, math.min(100, tonumber(saturation) or 0))

  local h = (hue % 100) / 100 * 360
  local s = saturation / 100

  -- HSV with value = 1 gives the fully saturated chromaticity for the hue.
  local c = s
  local x = c * (1 - math.abs(((h / 60) % 2) - 1))
  local m = 1 - c
  local r, g, b
  if h < 60 then
    r, g, b = c, x, 0
  elseif h < 120 then
    r, g, b = x, c, 0
  elseif h < 180 then
    r, g, b = 0, c, x
  elseif h < 240 then
    r, g, b = 0, x, c
  elseif h < 300 then
    r, g, b = x, 0, c
  else
    r, g, b = c, 0, x
  end
  r, g, b = r + m, g + m, b + m

  -- sRGB gamma expansion.
  local function gamma(v)
    if v > 0.04045 then
      return ((v + 0.055) / 1.055) ^ 2.4
    end
    return v / 12.92
  end
  r, g, b = gamma(r), gamma(g), gamma(b)

  -- Linear sRGB -> XYZ (D65), then chromaticity.
  local X = r * 0.664511 + g * 0.154324 + b * 0.162028
  local Y = r * 0.283881 + g * 0.668433 + b * 0.047685
  local Z = r * 0.000088 + g * 0.072310 + b * 0.986039
  local total = X + Y + Z
  if total <= 0 then
    return 0, 0
  end
  return X / total, Y / total
end

local function send_xy_color(device, component, hue, saturation)
  local ep = component_to_endpoint(device, component)
  local x, y = hs_to_xy(hue, saturation)
  local color_x = math.floor(x * 65535 + 0.5)
  local color_y = math.floor(y * 65535 + 0.5)

  log.info(string.format("T1M ring color: h=%s s=%s -> x=%d y=%d ep=0x%02X", tostring(hue), tostring(saturation), color_x, color_y, ep))

  device:send(clusters.ColorControl.commands.MoveToColor(device, color_x, color_y, 0):to_endpoint(ep))

  device:emit_event_for_endpoint(ep, capabilities.colorControl.hue(hue))
  device:emit_event_for_endpoint(ep, capabilities.colorControl.saturation(saturation))
  device:emit_event_for_endpoint(ep, capabilities.colorControl.color({ hue = hue, saturation = saturation }))
end

local function latest_hue_saturation(device, component)
  local hue = device:get_latest_state(component, capabilities.colorControl.ID, capabilities.colorControl.hue.NAME)
  local saturation = device:get_latest_state(component, capabilities.colorControl.ID, capabilities.colorControl.saturation.NAME)
  return hue or 0, saturation or 0
end

local function set_color(driver, device, command)
  local color = command.args.color or {}
  send_xy_color(device, command.component or "outerRing", color.hue or 0, color.saturation or 0)
end

local function set_hue(driver, device, command)
  local component = command.component or "outerRing"
  local _, saturation = latest_hue_saturation(device, component)
  send_xy_color(device, component, command.args.hue or 0, saturation)
end

local function set_saturation(driver, device, command)
  local component = command.component or "outerRing"
  local hue = latest_hue_saturation(device, component)
  send_xy_color(device, component, hue, command.args.saturation or 0)
end

-- Report the device's stored power-on behavior (0xFCC0/0x0517).
local function power_on_state_attr_handler(driver, device, value, zb_rx)
  local state = POWER_ON_STATES[value.value]
  if state == nil then
    log.warn(string.format("Unknown power-on state value: %s", tostring(value.value)))
    return
  end
  local ep = zb_rx.address_header.src_endpoint.value
  device:emit_event_for_endpoint(ep, power_on_state.powerOnState(state))
end

-- Set the power-on behavior for the component's endpoint.
local function set_power_on_state(driver, device, command)
  local state = command.args.state
  local code = POWER_ON_CODES[state]
  if code == nil then
    log.warn(string.format("Unknown power-on state: %s", tostring(state)))
    return
  end

  local ep = component_to_endpoint(device, command.component or "main")
  device:send(cluster_base.write_manufacturer_specific_attribute(
    device, POWER_ON_CLUSTER_ID, POWER_ON_STATE_ATTR_ID, LUMI_MFG_CODE, data_types.Uint8, code):to_endpoint(ep))
  device:emit_event_for_endpoint(ep, power_on_state.powerOnState(state))
end

local aqara_t1m_driver_template = {
  supported_capabilities = {
    capabilities.switch,
    capabilities.switchLevel,
    capabilities.colorTemperature,
    capabilities.colorControl,
    capabilities.refresh,
  },
  capability_handlers = {
    [capabilities.refresh.ID] = {
      [capabilities.refresh.commands.refresh.NAME] = do_refresh,
    },
    [power_on_state.ID] = {
      [power_on_state.commands.setPowerOnState.NAME] = set_power_on_state,
    },
    [capabilities.switchLevel.ID] = {
      [capabilities.switchLevel.commands.setLevel.NAME] = set_level,
    },
    [capabilities.colorControl.ID] = {
      [capabilities.colorControl.commands.setColor.NAME] = set_color,
      [capabilities.colorControl.commands.setHue.NAME] = set_hue,
      [capabilities.colorControl.commands.setSaturation.NAME] = set_saturation,
    },
  },
  zigbee_handlers = {
    attr = {
      [POWER_ON_CLUSTER_ID] = {
        [POWER_ON_STATE_ATTR_ID] = power_on_state_attr_handler,
      },
    },
  },
  lifecycle_handlers = {
    init = device_init,
    doConfigure = do_configure,
  },
}

defaults.register_for_default_handlers(aqara_t1m_driver_template, aqara_t1m_driver_template.supported_capabilities)

local aqara_t1m = ZigbeeDriver("aqara-t1m", aqara_t1m_driver_template)
aqara_t1m:run()
