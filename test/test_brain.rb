# frozen_string_literal: true

require_relative "test_helper"

# Stub dependencies
AI_AGENT_NAME = "Galen" unless defined?(AI_AGENT_NAME)
BRAINIAC_CONFIG = {} unless defined?(BRAINIAC_CONFIG)
CONFIG_MTIMES = {} unless defined?(CONFIG_MTIMES)
FIZZY_CONFIG = { "authorized_users" => [] } unless defined?(FIZZY_CONFIG)
FIZZY_BOARDS = {} unless defined?(FIZZY_BOARDS)
GITHUB_CONFIG = {} unless defined?(GITHUB_CONFIG)
AGENT_REGISTRY = {
  "galen" => { "fizzy_name" => "Galen", "local" => true, "env" => {} },
  "glados" => { "fizzy_name" => "GLaDOS", "local" => true, "env" => {} },
  "kaylee" => { "fizzy_name" => "Kaylee", "env" => {} }
} unless defined?(AGENT_REGISTRY)
AUTHORIZED_USER_IDS = [] unless defined?(AUTHORIZED_USER_IDS)
NOTIFICATION_COMMAND = nil unless defined?(NOTIFICATION_COMMAND)
DISCORD_ENABLED = false unless defined?(DISCORD_ENABLED)
PROJECTS = {} unless defined?(PROJECTS)
DEFAULT_PROJECT = {
  "repo_path" => Dir.pwd, "fizzy_tags" => [], "github_repo" => nil,
  "agent_cli" => "kiro-cli", "agent_cli_args" => "chat --no-interactive",
  "agent_model_flag" => "--model", "agent_model" => nil,
  "agent_effort_flag" => "--effort", "agent_effort" => nil,
  "allowed_models" => {}, "allowed_efforts" => %w[low medium high xhigh max]
}.freeze unless defined?(DEFAULT_PROJECT)

require_relative "../lib/brainiac/brain"

class TestBrain < Minitest::Test
  # --- Path helpers ---

  def test_memory_dir_for_agent
    path = memory_dir_for("Galen")
    assert_equal File.join(MEMORY_BASE_DIR, "galen"), path
  end

  def test_memory_dir_for_agent_normalizes_name
    path = memory_dir_for("Sleeper Service")
    assert_equal File.join(MEMORY_BASE_DIR, "sleeper-service"), path
  end

  def test_persona_dir_for_agent
    path = persona_dir_for("GLaDOS")
    assert_equal File.join(PERSONA_BASE_DIR, "glados"), path
  end

  def test_persona_collection_for_agent
    assert_equal "galen-persona", persona_collection_for("Galen")
    assert_equal "glados-persona", persona_collection_for("GLaDOS")
  end

  # --- Brain git repo detection ---

  def test_brain_git_repo_false_without_git_dir
    refute brain_git_repo?
  end

  def test_brain_git_repo_true_with_git_dir
    FileUtils.mkdir_p(File.join(BRAIN_BASE_DIR, ".git"))
    assert brain_git_repo?
  ensure
    FileUtils.rm_rf(File.join(BRAIN_BASE_DIR, ".git"))
  end
end
