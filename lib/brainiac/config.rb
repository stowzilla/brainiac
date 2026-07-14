# frozen_string_literal: true

require "json"
require "openssl"
require "open3"
require "fileutils"
require "logger"
require "securerandom"
require "net/http"
require "uri"

# --- Version ---

require_relative "version"
require_relative "config_loader"
BRAINIAC_VERSION = Brainiac::VERSION

# --- Environment & paths ---

BRAINIAC_DIR = ENV.fetch("BRAINIAC_DIR", File.join(Dir.home, ".brainiac"))
PROJECTS_FILE = File.join(BRAINIAC_DIR, "projects.json")
KIRO_AGENTS_DIR = File.join(Dir.home, ".kiro", "agents")
WORK_ITEM_MAP_FILE = File.join(BRAINIAC_DIR, "work_items.json")
AGENT_REGISTRY_FILE = File.join(BRAINIAC_DIR, "agents.json")

# --- Master config (handler toggles, global settings) ---

BRAINIAC_CONFIG_FILE = File.join(BRAINIAC_DIR, "brainiac.json")

def load_brainiac_config
  # Try TOML first (brainiac.toml), fall back to brainiac.json
  config_base = File.join(BRAINIAC_DIR, "brainiac")
  Brainiac::ConfigLoader.load(config_base, default: {})
rescue StandardError => e
  LOG.error "Failed to parse brainiac config: #{e.message}" if defined?(LOG)
  {}
end

BRAINIAC_CONFIG = load_brainiac_config

# --- Default agent name ---
# Priority: AI_AGENT_NAME env var → brainiac config "default_agent" → first agent in agents → error.
def resolve_default_agent
  # 1. Env var
  name = ENV.fetch("AI_AGENT_NAME", nil)
  return name if name

  # 2. brainiac config (brainiac.toml or brainiac.json)
  name = BRAINIAC_CONFIG["default_agent"]
  return name if name

  # 3. First agent in agents config (agents.toml or agents.json)
  agents_base = File.join(BRAINIAC_DIR, "agents")
  agents = Brainiac::ConfigLoader.load(agents_base, default: {})
  first_agent = agents.values.first
  if first_agent
    agent_name = first_agent["fizzy_name"] || first_agent["display_name"] || agents.keys.first.capitalize
    warn <<~MSG
      [Brainiac] No default agent configured — using "#{agent_name}" (first agent in agents config).
      To set explicitly, either:
        export AI_AGENT_NAME="#{agent_name}"
      Or add to ~/.brainiac/brainiac.toml:
        default_agent = "#{agent_name}"
    MSG
    return agent_name
  end

  # 4. Nothing found
  raise <<~MSG
    No default agent configured and no agents found.
    Set one of:
      1. Environment variable: export AI_AGENT_NAME="YourAgent"
      2. In ~/.brainiac/brainiac.toml: default_agent = "YourAgent"
      3. In ~/.brainiac/brainiac.json: { "default_agent": "YourAgent" }
  MSG
end

AI_AGENT_NAME = resolve_default_agent

LOG_LEVEL = ENV.fetch("LOG_LEVEL", "info").downcase
LOG = Logger.new($stdout)
LOG.level = case LOG_LEVEL
            when "debug" then Logger::DEBUG
            when "info" then Logger::INFO
            when "warn" then Logger::WARN
            when "error" then Logger::ERROR
            else Logger::INFO # rubocop:disable Lint/DuplicateBranch
            end

# --- Brain paths ---

BRAIN_BASE_DIR       = File.join(BRAINIAC_DIR, "brain")
KNOWLEDGE_DIR        = File.join(BRAIN_BASE_DIR, "knowledge")
PERSONA_BASE_DIR     = File.join(BRAIN_BASE_DIR, "persona")
MEMORY_BASE_DIR      = File.join(BRAINIAC_DIR, "brain", "memory")
MEMORY_FILE_TEMPLATE = "card-{{CARD_ID}}.md"
KNOWLEDGE_COLLECTION = "brainiac-knowledge"

# --- Roles ---

ROLES_DIR = File.join(BRAINIAC_DIR, "roles")

NOTIFICATION_COMMAND = ENV.fetch("NOTIFICATION_COMMAND", nil)

# --- Projects ---

def load_projects_config
  projects_base = File.join(BRAINIAC_DIR, "projects")
  projects = Brainiac::ConfigLoader.load(projects_base, default: {})
  LOG.info "Loaded #{projects.size} project(s)" if projects.any?
  projects
rescue StandardError => e
  LOG.error "Failed to parse projects config: #{e.message}"
  {}
end

# Track file mtimes to avoid unnecessary reloads
CONFIG_MTIMES = {}

def file_changed?(path, force: false)
  return true if force
  return true unless File.exist?(path)

  current_mtime = File.mtime(path)
  last_mtime = CONFIG_MTIMES[path]
  if last_mtime == current_mtime
    false
  else
    CONFIG_MTIMES[path] = current_mtime
    true
  end
end

def reload_projects!(force: false)
  # Check both possible formats for changes
  projects_base = File.join(BRAINIAC_DIR, "projects")
  resolved = Brainiac::ConfigLoader.resolve_path(projects_base) || PROJECTS_FILE
  return unless file_changed?(resolved, force: force)

  PROJECTS.replace(load_projects_config)
  LOG.info "Reloaded projects configuration: #{PROJECTS.keys.join(", ")}"
end

PROJECTS = load_projects_config

DEFAULT_PROJECT = {
  "repo_path" => ENV.fetch("REPO_PATH", Dir.pwd),
  "github_repo" => ENV.fetch("GITHUB_REPO", nil),
  # CLI defaults below are overridden by ~/.brainiac/cli-providers/*.json when a
  # cli_provider is configured on the project or agent. These only apply as a
  # last-resort fallback when no provider config exists.
  "agent_cli" => ENV.fetch("AGENT_CLI", "kiro-cli"),
  "agent_cli_args" => ENV.fetch("AGENT_CLI_ARGS", "chat --trust-all-tools --no-interactive"),
  "agent_model_flag" => ENV["AGENT_MODEL_FLAG"] || "--model",
  "agent_model" => ENV.fetch("AGENT_MODEL", nil),
  "agent_effort_flag" => ENV["AGENT_EFFORT_FLAG"] || "--effort",
  "agent_effort" => ENV.fetch("AGENT_EFFORT", nil),
  "allowed_models" => {
    "opus" => "claude-opus-4.6",
    "sonnet" => "claude-sonnet-4.6",
    "haiku" => "claude-haiku-4.5",
    "deepseek" => "deepseek-3.2",
    "minimax" => "minimax-m2.5",
    "minimax25" => "minimax-m2.5",
    "minimax21" => "minimax-m2.1",
    "qwen" => "qwen3-coder-next",
    "auto" => "auto"
  },
  "allowed_efforts" => %w[low medium high xhigh max]
}.freeze

# --- Version check ---

# Check if local brainiac is behind origin/master.
# Returns { behind: true, local_sha:, remote_sha:, commits_behind: } or { behind: false }
def check_brainiac_version
  brainiac_dir = File.join(__dir__, "..", "..")

  # Fetch latest from origin (quiet, don't fail if offline)
  _, _, status = Open3.capture3("git", "fetch", "origin", "master", "--quiet", chdir: brainiac_dir)
  unless status.success?
    LOG.warn "[Version] Could not fetch origin/master — skipping version check"
    return { behind: false }
  end

  local_sha, = Open3.capture3("git", "rev-parse", "HEAD", chdir: brainiac_dir)
  remote_sha, = Open3.capture3("git", "rev-parse", "origin/master", chdir: brainiac_dir)
  local_sha = local_sha.strip
  remote_sha = remote_sha.strip

  return { behind: false } if local_sha == remote_sha

  count, = Open3.capture3("git", "rev-list", "--count", "HEAD..origin/master", chdir: brainiac_dir)
  { behind: true, local_sha: local_sha[0..6], remote_sha: remote_sha[0..6], commits_behind: count.strip.to_i }
end

# Owner identifier (for version-outdated notifications).
# Reads from brainiac config (brainiac.toml or brainiac.json).
def owner_id
  config_base = File.join(BRAINIAC_DIR, "brainiac")
  config = Brainiac::ConfigLoader.load(config_base, default: {})
  config["owner_id"]
end

# --- Dashboard auth ---

DASHBOARD_TOKEN = begin
  config_base = File.join(BRAINIAC_DIR, "brainiac")
  config = Brainiac::ConfigLoader.load(config_base, default: {})
  config["dashboard_token"]
end
