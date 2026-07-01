#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Waybar Status Module
# Reads from daemon socket and outputs JSON for waybar (agent sessions).

require_relative "../shared"

AGENTS = load_agent_config.freeze
INFRA_CMDS = %w[kiro-cli-chat ruby-lsp clangd gopls].freeze

def escape_pango(str)
  str.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")
end

def generate_output
  state = fetch_state

  return { text: "⚠️", tooltip: "Brainiac Error: #{escape_pango(state["error"])}", class: "error" } if state["error"]

  sessions = state["sessions"] || []

  return { text: "💤", tooltip: "No active agent sessions", class: "idle" } if sessions.empty?

  text = sessions.map { |s| AGENTS.dig(s["agent"]&.downcase, :emoji) || DEFAULT_EMOJI }.join(" ")

  tooltip_lines = sessions.map do |s|
    agent = s["agent"]
    emoji = AGENTS.dig(agent&.downcase, :emoji) || DEFAULT_EMOJI
    elapsed = format_elapsed(s["elapsed_seconds"] || 0)
    context = format_context(s["card_key"])

    lines = ["#{emoji} #{agent}: #{context} (#{elapsed})"]

    (s["children"] || []).each do |c|
      cmd_short = c["cmd"].to_s.split("/").last.to_s.split.first.to_s
      cmd_short = c["cmd"].to_s[0..40] if cmd_short.empty?
      next if INFRA_CMDS.any? { |ic| cmd_short.start_with?(ic) }

      lines << "   └ #{escape_pango(cmd_short)} (#{format_elapsed(c["elapsed_seconds"])}) [PID #{c["pid"]}]"
    end

    lines.join("\n")
  end

  tooltip_lines << "\n[Click to manage]"

  { text: text, tooltip: tooltip_lines.join("\n"), class: "working" }
end

puts generate_output.to_json
