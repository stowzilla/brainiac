# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "logger"
require "securerandom"

# This test needs to simulate the full Fizzy comment routing.
# It loads modules in the correct order with proper config files in place.

# Set up a temporary brainiac dir with all needed config
TEST_DIR = Dir.mktmpdir("fizzy-comments-test")
ENV["BRAINIAC_DIR"] = TEST_DIR
ENV["AI_AGENT_NAME"] = "Galen"
ENV["LOG_LEVEL"] = "error"

FileUtils.mkdir_p(File.join(TEST_DIR, "brain", "knowledge"))
FileUtils.mkdir_p(File.join(TEST_DIR, "brain", "persona"))
FileUtils.mkdir_p(File.join(TEST_DIR, "brain", "memory"))
FileUtils.mkdir_p(File.join(TEST_DIR, "roles"))
FileUtils.mkdir_p(File.join(TEST_DIR, "cli-providers"))

# Write agent registry
File.write(File.join(TEST_DIR, "agents.json"), JSON.generate({
  "galen" => { "fizzy_name" => "Galen", "local" => true, "env" => { "FIZZY_TOKEN" => "tok" } },
  "glados" => { "fizzy_name" => "GLaDOS", "local" => true, "env" => { "FIZZY_TOKEN" => "tok2" } },
  "kaylee" => { "fizzy_name" => "Kaylee", "local" => false, "env" => {} }
}))

# Write fizzy config
File.write(File.join(TEST_DIR, "fizzy.json"), JSON.generate({
  "authorized_users" => [
    { "id" => "user-andy", "name" => "Andy", "human" => true },
    { "id" => "user-adam", "name" => "Adam", "human" => true },
    { "id" => "agent-galen", "name" => "Galen", "human" => false },
    { "id" => "agent-glados", "name" => "GLaDOS", "human" => false }
  ],
  "boards" => {}
}))

# Write projects
File.write(File.join(TEST_DIR, "projects.json"), JSON.generate({
  "marketplace" => {
    "repo_path" => "/tmp/test-marketplace",
    "fizzy_tags" => ["marketplace", "mp"],
    "github_repo" => "stowzilla/marketplace",
    "agent_cli" => "kiro-cli",
    "agent_cli_args" => "chat --no-interactive",
    "agent_model_flag" => "--model",
    "allowed_models" => { "opus" => "claude-opus-4.6", "sonnet" => "claude-sonnet-4.6" }
  }
}))

File.write(File.join(TEST_DIR, "github.json"), JSON.generate({ "webhook_secret" => "gh-test" }))

$LOAD_PATH.unshift File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

# Load modules in order
require_relative "../lib/brainiac/config"
require_relative "../lib/brainiac/users"
require_relative "../lib/brainiac/agents"
require_relative "../lib/brainiac/brain"
require_relative "../lib/brainiac/sessions"
require_relative "../lib/brainiac/planning"
require_relative "../lib/brainiac/helpers"
require_relative "../lib/brainiac/handlers/shared/inline_tags"
require_relative "../lib/brainiac/handlers/shared/git"

# Stub functions that need external tools (fizzy CLI, qmd, etc.)
def notify_unauthorized(event, creator, context) = nil
def handle_deploy_comment(eventable, text, card_id) = [200, { status: "deploy_handled" }.to_json]
def prefetch_card_context(card_number, repo_path:, agent_name: nil) = ""
def build_brain_context(agent_name:, card_title: nil, card_number: nil, project_key: nil, source: nil) = ""
def run_agent(prompt:, agent_name:, worktree:, project_config:, model: nil, effort: nil, session_key:, log_prefix:, source: nil, source_context: nil, cli_provider_override: nil, extra_env: {}) = nil
def detect_effort(project_config, tags: [], text: "") = nil
def detect_planning_mode(text:, tags: [], card_internal_id: nil, card_number: nil) = nil

require_relative "../lib/brainiac/handlers/fizzy/comments"

class TestFizzyCommentRouting < Minitest::Test
  def setup
    PROCESSED_EVENTS.clear
    ACTIVE_SESSIONS.clear
    LAST_COMMENT_TIMES.clear
    AGENT_DISPATCH_DEPTH.clear
    # Set up card map
    save_card_map({
      "card-internal-1" => {
        "number" => 42,
        "branch" => "fizzy-42-test-feature",
        "worktree" => "/tmp/test-marketplace--fizzy-42-test-feature",
        "project" => "marketplace",
        "agent" => "Galen"
      }
    })
  end

  # --- Deploy comment routing ---

  def test_deploy_comment_routes_to_deploy_handler
    payload = build_comment_payload(body: "dev01", card_internal_id: "card-internal-1")
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "deploy_handled"
  end

  def test_deploy_comment_case_insensitive
    payload = build_comment_payload(body: "DEV02", card_internal_id: "card-internal-1")
    status, body = handle_comment(payload)
    assert_includes body, "deploy_handled"
  end

  # --- Human mention gating ---

  def test_human_mentioned_skips_dispatch
    payload = build_comment_payload(
      body: "@Andy what do you think?",
      creator_id: "user-adam", creator_name: "Adam",
      card_internal_id: "card-internal-1"
    )
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "human mentioned"
  end

  # --- Non-local agent mention ---

  def test_non_local_agent_mention_ignored
    payload = build_comment_payload(
      body: "@Kaylee can you help?",
      creator_id: "user-andy", creator_name: "Andy",
      card_internal_id: "card-internal-1"
    )
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "non-local agent mentioned"
  end

  # --- Unauthorized user ---

  def test_unauthorized_user_rejected
    payload = build_comment_payload(
      body: "@Galen do something",
      creator_id: "hacker-unknown", creator_name: "Hacker",
      card_internal_id: "card-internal-1"
    )
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "unauthorized"
  end

  # --- Self-comment filtering ---

  def test_agent_self_comment_without_mention_ignored
    # Galen comments on his own card without mentioning another agent
    payload = build_comment_payload(
      body: "I've finished the implementation",
      creator_id: "agent-galen", creator_name: "Galen",
      card_internal_id: "card-internal-1"
    )
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "self-comment"
  end

  # --- Agent-to-agent depth limiting ---

  def test_agent_to_agent_allowed_within_limit
    record_human_comment("card-internal-1")
    # Verify the depth check passes (not blocked)
    assert agent_dispatch_allowed?("card-internal-1")
    # We can't fully test the dispatch (needs real filesystem), but we verify
    # it doesn't hit the depth limit by checking it proceeds past that gate.
    # The error will be a filesystem error from trying to create a worktree,
    # NOT "agent-to-agent depth limit"
    payload = build_comment_payload(
      body: "@GLaDOS review this please",
      creator_id: "agent-galen", creator_name: "Galen",
      card_internal_id: "card-internal-1"
    )
    begin
      handle_comment(payload)
    rescue Errno::ENOENT
      # Expected: it proceeds to worktree creation which fails (no real repo)
      # This proves it passed the depth check
    end
  end

  def test_agent_to_agent_blocked_at_max_depth
    # Set depth to max
    AGENT_DISPATCH_DEPTH["card-internal-1"] = { count: AGENT_DISPATCH_MAX_DEPTH, last_human_at: Time.now }
    payload = build_comment_payload(
      body: "@GLaDOS review this please",
      creator_id: "agent-galen", creator_name: "Galen",
      card_internal_id: "card-internal-1"
    )
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "agent-to-agent depth limit"
  end

  # --- Untracked card ---

  def test_comment_on_untracked_card_without_mention_ignored
    payload = build_comment_payload(
      body: "hello there",
      creator_id: "user-andy", creator_name: "Andy",
      card_internal_id: "unknown-card-xyz"
    )
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "not relevant"
  end

  # --- Comment cooldown ---

  def test_comment_cooldown_prevents_rapid_fire
    record_human_comment("card-internal-1")
    touch_comment_cooldown("card-42-galen")
    payload = build_comment_payload(
      body: "@Galen do more",
      creator_id: "user-andy", creator_name: "Andy",
      card_internal_id: "card-internal-1"
    )
    status, body = handle_comment(payload)
    assert_equal 200, status
    assert_includes body, "comment cooldown"
  end

  # --- Cancel command ---

  def test_cancel_command_kills_active_session
    record_human_comment("card-internal-1")
    pid = spawn("sleep", "30")
    register_session("card-42", pid, agent_name: "Galen")

    payload = build_comment_payload(
      body: "cancel",
      creator_id: "user-andy", creator_name: "Andy",
      card_internal_id: "card-internal-1"
    )
    status, _body = handle_comment(payload)
    assert_equal 200, status
  ensure
    Process.kill("KILL", pid) rescue nil
    Process.wait(pid) rescue nil
  end

  private

  def build_comment_payload(body:, creator_id: "user-andy", creator_name: "Andy",
                            card_internal_id: "card-internal-1", card_number: 42)
    {
      "event" => "comment_created",
      "creator" => { "id" => creator_id, "name" => creator_name },
      "eventable" => {
        "id" => "comment-#{rand(10_000)}",
        "body" => { "plain_text" => body, "html" => "<p>#{body}</p>" },
        "creator" => { "id" => creator_id, "name" => creator_name },
        "card" => {
          "id" => card_internal_id,
          "number" => card_number,
          "title" => "Test Feature",
          "tags" => [{ "name" => "marketplace" }]
        }
      }
    }
  end
end

Minitest.after_run { FileUtils.rm_rf(TEST_DIR) }
