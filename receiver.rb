#!/usr/bin/env ruby

# Brainiac — modular webhook receiver
#
# This is the thin entry point. All logic lives in lib/brainiac/*.
# Start with: ruby receiver.rb

require "sinatra"
require "json"

# The directory this server is running from (supports worktrees)
SERVER_ROOT = File.expand_path(__dir__)

# Load all modules
require_relative "lib/brainiac/hooks"
require_relative "lib/brainiac/config"
require_relative "lib/brainiac/users"
require_relative "lib/brainiac/agents"
require_relative "lib/brainiac/brain"
require_relative "lib/brainiac/skills"
require_relative "lib/brainiac/sessions"
require_relative "lib/brainiac/prompts"
require_relative "lib/brainiac/helpers"
require_relative "lib/brainiac/notifications"
require_relative "lib/brainiac/cron"
require_relative "lib/brainiac/restart"
require_relative "lib/brainiac/plugins"
require_relative "lib/brainiac/handlers/shared/git"
require_relative "lib/brainiac/handlers/shared/inline_tags"

# Namespace for gem-based plugins (brainiac-whatsapp, brainiac-slack, etc.)
module Brainiac
  module Plugins
  end
end

# --- Custom handlers + plugins ---

# Reload hook registry — custom handlers register callbacks here
module ReloadHooks
  @hooks = []

  def self.register(name, &block)
    @hooks << { name: name, block: block }
  end

  def self.run_all!
    @hooks.each { |hook| hook[:block].call }
  end
end

def register_reload_hook(name, &)
  ReloadHooks.register(name, &)
end

# Load custom handlers from ~/.brainiac/handlers/ (legacy plugin system)
CUSTOM_HANDLERS_DIR = File.join(BRAINIAC_DIR, "handlers")
if Dir.exist?(CUSTOM_HANDLERS_DIR)
  Dir.glob(File.join(CUSTOM_HANDLERS_DIR, "*.rb")).each do |handler|
    handler_name = File.basename(handler, ".rb")
    LOG.info "[Handlers] Loading custom handler: #{handler_name}"
    require handler
  end
end

# --- Load gem-based plugins (brainiac-*) ---
load_plugins!(Sinatra::Application)

# Emit server_started hook — plugins can run startup tasks (backfill, background jobs, etc.)
Brainiac.emit(:server_started)

# --- Sinatra config ---
set :host_authorization, { permit_all: true }

# Disable Sinatra's default logging (we use SelectiveLogger instead)
set :logging, false

# Suppress Sinatra/Puma startup banners — we log our own version line
disable :show_exceptions
set :quiet, true
set :server_settings, { Silent: true }

# Custom logger that filters polling endpoints unless LOG_LEVEL=debug
SILENT_POLL_PATHS = %w[/api/status /api/deployments].freeze

class SelectiveLogger < Rack::CommonLogger
  def call(env)
    if SILENT_POLL_PATHS.include?(env["PATH_INFO"]) && LOG.level > Logger::DEBUG
      @app.call(env)
    else
      super
    end
  end
end

configure do
  use SelectiveLogger, LOG
end

LOG.info "[Brainiac] Starting v#{BRAINIAC_VERSION} on port #{settings.port} (#{settings.environment})"

# --- Dashboard authentication ---

helpers do
  def authenticate_dashboard!
    return unless DASHBOARD_TOKEN # No token configured = no auth (local-only mode)

    provided = params["token"] || request.env["HTTP_AUTHORIZATION"]&.sub(/^Bearer /i, "")
    halt 401, "Unauthorized" unless provided == DASHBOARD_TOKEN
  end

  def localhost_request?
    host = request.env["HTTP_HOST"].to_s
    host.include?("localhost") || host.include?("127.0.0.1")
  end
end

before "/dashboard" do
  authenticate_dashboard!
end

before "/api/*" do
  # Skip auth for all localhost requests (CLI, waybar, daemon, etc.)
  pass if localhost_request?
  # Skip auth for webhook-related routes that have their own verification
  pass if request.path_info == "/api/discord"
  authenticate_dashboard!
end

# --- Admin API routes ---
require_relative "lib/brainiac/routes/api"

# --- Dashboard ---

WAYBAR_CONFIG_PATH = File.expand_path("~/.brainiac/waybar.json")

def load_dashboard_agents
  return {} unless File.exist?(WAYBAR_CONFIG_PATH)

  config = JSON.parse(File.read(WAYBAR_CONFIG_PATH))
  agents = {}
  (config["agents"] || []).each { |a| agents[a["name"].downcase] = { emoji: a["emoji"], color: a["color"] } }
  agents
rescue StandardError
  {}
end

get "/dashboard" do
  content_type :html
  erb :dashboard, layout: false
end

# --- Discord fallback (plugin handles startup when installed) ---

unless Brainiac.channel_prompts[:discord]
  get "/api/discord" do
    content_type :json
    { enabled: false, reason: "brainiac-discord plugin not installed" }.to_json
  end
end

start_brainiac_restart_monitor

LOG.info "[Cron] Starting cron thread..."
start_cron_thread

# Skill curator: runs daily, archives stale skills, logs consolidation candidates.
CURATOR_THREAD = Thread.new do
  loop do
    sleep(86_400) # Run once per day
    LOG.info "[Curator] Running scheduled skill curation..."
    curate_skills
  rescue StandardError => e
    LOG.warn "[Curator] Error: #{e.message}"
  end
end

LOG.info "[Monitor] Starting daemon..."
daemon_path = File.join(__dir__, "monitor", "daemon.rb")
daemon_pid_file = "/tmp/brainiac-daemon.pid"

# Kill old daemon if it exists
if File.exist?(daemon_pid_file)
  old_pid = File.read(daemon_pid_file).strip.to_i
  begin
    Process.kill("TERM", old_pid)
    LOG.info "[Monitor] Killed old daemon (PID #{old_pid})"
  rescue Errno::ESRCH
    LOG.debug "[Monitor] Old daemon PID #{old_pid} not running"
  end
end

# Start new daemon
pid = spawn("ruby", daemon_path, chdir: __dir__, out: "/dev/null", err: "/dev/null")
File.write(daemon_pid_file, pid)
Process.detach(pid)
LOG.info "[Monitor] Daemon started (PID #{pid})"
