# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "logger"
require "tempfile"
require "open3"
require "securerandom"

# --- Set up a single test environment used by ALL test files ---
# This is critical: rake test loads all test files into one process.

TEST_BRAINIAC_DIR = Dir.mktmpdir("brainiac-test")

# Set env vars BEFORE loading any brainiac modules
ENV["BRAINIAC_DIR"] = TEST_BRAINIAC_DIR
ENV["AI_AGENT_NAME"] = "Galen"
ENV["LOG_LEVEL"] = "error"

# Create the full directory structure
[
  File.join(TEST_BRAINIAC_DIR, "brain", "knowledge"),
  File.join(TEST_BRAINIAC_DIR, "brain", "persona", "galen"),
  File.join(TEST_BRAINIAC_DIR, "brain", "persona", "glados"),
  File.join(TEST_BRAINIAC_DIR, "brain", "memory", "galen"),
  File.join(TEST_BRAINIAC_DIR, "brain", "memory", "glados"),
  File.join(TEST_BRAINIAC_DIR, "roles"),
  File.join(TEST_BRAINIAC_DIR, "cli-providers"),
  File.join(TEST_BRAINIAC_DIR, "plans")
].each { |d| FileUtils.mkdir_p(d) }

# Write agent registry
agent_data = {
  "galen" => { "display_name" => "Galen", "local" => true,
               "env" => { "SERVICE_TOKEN" => "token_galen", "DISCORD_BOT_TOKEN" => "Bot_galen" } },
  "glados" => { "display_name" => "GLaDOS", "local" => true,
                "env" => { "SERVICE_TOKEN" => "token_glados", "DISCORD_BOT_TOKEN" => "Bot_glados" } },
  "kaylee" => { "display_name" => "Kaylee", "local" => false,
                "env" => { "SERVICE_TOKEN" => "token_kaylee" } },
  "sleeper-service" => { "display_name" => "Sleeper Service", "local" => false,
                         "env" => {} },
  "threepio" => { "display_name" => "Threepio", "local" => false, "env" => {} }
}
File.write(File.join(TEST_BRAINIAC_DIR, "agents.json"), JSON.generate(agent_data))

# Write GitHub config
File.write(File.join(TEST_BRAINIAC_DIR, "github.json"), JSON.generate({
                                                                        "webhook_secret" => "github-test-secret"
                                                                      }))

# Write projects config
project_data = {
  "marketplace" => {
    "repo_path" => "/home/test/Code/marketplace",
    "tags" => %w[marketplace mp],
    "github_repo" => "stowzilla/marketplace",
    "agent_cli" => "kiro-cli",
    "agent_cli_args" => "chat --no-interactive",
    "agent_model_flag" => "--model",
    "allowed_models" => {
      "opus" => "claude-opus-4.6",
      "sonnet" => "claude-sonnet-4.6",
      "haiku" => "claude-haiku-4.5",
      "deepseek" => "deepseek-3.2",
      "auto" => "auto"
    }
  },
  "brainiac" => {
    "repo_path" => "/home/test/Code/brainiac",
    "tags" => ["brainiac"],
    "github_repo" => "stowzilla/brainiac",
    "default" => true
  }
}
File.write(File.join(TEST_BRAINIAC_DIR, "projects.json"), JSON.generate(project_data))

# Write discord config
discord_data = {
  "default_project" => "marketplace",
  "channel_mappings" => { "channel-brainiac" => { "project" => "brainiac" } },
  "authorized_role_ids" => [],
  "authorized_user_ids" => [],
  "user_mappings" => { "Andy" => "397928984232591361" }
}
File.write(File.join(TEST_BRAINIAC_DIR, "discord.json"), JSON.generate(discord_data))

# Write users config
user_data = {
  "users" => [
    {
      "canonical_name" => "Andy Davis",
      "identities" => {
        "discord" => { "username" => "ardavis",
                       "user_id" => "397928984232591361" },
        "github" => { "username" => "ardavis" }
      },
      "aliases" => ["Andy"]
    },
    {
      "canonical_name" => "Adam Dalton",
      "identities" => {
        "discord" => { "username" => "fladamd",
                       "user_id" => "832331260088287242" },
        "github" => { "username" => "dalton" }
      },
      "aliases" => []
    },
    {
      "canonical_name" => "Galen",
      "identities" => { "discord" => { "username" => "galen-bot",
                                       "user_id" => "1475925968584573181" } },
      "aliases" => []
    }
  ],
  "schema_version" => "1.0"
}
File.write(File.join(TEST_BRAINIAC_DIR, "users.json"), JSON.generate(user_data))

# Write brainiac.json (handler config)
brainiac_data = {
  "default_agent" => "Galen",
  "handlers" => { "github" => true, "discord" => true,
                  "zoho" => false }
}
File.write(File.join(TEST_BRAINIAC_DIR, "brainiac.json"), JSON.generate(brainiac_data))

# --- Note: KIRO_AGENTS_DIR points to ~/.kiro/agents/ which may have real agents.
# Tests should be resilient to extra agents being discovered from disk.

# Add project root to load path
$LOAD_PATH.unshift File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# --- Load brainiac modules ONCE for all tests ---
require_relative "../lib/brainiac/hooks"
require_relative "../lib/brainiac/config"
require_relative "../lib/brainiac/users"
require_relative "../lib/brainiac/agents"
require_relative "../lib/brainiac/brain"
require_relative "../lib/brainiac/sessions"
require_relative "../lib/brainiac/helpers"
require_relative "../lib/brainiac/handlers/shared/inline_tags"
require_relative "../lib/brainiac/handlers/shared/git"

# Stub functions that need external tools.
# These redefine methods loaded from lib/ — suppress redefinition warnings.
verbose = $VERBOSE
$VERBOSE = nil
def prefetch_card_context(_card_number, repo_path:, agent_name: nil) = ""

def run_agent(prompt:, agent_name:, worktree:, project_config:, session_key:, log_prefix:, model: nil, effort: nil, source: nil, source_context: nil,
              cli_provider_override: nil, extra_env: {})
  nil
end

def auto_inject_skills(_context) = ""
def render_prompt(_template, _vars, brain_context: "", agent_name: nil, channel: :discord) = "rendered prompt"
def role_content_for(_agent_name) = nil
$VERBOSE = verbose

PROMPT_FOLLOWUP_NO_WORKTREE = "Stub prompt" unless defined?(PROMPT_FOLLOWUP_NO_WORKTREE)
PROMPT_FOLLOWUP_COMMENT = "Stub prompt" unless defined?(PROMPT_FOLLOWUP_COMMENT)
PROMPT_CROSS_AGENT_REVIEW = "Stub prompt" unless defined?(PROMPT_CROSS_AGENT_REVIEW)
PROMPT_CARD_ASSIGNED = "Stub prompt" unless defined?(PROMPT_CARD_ASSIGNED)
PROMPT_NEW_MENTION = "Stub prompt" unless defined?(PROMPT_NEW_MENTION)

def handle_deploy_comment(_eventable, _text, _card_id) = [200, { status: "deploy_handled" }.to_json]

# Cleanup
Minitest.after_run { FileUtils.rm_rf(TEST_BRAINIAC_DIR) }
