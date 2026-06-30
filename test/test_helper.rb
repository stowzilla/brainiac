# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "logger"
require "tempfile"
require "open3"
require "securerandom"
require "set"

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
File.write(File.join(TEST_BRAINIAC_DIR, "agents.json"), JSON.generate({
  "galen" => { "fizzy_name" => "Galen", "local" => true, "env" => { "FIZZY_TOKEN" => "fizzy_galen_token", "DISCORD_BOT_TOKEN" => "Bot_galen" } },
  "glados" => { "fizzy_name" => "GLaDOS", "local" => true, "env" => { "FIZZY_TOKEN" => "fizzy_glados_token", "DISCORD_BOT_TOKEN" => "Bot_glados" } },
  "kaylee" => { "fizzy_name" => "Kaylee", "local" => false, "env" => { "FIZZY_TOKEN" => "fizzy_kaylee_token" } },
  "sleeper-service" => { "fizzy_name" => "Sleeper Service", "local" => false, "env" => {} },
  "threepio" => { "fizzy_name" => "Threepio", "local" => false, "env" => {} }
}))

# Write fizzy config
File.write(File.join(TEST_BRAINIAC_DIR, "fizzy.json"), JSON.generate({
  "authorized_users" => [
    { "id" => "user-1", "name" => "Andy", "human" => true },
    { "id" => "user-2", "name" => "Adam", "human" => true },
    { "id" => "agent-1", "name" => "Galen", "human" => false },
    { "id" => "agent-2", "name" => "GLaDOS", "human" => false }
  ],
  "boards" => {
    "development" => {
      "board_id" => "board-123",
      "webhook_secret" => "dev-board-secret",
      "columns" => { "right_now" => "col-1", "needs_review" => "col-2", "uat" => "col-3" }
    }
  }
}))

# Write GitHub config
File.write(File.join(TEST_BRAINIAC_DIR, "github.json"), JSON.generate({
  "webhook_secret" => "github-test-secret"
}))

# Write projects config
File.write(File.join(TEST_BRAINIAC_DIR, "projects.json"), JSON.generate({
  "marketplace" => {
    "repo_path" => "/home/test/Code/marketplace",
    "fizzy_tags" => ["marketplace", "mp"],
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
    "fizzy_tags" => ["brainiac"],
    "github_repo" => "stowzilla/brainiac",
    "default" => true
  }
}))

# Write discord config
File.write(File.join(TEST_BRAINIAC_DIR, "discord.json"), JSON.generate({
  "default_project" => "marketplace",
  "channel_mappings" => { "channel-brainiac" => { "project" => "brainiac" } },
  "authorized_role_ids" => [],
  "authorized_user_ids" => [],
  "user_mappings" => { "Andy" => "397928984232591361" }
}))

# Write users config
File.write(File.join(TEST_BRAINIAC_DIR, "users.json"), JSON.generate({
  "users" => [
    {
      "canonical_name" => "Andy Davis",
      "identities" => {
        "discord" => { "username" => "ardavis", "user_id" => "397928984232591361" },
        "github" => { "username" => "ardavis" },
        "fizzy" => { "username" => "andy-davis" }
      },
      "aliases" => ["Andy"]
    },
    {
      "canonical_name" => "Adam Dalton",
      "identities" => {
        "discord" => { "username" => "fladamd", "user_id" => "832331260088287242" },
        "github" => { "username" => "dalton" },
        "fizzy" => { "username" => "adam-dalton" }
      },
      "aliases" => []
    },
    {
      "canonical_name" => "Galen",
      "identities" => { "discord" => { "username" => "galen-bot", "user_id" => "1475925968584573181" } },
      "aliases" => []
    }
  ],
  "schema_version" => "1.0"
}))

# Write brainiac.json (handler config)
File.write(File.join(TEST_BRAINIAC_DIR, "brainiac.json"), JSON.generate({
  "default_agent" => "Galen",
  "handlers" => { "fizzy" => true, "github" => true, "discord" => true, "zoho" => false }
}))

# --- Note: KIRO_AGENTS_DIR points to ~/.kiro/agents/ which may have real agents.
# Tests should be resilient to extra agents being discovered from disk.

# Add project root to load path
$LOAD_PATH.unshift File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# --- Load brainiac modules ONCE for all tests ---
require_relative "../lib/brainiac/config"
require_relative "../lib/brainiac/users"
require_relative "../lib/brainiac/agents"
require_relative "../lib/brainiac/brain"
require_relative "../lib/brainiac/sessions"
require_relative "../lib/brainiac/planning"
require_relative "../lib/brainiac/helpers"
require_relative "../lib/brainiac/handlers/shared/inline_tags"
require_relative "../lib/brainiac/handlers/shared/git"
require_relative "../lib/brainiac/handlers/discord/config"

# Stub functions that need external tools
def prefetch_card_context(card_number, repo_path:, agent_name: nil) = ""
def run_agent(prompt:, agent_name:, worktree:, project_config:, model: nil, effort: nil, session_key:, log_prefix:, source: nil, source_context: nil, cli_provider_override: nil, extra_env: {}) = nil

# Load fizzy comment handler (needs prompts stub)
PROMPT_FOLLOWUP_NO_WORKTREE = "Stub prompt" unless defined?(PROMPT_FOLLOWUP_NO_WORKTREE)
PROMPT_FOLLOWUP_COMMENT = "Stub prompt" unless defined?(PROMPT_FOLLOWUP_COMMENT)
PROMPT_CROSS_AGENT_REVIEW = "Stub prompt" unless defined?(PROMPT_CROSS_AGENT_REVIEW)
PROMPT_CARD_ASSIGNED = "Stub prompt" unless defined?(PROMPT_CARD_ASSIGNED)
PROMPT_NEW_MENTION = "Stub prompt" unless defined?(PROMPT_NEW_MENTION)

def render_prompt(template, vars, brain_context: "", agent_name: nil, channel: :fizzy) = "rendered prompt"
def auto_inject_skills(context) = ""
def role_content_for(agent_name) = nil

require_relative "../lib/brainiac/handlers/fizzy/comments"
require_relative "../lib/brainiac/handlers/fizzy/assignment"

# Stub deploy handler (lives in fizzy/deploy.rb which we don't load)
def handle_deploy_comment(eventable, text, card_id) = [200, { status: "deploy_handled" }.to_json]

# Cleanup
Minitest.after_run { FileUtils.rm_rf(TEST_BRAINIAC_DIR) }
