#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac macOS Menu Bar Plugin (xbar/SwiftBar)
# Outputs xbar-format text: sessions, recent, deployments.

require "shellwords"
require "time"
require_relative "../shared"

SELF_PATH = File.realpath(__FILE__)
AGENTS = load_agent_config.freeze
CONFIG = load_monitor_config.freeze
FIZZY_ACCOUNT_ID = CONFIG["fizzy_account_id"]
DISCORD_GUILD_ID = CONFIG["discord_guild_id"]

LOG_VIEWER_PATH = File.join(File.dirname(SELF_PATH), "view_logs.rb")
DEPLOY_SCRIPT_PATH = File.join(File.dirname(SELF_PATH), "deploy_env.rb")
OPEN_SCRIPT = File.join(File.dirname(SELF_PATH), "open_action.sh")

def log_action(log_file)
  return "" unless log_file

  " | shell=#{LOG_VIEWER_PATH} param1=#{log_file} terminal=false refresh=false"
end

def full_log_action(log_file)
  return "" unless log_file

  " | shell=#{OPEN_SCRIPT} param1=#{log_file.shellescape} terminal=false refresh=false"
end

def prompt_url(card_key)
  return nil unless card_key

  if card_key.start_with?("card-")
    card_num = card_key.split("-")[1]
    "https://app.fizzy.do/#{FIZZY_ACCOUNT_ID}/cards/#{card_num}" if FIZZY_ACCOUNT_ID && card_num
  elsif card_key.start_with?("discord-") && DISCORD_GUILD_ID
    parts = card_key.split("-")
    channel_id = parts[-2]
    message_id = parts[-1]
    "https://discord.com/channels/#{DISCORD_GUILD_ID}/#{channel_id}/#{message_id}" if channel_id && message_id
  end
end

def prompt_action(card_key)
  url = prompt_url(card_key)
  url ? " | shell=#{OPEN_SCRIPT} param1=#{url} terminal=false refresh=false" : ""
end

def worktree_path(log_file, card_key)
  return nil unless log_file && card_key&.start_with?("card-")

  dir = File.dirname(log_file, 2)
  dir if File.directory?(dir) && dir != "/"
end

def worktree_action(log_file, card_key)
  path = worktree_path(log_file, card_key)
  path ? " | shell=#{OPEN_SCRIPT} param1=#{path.shellescape} terminal=false refresh=false" : ""
end

def render_session_submenu(session)
  lines = tail_log(session["log_file"]).map { |line| "-- #{format_log_line(line)} | font=#{LOG_FONT} size=#{LOG_SIZE}" }
  lines << "-- ---" if session["log_file"]
  lines << "-- Tail Log#{log_action(session["log_file"])}" if session["log_file"]
  lines << "-- View Full Log#{full_log_action(session["log_file"])}" if session["log_file"]
  lines << "-- Open Prompt#{prompt_action(session["card_key"])}" unless prompt_url(session["card_key"]).nil?
  wt = worktree_path(session["log_file"], session["card_key"])
  lines << "-- Open Worktree#{worktree_action(session["log_file"], session["card_key"])}" if wt
  lines
end

def generate_output
  state = fetch_state
  deployments = fetch_deployments

  return ["⚠️", "---", state["error"], "---", "Refresh | refresh=true"].join("\n") if state["error"] && !deployments

  sessions = state["sessions"] || []
  recent = state["recent"] || []
  lines = []

  # Title line
  parts = []
  parts << sessions.map { |s| AGENTS.dig(s["agent"]&.downcase, :emoji) || DEFAULT_EMOJI }.join(" ") if sessions.any?
  parts << deployments.map { |d| deploy_dot_emoji(d) }.join if deployments&.any?
  lines << (parts.any? ? parts.join(" ") : "💤")
  lines << "---"

  # Active sessions
  if sessions.any?
    lines << "Active | size=12"
    sessions.each do |s|
      agent_key = (s["agent"] || "").downcase
      emoji = AGENTS.dig(agent_key, :emoji) || DEFAULT_EMOJI
      color = AGENTS.dig(agent_key, :color)
      color_str = color ? " color=#{hex_color(color)}" : ""
      context = format_context(s["card_key"])
      elapsed = format_elapsed(s["elapsed_seconds"] || 0)
      lines << "#{emoji} #{s["agent"]}: #{context} (#{elapsed}) |#{color_str}"
      lines.concat(render_session_submenu(s))
    end
  else
    lines << "No active sessions | size=12"
  end

  # Recent
  if recent.any?
    lines << "---"
    lines << "Recent | size=12"
    recent.each do |s|
      emoji = AGENTS.dig((s["agent"] || "").downcase, :emoji) || DEFAULT_EMOJI
      context = format_context(s["card_key"])
      ago = time_ago(s["finished_at"]) || "?"
      lines << "#{emoji} #{s["agent"]}: #{context} — #{ago}"
      lines.concat(render_session_submenu(s))
    end
  end

  # Deployments
  if deployments&.any?
    lines << "---"
    lines << "Deployments | size=12"
    deployments.each do |d|
      label = d["label"] || d["env"]
      env = d["env"]
      dot = deploy_dot_emoji(d)
      if d["status"] == "occupied"
        card = d["card_number"] ? "##{d["card_number"]}" : d["branch"] || "unknown"
        ago = time_ago(d["deployed_at"])
        status_label = case d["last_deploy_status"]
                       when "deploying" then " — deploying…"
                       when "failed" then " — FAILED"
                       else ""
                       end
        line = "#{dot} #{label}: #{card}#{status_label}#{" (#{ago})" if ago}"
        lines << (d["url"] ? "#{line} | href=#{d["url"]}" : line)
      else
        ago = time_ago(d["cleared_at"])
        last = d["last_card"] ? " (was ##{d["last_card"]})" : ""
        lines << "#{dot} #{label}: Available#{" #{ago}" if ago}#{last}"
      end
      lines << "-- Deploy to #{label} | shell=#{DEPLOY_SCRIPT_PATH} param1=#{env} terminal=false refresh=true"
      lines << "-- Open #{label} | shell=#{OPEN_SCRIPT} param1=#{d["url"]} terminal=false refresh=false" if d["status"] == "occupied" && d["url"]
    end
  end

  lines << "---"
  lines << "Refresh | refresh=true"
  lines.join("\n")
end

puts generate_output
