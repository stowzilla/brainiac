#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Waybar — Middle-click: Open the Discord thread for a session.
# Constructs a deep link to the Discord thread and opens it in the browser.
# Only works for Discord sessions (card_key starts with "discord-").

require_relative "../shared"

AGENTS = load_agent_config.freeze
DISCORD_CONFIG_FILE = File.join(BRAINIAC_DIR, "discord.json")

def load_discord_config
  return {} unless File.exist?(DISCORD_CONFIG_FILE)

  JSON.parse(File.read(DISCORD_CONFIG_FILE))
rescue JSON::ParserError
  {}
end

def open_url(url)
  system("xdg-open", url)
end

state = fetch_state

if state["error"]
  system("notify-send", "Brainiac Error", state["error"])
  exit 1
end

sessions = state["sessions"] || []
discord_sessions = sessions.select { |s| s["card_key"].to_s.start_with?("discord-") }

if discord_sessions.empty?
  system("notify-send", "Brainiac", "No active Discord sessions")
  exit 0
end

discord_config = load_discord_config
guild_id = discord_config["guild_id"]

unless guild_id
  system("notify-send", "Brainiac", "No guild_id in discord.json — add \"guild_id\": \"YOUR_SERVER_ID\" to ~/.brainiac/discord.json")
  exit 1
end

def extract_thread_id(session)
  # channel_id from API response is the thread/channel ID
  return session["channel_id"] if session["channel_id"]

  # Fallback: parse from card_key format "discord-<agent>-<channel_id>-<message_id>"
  parts = session["card_key"].to_s.split("-")
  # card_key = "discord-<agent_key>-<channel_id>-<message_id>"
  # agent_key can contain hyphens, so we need the last two numeric segments
  # Channel IDs and message IDs are always large numbers (snowflakes)
  numeric_parts = parts.grep(/\A\d{15,}\z/)
  numeric_parts.first # First snowflake is the channel/thread ID
end

def open_discord_thread(guild_id, session)
  thread_id = extract_thread_id(session)
  unless thread_id
    system("notify-send", "Brainiac", "Cannot determine thread ID for #{session["agent"]}")
    return
  end

  url = "https://discord.com/channels/#{guild_id}/#{thread_id}"
  open_url(url)
end

# Single Discord session → open immediately
if discord_sessions.size == 1
  open_discord_thread(guild_id, discord_sessions[0])
  exit 0
end

# Multiple Discord sessions → picker
def find_launcher
  %w[rofi fuzzel wofi zenity fzf].find { |cmd| system("which #{cmd} > /dev/null 2>&1") }
end

def run_menu(launcher, entries)
  menu_text = entries.map { |e| e[:display] }.join("\n")
  case launcher
  when "rofi"
    IO.popen(%w[rofi -dmenu -i -p] + ["Open Thread"], "r+") do |io|
      io.puts menu_text
      io.close_write
      io.read.strip
    end
  when "fuzzel"
    IO.popen(%w[fuzzel --dmenu --prompt] + ["Open Thread: "], "r+") do |io|
      io.puts menu_text
      io.close_write
      io.read.strip
    end
  when "wofi"
    IO.popen(%w[wofi --dmenu --prompt] + ["Open Thread"], "r+") do |io|
      io.puts menu_text
      io.close_write
      io.read.strip
    end
  when "zenity"
    IO.popen(["zenity", "--list", "--title", "Open Thread", "--column", "Session", "--width", "600", "--height", "400"], "r+",
             err: "/dev/null") do |io|
      entries.each { |e| io.puts e[:display] }
      io.close_write
      io.read.strip
    end
  when "fzf"
    `echo "#{menu_text}" | fzf --prompt="Open Thread: "`.strip
  end
end

entries = discord_sessions.map do |s|
  agent = s["agent"]
  elapsed = format_elapsed(s["elapsed_seconds"] || 0)
  emoji = AGENTS.dig(agent&.downcase, :emoji) || DEFAULT_EMOJI
  { display: "#{emoji} #{agent}: Discord (#{elapsed})", session: s }
end

launcher = find_launcher
unless launcher
  # Fallback: open first session's thread
  open_discord_thread(guild_id, discord_sessions[0])
  exit 0
end

selected_line = run_menu(launcher, entries)
unless selected_line.to_s.empty?
  selected = entries.find { |e| e[:display].strip == selected_line.strip }
  open_discord_thread(guild_id, selected[:session]) if selected
end
