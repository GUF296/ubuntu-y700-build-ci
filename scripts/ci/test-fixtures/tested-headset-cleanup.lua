log = Log.open_topic ("s-y700-headset-cleanup")

local speaker_sink = "alsa_output.platform-sound.HiFi__Speaker__sink"
local headphones_sink = "alsa_output.platform-sound.HiFi__Headphones__sink"
local mic1_source = "alsa_input.platform-sound.HiFi__Mic1__source"
local headset_source = "alsa_input.platform-sound.HiFi__Headset__source"

local function basename (name)
  return tostring (name or ""):gsub ("%.%d+$", "")
end

local function is_y700_hifi_node (node)
  local props = node.properties or {}
  local name = tostring (props ["node.name"] or "")
  return name:find ("^alsa_.*%.platform%-sound%.HiFi__") ~= nil
end

local function has_node (node_om, target)
  for node in node_om:iterate {
      Constraint { "media.class", "matches", "Audio/*", type = "pw-global" },
    } do
    if basename ((node.properties or {}) ["node.name"]) == target then
      return true
    end
  end
  return false
end

local function current_mode (node_om)
  local has_speaker = has_node (node_om, speaker_sink)
  local has_headphones = has_node (node_om, headphones_sink)

  if has_headphones and not has_speaker then
    return "headset"
  end
  if has_speaker and not has_headphones then
    return "speaker"
  end
  return "unknown"
end

local function is_stale (name, mode)
  name = basename (name)
  if mode == "headset" then
    return name == speaker_sink or name == mic1_source
  elseif mode == "speaker" then
    return name == headphones_sink or name == headset_source
  end
  return false
end

local function destroy_stale_nodes (source)
  local node_om = source:call ("get-object-manager", "node")
  local mode = current_mode (node_om)

  if mode == "unknown" then
    return
  end

  for node in node_om:iterate {
      Constraint { "media.class", "matches", "Audio/*", type = "pw-global" },
    } do
    if is_y700_hifi_node (node) and is_stale ((node.properties or {}) ["node.name"], mode) then
      pcall (function () node:send_command ("Suspend") end)
      pcall (function () node:request_destroy () end)
    end
  end
end

local function cleanup_now_and_soon (source)
  destroy_stale_nodes (source)
  Core.timeout_add (100, function () destroy_stale_nodes (source); return false end)
end

SimpleEventHook {
  name = "y700/headset-cleanup-device",
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
    cleanup_now_and_soon (event:get_source ())
  end
}:register ()

SimpleEventHook {
  name = "y700/headset-cleanup-node",
  interests = {
    EventInterest {
      Constraint { "event.type", "=", "node-added" },
      Constraint { "media.class", "matches", "Audio/*", type = "pw-global" },
      Constraint { "node.name", "matches", "alsa_*platform-sound.HiFi__*", type = "pw-global" },
    },
  },
  execute = function (event)
    cleanup_now_and_soon (event:get_source ())
  end
}:register ()

log:notice ("Y700_HEADSET_CLEANUP_WP05_IMMEDIATE_100MS_LOADED")
