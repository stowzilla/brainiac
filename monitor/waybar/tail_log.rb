#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Waybar — Left-click: Tail the active session log.
# If one session → tails immediately. If multiple → quick picker to choose.

require_relative "../shared"

AGENTS = load_agent_config.freeze
INFRA_CMDS = %w[kiro-cli-chat ruby-lsp clangd gopls].freeze

state = fetch_state

if state["error"]
  system("notify-send", "Brainiac Error", state["error"])
  exit 1
end

sessions = state["sessions"] || []

if sessions.empty?
  system("notify-send", "Brainiac", "No active agent sessions")
  exit 0
end

def open_log(log_file)
  return unless log_file && File.exist?(log_file)

  terminal = %w[alacritty kitty gnome-terminal xterm].find { |t| system("which #{t} > /dev/null 2>&1") }
  case terminal
  when "alacritty"
    spawn("alacritty", "-e", "tail", "-f", log_file)
  when "kitty"
    spawn("kitty", "tail", "-f", log_file)
  when "gnome-terminal"
    spawn("gnome-terminal", "--", "tail", "-f", log_file)
  else
    spawn("xterm", "-e", "tail", "-f", log_file)
  end
end

# Single session → open immediately
if sessions.size == 1
  open_log(sessions[0]["log_file"])
  exit 0
end

# Multiple sessions → quick picker
def find_launcher
  %w[rofi fuzzel wofi zenity fzf].find { |cmd| system("which #{cmd} > /dev/null 2>&1") }
end

def run_menu(launcher, entries)
  menu_text = entries.map { |e| e[:display] }.join("\n")
  case launcher
  when "rofi"
    IO.popen(%w[rofi -dmenu -i -p] + ["Tail Log"], "r+") do |io|
      io.puts menu_text
      io.close_write
      io.read.strip
    end
  when "fuzzel"
    IO.popen(%w[fuzzel --dmenu --prompt] + ["Tail Log: "], "r+") do |io|
      io.puts menu_text
      io.close_write
      io.read.strip
    end
  when "wofi"
    IO.popen(%w[wofi --dmenu --prompt] + ["Tail Log"], "r+") do |io|
      io.puts menu_text
      io.close_write
      io.read.strip
    end
  when "zenity"
    IO.popen(["zenity", "--list", "--title", "Tail Log", "--column", "Session", "--width", "600", "--height", "400"], "r+",
             err: "/dev/null") do |io|
      entries.each { |e| io.puts e[:display] }
      io.close_write
      io.read.strip
    end
  when "fzf"
    `echo "#{menu_text}" | fzf --prompt="Tail Log: "`.strip
  end
end

entries = sessions.map do |s|
  agent = s["agent"]
  elapsed = format_elapsed(s["elapsed_seconds"] || 0)
  context = format_context(s["card_key"])
  emoji = AGENTS.dig(agent&.downcase, :emoji) || DEFAULT_EMOJI
  { display: "#{emoji} #{agent}: #{context} (#{elapsed})", log_file: s["log_file"] }
end

launcher = find_launcher
unless launcher
  # Fallback: open first session's log
  open_log(sessions[0]["log_file"])
  exit 0
end

selected_line = run_menu(launcher, entries)
unless selected_line.to_s.empty?
  selected = entries.find { |e| e[:display].strip == selected_line.strip }
  open_log(selected[:log_file]) if selected
end
