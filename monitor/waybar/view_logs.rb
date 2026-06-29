#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Log Viewer (Linux — rofi/fuzzel/wofi/zenity/fzf)
# Shows a menu to select which agent log to tail, with kill support.

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

# Build menu entries: sessions + their child processes
entries = []
sessions.each do |s|
  agent = s["agent"]
  elapsed = format_elapsed(s["elapsed_seconds"])
  context = format_context(s["card_key"])
  emoji = AGENTS.dig(agent&.downcase, :emoji) || DEFAULT_EMOJI
  entries << { display: "#{emoji} #{agent}: #{context} (#{elapsed})", type: :log, log: s["log_file"] }
  entries << { display: "   ⛔ Kill session: #{agent} (#{context})", type: :kill_session, card_key: s["card_key"], agent: agent }

  (s["children"] || []).each do |c|
    cmd_short = c["cmd"].to_s.split("/").last.to_s.split.first.to_s
    cmd_short = c["cmd"].to_s[0..40] if cmd_short.empty?
    next if INFRA_CMDS.any? { |ic| cmd_short.start_with?(ic) }

    entries << {
      display: "   └ 🔪 Kill: #{cmd_short} (#{format_elapsed(c["elapsed_seconds"])}) [PID #{c["pid"]}]",
      type: :kill_child, pid: c["pid"], cmd: cmd_short
    }
  end
end

# If only one session with no children, open log directly
if entries.size == 1 && entries[0][:type] == :log
  spawn("alacritty", "-e", "tail", "-f", entries[0][:log]) if entries[0][:log]
  exit 0
end

def find_launcher
  %w[rofi fuzzel wofi zenity fzf].find { |cmd| system("which #{cmd} > /dev/null 2>&1") }
end

def run_menu(launcher, entries)
  menu_text = entries.map { |e| e[:display] }.join("\n")
  case launcher
  when "rofi"
    IO.popen(%w[rofi -dmenu -i -p] + ["Agent Sessions"], "r+") do |io|
      io.puts menu_text
      io.close_write
      io.read.strip
    end
  when "fuzzel"
    IO.popen(%w[fuzzel --dmenu --prompt] + ["Agent Sessions: "], "r+") do |io|
      io.puts menu_text
      io.close_write
      io.read.strip
    end
  when "wofi"
    IO.popen(%w[wofi --dmenu --prompt] + ["Agent Sessions"], "r+") do |io|
      io.puts menu_text
      io.close_write
      io.read.strip
    end
  when "zenity"
    IO.popen(["zenity", "--list", "--title", "Agent Sessions", "--column", "Session", "--width", "600", "--height", "400"], "r+", err: "/dev/null") do |io|
      entries.each { |e| io.puts e[:display] }
      io.close_write
      io.read.strip
    end
  when "fzf"
    `echo "#{menu_text}" | fzf --prompt="Agent Sessions: "`.strip
  end
end

launcher = find_launcher
unless launcher
  system("notify-send", "Brainiac", "No menu launcher found (install rofi, fuzzel, wofi, zenity, or fzf)")
  exit 1
end

selected_line = run_menu(launcher, entries)

unless selected_line.to_s.empty?
  selected = entries.find { |e| e[:display].strip == selected_line.strip }
  if selected
    case selected[:type]
    when :log
      spawn("alacritty", "-e", "tail", "-f", selected[:log]) if selected[:log]
    when :kill_session
      uri = URI("#{SERVER_URL}/api/sessions/kill/#{selected[:card_key]}")
      response = Net::HTTP.post(uri, "", { "Content-Type" => "application/json" })
      msg = response.is_a?(Net::HTTPSuccess) ? "Killed session: #{selected[:agent]}" : "Failed to kill session: #{selected[:agent]}"
      system("notify-send", "Brainiac", msg)
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
end
