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

  def test_save_and_load_work_item_map_new_format
    work_item_id = "wi-12345678"
    map = {
      work_item_id => {
        "id" => work_item_id,
        "branch" => "fizzy-42-test",
        "worktree" => "/tmp/test-worktree",
        "project" => "marketplace",
        "agent" => "Sherlock",
        "sources" => {
          "fizzy" => { "card_internal_id" => "card-abc", "card_number" => 42 }
        }
      }
    }
    save_work_item_map(map)
    loaded = load_work_item_map
    assert_equal work_item_id, loaded[work_item_id]["id"]
    assert_equal "fizzy-42-test", loaded[work_item_id]["branch"]
    assert_equal 42, loaded[work_item_id]["sources"]["fizzy"]["card_number"]
  end

  def test_migrate_old_format_work_item_map
    old_map = {
      "fizzy-uuid-123" => {
        "number" => 42,
        "branch" => "fizzy-42-fix-login",
        "worktree" => "/tmp/marketplace--fizzy-42-fix-login",
        "project" => "marketplace",
        "agent" => "Sherlock"
      }
    }
    save_work_item_map(old_map)
    loaded = load_work_item_map

    # Should have exactly one entry, with a generated work item ID
    assert_equal 1, loaded.size
    entry = loaded.values.first
    assert_equal "fizzy-42-fix-login", entry["branch"]
    assert_equal "/tmp/marketplace--fizzy-42-fix-login", entry["worktree"]
    assert_equal "marketplace", entry["project"]
    assert_equal "Sherlock", entry["agent"]
    assert_equal "fizzy-uuid-123", entry["sources"]["fizzy"]["card_internal_id"]
    assert_equal 42, entry["sources"]["fizzy"]["card_number"]
    assert entry["id"].start_with?("wi-")
  end

  def test_migrate_old_format_preserves_prs
    old_map = {
      "fizzy-uuid-456" => {
        "number" => 10,
        "branch" => "fizzy-10-add-feature",
        "worktree" => "/tmp/test",
        "project" => "brainiac",
        "agent" => "Robin",
        "prs" => [{ "number" => 5, "url" => "https://github.com/org/repo/pull/5" }]
      }
    }
    save_work_item_map(old_map)
    loaded = load_work_item_map

    entry = loaded.values.first
    assert_equal [{ "number" => 5, "url" => "https://github.com/org/repo/pull/5" }], entry["sources"]["github"]["prs"]
  end

  def test_find_work_item_by_branch
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    register_work_item(branch: "discord-bugfixes-123", worktree: "/tmp/wt", project: "brainiac", agent: "Galen")

    result = find_work_item_by_branch("discord-bugfixes-123")
    refute_nil result
    work_item_id, info = result
    assert work_item_id.start_with?("wi-")
    assert_equal "discord-bugfixes-123", info["branch"]
    assert_equal "Galen", info["agent"]
  end

  def test_find_work_item_by_branch_not_found
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    assert_nil find_work_item_by_branch("nonexistent-branch")
  end

  def test_find_work_item_by_id
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    wid = register_work_item(branch: "test-branch", project: "brainiac", agent: "Sherlock")

    info = find_work_item_by_id(wid)
    refute_nil info
    assert_equal "test-branch", info["branch"]
  end

  def test_find_work_item_by_card
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    register_work_item(
      branch: "fizzy-99-something",
      project: "marketplace",
      agent: "Sherlock",
      source: "fizzy",
      source_data: { "card_internal_id" => "uuid-fizzy-99", "card_number" => 99 }
    )

    result = find_work_item_by_card("uuid-fizzy-99")
    refute_nil result
    _wid, info = result
    assert_equal "fizzy-99-something", info["branch"]
    assert_equal 99, info["sources"]["fizzy"]["card_number"]
  end

  def test_register_work_item_creates_new
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    wid = register_work_item(
      branch: "new-feature-branch",
      worktree: "/tmp/worktree",
      project: "marketplace",
      agent: "Galen",
      source: "discord",
      source_data: { "thread_id" => "12345" }
    )

    assert wid.start_with?("wi-")
    info = find_work_item_by_id(wid)
    assert_equal "new-feature-branch", info["branch"]
    assert_equal "/tmp/worktree", info["worktree"]
    assert_equal "12345", info["sources"]["discord"]["thread_id"]
  end

  def test_register_work_item_updates_existing_branch
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    wid1 = register_work_item(branch: "shared-branch", project: "brainiac", agent: "Galen",
                              source: "discord", source_data: { "thread_id" => "111" })

    # Register same branch from fizzy — should attach to existing work item
    wid2 = register_work_item(branch: "shared-branch", worktree: "/tmp/new-wt", agent: "Sherlock",
                              source: "fizzy", source_data: { "card_number" => 50 })

    assert_equal wid1, wid2
    info = find_work_item_by_id(wid1)
    assert_equal "/tmp/new-wt", info["worktree"]
    assert_equal "Sherlock", info["agent"]
    assert_equal "111", info["sources"]["discord"]["thread_id"]
    assert_equal 50, info["sources"]["fizzy"]["card_number"]
  end

  def test_register_work_item_source
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    wid = register_work_item(branch: "my-branch", project: "brainiac", agent: "Galen")

    success = register_work_item_source(work_item_id: wid, source: "github",
                                        source_data: { "prs" => [{ "number" => 8 }] })
    assert success
    info = find_work_item_by_id(wid)
    assert_equal [{ "number" => 8 }], info["sources"]["github"]["prs"]
  end

  def test_register_work_item_source_by_branch
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    register_work_item(branch: "branch-for-source", project: "brainiac", agent: "Galen")

    success = register_work_item_source(branch: "branch-for-source", source: "fizzy",
                                        source_data: { "card_number" => 77 })
    assert success
    result = find_work_item_by_branch("branch-for-source")
    assert_equal 77, result[1]["sources"]["fizzy"]["card_number"]
  end

  def test_register_work_item_source_not_found
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    refute register_work_item_source(work_item_id: "wi-nonexistent", source: "github", source_data: {})
  end

  def test_generate_work_item_id_deterministic_for_branch
    id1 = generate_work_item_id(branch: "my-feature")
    id2 = generate_work_item_id(branch: "my-feature")
    assert_equal id1, id2
    assert id1.start_with?("wi-")
  end

  def test_generate_work_item_id_different_branches
    id1 = generate_work_item_id(branch: "branch-a")
    id2 = generate_work_item_id(branch: "branch-b")
    refute_equal id1, id2
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

  def test_intent_skip_returns_false_when_no_message
    refute intent_skip?(nil, agent_name: "Sherlock")
  end

  def test_intent_skip_returns_false_when_no_agent_name
    refute intent_skip?("do the thing", agent_name: nil)
  end

  def test_intent_skip_returns_false_when_intent_disabled
    # Default config has intent disabled
    refute intent_skip?("do the thing", agent_name: "Sherlock", source: :discord)
  end

  def test_intent_skip_returns_false_when_enabled_but_connection_fails
    original = BRAINIAC_CONFIG.dup
    BRAINIAC_CONFIG["intent"] = { "enabled" => true, "endpoint" => "http://localhost:99999/api/generate", "timeout" => 1 }

    # check_intent fail-opens (returns true) → intent_skip? returns false (don't skip)
    refute intent_skip?("do the thing", agent_name: "Sherlock", source: :discord)
  ensure
    BRAINIAC_CONFIG.replace(original)
  end
end
