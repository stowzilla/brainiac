# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/handlers/shared/inline_tags"

class TestInlineTags < Minitest::Test
  # --- Project tag ---

  def test_parse_project_tag
    result = parse_inline_tags("[project:marketplace] hello world")
    assert_equal "marketplace", result[:project]
    assert_equal "hello world", result[:clean_text]
  end

  def test_parse_project_tag_case_insensitive
    result = parse_inline_tags("[Project:MyApp] check status")
    assert_equal "MyApp", result[:project]
  end

  def test_no_project_tag
    result = parse_inline_tags("just a normal message")
    assert_nil result[:project]
  end

  # --- Model tag ---

  def test_parse_model_tag_opus
    result = parse_inline_tags("[opus] do the thing")
    assert_equal "opus", result[:model_tag]
    assert_equal "do the thing", result[:clean_text]
  end

  def test_parse_model_tag_sonnet
    result = parse_inline_tags("[sonnet] analyze this")
    assert_equal "sonnet", result[:model_tag]
  end

  def test_parse_model_tag_haiku
    result = parse_inline_tags("[haiku] short response please")
    assert_equal "haiku", result[:model_tag]
  end

  def test_parse_model_tag_deepseek
    result = parse_inline_tags("[deepseek] code review")
    assert_equal "deepseek", result[:model_tag]
  end

  # --- Effort tag ---

  def test_parse_effort_tag
    result = parse_inline_tags("[effort:high] complex task")
    assert_equal "high", result[:effort]
    assert_equal "complex task", result[:clean_text]
  end

  def test_parse_effort_tag_max
    result = parse_inline_tags("[effort:max] thorough review")
    assert_equal "max", result[:effort]
  end

  def test_parse_effort_tag_case_insensitive
    result = parse_inline_tags("[Effort:LOW] quick fix")
    assert_equal "low", result[:effort]
  end

  # --- CLI provider tag ---

  def test_parse_cli_provider_tag
    result = parse_inline_tags("[cli:grok] use grok for this")
    assert_equal "grok", result[:cli_provider]
    assert_equal "use grok for this", result[:clean_text]
  end

  # --- Chat mode ---

  def test_parse_chat_tag
    result = parse_inline_tags("[chat] what is this?")
    assert result[:chat_mode]
    assert_equal "what is this?", result[:clean_text]
  end

  def test_parse_question_tag
    result = parse_inline_tags("[question] explain this")
    assert result[:chat_mode]
  end

  def test_parse_question_mark_tag
    result = parse_inline_tags("[?] how does this work")
    assert result[:chat_mode]
  end

  def test_no_chat_mode_by_default
    result = parse_inline_tags("normal message")
    refute result[:chat_mode]
  end

  # --- Planning mode ---

  def test_parse_plan_tag
    result = parse_inline_tags("[plan] design the API")
    assert result[:planning]
    assert_equal "design the API", result[:clean_text]
  end

  def test_no_planning_by_default
    result = parse_inline_tags("just do it")
    refute result[:planning]
  end

  # --- Deploy intent ---

  def test_parse_deploy_tag_auto
    result = parse_inline_tags("[deploy] ship it")
    assert_equal :auto, result[:deploy_intent]
    assert_equal "ship it", result[:clean_text]
  end

  def test_parse_deploy_tag_with_target
    result = parse_inline_tags("[deploy:dev01] push to dev")
    assert_equal "dev01", result[:deploy_intent]
  end

  def test_no_deploy_by_default
    result = parse_inline_tags("no deploy here")
    assert_nil result[:deploy_intent]
  end

  # --- Worktree override ---

  def test_parse_worktree_tag
    result = parse_inline_tags("[worktree:feature-branch] work here")
    assert_equal "feature-branch", result[:worktree_override]
    assert_equal "work here", result[:clean_text]
  end

  def test_no_worktree_by_default
    result = parse_inline_tags("normal work")
    assert_nil result[:worktree_override]
  end

  # --- Multiple tags ---

  def test_multiple_tags_combined
    result = parse_inline_tags("[project:brainiac] [opus] [effort:max] [plan] review the architecture")
    assert_equal "brainiac", result[:project]
    assert_equal "max", result[:effort]
    assert result[:planning]
    # model_tag picks up "opus" after known tags are stripped
    assert_equal "opus", result[:model_tag]
    assert_includes result[:clean_text], "review the architecture"
  end

  def test_tags_stripped_from_clean_text
    result = parse_inline_tags("[project:mp] [sonnet] hello there")
    refute_includes result[:clean_text], "[project:mp]"
    refute_includes result[:clean_text], "[sonnet]"
    assert_equal "hello there", result[:clean_text]
  end

  # --- Edge cases ---

  def test_empty_string
    result = parse_inline_tags("")
    assert_nil result[:project]
    assert_nil result[:model_tag]
    assert_equal "", result[:clean_text]
  end

  def test_only_tags_no_content
    result = parse_inline_tags("[opus] [plan]")
    assert_equal "opus", result[:model_tag]
    assert result[:planning]
    assert_equal "", result[:clean_text]
  end

  def test_tags_in_middle_of_text
    result = parse_inline_tags("hey [opus] how are you")
    assert_equal "opus", result[:model_tag]
    assert_equal "hey  how are you", result[:clean_text]
  end

  def test_unknown_single_word_bracket_treated_as_model
    result = parse_inline_tags("[minimax] something")
    assert_equal "minimax", result[:model_tag]
  end
end
