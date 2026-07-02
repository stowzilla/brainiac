#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Waybar Per-Environment Deploy Module
# Usage: deploy_env.rb <env_key>
#        deploy_env.rb <env_key> --click
#        deploy_env.rb <env_key> --deploy

require "shellwords"
require "time"
require_relative "../shared"

env_key = ARGV.find { |a| !a.start_with?("--") }
unless env_key
  puts({ text: "?", tooltip: "No env specified", class: "error" }.to_json)
  exit
end

def resize_deploy_terminal
  script = "sleep 0.5 && " \
           'width=$(hyprctl monitors -j | ruby -rjson -e "puts JSON.parse(STDIN.read)[0][%q(width)]") && ' \
           "delta=$(( (width / 2) - (width * 15 / 100) )) && " \
           'hyprctl --batch "dispatch focuswindow class:brainiac-deploy; dispatch resizeactive -${delta} 0"'
  spawn("bash", "-c", script, %i[out err] => "/dev/null")
end

def handle_click(env_key, deployment)
  return unless deployment

  if deployment["last_deploy_status"] == "failed" && deployment["last_deploy_log"]
    log = deployment["last_deploy_log"]
    if File.exist?(log.to_s)
      label = deployment["label"] || env_key
      cmd = "echo '=== Deploy failure: #{label} ===' && echo && " \
            "cat #{Shellwords.escape(log)} && echo && echo 'Press Enter to close...' && read"
      spawn("alacritty", "--class", "brainiac-deploy", "-e", "bash", "-c", cmd,
            %i[out err] => "/dev/null")
      resize_deploy_terminal
      return
    end
  end

  url = deployment["url"]
  spawn("xdg-open", url, %i[out err] => "/dev/null") if url
end

def handle_deploy(env_key, deployment)
  return unless deployment

  prefill = deployment["status"] == "occupied" && deployment["card_number"] ? deployment["card_number"].to_s : ""
  card_number = `timeout 60 zenity --entry --title="Deploy to #{env_key}" --text="Card number:"#{unless prefill.empty?
                                                                                                   " --entry-text=#{Shellwords.escape(prefill)}"
                                                                                                 end} 2>/dev/null`.strip
  return if card_number.empty?

  worktree = resolve_worktree(card_number)
  unless worktree
    `timeout 10 zenity --error --text="No worktree found for card ##{card_number}" 2>/dev/null`
    return
  end

  aws_profile = resolve_aws_profile(env_key)
  mark_deploying_via_api(env_key, worktree: worktree)

  script = deploy_bash_script(env_key, worktree: worktree, aws_profile: aws_profile)
  spawn("alacritty", "--class", "brainiac-deploy", "-e", "bash", "-c", script, %i[out err] => "/dev/null")
  resize_deploy_terminal
end

def generate_output(env_key)
  deployments = fetch_deployments
  unless deployments
    puts({ text: "", tooltip: "#{env_key}: server unreachable", class: "error" }.to_json)
    return
  end

  d = deployments.find { |dep| dep["env"] == env_key }
  unless d
    puts({ text: "", tooltip: "#{env_key}: not configured", class: "error" }.to_json)
    return
  end

  label = d["label"] || env_key

  if d["status"] == "occupied"
    deploy_time = d["last_deploy_at"] || d["deployed_at"]
    recent = deploy_time && (Time.now - Time.parse(deploy_time)) < DEPLOY_RECENT_WINDOW
    status = d["last_deploy_status"]

    if status == "deploying"
      dot = '<span color="#ffaa00">●</span>'
      css_class = "deploy-deploying"
    elsif status == "failed"
      dot = '<span color="#ff4444">●</span>'
      css_class = "deploy-failed"
    elsif recent && status == "success"
      dot = '<span color="#4488ff">●</span>'
      css_class = "deploy-recent"
    else
      dot = '<span color="#ff4444">●</span>'
      css_class = "deploy-occupied"
    end

    card = d["card_number"] ? "##{d["card_number"]}" : d["branch"] || "unknown"
    branch = d["branch"] ? " — #{d["branch"]}" : ""
    ago = time_ago(d["deployed_at"])
    status_icon = case status
                  when "deploying" then "🚀"
                  when "failed" then "💥"
                  when "success" then recent ? "🚀✅" : "🔴"
                  else "🔴"
                  end
    tooltip = "#{status_icon} #{label}: #{card}#{branch}#{" (#{ago})" if ago}\nClick: open URL | Right-click: deploy"
  else
    dot = '<span color="#44ff44">●</span>'
    css_class = "deploy-available"
    ago = time_ago(d["cleared_at"])
    last = d["last_card"] ? " (was ##{d["last_card"]})" : ""
    tooltip = "🟢 #{label}: Available#{" #{ago}" if ago}#{last}\nRight-click: deploy"
  end

  puts({ text: dot, tooltip: tooltip, class: css_class }.to_json)
end

deployments = fetch_deployments
deployment = deployments&.find { |d| d["env"] == env_key }

if ARGV.include?("--click")
  handle_click(env_key, deployment)
elsif ARGV.include?("--deploy")
  handle_deploy(env_key, deployment)
else
  generate_output(env_key)
end
