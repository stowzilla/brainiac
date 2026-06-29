# frozen_string_literal: true

# Discord WebSocket gateway connections.
#
# Each agent with a DISCORD_BOT_TOKEN gets its own persistent WebSocket
# connection. The gateway dispatches MESSAGE_CREATE, MESSAGE_UPDATE,
# and MESSAGE_REACTION_ADD events to handler functions.

DISCORD_GATEWAY_URL = "wss://gateway.discord.gg/?v=10&encoding=json"

# Per-bot state: { agent_key => { token:, user_id:, status:, thread: } }
DISCORD_BOTS = {}
DISCORD_BOTS_MUTEX = Mutex.new
DISCORD_ALL_READY_LOGGED = { done: false }

def start_discord_gateway_for(agent_key, bot_token)
  Thread.new do
    agent_display = fizzy_display_name(agent_key) || agent_key.capitalize
    bot_user_id = nil

    loop do
      DISCORD_BOTS_MUTEX.synchronize do
        DISCORD_BOTS[agent_key] ||= {}
        DISCORD_BOTS[agent_key][:status] = "connecting"
        DISCORD_BOTS[agent_key][:token] = bot_token
      end

      LOG.debug "[Discord:#{agent_display}] Connecting to Gateway..."

      heartbeat_thread = nil
      last_sequence = nil

      ws = WebSocket::Client::Simple.connect(DISCORD_GATEWAY_URL)

      ws.on :message do |msg|
        next if msg.data.nil? || msg.data.empty?

        payload = JSON.parse(msg.data)
        op = payload["op"]
        data = payload["d"]
        last_sequence = payload["s"] if payload["s"]

        case op
        when 10 # Hello
          heartbeat_interval = data["heartbeat_interval"]
          LOG.debug "[Discord:#{agent_display}] Gateway connected, heartbeat: #{heartbeat_interval}ms"

          heartbeat_thread&.kill
          heartbeat_thread = Thread.new do
            loop do
              sleep(heartbeat_interval / 1000.0)
              ws.send({ op: 1, d: last_sequence }.to_json)
            end
          end

          ws.send({
            op: 2,
            d: {
              token: bot_token,
              intents: 46_593,
              properties: { os: RUBY_PLATFORM, browser: "brainiac", device: "brainiac" }
            }
          }.to_json)

        when 0 # Dispatch
          case payload["t"]
          when "READY"
            bot_user_id = data.dig("user", "id")
            DISCORD_BOTS_MUTEX.synchronize do
              DISCORD_BOTS[agent_key][:user_id] = bot_user_id
              DISCORD_BOTS[agent_key][:status] = "ready"
            end
            guild_count = data["guilds"]&.size || 0
            LOG.info "[Discord] #{agent_display} ready (#{guild_count} #{guild_count == 1 ? "guild" : "guilds"})"
            LOG.debug "[Discord:#{agent_display}] user_id=#{bot_user_id}"

            DISCORD_BOTS_MUTEX.synchronize do
              if !DISCORD_ALL_READY_LOGGED[:done] && DISCORD_BOTS.all? { |_, info| info[:status] == "ready" }
                DISCORD_ALL_READY_LOGGED[:done] = true
                LOG.info "[Discord] All bots connected."
              end
            end

          when "MESSAGE_CREATE"
            Thread.new do
              handle_discord_message(data, agent_key, bot_token, bot_user_id)
            rescue StandardError => e
              LOG.error "[Discord:#{agent_display}] Error handling message: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
            end

          when "MESSAGE_UPDATE"
            if data["edited_timestamp"]
              Thread.new do
                handle_discord_message(data, agent_key, bot_token, bot_user_id)
              rescue StandardError => e
                LOG.error "[Discord:#{agent_display}] Error handling message update: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
              end
            end

          when "MESSAGE_REACTION_ADD"
            Thread.new do
              handle_discord_reaction(data, agent_key, bot_token, bot_user_id)
            rescue StandardError => e
              LOG.error "[Discord:#{agent_display}] Error handling reaction: #{e.message}\n#{e.backtrace.first(3).join("\n")}"
            end
          end

        when 1  then ws.send({ op: 1, d: last_sequence }.to_json)
        when 7  then LOG.info "[Discord:#{agent_display}] Reconnect requested"
                     ws.close
        when 9  then LOG.warn "[Discord:#{agent_display}] Invalid session, re-identifying in 5s"
                     sleep 5
                     ws.send({ op: 2, d: { token: bot_token, intents: 46_593,
                                           properties: { os: RUBY_PLATFORM, browser: "brainiac", device: "brainiac" } } }.to_json)
        when 11 then nil # Heartbeat ACK
        end
      rescue StandardError => e
        LOG.error "[Discord:#{agent_display}] Gateway message error: #{e.message}"
      end

      ws.on :open do
        LOG.debug "[Discord:#{agent_display}] WebSocket connected"
      end

      ws.on :close do |e|
        DISCORD_BOTS_MUTEX.synchronize do
          DISCORD_BOTS[agent_key][:status] = "disconnected" if DISCORD_BOTS[agent_key]
        end
        LOG.warn "[Discord:#{agent_display}] WebSocket closed: #{e&.inspect}"
        heartbeat_thread&.kill
      end

      ws.on :error do |e|
        LOG.error "[Discord:#{agent_display}] WebSocket error: #{e.message}"
      end

      loop do
        sleep 1
        next if ws.open?

        LOG.info "[Discord:#{agent_display}] Connection lost, reconnecting in 5s..."
        sleep 5
        break
      end
    rescue StandardError => e
      DISCORD_BOTS_MUTEX.synchronize do
        DISCORD_BOTS[agent_key][:status] = "error" if DISCORD_BOTS[agent_key]
      end
      LOG.error "[Discord:#{agent_display}] Gateway error: #{e.message}, reconnecting in 5s..."
      sleep 5
    end
  end
end

# Start all per-agent Discord bots.
def start_all_discord_gateways
  tokens = discord_bot_tokens
  if tokens.empty?
    LOG.info "[Discord] No agents have DISCORD_BOT_TOKEN configured — Discord disabled"
    return
  end

  LOG.info "[Discord] Starting #{tokens.size} bot(s): #{tokens.keys.join(", ")}"

  DISCORD_BOTS_MUTEX.synchronize do
    tokens.each do |agent_key, token|
      DISCORD_BOTS[agent_key] = { token: token, status: "starting", user_id: nil }
    end
  end

  tokens.each do |agent_key, token|
    start_discord_gateway_for(agent_key, token)
    sleep 1 # Stagger connections to avoid rate limits
  end
end

# Summary of all bot statuses for the API endpoint.
def discord_bots_status
  DISCORD_BOTS_MUTEX.synchronize do
    DISCORD_BOTS.transform_values do |info|
      { status: info[:status], user_id: info[:user_id] }
    end
  end
end
