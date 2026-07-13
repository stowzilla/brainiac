#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Waybar Per-Session Module
# Each instance represents one session slot.
#
# Usage: session_slot.rb <index>              → JSON output for waybar
#        session_slot.rb <index> --tail       → Left-click: tail the log
#        session_slot.rb <index> --manage     → Right-click: kill menu
#        session_slot.rb <index> --thread     → Middle-click: open Discord thread

require "shellwords"
require "time"
require_relative "../shared"

AGENTS = load_agent_config.freeze
INFRA_CMDS = %w[kiro-cli-chat ruby-lsp clangd gopls].freeze
DISCORD_CONFIG_FILE = File.join(BRAINIAC_DIR, "discord.json")

index = ARGV.find { |a| !a.start_with?("--") }&.to_i
unless index
  puts({ text: "", tooltip: "", class: "" }.to_json)
  exit
end

def load_discord_guild_id
  return nil unless File.exist?(DISCORD_CONFIG_FILE)

  config = JSON.parse(File.read(DISCORD_CONFIG_FILE))
  config["guild_id"]
rescue JSON::ParserError
  nil
end

def escape_pango(str)
  str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
end

def find_terminal
  %w[alacritty kitty gnome-terminal xterm].find { |t| system("which #{t} > /dev/null 2>&1") }
end

def open_log(log_file)
  return unless log_file && File.exist?(log_file)

  terminal = find_terminal
  case terminal
  when "alacritty"
    spawn("alacritty", "-e", "tail", "-f", log_file, %i[out err] => "/dev/null")
  when "kitty"
    spawn("kitty", "tail", "-f", log_file, %i[out err] => "/dev/null")
  when "gnome-terminal"
    spawn("gnome-terminal", "--", "tail", "-f", log_file, %i[out err] => "/dev/null")
  else
    spawn("xterm", "-e", "tail", "-f", log_file, %i[out err] => "/dev/null")
  end
end

def handle_tail(session)
  return unless session

  open_log(session["log_file"])
end

def handle_manage(session)
  return unless session

  entries = []
  agent = session["agent"]
  elapsed = format_elapsed(session["elapsed_seconds"] || 0)
  context = format_context(session["card_key"])
  emoji = AGENTS.dig(agent&.downcase, :emoji) || DEFAULT_EMOJI

  entries << { display: "#{emoji} #{agent}: #{context} (#{elapsed})", type: :log, log: session["log_file"] }
  entries << { display: "   ⛔ Kill session", type: :kill_session, card_key: session["card_key"], agent: agent }

  (session["children"] || []).each do |c|
    cmd_short = c["cmd"].to_s.split("/").last.to_s.split.first.to_s
    cmd_short = c["cmd"].to_s[0..40] if cmd_short.empty?
    next if INFRA_CMDS.any? { |ic| cmd_short.start_with?(ic) }

    entries << {
      display: "   └ 🔪 Kill: #{cmd_short} (#{format_elapsed(c["elapsed_seconds"])}) [PID #{c["pid"]}]",
      type: :kill_child, pid: c["pid"], cmd: cmd_short
    }
  end

  launcher = %w[rofi fuzzel wofi zenity fzf].find { |cmd| system("which #{cmd} > /dev/null 2>&1") }
  unless launcher
    system("notify-send", "Brainiac", "No menu launcher found")
    return
  end

  menu_text = entries.map { |e| e[:display] }.join("\n")
  selected_line = case launcher
                  when "rofi"
                    IO.popen(%w[rofi -dmenu -i -p] + ["Manage"], "r+") do |io|
                      io.puts menu_text
                      io.close_write
                      io.read.strip
                    end
                  when "fuzzel"
                    IO.popen(%w[fuzzel --dmenu --prompt] + ["Manage: "], "r+") do |io|
                      io.puts menu_text
                      io.close_write
                      io.read.strip
                    end
                  when "wofi"
                    IO.popen(%w[wofi --dmenu --prompt] + ["Manage"], "r+") do |io|
                      io.puts menu_text
                      io.close_write
                      io.read.strip
                    end
                  when "zenity"
                    IO.popen(["zenity", "--list", "--title", "Manage", "--column", "Action", "--width", "500", "--height", "300"], "r+",
                             err: "/dev/null") do |io|
                      entries.each { |e| io.puts e[:display] }
                      io.close_write
                      io.read.strip
                    end
                  when "fzf"
                    `echo "#{menu_text}" | fzf --prompt="Manage: "`.strip
                  end

  return if selected_line.to_s.empty?

  selected = entries.find { |e| e[:display].strip == selected_line.strip }
  return unless selected

  case selected[:type]
  when :log
    open_log(selected[:log])
  when :kill_session
    uri = URI("#{SERVER_URL}/api/sessions/kill/#{selected[:card_key]}")
    Net::HTTP.post(uri, "", { "Content-Type" => "application/json" })
    system("notify-send", "Brainiac", "Killed session: #{selected[:agent]}")
  when :kill_child
    begin
      Process.kill("TERM", selected[:pid])
    rescue StandardError
      nil
    end
    Thread.new do
      sleep 3
      begin
        Process.kill("KILL", selected[:pid])
      rescue StandardError
        nil
      end
    end
    system("notify-send", "Brainiac", "Killed #{selected[:cmd]} (PID #{selected[:pid]})")
  end
end

def handle_thread(session)
  return unless session

  guild_id = load_discord_guild_id
  unless guild_id
    system("notify-send", "Brainiac", "No guild_id in discord.json")
    return
  end

  unless session["card_key"].to_s.start_with?("discord-")
    system("notify-send", "Brainiac", "Not a Discord session (#{session["agent"]})")
    return
  end

  thread_id = session["channel_id"]
  unless thread_id
    # Fallback: parse from card_key
    parts = session["card_key"].to_s.split("-")
    numeric_parts = parts.grep(/\A\d{15,}\z/)
    thread_id = numeric_parts.first
  end

  unless thread_id
    system("notify-send", "Brainiac", "Cannot determine thread ID")
    return
  end

  url = "https://discord.com/channels/#{guild_id}/#{thread_id}"
  spawn("xdg-open", url, %i[out err] => "/dev/null")
end

def generate_output(index)
  state = fetch_state

  if state["error"]
    puts({ text: "", tooltip: "", class: "" }.to_json) if index.positive?
    puts({ text: "⚠️", tooltip: "Brainiac Error: #{escape_pango(state["error"])}", class: "error" }.to_json) if index.zero?
    return
  end

  sessions = state["sessions"] || []

  if index.zero? && sessions.empty?
    puts({ text: "💤", tooltip: "No active agent sessions", class: "idle" }.to_json)
    return
  end

  session = sessions[index]
  unless session
    puts({ text: "", tooltip: "", class: "" }.to_json)
    return
  end

  agent = session["agent"]
  emoji = AGENTS.dig(agent&.downcase, :emoji) || DEFAULT_EMOJI
  elapsed = format_elapsed(session["elapsed_seconds"] || 0)
  context = format_context(session["card_key"])

  tooltip_lines = ["#{emoji} #{agent}: #{context} (#{elapsed})"]

  (session["children"] || []).each do |c|
    cmd_short = c["cmd"].to_s.split("/").last.to_s.split.first.to_s
    cmd_short = c["cmd"].to_s[0..40] if cmd_short.empty?
    next if INFRA_CMDS.any? { |ic| cmd_short.start_with?(ic) }

    tooltip_lines << "   └ #{escape_pango(cmd_short)} (#{format_elapsed(c["elapsed_seconds"])}) [PID #{c["pid"]}]"
  end

  tooltip_lines << "\nL-click: tail log | R-click: manage | M-click: open thread"

  puts({ text: emoji, tooltip: tooltip_lines.join("\n"), class: "working" }.to_json)
end

# --- Main ---

state = fetch_state
sessions = state["sessions"] || []
session = sessions[index]

if ARGV.include?("--tail")
  handle_tail(session)
elsif ARGV.include?("--manage")
  handle_manage(session)
elsif ARGV.include?("--thread")
  handle_thread(session)
else
  generate_output(index)
end
