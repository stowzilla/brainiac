# frozen_string_literal: true

require_relative "test_helper"

class TestInlineTags < Minitest::Test
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

  def test_parse_model_tag_opus
    result = parse_inline_tags("[opus] do the thing")
    assert_equal "opus", result[:model_tag]
    assert_equal "do the thing", result[:clean_text]
  end

  def test_parse_model_tag_sonnet
    result = parse_inline_tags("[sonnet] analyze this")
    assert_equal "sonnet", result[:model_tag]
  end

  def test_parse_effort_tag
    result = parse_inline_tags("[effort:high] complex task")
    assert_equal "high", result[:effort]
    assert_equal "complex task", result[:clean_text]
  end

  def test_parse_effort_tag_case_insensitive
    result = parse_inline_tags("[Effort:LOW] quick fix")
    assert_equal "low", result[:effort]
  end

  def test_parse_cli_provider_tag
    result = parse_inline_tags("[cli:grok] use grok for this")
    assert_equal "grok", result[:cli_provider]
    assert_equal "use grok for this", result[:clean_text]
  end

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

  def test_parse_plan_tag
    result = parse_inline_tags("[plan] design the API")
    assert result[:planning]
    assert_equal "design the API", result[:clean_text]
  end

  def test_no_planning_by_default
    result = parse_inline_tags("just do it")
    refute result[:planning]
  end

  def test_parse_deploy_tag_auto
    result = parse_inline_tags("[deploy] ship it")
    assert_equal :auto, result[:deploy_intent]
  end

  def test_parse_deploy_tag_with_target
    result = parse_inline_tags("[deploy:dev01] push to dev")
    assert_equal "dev01", result[:deploy_intent]
  end

  def test_parse_worktree_tag
    result = parse_inline_tags("[worktree:feature-branch] work here")
    assert_equal "feature-branch", result[:worktree_override]
    assert_equal "work here", result[:clean_text]
  end

  def test_multiple_tags_combined
    result = parse_inline_tags("[project:brainiac] [effort:max] [plan] review the architecture")
    assert_equal "brainiac", result[:project]
    assert_equal "max", result[:effort]
    assert result[:planning]
    assert_includes result[:clean_text], "review the architecture"
  end

  def test_empty_string
    result = parse_inline_tags("")
    assert_nil result[:project]
    assert_equal "", result[:clean_text]
  end

  def test_only_tags_no_content
    result = parse_inline_tags("[opus] [plan]")
    assert_equal "opus", result[:model_tag]
    assert result[:planning]
    assert_equal "", result[:clean_text]
  end
end
