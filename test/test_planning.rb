# frozen_string_literal: true

require_relative "test_helper"

class TestPlanning < Minitest::Test
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

  def test_detect_planning_mode_returns_nil_without_tag
    result = detect_planning_mode(text: "just do it", tags: [{ "name" => "marketplace" }])
    assert_nil result
  end

  def test_detect_planning_mode_discord_card_id_fallback
    result = detect_planning_mode(text: "[plan] question", tags: [])
    assert result
    assert_match(/^discord-/, result[:card_id])
  end

  def test_planning_complete_false_when_no_memory
    refute planning_complete?("card-nonexistent-99", "Galen")
  end

  def test_planning_complete_true_with_marker
    memory_dir = memory_dir_for("Galen")
    FileUtils.mkdir_p(memory_dir)
    File.write(File.join(memory_dir, "card-card-plan-100.md"), "planning_complete: true\nDone.")
    assert planning_complete?("card-plan-100", "Galen")
  end

  def test_finalize_plan_fails_without_memory
    result = finalize_plan(card_id: "no-memory-xyz", card_number: 1, agent_name: "Galen",
                           project_key: "mp", repo_path: "/tmp")
    refute result[:success]
    assert_includes result[:error], "No memory file"
  end

  def test_finalize_plan_fails_without_plan_file
    memory_dir = memory_dir_for("Galen")
    FileUtils.mkdir_p(memory_dir)
    File.write(File.join(memory_dir, "card-plan-missing-file.md"), "Q&A here")
    result = finalize_plan(card_id: "plan-missing-file", card_number: 5, agent_name: "Galen",
                           project_key: "mp", repo_path: "/tmp")
    refute result[:success]
    assert_includes result[:error], "Plan file not generated"
  end
end
