# frozen_string_literal: true

require_relative "test_helper"

class TestHelpers < Minitest::Test
  def test_slugify_basic
    assert_equal "hello-world", slugify("Hello World")
  end

  def test_slugify_strips_special_chars
    assert_equal "fix-bug-in-login", slugify("Fix bug in login!")
  end

  def test_slugify_truncates_to_max_length
    long_title = "a" * 100
    result = slugify(long_title, max_length: 40)
    assert_operator result.length, :<=, 40
  end

  def test_identify_project_by_repo
    key, config = identify_project_by_repo("stowzilla/marketplace")
    assert_equal "marketplace", key
    assert_equal "/home/test/Code/marketplace", config["repo_path"]
  end

  def test_identify_project_by_repo_not_found_falls_to_default
    key, _config = identify_project_by_repo("someorg/unknown-repo")
    assert_equal "brainiac", key
  end

  def test_load_work_item_map_empty_when_no_file
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    assert_equal({}, load_work_item_map)
  end

  def test_save_and_load_work_item_map
    map = { "card-abc" => { "number" => 42, "branch" => "fizzy-42-test" } }
    save_work_item_map(map)
    loaded = load_work_item_map
    assert_equal 42, loaded["card-abc"]["number"]
  end

  def test_detect_model_from_inline_text
    config = PROJECTS["marketplace"]
    assert_equal "claude-opus-4.6", detect_model(config, text: "[opus] do the thing")
  end

  def test_detect_model_from_tags
    config = PROJECTS["marketplace"]
    assert_equal "claude-sonnet-4.6", detect_model(config, tags: [{ "name" => "sonnet" }])
  end

  def test_detect_model_text_priority_over_tags
    config = PROJECTS["marketplace"]
    result = detect_model(config, text: "[haiku] review", tags: [{ "name" => "opus" }])
    assert_equal "claude-haiku-4.5", result
  end

  def test_mark_and_check_card_merged
    mark_work_item_merged(100)
    assert work_item_merged?(100)
  end

  def test_card_not_merged_initially
    refute work_item_merged?(999)
  end

  def test_detect_cli_provider_from_text
    assert_equal "grok", detect_cli_provider(text: "[cli:grok] do stuff")
  end

  def test_default_project_key
    assert_equal "brainiac", default_project_key
  end
end
