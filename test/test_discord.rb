# frozen_string_literal: true

require "minitest/autorun"
require "json"
require "tmpdir"
require "fileutils"
require "logger"

# Set up temp brainiac dir for Discord tests
TEST_DIR = Dir.mktmpdir("discord-test")
ENV["BRAINIAC_DIR"] = TEST_DIR
ENV["AI_AGENT_NAME"] = "Galen"
ENV["LOG_LEVEL"] = "error"

FileUtils.mkdir_p(File.join(TEST_DIR, "brain", "knowledge"))
FileUtils.mkdir_p(File.join(TEST_DIR, "brain", "persona"))
FileUtils.mkdir_p(File.join(TEST_DIR, "brain", "memory"))
FileUtils.mkdir_p(File.join(TEST_DIR, "roles"))
FileUtils.mkdir_p(File.join(TEST_DIR, "cli-providers"))

File.write(File.join(TEST_DIR, "agents.json"), JSON.generate({
  "galen" => { "fizzy_name" => "Galen", "local" => true, "env" => { "FIZZY_TOKEN" => "tok", "DISCORD_BOT_TOKEN" => "Bot_galen" } },
  "glados" => { "fizzy_name" => "GLaDOS", "local" => true, "env" => { "FIZZY_TOKEN" => "tok2", "DISCORD_BOT_TOKEN" => "Bot_glados" } },
  "kaylee" => { "fizzy_name" => "Kaylee", "local" => false, "env" => { "FIZZY_TOKEN" => "tok3" } }
}))

File.write(File.join(TEST_DIR, "fizzy.json"), JSON.generate({
  "authorized_users" => [], "boards" => {}
}))

File.write(File.join(TEST_DIR, "github.json"), JSON.generate({ "webhook_secret" => "gh-test" }))

File.write(File.join(TEST_DIR, "projects.json"), JSON.generate({
  "marketplace" => {
    "repo_path" => "/tmp/test-mp",
    "fizzy_tags" => ["marketplace"],
    "github_repo" => "stowzilla/marketplace",
    "agent_cli" => "kiro-cli", "agent_cli_args" => "chat --no-interactive",
    "agent_model_flag" => "--model",
    "allowed_models" => { "opus" => "claude-opus-4.6", "sonnet" => "claude-sonnet-4.6" }
  },
  "brainiac" => {
    "repo_path" => "/tmp/test-brainiac",
    "fizzy_tags" => ["brainiac"],
    "github_repo" => "stowzilla/brainiac"
  }
}))

File.write(File.join(TEST_DIR, "discord.json"), JSON.generate({
  "default_project" => "marketplace",
  "channel_mappings" => { "channel-brainiac" => { "project" => "brainiac" } },
  "authorized_role_ids" => [],
  "authorized_user_ids" => [],
  "user_mappings" => { "Andy" => "397928984232591361" }
}))

$LOAD_PATH.unshift File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)

require_relative "../lib/brainiac/config"
require_relative "../lib/brainiac/users"
require_relative "../lib/brainiac/agents"
require_relative "../lib/brainiac/sessions"
require_relative "../lib/brainiac/handlers/shared/inline_tags"
require_relative "../lib/brainiac/handlers/discord/config"

class TestDiscordConfig < Minitest::Test
  def test_load_discord_config_parses_file
    config = load_discord_config
    assert_equal "marketplace", config["default_project"]
    assert_instance_of Hash, config["channel_mappings"]
  end

  def test_discord_bot_tokens_collected_from_registry
    tokens = discord_bot_tokens
    assert_equal "Bot_galen", tokens["galen"]
    assert_equal "Bot_glados", tokens["glados"]
  end

  def test_discord_bot_tokens_excludes_agents_without_token
    tokens = discord_bot_tokens
    refute tokens.key?("kaylee")
  end

  def test_find_project_for_mapped_channel
    result = find_project_for_discord_channel("channel-brainiac")
    assert result
    project_key, _project_config, _mapping = result
    assert_equal "brainiac", project_key
  end

  def test_find_project_for_unmapped_channel_uses_default
    result = find_project_for_discord_channel("random-channel-999")
    assert result
    project_key, _project_config, _mapping = result
    assert_equal "marketplace", project_key
  end

  def test_find_project_returns_nil_when_no_default
    original = DISCORD_CONFIG.dup
    DISCORD_CONFIG.replace({ "channel_mappings" => {} })
    assert_nil find_project_for_discord_channel("unknown")
  ensure
    DISCORD_CONFIG.replace(original)
  end

  def test_thread_map_persistence
    FileUtils.rm_f(DISCORD_THREAD_MAP_FILE)
    assert_equal({}, load_discord_thread_map)

    map = { "galen:ch1" => { "worktree" => "/tmp/wt", "branch" => "discord-test" } }
    save_discord_thread_map(map)
    loaded = load_discord_thread_map
    assert_equal "/tmp/wt", loaded["galen:ch1"]["worktree"]
  end
end

class TestDiscordSessionMechanics < Minitest::Test
  def setup
    ACTIVE_SESSIONS.clear
    AGENT_DISPATCH_DEPTH.clear
  end

  def test_supersede_window_constant
    assert_equal 60, SUPERSEDE_WINDOW
  end

  def test_supersedable_session_found_within_window
    pid = spawn("sleep", "30")
    register_session("discord-galen-ch1-msg1", pid,
                     supersede_key: "discord-galen-ch1", agent_name: "Galen")
    result = find_supersedable_session("discord-galen-ch1")
    assert result
    assert_equal pid, result[:pid]
  ensure
    Process.kill("KILL", pid) rescue nil
    Process.wait(pid) rescue nil
  end

  def test_supersedable_session_not_found_outside_window
    pid = spawn("sleep", "30")
    register_session("discord-galen-ch1-msg1", pid,
                     supersede_key: "discord-galen-ch1", agent_name: "Galen")
    ACTIVE_SESSIONS["discord-galen-ch1-msg1"][:started_at] = Time.now - 120
    assert_nil find_supersedable_session("discord-galen-ch1")
  ensure
    Process.kill("KILL", pid) rescue nil
    Process.wait(pid) rescue nil
  end

  def test_discord_inline_tags_parsed
    tags = parse_inline_tags("[project:brainiac] [opus] how does the webhook work?")
    assert_equal "brainiac", tags[:project]
    assert_equal "opus", tags[:model_tag]
    assert_equal "how does the webhook work?", tags[:clean_text]
  end

  def test_discord_chat_mode_tag
    tags = parse_inline_tags("[chat] what is a worktree?")
    assert tags[:chat_mode]
  end

  def test_discord_dispatch_depth_tracking
    record_human_comment("discord-channel-1")
    assert agent_dispatch_allowed?("discord-channel-1")
    record_agent_dispatch("discord-channel-1")
    assert agent_dispatch_allowed?("discord-channel-1")
  end

  def test_session_supersede_kills_old_and_registers_new
    pid1 = spawn("sleep", "30")
    register_session("discord-galen-ch1-msg1", pid1,
                     supersede_key: "discord-galen-ch1", agent_name: "Galen")

    # Find and kill the supersedable session
    old = find_supersedable_session("discord-galen-ch1")
    assert old
    kill_session(old[:session_key])
    sleep 0.1
    refute session_active?("discord-galen-ch1-msg1")
  ensure
    Process.kill("KILL", pid1) rescue nil
    Process.wait(pid1) rescue nil
  end
end

Minitest.after_run { FileUtils.rm_rf(TEST_DIR) }
