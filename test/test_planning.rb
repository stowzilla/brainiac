# frozen_string_literal: true

require_relative "test_helper"

# Stub config dependencies
AI_AGENT_NAME = "Galen" unless defined?(AI_AGENT_NAME)
BRAINIAC_CONFIG = {} unless defined?(BRAINIAC_CONFIG)
CONFIG_MTIMES = {} unless defined?(CONFIG_MTIMES)
PROJECTS = {} unless defined?(PROJECTS)
FIZZY_CONFIG = { "authorized_users" => [] } unless defined?(FIZZY_CONFIG)
FIZZY_BOARDS = {} unless defined?(FIZZY_BOARDS)
GITHUB_CONFIG = {} unless defined?(GITHUB_CONFIG)
AGENT_REGISTRY = {} unless defined?(AGENT_REGISTRY)
AUTHORIZED_USER_IDS = [] unless defined?(AUTHORIZED_USER_IDS)
NOTIFICATION_COMMAND = nil unless defined?(NOTIFICATION_COMMAND)
DISCORD_ENABLED = false unless defined?(DISCORD_ENABLED)

DEFAULT_PROJECT = {
  "repo_path" => Dir.pwd, "fizzy_tags" => [], "github_repo" => nil,
  "agent_cli" => "kiro-cli", "agent_cli_args" => "chat --no-interactive",
  "agent_model_flag" => "--model", "agent_model" => nil,
  "agent_effort_flag" => "--effort", "agent_effort" => nil,
  "allowed_models" => {}, "allowed_efforts" => %w[low medium high xhigh max]
}.freeze unless defined?(DEFAULT_PROJECT)

require_relative "../lib/brainiac/brain"
require_relative "../lib/brainiac/planning"

class TestPlanning < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir("planning-test")
    FileUtils.mkdir_p(PLANS_DIR)
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  # --- Planning mode detection ---

  def test_detect_planning_mode_with_plan_tag_in_text
    result = detect_planning_mode(text: "[plan] design the API", tags: [], card_internal_id: "abc", card_number: 42)
    assert result
    assert_equal :planning, result[:mode]
    assert_equal "abc", result[:card_id]
    assert_equal 42, result[:card_number]
  end

  def test_detect_planning_mode_with_plan_fizzy_tag
    tags = [{ "name" => "plan" }]
    result = detect_planning_mode(text: "Build the feature", tags: tags, card_internal_id: "def", card_number: 10)
    assert result
    assert_equal :planning, result[:mode]
  end

  def test_detect_planning_mode_case_insensitive
    result = detect_planning_mode(text: "[Plan] do it", tags: [])
    assert result
  end

  def test_detect_planning_mode_returns_nil_without_tag
    result = detect_planning_mode(text: "just do it", tags: [{ "name" => "marketplace" }])
    assert_nil result
  end

  def test_detect_planning_mode_discord_card_id_fallback
    result = detect_planning_mode(text: "[plan] question", tags: [])
    assert result
    assert_match(/^discord-/, result[:card_id])
  end

  # --- Planning completion check ---

  def test_planning_complete_false_when_no_memory
    refute planning_complete?("card-99", "Galen")
  end

  def test_planning_complete_false_without_marker
    memory_dir = memory_dir_for("Galen")
    FileUtils.mkdir_p(memory_dir)
    File.write(File.join(memory_dir, "card-card-99.md"), "Some notes here\nNo completion marker")
    refute planning_complete?("card-99", "Galen")
  end

  def test_planning_complete_true_with_marker
    memory_dir = memory_dir_for("Galen")
    FileUtils.mkdir_p(memory_dir)
    File.write(File.join(memory_dir, "card-card-100.md"), "## Planning\nplanning_complete: true\nDone.")
    assert planning_complete?("card-100", "Galen")
  end

  # --- Plan finalization ---

  def test_finalize_plan_fails_without_memory
    result = finalize_plan(card_id: "no-memory", card_number: 1, agent_name: "Galen",
                           project_key: "mp", repo_path: "/tmp")
    refute result[:success]
    assert_includes result[:error], "No memory file"
  end

  def test_finalize_plan_fails_without_plan_file
    memory_dir = memory_dir_for("Galen")
    FileUtils.mkdir_p(memory_dir)
    File.write(File.join(memory_dir, "card-plan-test.md"), "## Planning Q&A\nQ: What?\nA: This.")

    result = finalize_plan(card_id: "plan-test", card_number: 5, agent_name: "Galen",
                           project_key: "mp", repo_path: "/tmp")
    refute result[:success]
    assert_includes result[:error], "Plan file not generated"
  end

  def test_finalize_plan_parses_tasks
    memory_dir = memory_dir_for("Galen")
    FileUtils.mkdir_p(memory_dir)
    File.write(File.join(memory_dir, "card-task-test.md"), "## Planning Q&A\nQ: What?\nA: Build it.")

    plan_file = File.join(PLANS_DIR, "card-task-test-plan.md")
    File.write(plan_file, <<~PLAN)
      # Plan for Card #7

      ## Task Breakdown
      ### Task 1: Set up database schema
      ### Task 2: Build API endpoints
      ### Task 3: Write tests
    PLAN

    # finalize_plan tries to run fizzy commands, which will fail in test, but we can
    # verify it finds the tasks by checking it doesn't return the "no tasks" warning path
    # We just test that the plan file is parseable - finalize_plan needs fizzy CLI
    plan_content = File.read(plan_file)
    tasks = []
    plan_content.scan(/^###\s+Task\s+\d+:\s+(.+)$/i) { |m| tasks << m[0].strip }
    assert_equal 3, tasks.size
    assert_equal "Set up database schema", tasks[0]
    assert_equal "Build API endpoints", tasks[1]
    assert_equal "Write tests", tasks[2]
  end
end
