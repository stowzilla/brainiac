# frozen_string_literal: true

# Shared helpers for all monitor scripts (waybar, xbar, daemon).
#
# Provides: constants, config loading, state fetching, formatting utilities.
# Require this at the top of any monitor script.

require "json"
require "net/http"
require "socket"
require "uri"

# --- Constants ---

SOCKET_PATH = "/tmp/brainiac-monitor.sock"
API_URL = "http://localhost:4567/api/status"
SERVER_URL = "http://localhost:4567"
CONFIG_PATH = File.expand_path("~/.brainiac/waybar.json")
BRAINIAC_DIR = File.expand_path("~/.brainiac")

# --- Agent Config ---

# Load agent configuration from ~/.brainiac/waybar.json.
# Returns { "sherlock" => { emoji: "🤖", color: "blue" }, ... }
def load_agent_config
  config = JSON.parse(File.read(CONFIG_PATH, encoding: "utf-8"))
  agents = {}
  (config["agents"] || []).each do |agent|
    agents[agent["name"].downcase] = { emoji: agent["emoji"], color: agent["color"] }
  end
  agents
rescue StandardError => e
  warn "Failed to load waybar.json: #{e.message}"
  {}
end

def load_monitor_config
  return {} unless File.exist?(CONFIG_PATH)

  JSON.parse(File.read(CONFIG_PATH, encoding: "utf-8"))
rescue StandardError
  {}
end

DEFAULT_EMOJI = "❓"

# --- State Fetching ---

# Fetch state from daemon socket (fast, no HTTP overhead).
def fetch_state_from_socket
  socket = UNIXSocket.new(SOCKET_PATH)
  data = socket.read
  socket.close
  JSON.parse(data)
end

# Fetch state from brainiac HTTP API (fallback when daemon not running).
def fetch_state_from_api
  uri = URI(API_URL)
  response = Net::HTTP.get_response(uri)
  return nil unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
rescue StandardError
  nil
end

# Fetch agent state — tries socket first, falls back to API.
def fetch_state
  fetch_state_from_socket
rescue Errno::ENOENT, Errno::ECONNREFUSED
  fetch_state_from_api || { "sessions" => [], "count" => 0, "error" => "server not reachable" }
rescue StandardError => e
  { "sessions" => [], "count" => 0, "error" => e.message }
end

# Fetch deployment state from API.
def fetch_deployments
  uri = URI("#{SERVER_URL}/api/deployments")
  response = Net::HTTP.get_response(uri)
  JSON.parse(response.body)["deployments"] || []
rescue StandardError
  nil
end

# --- Formatting ---

def format_elapsed(seconds)
  return "#{seconds}s" if seconds < 60

  minutes = seconds / 60
  return "#{minutes}m" if minutes < 60

  hours = minutes / 60
  return "#{hours}h" if hours < 24

  "#{hours / 24}d"
end

def format_context(card_key)
  return "" unless card_key

  if card_key.start_with?("discord-")
    "Discord"
  elsif card_key.start_with?("card-")
    "##{card_key.split("-")[1]}"
  else
    card_key
  end
end

def time_ago(iso_string)
  return nil unless iso_string

  seconds = (Time.now - Time.parse(iso_string)).to_i
  "#{format_elapsed(seconds)} ago"
rescue StandardError
  nil
end

# --- Log Preview ---

ANSI_REGEX = /\e\[[0-9;]*[a-zA-Z]|\e\[\?[0-9;]*[a-zA-Z]/
LOG_PREVIEW_LINES = 15
LOG_LINE_MAX = 80
LOG_FONT = "SFMono-Regular"
LOG_SIZE = 12

def tail_log(log_file, lines: LOG_PREVIEW_LINES)
  return [] unless log_file && File.exist?(log_file)

  raw = `tail -n 50 #{log_file.shellescape} 2>/dev/null`
  raw.encode("UTF-8", invalid: :replace, undef: :replace, replace: "")
     .lines
     .map { |l| l.gsub(ANSI_REGEX, "").gsub(/[^[:print:]\t]/, "").strip }
     .reject(&:empty?)
     .last(lines)
rescue StandardError
  []
end

def format_log_line(text)
  text.length > LOG_LINE_MAX ? "#{text[0, LOG_LINE_MAX]}…" : text
end

# --- Deploy Helpers ---

DEPLOY_RECENT_WINDOW = 30 * 60 # 30 minutes

def deploy_dot_emoji(dep)
  status = dep["last_deploy_status"]
  if status == "deploying"
    "🟠"
  elsif status == "failed"
    "💥"
  elsif dep["status"] == "occupied"
    deploy_time = dep["last_deploy_at"] || dep["deployed_at"]
    recent = deploy_time && (Time.now - Time.parse(deploy_time)) < DEPLOY_RECENT_WINDOW
    recent ? "🚀" : "🔴"
  else
    "🟢"
  end
end

# Resolve worktree path for a card number from card_map.json or filesystem glob.
def resolve_worktree(card_number, glob_base: "~/Code")
  # Try card_map.json first
  card_map_path = File.join(BRAINIAC_DIR, "card_map.json")
  if File.exist?(card_map_path)
    card_map = begin
      JSON.parse(File.read(card_map_path))
    rescue StandardError
      {}
    end
    entry = card_map.values.find { |e| e["number"].to_s == card_number.to_s }
    return entry["worktree"] if entry && entry["worktree"] && File.directory?(entry["worktree"].to_s)
  end

  # Fallback: glob
  matches = Dir.glob(File.expand_path("#{glob_base}/*fizzy-#{card_number}-*/"))
  matches.find { |d| File.directory?(d) }
end

# Generate the bash deploy script with terraform lock retry logic.
def deploy_bash_script(env_key, worktree:, aws_profile: nil)
  <<~BASH
    cd #{worktree.shellescape}
    #{"export AWS_PROFILE=#{aws_profile.shellescape}" if aws_profile}
    echo "🚀 Deploying to #{env_key}..."
    echo
    logfile=$(mktemp)
    ./scripts/deploy.sh #{env_key.shellescape} 2>&1 | tee "$logfile"
    status=${PIPESTATUS[0]}
    if [ $status -ne 0 ] && grep -q "checksums previously recorded in the dependency lock file" "$logfile"; then
      echo
      echo "⚠️  Terraform lock file mismatch — removing lock and running init -upgrade..."
      echo
      rm -f infrastructure/#{env_key.shellescape}/.terraform.lock.hcl
      (cd infrastructure/#{env_key.shellescape} && terraform init -upgrade)
      echo
      echo "🔄 Retrying deploy..."
      echo
      ./scripts/deploy.sh #{env_key.shellescape} 2>&1
      status=$?
    fi
    rm -f "$logfile"
    echo
    if [ $status -eq 0 ]; then echo "✅ Deploy complete"; else echo "❌ Deploy failed (exit $status)"; fi
    echo "Press Enter to close..."
    read
  BASH
end

# Mark an environment as deploying via the brainiac API.
def mark_deploying_via_api(env_key, worktree:)
  uri = URI("#{SERVER_URL}/api/deployments/#{env_key}/deploying")
  req = Net::HTTP::Post.new(uri, "Content-Type" => "application/json")
  req.body = { worktree: worktree }.to_json
  Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(req) }
rescue StandardError
  # Non-fatal — deploy proceeds even if server is unreachable
end

# Resolve AWS_PROFILE from deployments.json for an environment.
def resolve_aws_profile(env_key)
  config_file = File.join(BRAINIAC_DIR, "deployments.json")
  return nil unless File.exist?(config_file)

  cfg = begin
    JSON.parse(File.read(config_file))
  rescue StandardError
    {}
  end
  cfg.dig("environments", env_key, "aws_profile")
end

# --- Color ---

COLOR_MAP = {
  "red" => "#ff5555", "green" => "#50fa7b", "blue" => "#8be9fd",
  "yellow" => "#f1fa8c", "cyan" => "#8be9fd", "magenta" => "#ff79c6",
  "purple" => "#bd93f9", "pink" => "#ff79c6", "white" => "#f8f8f2"
}.freeze

def hex_color(name)
  COLOR_MAP[name] || name
end
