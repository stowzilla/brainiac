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

  def test_update_work_item_overrides_by_id
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    wid = register_work_item(branch: "override-branch", project: "brainiac", agent: "Galen")

    success = update_work_item_overrides(work_item_id: wid, cli_provider: "grok", model: "claude-opus-4.5")
    assert success
    info = find_work_item_by_id(wid)
    assert_equal "grok", info["overrides"]["cli_provider"]
    assert_equal "claude-opus-4.5", info["overrides"]["model"]
    assert_nil info["overrides"]["effort"]
  end

  def test_update_work_item_overrides_by_branch
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    register_work_item(branch: "override-branch-2", project: "brainiac", agent: "Galen")

    success = update_work_item_overrides(branch: "override-branch-2", effort: "high")
    assert success
    overrides = work_item_overrides_for(branch: "override-branch-2")
    assert_equal "high", overrides["effort"]
  end

  def test_update_work_item_overrides_merges_incrementally
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    wid = register_work_item(branch: "incremental-branch", project: "brainiac", agent: "Galen")

    update_work_item_overrides(work_item_id: wid, cli_provider: "grok")
    update_work_item_overrides(work_item_id: wid, effort: "high")

    overrides = work_item_overrides_for(work_item_id: wid)
    assert_equal "grok", overrides["cli_provider"]
    assert_equal "high", overrides["effort"]
  end

  def test_update_work_item_overrides_not_found
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    refute update_work_item_overrides(work_item_id: "wi-nonexistent", cli_provider: "grok")
  end

  def test_work_item_overrides_for_empty_when_none_set
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    wid = register_work_item(branch: "no-overrides", project: "brainiac", agent: "Galen")

    overrides = work_item_overrides_for(work_item_id: wid)
    assert_equal({}, overrides)
  end

  def test_work_item_overrides_for_not_found
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    assert_equal({}, work_item_overrides_for(work_item_id: "wi-nonexistent"))
  end

  def test_resolve_work_item_overrides_uses_stored_when_no_inline
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    wid = register_work_item(branch: "resolve-test", project: "brainiac", agent: "Galen")
    update_work_item_overrides(work_item_id: wid, cli_provider: "grok", effort: "high")

    resolved = resolve_work_item_overrides(work_item_id: wid)
    assert_equal "grok", resolved[:cli_provider]
    assert_equal "high", resolved[:effort]
    assert_nil resolved[:model]
  end

  def test_resolve_work_item_overrides_inline_wins_and_persists
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    wid = register_work_item(branch: "resolve-inline-test", project: "brainiac", agent: "Galen")
    update_work_item_overrides(work_item_id: wid, cli_provider: "grok")

    resolved = resolve_work_item_overrides(work_item_id: wid, inline_cli_provider: "kiro", inline_model: "claude-opus-4.5")
    assert_equal "kiro", resolved[:cli_provider]
    assert_equal "claude-opus-4.5", resolved[:model]

    # Verify it was persisted
    stored = work_item_overrides_for(work_item_id: wid)
    assert_equal "kiro", stored["cli_provider"]
    assert_equal "claude-opus-4.5", stored["model"]
  end

  def test_resolve_work_item_overrides_no_work_item
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
    resolved = resolve_work_item_overrides(branch: "nonexistent", inline_cli_provider: "grok")
    assert_equal "grok", resolved[:cli_provider]
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

  # --- load_cli_provider tests ---

  def test_load_cli_provider_with_profile_agent_flag
    provider_dir = File.join(TEST_BRAINIAC_DIR, "cli-providers")
    File.write(File.join(provider_dir, "codex.json"), JSON.generate({
      "binary" => "codex",
      "default_args" => "exec --sandbox workspace-write -",
      "agent_flag" => "--profile",
      "model_flag" => "--model",
      "prompt_mode" => "stdin",
      "models" => { "o3" => "o3", "o4-mini" => "o4-mini" }
    }))

    config = load_cli_provider("codex")
    assert_equal "codex", config["agent_cli"]
    assert_equal "--profile", config["agent_flag"]
    assert_equal "exec --sandbox workspace-write -", config["agent_cli_args"]
    assert_equal "--model", config["agent_model_flag"]
    assert_equal "stdin", config["prompt_mode"]
    assert_equal({ "o3" => "o3", "o4-mini" => "o4-mini" }, config["allowed_models"])
  end

  def test_load_cli_provider_with_null_agent_flag
    provider_dir = File.join(TEST_BRAINIAC_DIR, "cli-providers")
    File.write(File.join(provider_dir, "grok-test.json"), JSON.generate({
      "binary" => "grok",
      "default_args" => "--always-approve",
      "agent_flag" => nil,
      "model_flag" => "--model",
      "prompt_mode" => "flag",
      "prompt_flag" => "--prompt-file"
    }))

    config = load_cli_provider("grok-test")
    assert_equal "grok", config["agent_cli"]
    assert_nil config["agent_flag"]
    # nil agent_flag should be preserved (not compacted away)
    assert config.key?("agent_flag")
  end

  def test_load_cli_provider_missing_agent_flag_defaults_to_agent
    provider_dir = File.join(TEST_BRAINIAC_DIR, "cli-providers")
    File.write(File.join(provider_dir, "minimal.json"), JSON.generate({
      "binary" => "some-cli",
      "default_args" => ""
    }))

    config = load_cli_provider("minimal")
    assert_equal "--agent", config["agent_flag"]
  end

  # --- build_agent_cmd tests ---

  def test_build_agent_cmd_default_agent_flag
    resolved = {
      "agent_cli" => "kiro-cli",
      "agent_flag" => "--agent",
      "agent_cli_args" => "chat --no-interactive",
      "agent_model_flag" => "--model",
      "allowed_models" => { "opus" => "claude-opus-4.5" }
    }
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", model: "claude-opus-4.5")
    assert_equal %w[kiro-cli --agent sherlock chat --no-interactive --model claude-opus-4.5], cmd
  end

  def test_build_agent_cmd_profile_agent_flag_for_codex
    resolved = {
      "agent_cli" => "codex",
      "agent_flag" => "--profile",
      "agent_cli_args" => "exec --sandbox workspace-write -",
      "agent_model_flag" => "--model",
      "allowed_models" => { "o3" => "o3", "o4-mini" => "o4-mini" },
      "prompt_mode" => "stdin"
    }
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", model: "o3")
    assert_equal %w[codex --profile sherlock exec --sandbox workspace-write - --model o3], cmd
  end

  def test_build_agent_cmd_null_agent_flag_suppresses_agent_name
    resolved = {
      "agent_cli" => "grok",
      "agent_flag" => nil,
      "agent_cli_args" => "--always-approve",
      "agent_model_flag" => "--model",
      "allowed_models" => {}
    }
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock")
    assert_equal %w[grok --always-approve], cmd
    refute_includes cmd, "sherlock"
  end

  def test_build_agent_cmd_no_agent_config_name
    resolved = {
      "agent_cli" => "codex",
      "agent_flag" => "--profile",
      "agent_cli_args" => "exec -",
      "agent_model_flag" => "--model",
      "allowed_models" => {}
    }
    cmd = build_agent_cmd(resolved, agent_config_name: nil)
    assert_equal %w[codex exec -], cmd
    refute_includes cmd, "--profile"
  end

  def test_build_agent_cmd_resume_flag
    resolved = {
      "agent_cli" => "kiro-cli",
      "agent_flag" => "--agent",
      "agent_cli_args" => "chat --no-interactive",
      "agent_model_flag" => "--model",
      "allowed_models" => {},
      "resume_flag" => "--resume"
    }
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", resume: true)
    assert_includes cmd, "--resume"
  end

  def test_build_agent_cmd_prompt_flag_mode
    resolved = {
      "agent_cli" => "grok",
      "agent_flag" => nil,
      "agent_cli_args" => "--always-approve",
      "agent_model_flag" => "--model",
      "allowed_models" => {},
      "prompt_mode" => "flag",
      "prompt_flag" => "--prompt-file"
    }
    cmd = build_agent_cmd(resolved, prompt_file: "/tmp/prompt.md")
    assert_equal %w[grok --always-approve --prompt-file /tmp/prompt.md], cmd
  end

  def test_detect_model_from_inline_text
    config = PROJECTS["marketplace"]
    assert_equal "claude-opus-4.5", detect_model(config, text: "[opus] do the thing")
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

  # --- build_agent_cmd tests ---

  def test_build_agent_cmd_basic
    resolved = {
      "agent_cli" => "kiro-cli",
      "agent_flag" => "--agent",
      "agent_cli_args" => "chat --no-interactive",
      "agent_model_flag" => "--model",
      "agent_effort_flag" => "--effort",
      "allowed_models" => { "opus" => "claude-opus-4.5" },
      "prompt_mode" => "stdin"
    }
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", model: "claude-opus-4.5")
    assert_equal %w[kiro-cli --agent sherlock chat --no-interactive --model claude-opus-4.5], cmd
  end

  def test_build_agent_cmd_with_cwd_flag
    resolved = {
      "agent_cli" => "codex",
      "agent_flag" => nil,
      "agent_cli_args" => "--full-auto",
      "agent_model_flag" => "-m",
      "cwd_flag" => "-C",
      "allowed_models" => { "o4-mini" => "o4-mini" },
      "prompt_mode" => "flag",
      "prompt_flag" => "--prompt-file"
    }
    cmd = build_agent_cmd(resolved, model: "o4-mini", chdir: "/home/user/projects/myapp", prompt_file: "/tmp/prompt.md")
    assert_equal %w[codex -C /home/user/projects/myapp --full-auto -m o4-mini --prompt-file /tmp/prompt.md], cmd
  end

  def test_build_agent_cmd_cwd_flag_omitted_when_no_chdir
    resolved = {
      "agent_cli" => "codex",
      "agent_flag" => nil,
      "agent_cli_args" => "--full-auto",
      "cwd_flag" => "-C",
      "prompt_mode" => "stdin"
    }
    cmd = build_agent_cmd(resolved)
    assert_equal %w[codex --full-auto], cmd
    refute_includes cmd, "-C"
  end

  def test_build_agent_cmd_no_cwd_flag_in_config
    resolved = {
      "agent_cli" => "kiro-cli",
      "agent_flag" => "--agent",
      "agent_cli_args" => "chat --no-interactive",
      "prompt_mode" => "stdin"
    }
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", chdir: "/home/user/project")
    # chdir is passed but no cwd_flag in config — should not appear in cmd
    assert_equal %w[kiro-cli --agent sherlock chat --no-interactive], cmd
    refute_includes cmd, "/home/user/project"
  end

  def test_build_agent_cmd_cwd_flag_position_before_args
    resolved = {
      "agent_cli" => "codex",
      "agent_flag" => nil,
      "agent_cli_args" => "--full-auto --sandbox workspace-write",
      "cwd_flag" => "-C",
      "prompt_mode" => "stdin"
    }
    cmd = build_agent_cmd(resolved, chdir: "/tmp/worktree")
    # -C should appear right after the binary, before default_args
    assert_equal "codex", cmd[0]
    assert_equal "-C", cmd[1]
    assert_equal "/tmp/worktree", cmd[2]
    assert_equal "--full-auto", cmd[3]
  end

  def test_build_agent_cmd_with_resume_flag
    resolved = {
      "agent_cli" => "grok",
      "agent_flag" => nil,
      "agent_cli_args" => "--always-approve",
      "resume_flag" => "-c",
      "prompt_mode" => "stdin"
    }
    cmd = build_agent_cmd(resolved, resume: true)
    assert_includes cmd, "-c"
  end

  def test_build_agent_cmd_with_standard_effort_flag
    resolved = {
      "agent_cli" => "kiro-cli",
      "agent_cli_args" => "chat --no-interactive",
      "agent_flag" => "--agent",
      "agent_effort_flag" => "--effort",
      "agent_model_flag" => "--model",
      "allowed_models" => { "opus" => "claude-opus-4.5" }
    }
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", effort: "high")
    assert_includes cmd, "--effort"
    assert_includes cmd, "high"
    idx = cmd.index("--effort")
    assert_equal "high", cmd[idx + 1]
  end

  def test_build_agent_cmd_with_config_override_effort
    resolved = {
      "agent_cli" => "codex",
      "agent_cli_args" => "--full-auto",
      "agent_flag" => nil,
      "effort_config_key" => "model_reasoning_effort",
      "config_override_flag" => "-c",
      "agent_model_flag" => "--model",
      "allowed_models" => { "gpt5" => "gpt-5.5" }
    }
    cmd = build_agent_cmd(resolved, effort: "high")
    assert_includes cmd, "-c"
    idx = cmd.index("-c")
    assert_equal 'model_reasoning_effort="high"', cmd[idx + 1]
    # Should NOT include --effort
    refute_includes cmd, "--effort"
  end

  def test_build_agent_cmd_with_effort_map
    resolved = {
      "agent_cli" => "codex",
      "agent_cli_args" => "--full-auto",
      "agent_flag" => nil,
      "effort_config_key" => "model_reasoning_effort",
      "config_override_flag" => "-c",
      "effort_map" => { "max" => "xhigh", "low" => "low" },
      "agent_model_flag" => "--model",
      "allowed_models" => {}
    }
    cmd = build_agent_cmd(resolved, effort: "max")
    idx = cmd.index("-c")
    assert_equal 'model_reasoning_effort="xhigh"', cmd[idx + 1]
  end

  def test_build_agent_cmd_effort_map_passthrough_unmapped
    resolved = {
      "agent_cli" => "codex",
      "agent_cli_args" => "--full-auto",
      "agent_flag" => nil,
      "effort_config_key" => "model_reasoning_effort",
      "config_override_flag" => "-c",
      "effort_map" => { "max" => "xhigh" },
      "agent_model_flag" => "--model",
      "allowed_models" => {}
    }
    # "medium" isn't in the map, so it passes through unchanged
    cmd = build_agent_cmd(resolved, effort: "medium")
    idx = cmd.index("-c")
    assert_equal 'model_reasoning_effort="medium"', cmd[idx + 1]
  end

  def test_build_agent_cmd_no_effort_when_nil
    resolved = {
      "agent_cli" => "codex",
      "agent_cli_args" => "--full-auto",
      "agent_flag" => nil,
      "effort_config_key" => "model_reasoning_effort",
      "config_override_flag" => "-c",
      "agent_effort_flag" => "--effort",
      "agent_model_flag" => "--model",
      "allowed_models" => {}
    }
    cmd = build_agent_cmd(resolved, effort: nil)
    refute_includes cmd, "-c"
    refute_includes cmd, "--effort"
  end

  def test_build_agent_cmd_config_override_defaults_to_dash_c
    # If config_override_flag is not set, defaults to "-c"
    resolved = {
      "agent_cli" => "codex",
      "agent_cli_args" => "--full-auto",
      "agent_flag" => nil,
      "effort_config_key" => "model_reasoning_effort",
      "agent_model_flag" => "--model",
      "allowed_models" => {}
    }
    cmd = build_agent_cmd(resolved, effort: "high")
    assert_includes cmd, "-c"
    idx = cmd.index("-c")
    assert_equal 'model_reasoning_effort="high"', cmd[idx + 1]
  end

  def test_map_effort_level_with_map
    resolved = { "effort_map" => { "max" => "xhigh", "low" => "minimal" } }
    assert_equal "xhigh", map_effort_level("max", resolved)
    assert_equal "minimal", map_effort_level("low", resolved)
    assert_equal "medium", map_effort_level("medium", resolved) # passthrough
  end

  def test_map_effort_level_without_map
    resolved = {}
    assert_equal "high", map_effort_level("high", resolved)
  end

  def test_map_effort_level_nil_effort
    resolved = { "effort_map" => { "max" => "xhigh" } }
    assert_nil map_effort_level(nil, resolved)
  end

  def test_load_cli_provider_with_cwd_flag
    provider_file = File.join(TEST_BRAINIAC_DIR, "cli-providers", "codex-test.json")
    File.write(provider_file, JSON.generate({
                                              "binary" => "codex",
                                              "default_args" => "--full-auto",
                                              "agent_flag" => nil,
                                              "model_flag" => "-m",
                                              "cwd_flag" => "-C",
                                              "prompt_mode" => "flag",
                                              "prompt_flag" => "--prompt-file",
                                              "models" => { "o4-mini" => "o4-mini" }
                                            }))
    config = load_cli_provider("codex-test")
    assert_equal "-C", config["cwd_flag"]
    assert_equal "codex", config["agent_cli"]
    assert_nil config["agent_flag"]
  ensure
    FileUtils.rm_f(provider_file)
  end

  def test_load_cli_provider_with_effort_config_key
    # Write a codex-like provider config to the test cli-providers dir
    provider_file = File.join(TEST_BRAINIAC_DIR, "cli-providers", "codex-effort-test.json")
    File.write(provider_file, JSON.generate({
                                              "binary" => "codex",
                                              "default_args" => "--full-auto",
                                              "agent_flag" => nil,
                                              "model_flag" => "--model",
                                              "effort_flag" => nil,
                                              "effort_config_key" => "model_reasoning_effort",
                                              "config_override_flag" => "-c",
                                              "effort_map" => { "max" => "xhigh", "low" => "low" },
                                              "prompt_mode" => "stdin",
                                              "models" => { "gpt5" => "gpt-5.5" },
                                              "efforts" => %w[low medium high xhigh max]
                                            }))
    config = load_cli_provider("codex-effort-test")
    assert_equal "codex", config["agent_cli"]
    assert_equal "model_reasoning_effort", config["effort_config_key"]
    assert_equal "-c", config["config_override_flag"]
    assert_equal({ "max" => "xhigh", "low" => "low" }, config["effort_map"])
    assert_nil config["agent_effort_flag"] # effort_flag was nil, so it's compacted out
  ensure
    FileUtils.rm_f(provider_file)
  end

  def test_load_cli_provider_without_cwd_flag
    provider_file = File.join(TEST_BRAINIAC_DIR, "cli-providers", "kiro-test.json")
    File.write(provider_file, JSON.generate({
                                              "binary" => "kiro-cli",
                                              "default_args" => "chat --no-interactive",
                                              "model_flag" => "--model",
                                              "models" => { "opus" => "claude-opus-4.5" }
                                            }))
    config = load_cli_provider("kiro-test")
    refute config.key?("cwd_flag")
    assert_equal "kiro-cli", config["agent_cli"]
  ensure
    FileUtils.rm_f(provider_file)
  end

  def test_full_integration_codex_effort_via_provider
    # Write a codex-like provider config
    provider_file = File.join(TEST_BRAINIAC_DIR, "cli-providers", "codex-int.json")
    File.write(provider_file, JSON.generate({
                                              "binary" => "codex",
                                              "default_args" => "--full-auto",
                                              "agent_flag" => nil,
                                              "model_flag" => "--model",
                                              "effort_flag" => nil,
                                              "effort_config_key" => "model_reasoning_effort",
                                              "config_override_flag" => "-c",
                                              "effort_map" => { "max" => "xhigh" },
                                              "prompt_mode" => "stdin",
                                              "models" => { "gpt5" => "gpt-5.5" },
                                              "efforts" => %w[low medium high xhigh max]
                                            }))
    # Resolve through the full pipeline
    project_config = { "cli_provider" => "codex-int" }
    resolved = resolve_project_cli_config(project_config)
    cmd = build_agent_cmd(resolved, effort: "max")
    # Should produce: codex --full-auto -c 'model_reasoning_effort="xhigh"'
    assert_equal "codex", cmd[0]
    assert_includes cmd, "-c"
    idx = cmd.index("-c")
    assert_equal 'model_reasoning_effort="xhigh"', cmd[idx + 1]
    refute_includes cmd, "--effort"
  ensure
    FileUtils.rm_f(provider_file)
  end
end
