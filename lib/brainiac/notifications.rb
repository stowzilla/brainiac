# frozen_string_literal: true

# Generic notification system for Brainiac.
#
# Provides a channel-agnostic way to send messages. Plugins register as
# notification providers for their channel. Core code emits notifications
# without knowing which plugin will deliver them.
#
# Configuration in ~/.brainiac/brainiac.json:
#   "notifications": {
#     "deploy": { "channel": "discord", "target": "channel-id-123" },
#     "cron": { "channel": "discord", "target": "channel-id-456" },
#     "restart": { "channel": "discord", "target": "channel-id-789" }
#   }
#
# Plugins register handlers:
#   Brainiac.on(:notify) do |ctx|
#     if ctx[:channel].to_s == "discord"
#       send_to_discord(ctx[:target], ctx[:message], agent: ctx[:agent])
#     end
#   end

NOTIFICATIONS_CONFIG_KEY = "notifications"

# Send a notification via the configured channel.
#
# @param event [Symbol, String] The notification event type (e.g. :deploy, :restart, :cron)
# @param message [String] The message content
# @param target [String, nil] Override target (channel ID, card number, etc.)
# @param channel [Symbol, String, nil] Override channel (:discord, :fizzy, etc.)
# @param agent [String, nil] Which agent identity to send as
# @param metadata [Hash] Extra context passed to the handler
def send_notification(event, message, target: nil, channel: nil, agent: nil, **metadata)
  config = notification_config_for(event)

  # Explicit params override config
  channel = (channel || config["channel"])&.to_sym
  target ||= config["target"]

  unless channel && target
    LOG.debug "[Notify] No channel/target configured for '#{event}', skipping" if LOG.debug?
    return false
  end

  agent ||= config["agent"]

  results = Brainiac.emit(:notify,
                          event: event.to_sym, channel: channel, target: target,
                          message: message, agent: agent, **metadata)

  if results.any?
    LOG.info "[Notify] #{event} delivered via #{channel} to #{target}"
    true
  else
    LOG.warn "[Notify] No handler responded for channel '#{channel}' (is the plugin installed?)"
    false
  end
rescue StandardError => e
  LOG.error "[Notify] Failed to send '#{event}': #{e.message}"
  false
end

# Get the notification config for a specific event type.
# Falls back to "default" config if no event-specific config exists.
def notification_config_for(event)
  brainiac_config_file = File.join(BRAINIAC_DIR, "brainiac.json")
  return {} unless File.exist?(brainiac_config_file)

  config = JSON.parse(File.read(brainiac_config_file))
  notifications = config[NOTIFICATIONS_CONFIG_KEY] || {}

  notifications[event.to_s] || notifications["default"] || {}
rescue JSON::ParserError
  {}
end

# Convenience: send a notification for cron job output.
def notify_cron_output(job, message, agent_name: nil)
  send_notification(:cron, message,
                    target: job[:notify_target],
                    channel: job[:notify_channel],
                    agent: agent_name || job[:agent],
                    job_id: job[:id],
                    forum_title: job[:forum_title],
                    forum_reply_to_latest: job[:forum_reply_to_latest])
end

# Convenience: send a deploy notification.
def notify_deploy(project_key, message)
  send_notification(:deploy, message, metadata_project: project_key)
end

# Convenience: send a restart notification.
def notify_restart(message)
  send_notification(:restart, message)
end
