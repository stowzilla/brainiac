# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "logger"
require "securerandom"

# This test file loads config.rb directly, so we need to set up the environment
# that config.rb expects. We do NOT use test_helper.rb because config.rb defines
# many of the same constants.

# Set env vars before loading config
ENV["AI_AGENT_NAME"] = "TestBot"
ENV["BRAINIAC_DIR"] = Dir.mktmpdir("config-test")
ENV["LOG_LEVEL"] = "error"

# Create required directories and files
FileUtils.mkdir_p(ENV["BRAINIAC_DIR"])
FileUtils.mkdir_p(File.join(ENV["BRAINIAC_DIR"], "brain", "knowledge"))
FileUtils.mkdir_p(File.join(ENV["BRAINIAC_DIR"], "brain", "persona"))
FileUtils.mkdir_p(File.join(ENV["BRAINIAC_DIR"], "brain", "memory"))
FileUtils.mkdir_p(File.join(ENV["BRAINIAC_DIR"], "roles"))

# Write config files
File.write(File.join(ENV["BRAINIAC_DIR"], "brainiac.json"), JSON.generate({
  "default_agent" => "TestBot",
  "handlers" => { "fizzy" => true, "github" => true, "discord" => false, "zoho" => false }
}))
File.write(File.join(ENV["BRAINIAC_DIR"], "fizzy.json"), JSON.generate({
  "authorized_users" => [
    { "id" => "user-1", "name" => "TestUser", "human" => true }
  ],
  "boards" => {
    "dev" => {
      "board_id" => "board-abc",
      "webhook_secret" => "dev-board-secret",
      "columns" => { "right_now" => "col-1", "needs_review" => "col-2" }
    }
  }
}))
File.write(File.join(ENV["BRAINIAC_DIR"], "github.json"), JSON.generate({
  "webhook_secret" => "gh-secret-123"
}))
File.write(File.join(ENV["BRAINIAC_DIR"], "projects.json"), JSON.generate({
  "testapp" => { "repo_path" => "/tmp/testapp", "fizzy_tags" => ["testapp"] }
}))

# Now load config
require_relative "../lib/brainiac/config"

class TestConfig < Minitest::Test
  def setup
    CONFIG_MTIMES.clear
  end

  # --- Constants ---

  def test_ai_agent_name_from_env
    assert_equal "TestBot", AI_AGENT_NAME
  end

  def test_brainiac_dir_from_env
    assert_equal ENV["BRAINIAC_DIR"], BRAINIAC_DIR
  end

  # --- Brainiac config ---

  def test_brainiac_config_loaded
    assert_equal "TestBot", BRAINIAC_CONFIG["default_agent"]
  end

  # --- Handler enabled ---

  def test_handler_enabled_fizzy
    assert handler_enabled?("fizzy")
  end

  def test_handler_enabled_github
    assert handler_enabled?("github")
  end

  def test_handler_disabled_discord
    refute handler_enabled?("discord")
  end

  def test_handler_disabled_zoho
    refute handler_enabled?("zoho")
  end

  # --- Fizzy config ---

  def test_fizzy_config_loaded
    assert_equal 1, FIZZY_CONFIG["authorized_users"].size
    assert_equal "TestUser", FIZZY_CONFIG["authorized_users"][0]["name"]
  end

  def test_board_config
    config = board_config("dev")
    assert config
    assert_equal "board-abc", config["board_id"]
  end

  def test_board_webhook_secret
    assert_equal "dev-board-secret", board_webhook_secret("dev")
  end

  def test_board_column_id
    assert_equal "col-1", board_column_id("dev", "right_now")
    assert_equal "col-2", board_column_id("dev", "needs_review")
  end

  def test_board_key_for_id
    assert_equal "dev", board_key_for_id("board-abc")
    assert_nil board_key_for_id("unknown")
  end

  # --- GitHub config ---

  def test_github_webhook_secret
    assert_equal "gh-secret-123", github_webhook_secret
  end

  # --- Projects ---

  def test_projects_loaded
    assert_equal 1, PROJECTS.size
    assert PROJECTS.key?("testapp")
    assert_equal "/tmp/testapp", PROJECTS["testapp"]["repo_path"]
  end

  # --- File change detection ---

  def test_file_changed_detects_new_file
    test_file = File.join(ENV["BRAINIAC_DIR"], "change-test.txt")
    File.write(test_file, "v1")
    assert file_changed?(test_file)
  end

  def test_file_changed_false_when_unchanged
    test_file = File.join(ENV["BRAINIAC_DIR"], "change-test2.txt")
    File.write(test_file, "v1")
    file_changed?(test_file)
    refute file_changed?(test_file)
  end

  def test_file_changed_true_after_modification
    test_file = File.join(ENV["BRAINIAC_DIR"], "change-test3.txt")
    File.write(test_file, "v1")
    file_changed?(test_file)
    sleep 0.01
    File.write(test_file, "v2")
    # Ensure mtime is actually different
    new_mtime = File.mtime(test_file) + 1
    File.utime(new_mtime, new_mtime, test_file)
    assert file_changed?(test_file)
  end

  def test_file_changed_true_with_force
    test_file = File.join(ENV["BRAINIAC_DIR"], "change-test4.txt")
    File.write(test_file, "v1")
    file_changed?(test_file)
    assert file_changed?(test_file, force: true)
  end

  # --- Authorization ---

  def test_authorized_user_ids_from_config
    assert_includes AUTHORIZED_USER_IDS, "user-1"
  end
end

Minitest.after_run { FileUtils.rm_rf(ENV["BRAINIAC_DIR"]) }
