# frozen_string_literal: true

require_relative "test_helper"

# We need to stub constants that agents.rb needs before requiring it
FIZZY_CONFIG = {
  "authorized_users" => [
    { "id" => "user-1", "name" => "Andy", "human" => true },
    { "id" => "user-2", "name" => "Adam", "human" => true },
    { "id" => "agent-1", "name" => "Galen", "human" => false }
  ]
} unless defined?(FIZZY_CONFIG)

# Write an agent registry
File.write(AGENT_REGISTRY_FILE, JSON.generate({
  "galen" => {
    "fizzy_name" => "Galen",
    "local" => true,
    "env" => { "FIZZY_TOKEN" => "fizzy_galen_token", "DISCORD_BOT_TOKEN" => "Bot_galen" }
  },
  "glados" => {
    "fizzy_name" => "GLaDOS",
    "local" => true,
    "env" => { "FIZZY_TOKEN" => "fizzy_glados_token", "DISCORD_BOT_TOKEN" => "Bot_glados" }
  },
  "kaylee" => {
    "fizzy_name" => "Kaylee",
    "env" => { "FIZZY_TOKEN" => "fizzy_kaylee_token" }
  },
  "sleeper-service" => {
    "fizzy_name" => "Sleeper Service",
    "local" => false,
    "env" => {}
  }
}))

# Stub AI_AGENT_NAME and PROJECTS
AI_AGENT_NAME = "Galen" unless defined?(AI_AGENT_NAME)
PROJECTS = {
  "marketplace" => {
    "repo_path" => "/home/test/Code/marketplace",
    "fizzy_tags" => ["marketplace", "mp"],
    "github_repo" => "stowzilla/marketplace",
    "agent_name" => "Galen"
  },
  "brainiac" => {
    "repo_path" => "/home/test/Code/brainiac",
    "fizzy_tags" => ["brainiac"],
    "github_repo" => "stowzilla/brainiac"
  }
} unless defined?(PROJECTS)

# Stub config helpers needed by agents.rb
CONFIG_MTIMES = {} unless defined?(CONFIG_MTIMES)
unless defined?(@file_changed_defined)
  def file_changed?(path, force: false)
    true
  end
  @file_changed_defined = true
end

require_relative "../lib/brainiac/agents"

class TestAgents < Minitest::Test
  # --- Agent registry loading ---

  def test_load_agent_registry_returns_hash
    registry = load_agent_registry
    assert_instance_of Hash, registry
    assert_equal 4, registry.size
  end

  def test_agent_registry_normalizes_keys
    registry = load_agent_registry
    assert registry.key?("galen")
    assert registry.key?("glados")
    assert registry.key?("sleeper-service")
  end

  # --- Agent env ---

  def test_agent_env_for_returns_env_hash
    env = agent_env_for("Galen")
    assert_equal "fizzy_galen_token", env["FIZZY_TOKEN"]
    assert_equal "Bot_galen", env["DISCORD_BOT_TOKEN"]
  end

  def test_agent_env_for_case_insensitive
    env = agent_env_for("GALEN")
    assert_equal "fizzy_galen_token", env["FIZZY_TOKEN"]
  end

  def test_agent_env_for_unknown_agent
    env = agent_env_for("UnknownBot")
    assert_equal({}, env)
  end

  def test_agent_env_for_nil
    env = agent_env_for(nil)
    assert_equal({}, env)
  end

  # --- Fizzy token ---

  def test_fizzy_token_for_returns_token
    assert_equal "fizzy_galen_token", fizzy_token_for("Galen")
  end

  def test_fizzy_token_for_glados
    assert_equal "fizzy_glados_token", fizzy_token_for("GLaDOS")
  end

  # --- Display names ---

  def test_fizzy_display_name_from_registry
    assert_equal "Galen", fizzy_display_name("galen")
    assert_equal "GLaDOS", fizzy_display_name("glados")
    assert_equal "Sleeper Service", fizzy_display_name("sleeper-service")
  end

  def test_fizzy_display_name_falls_back_to_input
    assert_equal "UnknownBot", fizzy_display_name("UnknownBot")
  end

  def test_fizzy_display_name_nil_returns_nil
    assert_nil fizzy_display_name(nil)
  end

  # --- Agent roster ---

  def test_agent_roster_returns_hash_of_names
    roster = agent_roster
    assert_instance_of Hash, roster
    assert_equal "Galen", roster["galen"]
    assert_equal "GLaDOS", roster["glados"]
  end

  # --- Local vs remote agents ---

  def test_local_agent_names_includes_marked_local
    locals = local_agent_names
    assert_includes locals, "Galen"
    assert_includes locals, "GLaDOS"
  end

  def test_local_agent_names_excludes_non_local
    locals = local_agent_names
    refute locals.any? { |n| n.downcase == "sleeper service" || n == "Sleeper Service" }
  end

  # --- All agent names ---

  def test_all_agent_names_includes_all_registered
    names = all_agent_names
    assert names.include?("Galen")
    assert names.include?("GLaDOS")
    assert names.include?("Kaylee")
    assert names.include?("Sleeper Service")
  end

  # --- Mention detection ---

  def test_detect_mentioned_agent_full_name
    assert_equal "Galen", detect_mentioned_agent("@Galen can you review this?")
  end

  def test_detect_mentioned_agent_case_insensitive
    assert_equal "Galen", detect_mentioned_agent("@galen look at this")
  end

  def test_detect_mentioned_agent_glados
    assert_equal "GLaDOS", detect_mentioned_agent("Hey @GLaDOS what do you think?")
  end

  def test_detect_mentioned_agent_multi_word_first_name
    assert_equal "Sleeper Service", detect_mentioned_agent("@Sleeper thoughts?")
  end

  def test_detect_mentioned_agent_no_mention
    assert_nil detect_mentioned_agent("No one mentioned here")
  end

  def test_detect_mentioned_agent_email_not_confused
    # "@" in email should not trigger agent detection
    assert_nil detect_mentioned_agent("send to user@example.com")
  end

  # --- Human mention detection ---

  def test_detect_mentioned_user_ids_finds_human
    ids = detect_mentioned_user_ids("@Andy can you approve?")
    assert_includes ids, "user-1"
  end

  def test_detect_mentioned_user_ids_empty_when_no_mention
    ids = detect_mentioned_user_ids("nothing here")
    assert_empty ids
  end

  # --- Comment from agent check ---

  def test_comment_from_agent_true
    assert comment_from_agent?("Galen")
    assert comment_from_agent?("GLaDOS")
  end

  def test_comment_from_agent_false_for_human
    refute comment_from_agent?("Andy")
    refute comment_from_agent?("SomeRandom")
  end

  def test_comment_from_agent_false_for_nil
    refute comment_from_agent?(nil)
  end

  # --- Roles ---

  def test_agent_roles_for_returns_empty_when_not_configured
    assert_equal [], agent_roles_for("Galen")
  end

  def test_load_role_returns_nil_for_missing_file
    assert_nil load_role("nonexistent-role")
  end

  def test_load_role_reads_markdown_file
    FileUtils.mkdir_p(ROLES_DIR)
    File.write(File.join(ROLES_DIR, "test-engineer.md"), "# Test Engineer\nYou write tests.")
    content = load_role("test-engineer")
    assert_includes content, "Test Engineer"
    assert_includes content, "You write tests"
  end

  def test_load_role_strips_yaml_frontmatter
    FileUtils.mkdir_p(ROLES_DIR)
    File.write(File.join(ROLES_DIR, "reviewer.md"), "---\nname: reviewer\n---\n# Reviewer\nReview code.")
    content = load_role("reviewer")
    refute_includes content, "---"
    assert_includes content, "# Reviewer"
  end
end
