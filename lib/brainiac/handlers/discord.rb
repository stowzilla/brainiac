# frozen_string_literal: true

# Discord bot handlers: per-agent gateway connections, message handling, API helpers.
#
# Each agent with a `discord_bot_token` in the agent registry gets its own
# Discord bot connection. Users @mention @Galen or @GLaDOS directly in Discord
# rather than a single shared bot.
#
# This file loads all Discord sub-modules:
#   discord/config.rb    — Config loading, thread map, channel routing
#   discord/api.rb       — REST API helpers (also used by GitHub/Zoho for notifications)
#   discord/delivery.rb  — Draft file delivery, poller, shared thread management
#   discord/reactions.rb — Reaction handler (cancel, thinking peek, feedback)
#   discord/message.rb   — Main message handler and agent dispatch
#   discord/gateway.rb   — WebSocket gateway connections per agent bot

require "English"

require_relative "discord/config"
require_relative "discord/api"
require_relative "discord/delivery"
require_relative "discord/reactions"
require_relative "discord/message"
require_relative "discord/gateway"
