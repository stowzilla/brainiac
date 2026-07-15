#!/usr/bin/env ruby
# frozen_string_literal: true

# One-time setup: installs Brainiac modules into waybar config.
#
# Adds:
#   - Per-session slot modules (custom/brainiac-session-0 through N)
#   - Per-environment deploy dots (custom/brainiac-deploy-<env>)
#
# Usage: ruby monitor/waybar/setup.rb

require "json"
require "fileutils"

WAYBAR_CONFIG = File.expand_path("~/.config/waybar/config.jsonc")
WAYBAR_STYLE  = File.expand_path("~/.config/waybar/style.css")
BRAINIAC_DIR  = File.expand_path("~/.brainiac")
DEPLOYMENTS_CONFIG = File.join(BRAINIAC_DIR, "deployments.json")
WAYBAR_JSON = File.join(BRAINIAC_DIR, "waybar.json")

# Max concurrent agent sessions to show (each gets its own clickable module)
MAX_SESSION_SLOTS = 8

# Wrapper scripts go to ~/.brainiac/bin/ and resolve from /api/status (server_root field)
# Falls back to the repo path where setup.rb was run from (handles gem version mismatch)
WRAPPER_DIR = File.join(BRAINIAC_DIR, "bin")
FileUtils.mkdir_p(WRAPPER_DIR)

# The directory where this setup script lives — used as fallback when the server_root
# (gem install) doesn't have newer files yet
SETUP_SOURCE_ROOT = File.expand_path("../..", __dir__)

def load_waybar_config
  content = File.read(WAYBAR_CONFIG)
  json_content = content.lines.reject { |line| line.strip.start_with?("//") }.join
  JSON.parse(json_content)
end

def save_waybar_config(config)
  File.write(WAYBAR_CONFIG, JSON.pretty_generate(config))
end

# Shared resolver code used by all wrapper scripts
RESOLVER_CODE = <<~RUBY
  require "json"
  require "net/http"
  require "uri"

  SETUP_SOURCE_ROOT = "#{SETUP_SOURCE_ROOT}"

  def resolve_server_root
    uri = URI("http://localhost:4567/api/status")
    response = Net::HTTP.start(uri.hostname, uri.port, open_timeout: 1, read_timeout: 2) { |http| http.get(uri.path) }
    if response.is_a?(Net::HTTPSuccess)
      data = JSON.parse(response.body)
      root = data["server_root"]
      return root if root && File.directory?(root)
    end
    root_file = File.expand_path("~/.brainiac/server.root")
    File.read(root_file).strip if File.exist?(root_file)
  rescue StandardError
    root_file = File.expand_path("~/.brainiac/server.root")
    File.exist?(root_file) ? File.read(root_file).strip : nil
  end

  def find_script(relative_path)
    # Try server_root first (gem install or running server's source)
    root = resolve_server_root
    if root
      script = File.join(root, relative_path)
      return script if File.exist?(script)
    end
    # Fallback: the repo where setup.rb was run from
    fallback = File.join(SETUP_SOURCE_ROOT, relative_path)
    return fallback if File.exist?(fallback)
    nil
  end
RUBY

# --- Create wrapper scripts ---

# Session slot wrapper (handles all session interactions)
session_slot_wrapper = File.join(WRAPPER_DIR, "waybar-session-slot")
File.write(session_slot_wrapper, <<~SCRIPT)
  #!/usr/bin/env ruby
  #{RESOLVER_CODE}
  script = find_script("monitor/waybar/session_slot.rb")
  exec("ruby", script, *ARGV) if script
  puts({ text: "", tooltip: "", class: "" }.to_json) unless ARGV.any? { |a| a.start_with?("--") }
SCRIPT
File.chmod(0o755, session_slot_wrapper)

# Log viewer wrapper (legacy — still available for global manage-all)
logs_wrapper = File.join(WRAPPER_DIR, "waybar-logs")
File.write(logs_wrapper, <<~SCRIPT)
  #!/usr/bin/env ruby
  #{RESOLVER_CODE}
  script = find_script("monitor/waybar/view_logs.rb")
  exec("ruby", script) if script
  warn "Brainiac: view_logs.rb not found"
SCRIPT
File.chmod(0o755, logs_wrapper)

# Deploy env wrapper
deploy_wrapper = File.join(WRAPPER_DIR, "waybar-deploy-env")
File.write(deploy_wrapper, <<~SCRIPT)
  #!/usr/bin/env ruby
  #{RESOLVER_CODE}
  script = find_script("monitor/waybar/deploy_env.rb")
  if script
    load script
    exit
  end
  puts({ text: "", tooltip: "Brainiac: deploy_env.rb not found", class: "error" }.to_json)
SCRIPT
File.chmod(0o755, deploy_wrapper)

puts "✓ Created wrapper scripts in #{WRAPPER_DIR}"

# --- Determine session slot count ---

session_slots = MAX_SESSION_SLOTS
if File.exist?(WAYBAR_JSON)
  waybar_cfg = begin
    JSON.parse(File.read(WAYBAR_JSON))
  rescue StandardError
    {}
  end
  session_slots = waybar_cfg["max_session_slots"] if waybar_cfg["max_session_slots"]
end

# --- Update waybar config ---

config = load_waybar_config

# Clean up old brainiac modules from all positions
%w[modules-left modules-center modules-right].each do |pos|
  next unless config[pos]

  config[pos].reject! { |m| m.to_s.include?("brainiac") }
end
config.each_key { |key| config.delete(key) if key.to_s.include?("brainiac") }

# Add per-session slot modules to modules-center
config["modules-center"] ||= []

session_slots.times do |i|
  mod_name = "custom/brainiac-session-#{i}"
  config["modules-center"] << mod_name

  config[mod_name] = {
    "exec" => "#{session_slot_wrapper} #{i}",
    "return-type" => "json",
    "interval" => 3,
    "format" => "{}",
    "tooltip" => true,
    "on-click" => "#{session_slot_wrapper} #{i} --tail",
    "on-click-right" => "#{session_slot_wrapper} #{i} --manage",
    "on-click-middle" => "#{session_slot_wrapper} #{i} --thread"
  }
end

puts "✓ Added #{session_slots} session slot module(s)"

# Add per-environment deploy modules (if deployments.json exists)
if File.exist?(DEPLOYMENTS_CONFIG)
  deployments = JSON.parse(File.read(DEPLOYMENTS_CONFIG))
  envs = (deployments["environments"] || {}).keys

  center = config["modules-center"]
  # Insert deploys after the session slots
  insert_idx = center.rindex { |m| m.to_s.include?("brainiac-session") }&.+(1) || center.length

  envs.each_with_index do |env, i|
    mod_name = "custom/brainiac-deploy-#{env}"
    center.insert(insert_idx + i, mod_name)

    config[mod_name] = {
      "exec" => "#{deploy_wrapper} #{env}",
      "return-type" => "json",
      "interval" => 30,
      "format" => "{}",
      "tooltip" => true,
      "escape" => false,
      "on-click" => "#{deploy_wrapper} #{env} --click",
      "on-click-right" => "#{deploy_wrapper} #{env} --deploy"
    }
  end

  puts "✓ Added #{envs.size} deploy environment module(s): #{envs.join(", ")}"
end

save_waybar_config(config)
puts "✓ Updated waybar config at #{WAYBAR_CONFIG}"

# --- Update CSS ---

style = File.exist?(WAYBAR_STYLE) ? File.read(WAYBAR_STYLE) : ""

unless style.include?("brainiac-session")
  # Remove old single-module style if present
  style = style.gsub(/\/\* Brainiac agent session module \*\/\n#custom-brainiac \{[^}]*\}\n?/, "")

  css = <<~CSS

    /* Brainiac per-session slot modules */
    [id^="custom-brainiac-session-"] {
      padding: 0 2px;
    }

    /* Brainiac per-environment deploy dots */
    [id^="custom-brainiac-deploy-"] {
      font-size: 28px;
      padding: 0 6px;
      border-radius: 8px;
      border: 2px solid transparent;
    }

    [id^="custom-brainiac-deploy-"].deploy-recent {
      border: 2px solid #4488ff;
    }

    [id^="custom-brainiac-deploy-"].deploy-failed {
      border: 2px solid #ff4444;
    }
  CSS
  File.write(WAYBAR_STYLE, "#{style.strip}\n#{css}")
  puts "✓ Added brainiac styles to #{WAYBAR_STYLE}"
end

puts ""
puts "Restart waybar to apply: omarchy restart waybar"
