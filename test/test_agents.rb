# frozen_string_literal: true

require_relative "test_helper"

class TestAgents < Minitest::Test
  def test_agent_env_for_returns_env_hash
    env = agent_env_for("Sherlock")
    assert_equal "token_sherlock", env["SERVICE_TOKEN"]
    assert_equal "Bot_sherlock", env["DISCORD_BOT_TOKEN"]
  end

  def test_agent_env_for_case_insensitive
    env = agent_env_for("SHERLOCK")
    assert_equal "token_sherlock", env["SERVICE_TOKEN"]
  end

  def test_agent_env_for_unknown_agent
    assert_equal({}, agent_env_for("UnknownBot"))
  end

  def test_agent_env_for_nil
    assert_equal({}, agent_env_for(nil))
  end

  def test_agent_display_name_from_registry
    assert_equal "Sherlock", agent_display_name("sherlock")
    assert_equal "Robin", agent_display_name("robin")
    assert_equal "Robin Hood", agent_display_name("robin-hood")
  end

  def test_agent_display_name_falls_back_to_input
    assert_equal "UnknownBot", agent_display_name("UnknownBot")
  end

  def test_agent_roster_returns_hash
    roster = agent_roster
    assert_instance_of Hash, roster
    assert_equal "Sherlock", roster["sherlock"]
    assert_equal "Robin", roster["robin"]
  end

  def test_local_agent_names_includes_marked_local
    locals = local_agent_names
    assert_includes locals, "Sherlock"
    assert(locals.any? { |n| n.downcase == "robin" })
  end

  def test_local_agent_names_excludes_non_local
    locals = local_agent_names
    refute locals.include?("Robin Hood")
  end

  def test_all_agent_names_includes_registered
    names = all_agent_names
    assert names.include?("Sherlock")
    assert(names.any? { |n| n.downcase == "robin" })
    assert(names.any? { |n| n.downcase == "merlin" || n == "Merlin" })
  end

  def test_detect_mentioned_agent_full_name
    assert_equal "Sherlock", detect_mentioned_agent("@Sherlock can you review this?")
  end

  def test_detect_mentioned_agent_case_insensitive
    agent = detect_mentioned_agent("@sherlock look at this")
    assert agent
    assert_equal "sherlock", agent.downcase
  end

  def test_detect_mentioned_agent_robin
    agent = detect_mentioned_agent("Hey @Robin what do you think?")
    assert agent
    assert_equal "robin", agent.downcase
  end

  def test_detect_mentioned_agent_no_mention
    assert_nil detect_mentioned_agent("No one mentioned here")
  end

  def test_comment_from_agent_true
    assert comment_from_agent?("Sherlock")
  end

  def test_comment_from_agent_false_for_human
    refute comment_from_agent?("Andy")
    refute comment_from_agent?("SomeRandom")
  end

  def test_comment_from_agent_false_for_nil
    refute comment_from_agent?(nil)
  end

  def test_load_role_returns_nil_for_missing_file
    assert_nil load_role("nonexistent-role")
  end

  def test_load_role_reads_markdown_file
    File.write(File.join(ROLES_DIR, "test-engineer.md"), "# Test Engineer\nYou write tests.")
    content = load_role("test-engineer")
    assert_includes content, "Test Engineer"
  end

  def test_load_role_strips_yaml_frontmatter
    File.write(File.join(ROLES_DIR, "reviewer.md"), "---\nname: reviewer\n---\n# Reviewer\nReview code.")
    content = load_role("reviewer")
    refute_includes content, "---"
    assert_includes content, "# Reviewer"
  end
end
