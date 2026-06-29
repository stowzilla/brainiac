#!/usr/bin/env ruby
# frozen_string_literal: true

# One-time setup: installs Brainiac modules into waybar config.
#
# Adds:
#   - Agent session status module (custom/brainiac)
#   - Per-environment deploy dots (custom/brainiac-deploy-<env>)
#
# Usage: ruby monitor/waybar/setup.rb

require "json"
require "fileutils"

WAYBAR_CONFIG = File.expand_path("~/.config/waybar/config.jsonc")
WAYBAR_STYLE  = File.expand_path("~/.config/waybar/style.css")
BRAINIAC_DIR  = File.expand_path("~/.brainiac")
DEPLOYMENTS_CONFIG = File.join(BRAINIAC_DIR, "deployments.json")

# Wrapper scripts go to ~/.brainiac/bin/ and resolve from server.root
WRAPPER_DIR = File.join(BRAINIAC_DIR, "bin")
FileUtils.mkdir_p(WRAPPER_DIR)

def load_waybar_config
  content = File.read(WAYBAR_CONFIG)
  json_content = content.lines.reject { |line| line.strip.start_with?("//") }.join
  JSON.parse(json_content)
end

def save_waybar_config(config)
  File.write(WAYBAR_CONFIG, JSON.pretty_generate(config))
end

# --- Create wrapper scripts ---

# Status wrapper
status_wrapper = File.join(WRAPPER_DIR, "waybar-status")
File.write(status_wrapper, <<~SCRIPT)
  #!/usr/bin/env ruby
  root_file = File.expand_path("~/.brainiac/server.root")
  if File.exist?(root_file)
    server_root = File.read(root_file).strip
    script = File.join(server_root, "monitor", "waybar", "status.rb")
    if File.exist?(script)
      load script
      exit
    end
  end
  require "json"
  puts({ text: "⚠️", tooltip: "Brainiac server root not found", class: "error" }.to_json)
SCRIPT
File.chmod(0o755, status_wrapper)

# Log viewer wrapper
logs_wrapper = File.join(WRAPPER_DIR, "waybar-logs")
File.write(logs_wrapper, <<~SCRIPT)
  #!/usr/bin/env ruby
  root_file = File.expand_path("~/.brainiac/server.root")
  if File.exist?(root_file)
    server_root = File.read(root_file).strip
    script = File.join(server_root, "monitor", "waybar", "view_logs.rb")
    exec("ruby", script) if File.exist?(script)
  end
  warn "Brainiac server root not found"
SCRIPT
File.chmod(0o755, logs_wrapper)

# Deploy env wrapper
deploy_wrapper = File.join(WRAPPER_DIR, "waybar-deploy-env")
File.write(deploy_wrapper, <<~SCRIPT)
  #!/usr/bin/env ruby
  root_file = File.expand_path("~/.brainiac/server.root")
  if File.exist?(root_file)
    server_root = File.read(root_file).strip
    script = File.join(server_root, "monitor", "waybar", "deploy_env.rb")
    if File.exist?(script)
      load script
      exit
    end
  end
  require "json"
  puts({ text: "", tooltip: "Brainiac server root not found", class: "error" }.to_json)
SCRIPT
File.chmod(0o755, deploy_wrapper)

puts "✓ Created wrapper scripts in #{WRAPPER_DIR}"

# --- Update waybar config ---

config = load_waybar_config

# Clean up old brainiac modules from all positions
%w[modules-left modules-center modules-right].each do |pos|
  next unless config[pos]

  config[pos].reject! { |m| m.to_s.include?("brainiac") }
end
config.each_key { |key| config.delete(key) if key.to_s.include?("brainiac") }

# Add agent session module to modules-center
config["modules-center"] ||= []
config["modules-center"] << "custom/brainiac"

config["custom/brainiac"] = {
  "exec" => status_wrapper,
  "return-type" => "json",
  "interval" => 3,
  "format" => "{}",
  "tooltip" => true,
  "on-click" => logs_wrapper
}

# Add per-environment deploy modules (if deployments.json exists)
if File.exist?(DEPLOYMENTS_CONFIG)
  deployments = JSON.parse(File.read(DEPLOYMENTS_CONFIG))
  envs = (deployments["environments"] || {}).keys

  center = config["modules-center"]
  brainiac_idx = center.index("custom/brainiac") || center.length

  envs.each_with_index do |env, i|
    mod_name = "custom/brainiac-deploy-#{env}"
    center.insert(brainiac_idx + i, mod_name)

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

unless style.include?("#custom-brainiac")
  css = <<~CSS

    /* Brainiac agent session module */
    #custom-brainiac {
      padding-right: 100px;
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
