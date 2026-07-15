local cutils = require ("common-utils")
local log = Log.open_topic ("s-tb321fu-headset-route-reconcile")

local debounce_ms = 250
local pending_timeout = nil
local pending_generation = 0

local nodes = {
  speaker = {
    stale = {
      ["alsa_output.platform-sound.HiFi__Headphones__sink"] = true,
      ["alsa_input.platform-sound.HiFi__Headset__source"] = true,
    },
  },
  headset = {
    stale = {
      ["alsa_output.platform-sound.HiFi__Speaker__sink"] = true,
      ["alsa_input.platform-sound.HiFi__Mic1__source"] = true,
    },
  },
}

local function basename (name)
  return tostring (name or ""):gsub ("%.%d+$", "")
end

local function classify_name (name)
  name = tostring (name or ""):lower ()
  local speaker = name:find ("speaker", 1, true) or
      name:find ("mic1", 1, true)
  local headset = name:find ("headphone", 1, true) or
      name:find ("headset", 1, true)

  if speaker and not headset then
    return "speaker"
  elseif headset and not speaker then
    return "headset"
  end
  return nil
end

local function active_profile_mode (device)
  local active = nil

  for pod in device:iterate_params ("Profile") do
    local profile = cutils.parseParam (pod, "Profile")
    if profile then
      if active then
        return nil
      end
      active = profile
    end
  end

  if not active or not tostring (active.name or ""):lower ():find ("hifi", 1, true) then
    return nil
  end
  return classify_name (active.name), active
end

local function active_route_mode (device)
  local mode = nil
  local found = false

  for pod in device:iterate_params ("Route") do
    local route = cutils.parseParam (pod, "Route")
    if route and route.available ~= "no" then
      local candidate = classify_name (route.name)
      if candidate then
        if mode and mode ~= candidate then
          return nil
        end
        mode = candidate
        found = true
      end
    end
  end

  return found and mode or nil
end

local function active_mode (device)
  local profile_mode, profile = active_profile_mode (device)
  if not profile then
    return nil
  end

  local route_mode = active_route_mode (device)
  if not route_mode or (profile_mode and profile_mode ~= route_mode) then
    return nil
  end
  return route_mode
end

local function platform_device (source)
  local device_om = source:call ("get-object-manager", "device")
  return device_om:lookup {
    Constraint { "device.name", "=", "alsa_card.platform-sound",
        type = "pw-global" },
  }
end

local function belongs_to_device (node, device)
  local node_device_id = tostring ((node.properties or {}) ["device.id"] or "")
  local device_id = tostring (device ["bound-id"] or
      (device.properties or {}) ["object.id"] or "")
  return node_device_id ~= "" and device_id ~= "" and node_device_id == device_id
end

local function reconcile (source)
  local device = platform_device (source)
  if not device then
    return
  end

  local mode = active_mode (device)
  if not mode then
    return
  end

  local node_om = source:call ("get-object-manager", "node")
  for node in node_om:iterate {
      Constraint { "media.class", "matches", "Audio/*", type = "pw-global" },
    } do
    local name = basename ((node.properties or {}) ["node.name"])
    if belongs_to_device (node, device) and nodes [mode].stale [name] then
      pcall (function () node:send_command ("Suspend") end)
      pcall (function () node:request_destroy () end)
    end
  end
end

local function schedule_reconcile (source)
  pending_generation = pending_generation + 1
  local generation = pending_generation

  if pending_timeout then
    pending_timeout:destroy ()
    pending_timeout = nil
  end

  pending_timeout = Core.timeout_add (debounce_ms, function ()
    if generation == pending_generation then
      pending_timeout = nil
      reconcile (source)
    end
    return false
  end)
end

SimpleEventHook {
  name = "tb321fu/headset-route-reconcile-device",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "device-added" },
      Constraint { "device.name", "=", "alsa_card.platform-sound" },
    },
    EventInterest {
      Constraint { "event.type", "=", "device-params-changed" },
      Constraint { "device.name", "=", "alsa_card.platform-sound" },
      Constraint { "event.subject.param-id", "c", "Route", "EnumRoute", "Profile" },
    },
  },
  execute = function (event)
    schedule_reconcile (event:get_source ())
  end,
}:register ()

SimpleEventHook {
  name = "tb321fu/headset-route-reconcile-node",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "media.class", "matches", "Audio/*", type = "pw-global" },
      Constraint { "node.name", "matches", "alsa_*platform-sound.HiFi__*",
          type = "pw-global" },
    },
  },
  execute = function (event)
    schedule_reconcile (event:get_source ())
  end,
}:register ()

log:notice ("TB321FU_HEADSET_ROUTE_RECONCILE_WP05_LOADED")
