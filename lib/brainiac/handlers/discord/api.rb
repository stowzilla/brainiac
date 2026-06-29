# frozen_string_literal: true

# Discord REST API helpers.
#
# Low-level HTTP methods and convenience wrappers for the Discord v10 API.
# Used by the Discord handler itself, but also by GitHub (deploy notifications)
# and Zoho (email notifications).

DISCORD_API_BASE = "https://discord.com/api/v10"

# Emojis reserved for brainiac functionality — not treated as feedback
RESERVED_EMOJIS = %w[👀 ❌ 🛑 🚫 ⚠️ ⏳ 😶 ❔ ❓ 🧠].freeze

def discord_api(method, path, token:, body: nil, log_errors: true)
  uri = URI("#{DISCORD_API_BASE}#{path}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true

  req = case method
        when :get    then Net::HTTP::Get.new(uri)
        when :post   then Net::HTTP::Post.new(uri)
        when :put    then Net::HTTP::Put.new(uri)
        when :delete then Net::HTTP::Delete.new(uri)
        end

  req["Authorization"] = "Bot #{token}"
  req["Content-Type"] = "application/json"
  req.body = body.to_json if body

  response = http.request(req)

  if response.code.to_i == 429
    retry_after = JSON.parse(response.body)["retry_after"] || 1
    LOG.warn "Discord rate limited, waiting #{retry_after}s"
    sleep retry_after
    return discord_api(method, path, token: token, body: body, log_errors: log_errors)
  end

  LOG.error "Discord API error (#{method} #{path}): HTTP #{response.code} - #{response.body}" if response.code.to_i >= 400 && log_errors

  JSON.parse(response.body) unless response.body.nil? || response.body.empty?
rescue StandardError => e
  LOG.error "Discord API error (#{method} #{path}): #{e.message}" if log_errors
  nil
end

# --- Channel & Message Operations ---

def fetch_discord_channel_history(channel_id, before_message_id, token:, limit: 10)
  messages = discord_api(:get, "/channels/#{channel_id}/messages?before=#{before_message_id}&limit=#{limit}", token: token)

  all_messages = messages.is_a?(Array) ? messages : []

  # If we're in a thread, check if the oldest message is a THREAD_STARTER_MESSAGE (type 21).
  # These messages have no content but point to the original message via referenced_message.
  # We need to include that original message for full context.
  if all_messages.any?
    oldest = all_messages.last # API returns newest-first
    all_messages << oldest["referenced_message"] if oldest && oldest["type"] == 21 && oldest["referenced_message"]
  end

  return "" if all_messages.empty?

  # Messages come newest-first from the API, reverse for chronological order
  lines = all_messages.reverse.filter_map do |msg|
    author = msg.dig("author", "username") || "unknown"
    content = msg["content"]&.strip || ""
    next if content.empty?

    "#{author}: #{content}"
  end

  return "" if lines.empty?

  lines.join("\n")
rescue StandardError => e
  LOG.warn "Failed to fetch channel history: #{e.message}"
  ""
end

def fetch_channel_info(channel_id, token:)
  discord_api(:get, "/channels/#{channel_id}", token: token)
end

def fetch_discord_message(channel_id, message_id, token:, log_errors: true)
  discord_api(:get, "/channels/#{channel_id}/messages/#{message_id}", token: token, log_errors: log_errors)
end

def fetch_guild_member(guild_id, user_id, token:)
  discord_api(:get, "/guilds/#{guild_id}/members/#{user_id}", token: token)
end

# --- Messaging ---

def send_discord_message(channel_id, content, token:, reply_to: nil)
  body = { content: content }
  body[:message_reference] = { message_id: reply_to } if reply_to
  result = discord_api(:post, "/channels/#{channel_id}/messages", token: token, body: body)
  if result && result["id"]
    LOG.info "[Discord] Message posted successfully to channel #{channel_id}, message_id: #{result["id"]}"
  else
    LOG.error "[Discord] Failed to post message to channel #{channel_id}, result: #{result.inspect}"
  end
  result
end

def send_long_discord_message(channel_id, content, token:, reply_to: nil)
  if content.length <= 2000
    send_discord_message(channel_id, content, token: token, reply_to: reply_to)
    return
  end

  chunks = []
  remaining = content
  while remaining.length.positive?
    if remaining.length <= 2000
      chunks << remaining
      remaining = ""
    else
      split_at = remaining.rindex("\n", 1990) || 1990
      chunks << remaining[0...split_at]
      remaining = remaining[split_at..].lstrip
    end
  end

  chunks.each_with_index do |chunk, i|
    send_discord_message(channel_id, chunk, token: token, reply_to: i.zero? ? reply_to : nil)
    sleep 0.5
  end
end

def send_discord_typing(channel_id, token:)
  discord_api(:post, "/channels/#{channel_id}/typing", token: token)
end

# --- Reactions ---

def add_discord_reaction(channel_id, message_id, emoji, token:)
  encoded = URI.encode_www_form_component(emoji)
  discord_api(:put, "/channels/#{channel_id}/messages/#{message_id}/reactions/#{encoded}/@me", token: token)
end

def remove_discord_reaction(channel_id, message_id, emoji, token:)
  encoded = URI.encode_www_form_component(emoji)
  discord_api(:delete, "/channels/#{channel_id}/messages/#{message_id}/reactions/#{encoded}/@me", token: token)
end

# --- Threads & Forums ---

def create_discord_thread(channel_id, message_id, name:, token:)
  thread_name = name.length > 100 ? "#{name[0..96]}..." : name
  discord_api(:post, "/channels/#{channel_id}/messages/#{message_id}/threads", token: token, body: {
                name: thread_name,
                auto_archive_duration: 1440
              })
end

def forum_channel?(channel_id, token:)
  info = fetch_channel_info(channel_id, token: token)
  info && info["type"] == 15
end

def find_latest_forum_thread(channel_id, token:)
  channel_info = fetch_channel_info(channel_id, token: token)
  return nil unless channel_info && channel_info["guild_id"]

  guild_id = channel_info["guild_id"]
  result = discord_api(:get, "/guilds/#{guild_id}/threads/active", token: token)
  return nil unless result && result["threads"]

  forum_threads = result["threads"]
                  .select { |t| t["parent_id"] == channel_id }
                  .sort_by { |t| t["id"].to_i }
                  .reverse

  return nil if forum_threads.empty?

  latest = forum_threads.first
  LOG.info "[Discord] Found latest forum thread: #{latest["id"]} (#{latest["name"]}) in channel #{channel_id}"
  latest
end

def create_forum_post(channel_id, title:, content:, token:)
  thread_name = title.length > 100 ? "#{title[0..96]}..." : title
  result = discord_api(:post, "/channels/#{channel_id}/threads", token: token, body: {
                         name: thread_name,
                         message: { content: content },
                         auto_archive_duration: 1440
                       })
  if result && result["id"]
    LOG.info "[Discord] Forum post created in channel #{channel_id}, thread_id: #{result["id"]}"
  else
    LOG.error "[Discord] Failed to create forum post in channel #{channel_id}, result: #{result.inspect}"
  end
  result
end
