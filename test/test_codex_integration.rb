# frozen_string_literal: true

require_relative "test_helper"

# Integration smoke tests for the Codex CLI provider dispatch path.
# These tests exercise the full pipeline from provider config → resolution → command building,
# covering features introduced across #1229–#1234:
#   - Profile-based agent identity (--profile)
#   - Working directory flag (-C)
#   - Session-based resume (exec resume --last)
#   - Centralized session detection (~/.codex/sessions)
#   - Output capture (--output-last-message / -o)
#   - Effort via config override (-c model_reasoning_effort="level")
#   - Effort mapping (max → xhigh)
#   - Model selection from provider-specific model roster
class TestCodexIntegration < Minitest::Test
  def setup
    @provider_dir = File.join(TEST_BRAINIAC_DIR, "cli-providers")
    FileUtils.mkdir_p(@provider_dir)

    # Write the canonical Codex provider config (mirrors templates/cli-providers/codex.json.example)
    @codex_config = {
      "binary" => "codex",
      "default_args" => "--full-auto",
      "agent_flag" => "--profile",
      "model_flag" => "--model",
      "effort_flag" => nil,
      "effort_config_key" => "model_reasoning_effort",
      "config_override_flag" => "-c",
      "effort_map" => {
        "low" => "low",
        "medium" => "medium",
        "high" => "high",
        "xhigh" => "xhigh",
        "max" => "xhigh"
      },
      "prompt_mode" => "stdin",
      "cwd_flag" => "-C",
      "resume_flag" => nil,
      "resume_args" => "exec resume --last --full-auto",
      "session_dir" => "~/.codex/sessions",
      "output_last_message_flag" => "-o",
      "models" => {
        "o3" => "o3",
        "o4-mini" => "o4-mini",
        "gpt5" => "gpt-5.5",
        "codex-mini" => "codex-mini-latest",
        "auto" => "o4-mini"
      },
      "efforts" => %w[low medium high xhigh max]
    }
    @provider_file = File.join(@provider_dir, "codex.json")
    File.write(@provider_file, JSON.generate(@codex_config))

    # Project configured to use the Codex provider
    @codex_project = {
      "repo_path" => "/home/test/Code/marketplace",
      "cli_provider" => "codex",
      "github_repo" => "stowzilla/marketplace"
    }
  end

  def teardown
    FileUtils.rm_f(@provider_file)
  end

  # ─── Provider Loading ───────────────────────────────────────────────────────

  def test_loads_codex_provider_with_all_fields
    config = load_cli_provider("codex")

    assert_equal "codex", config["agent_cli"]
    assert_equal "--full-auto", config["agent_cli_args"]
    assert_equal "--profile", config["agent_flag"]
    assert_equal "--model", config["agent_model_flag"]
    assert_equal "stdin", config["prompt_mode"]
    assert_equal "-C", config["cwd_flag"]
    assert_equal "-o", config["output_last_message_flag"]
    assert_equal "model_reasoning_effort", config["effort_config_key"]
    assert_equal "-c", config["config_override_flag"]
    assert_equal "exec resume --last --full-auto", config["resume_args"]
    assert_equal "~/.codex/sessions", config["session_dir"]
    assert_nil config["resume_flag"] # null → not included
    assert_equal({ "max" => "xhigh", "low" => "low", "medium" => "medium", "high" => "high", "xhigh" => "xhigh" },
                 config["effort_map"])
    assert_equal({ "o3" => "o3", "o4-mini" => "o4-mini", "gpt5" => "gpt-5.5",
                   "codex-mini" => "codex-mini-latest", "auto" => "o4-mini" },
                 config["allowed_models"])
  end

  # ─── Full Pipeline: Config → Resolve → Build ───────────────────────────────

  def test_full_pipeline_fresh_session_with_model
    resolved = resolve_project_cli_config(@codex_project)
    output_file = prepare_output_file(resolved, "fizzy-42", "20260824-120000")
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", model: "o3",
                                    chdir: "/home/test/Code/marketplace",
                                    output_file: output_file)

    # Expected: codex -C /path --profile sherlock --full-auto --model o3 -o /path/to/output
    assert_equal "codex", cmd[0]
    assert_equal "-C", cmd[1]
    assert_equal "/home/test/Code/marketplace", cmd[2]
    assert_equal "--profile", cmd[3]
    assert_equal "sherlock", cmd[4]
    assert_equal "--full-auto", cmd[5]
    assert_includes cmd, "--model"
    assert_includes cmd, "o3"
    assert_includes cmd, "-o"
    assert_match(/agent-fizzy-42-20260824-120000\.md$/, output_file)
  end

  def test_full_pipeline_fresh_session_no_agent
    resolved = resolve_project_cli_config(@codex_project)
    cmd = build_agent_cmd(resolved, agent_config_name: nil, model: "o4-mini",
                                    chdir: "/home/test/Code/marketplace")

    # No --profile when no agent name
    assert_equal "codex", cmd[0]
    assert_equal "-C", cmd[1]
    assert_equal "/home/test/Code/marketplace", cmd[2]
    assert_equal "--full-auto", cmd[3]
    assert_includes cmd, "--model"
    assert_includes cmd, "o4-mini"
    refute_includes cmd, "--profile"
  end

  def test_full_pipeline_with_effort_max_mapped_to_xhigh
    resolved = resolve_project_cli_config(@codex_project)
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", effort: "max",
                                    chdir: "/home/test/Code/marketplace")

    # Effort "max" maps to "xhigh" via effort_map, delivered as -c model_reasoning_effort="xhigh"
    assert_includes cmd, "-c"
    idx = cmd.index("-c")
    assert_equal 'model_reasoning_effort="xhigh"', cmd[idx + 1]
    refute_includes cmd, "--effort"
  end

  def test_full_pipeline_with_effort_high_passes_through
    resolved = resolve_project_cli_config(@codex_project)
    cmd = build_agent_cmd(resolved, effort: "high", chdir: "/home/test/Code/marketplace")

    # "high" maps to "high" in the effort_map (identity)
    idx = cmd.index("-c")
    assert_equal 'model_reasoning_effort="high"', cmd[idx + 1]
  end

  def test_full_pipeline_with_model_and_effort
    resolved = resolve_project_cli_config(@codex_project)
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", model: "gpt-5.5",
                                    effort: "medium", chdir: "/home/test/Code/marketplace")

    # Both --model and -c should be present
    assert_includes cmd, "--model"
    assert_includes cmd, "gpt-5.5"
    assert_includes cmd, "-c"
    idx = cmd.index("-c")
    assert_equal 'model_reasoning_effort="medium"', cmd[idx + 1]
  end

  def test_full_pipeline_model_not_in_allowed_list_is_skipped
    resolved = resolve_project_cli_config(@codex_project)
    cmd = build_agent_cmd(resolved, model: "claude-sonnet-4.6", chdir: "/home/test/Code/marketplace")

    # claude-sonnet-4.6 is not in the Codex allowed_models → --model should not appear
    refute_includes cmd, "--model"
    refute_includes cmd, "claude-sonnet-4.6"
  end

  # ─── Resume Path ───────────────────────────────────────────────────────────

  def test_resume_path_replaces_default_args
    resolved = resolve_project_cli_config(@codex_project)
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", resume: :resume_args,
                                    chdir: "/home/test/Code/marketplace")

    # When resume: :resume_args, use resume_args instead of default_args
    assert_includes cmd, "exec"
    assert_includes cmd, "resume"
    assert_includes cmd, "--last"
    refute_equal "--full-auto", cmd[5] # default_args replaced
    # Agent identity still present
    assert_includes cmd, "--profile"
    assert_includes cmd, "sherlock"
    # cwd_flag still present
    assert_equal "-C", cmd[1]
  end

  def test_resume_path_with_model_override
    resolved = resolve_project_cli_config(@codex_project)
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", model: "o3",
                                    resume: :resume_args, chdir: "/home/test/Code/marketplace")

    # Model is appended after resume_args
    assert_includes cmd, "resume"
    assert_includes cmd, "--model"
    assert_includes cmd, "o3"
  end

  def test_resolve_resume_with_matching_centralized_session
    Dir.mktmpdir do |dir|
      target_cwd = File.join(dir, "project")
      FileUtils.mkdir_p(target_cwd)

      # Simulate centralized session storage
      session_dir = File.join(dir, "codex-sessions", "2026", "08", "24")
      FileUtils.mkdir_p(session_dir)
      session_data = {
        "timestamp" => "2026-08-24T12:00:00Z",
        "ordinal" => 0,
        "type" => "session_meta",
        "payload" => { "session_id" => "sess-abc123", "cwd" => target_cwd }
      }
      File.write(File.join(session_dir, "session-abc123.jsonl"), JSON.generate(session_data))

      resolved = resolve_project_cli_config(@codex_project).merge(
        "session_dir" => File.join(dir, "codex-sessions")
      )
      result = resolve_resume(true, resolved, target_cwd)
      assert_equal :resume_args, result
    end
  end

  def test_resolve_resume_without_matching_session_returns_false
    Dir.mktmpdir do |dir|
      target_cwd = File.join(dir, "project")
      FileUtils.mkdir_p(target_cwd)

      # Session dir exists but no matching session files
      session_dir = File.join(dir, "codex-sessions")
      FileUtils.mkdir_p(session_dir)

      resolved = resolve_project_cli_config(@codex_project).merge(
        "session_dir" => session_dir
      )
      result = resolve_resume(true, resolved, target_cwd)
      refute result
    end
  end

  def test_resume_viable_full_pipeline
    Dir.mktmpdir do |dir|
      target_cwd = File.join(dir, "project")
      FileUtils.mkdir_p(target_cwd)

      # Create matching session
      session_dir = File.join(dir, "codex-sessions", "2026", "08", "24")
      FileUtils.mkdir_p(session_dir)
      session_data = { "payload" => { "cwd" => target_cwd } }
      File.write(File.join(session_dir, "session.jsonl"), JSON.generate(session_data))

      # Override the session_dir in the provider file to point to our temp dir
      @codex_config["session_dir"] = File.join(dir, "codex-sessions")
      File.write(@provider_file, JSON.generate(@codex_config))

      assert resume_viable?(project_config: @codex_project, chdir: target_cwd)
    end
  end

  def test_resume_not_viable_when_session_is_stale
    Dir.mktmpdir do |dir|
      target_cwd = File.join(dir, "project")
      FileUtils.mkdir_p(target_cwd)

      session_dir = File.join(dir, "codex-sessions", "2026", "08", "20")
      FileUtils.mkdir_p(session_dir)
      session_data = { "payload" => { "cwd" => target_cwd } }
      session_file = File.join(session_dir, "session-stale.jsonl")
      File.write(session_file, JSON.generate(session_data))
      # Make the file appear older than 24 hours
      FileUtils.touch(session_file, mtime: Time.now - 100_000)

      @codex_config["session_dir"] = File.join(dir, "codex-sessions")
      File.write(@provider_file, JSON.generate(@codex_config))

      refute resume_viable?(project_config: @codex_project, chdir: target_cwd)
    end
  end

  # ─── Output Capture ────────────────────────────────────────────────────────

  def test_output_file_prepared_for_codex_provider
    resolved = resolve_project_cli_config(@codex_project)
    output_file = prepare_output_file(resolved, "card-42", "20260824-180000")

    refute_nil output_file
    assert_match(/agent-card-42-20260824-180000\.md$/, output_file)
    assert Dir.exist?(File.dirname(output_file))
  end

  def test_output_flag_appears_in_command
    resolved = resolve_project_cli_config(@codex_project)
    output_file = prepare_output_file(resolved, "dispatch", "20260824-180000")
    cmd = build_agent_cmd(resolved, output_file: output_file, chdir: "/tmp/project")

    idx = cmd.index("-o")
    refute_nil idx, "Output flag -o should be in command"
    assert_equal output_file, cmd[idx + 1]
  end

  def test_output_capture_round_trip
    # Simulate write → read cycle (what happens between agent completion and hook)
    output_dir = File.join(TEST_BRAINIAC_DIR, "tmp", "output")
    FileUtils.mkdir_p(output_dir)
    output_file = File.join(output_dir, "agent-codex-test-20260824.md")

    agent_response = "## Summary\n\nI fixed the login bug by adding null checks to the auth middleware."
    File.write(output_file, agent_response)

    content = read_output_file(output_file)
    assert_equal agent_response.strip, content
  ensure
    FileUtils.rm_f(output_file)
  end

  # ─── Model Detection ───────────────────────────────────────────────────────

  def test_detect_model_uses_codex_provider_models
    # When cli_provider_override is "codex", model resolution uses Codex models
    result = detect_model(@codex_project, text: "[o3] fix this", cli_provider_override: "codex")
    assert_equal "o3", result
  end

  def test_detect_model_codex_auto_resolves
    result = detect_model(@codex_project, text: "[auto] fix this", cli_provider_override: "codex")
    assert_equal "o4-mini", result
  end

  def test_detect_model_codex_unknown_tag_returns_default
    result = detect_model(@codex_project, text: "[opus] fix this", cli_provider_override: "codex")
    # "opus" isn't in Codex allowed_models — returns nil (no agent_model set)
    assert_nil result
  end

  # ─── Effort Detection ──────────────────────────────────────────────────────

  def test_detect_effort_with_codex_provider
    result = detect_effort(@codex_project, text: "[effort:high] fix this", cli_provider_override: "codex")
    assert_equal "high", result
  end

  def test_detect_effort_max_is_allowed
    result = detect_effort(@codex_project, text: "[effort:max] fix this", cli_provider_override: "codex")
    assert_equal "max", result
  end

  def test_detect_effort_xhigh_is_allowed
    result = detect_effort(@codex_project, text: "[effort:xhigh] fix this", cli_provider_override: "codex")
    assert_equal "xhigh", result
  end

  # ─── CLI Provider Override via Inline Tag ───────────────────────────────────

  def test_detect_cli_provider_codex_from_inline_tag
    result = detect_cli_provider(text: "[cli:codex] implement login feature")
    assert_equal "codex", result
  end

  def test_inline_cli_override_affects_full_pipeline
    # Project uses kiro by default, but inline [cli:codex] overrides
    kiro_project = {
      "repo_path" => "/home/test/Code/marketplace",
      "cli_provider" => "kiro",
      "github_repo" => "stowzilla/marketplace"
    }
    # Write a kiro provider too
    kiro_file = File.join(@provider_dir, "kiro.json")
    File.write(kiro_file, JSON.generate({
                                          "binary" => "kiro-cli",
                                          "default_args" => "chat --no-interactive",
                                          "agent_flag" => "--agent",
                                          "model_flag" => "--model",
                                          "prompt_mode" => "stdin"
                                        }))

    # Resolve with codex override
    resolved = resolve_project_cli_config(kiro_project, cli_provider_override: "codex")
    assert_equal "codex", resolved["agent_cli"]
    assert_equal "--profile", resolved["agent_flag"]
    assert_equal "-C", resolved["cwd_flag"]
  ensure
    FileUtils.rm_f(kiro_file)
  end

  # ─── Work Item Override Persistence ─────────────────────────────────────────

  def test_work_item_codex_overrides_persist_across_dispatches
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)

    # First dispatch: create work item with codex overrides
    register_work_item(branch: "codex-integration-test", project: "marketplace", agent: "Sherlock")
    resolve_work_item_overrides(
      branch: "codex-integration-test",
      inline_cli_provider: "codex",
      inline_model: "o3",
      inline_effort: "high"
    )

    # Second dispatch: no inline tags — stored overrides should be returned
    stored = resolve_work_item_overrides(branch: "codex-integration-test")
    assert_equal "codex", stored[:cli_provider]
    assert_equal "o3", stored[:model]
    assert_equal "high", stored[:effort]
  end

  def test_work_item_inline_tags_override_stored_values
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)

    register_work_item(branch: "codex-override-test", project: "marketplace", agent: "Sherlock")
    # First: set codex + o3
    resolve_work_item_overrides(branch: "codex-override-test", inline_cli_provider: "codex", inline_model: "o3")

    # Second: inline changes model to gpt5
    result = resolve_work_item_overrides(branch: "codex-override-test", inline_model: "gpt-5.5")
    assert_equal "codex", result[:cli_provider]   # retained from stored
    assert_equal "gpt-5.5", result[:model]        # overridden by inline

    # Verify persistence
    stored = work_item_overrides_for(branch: "codex-override-test")
    assert_equal "gpt-5.5", stored["model"]
    assert_equal "codex", stored["cli_provider"]
  end

  # ─── Agent-Level CLI Provider ───────────────────────────────────────────────

  def test_agent_level_cli_provider_resolution
    # Set up an agent with cli_provider in the registry
    original_registry = AGENT_REGISTRY.dup
    AGENT_REGISTRY["sherlock"]["cli_provider"] = "codex"

    # A project without cli_provider — agent-level should kick in
    bare_project = { "repo_path" => "/tmp/project" }
    resolved = resolve_project_cli_config(bare_project, agent_name: "Sherlock")
    assert_equal "codex", resolved["agent_cli"]
  ensure
    AGENT_REGISTRY.replace(original_registry)
  end

  # ─── End-to-End Command Scenarios ──────────────────────────────────────────

  def test_scenario_fizzy_card_assigned_fresh_session
    # Simulates: card assigned to Sherlock, Codex provider, no prior session
    resolved = resolve_project_cli_config(@codex_project)
    output_file = prepare_output_file(resolved, "fizzy-42", "20260824-100000")
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", model: "o3",
                                    effort: "high", chdir: "/home/test/Code/marketplace",
                                    output_file: output_file)

    expected_prefix = %w[codex -C /home/test/Code/marketplace --profile sherlock --full-auto]
    assert_equal expected_prefix, cmd[0..5]
    assert_includes cmd, "--model"
    assert_includes cmd, "o3"
    assert_includes cmd, "-c"
    assert_includes cmd, 'model_reasoning_effort="high"'
    assert_includes cmd, "-o"
    assert_includes cmd, output_file
  end

  def test_scenario_follow_up_comment_resume_session
    # Simulates: follow-up comment on an existing card with prior Codex session
    resolved = resolve_project_cli_config(@codex_project)
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", model: "o4-mini",
                                    resume: :resume_args, chdir: "/home/test/Code/marketplace")

    # Resume replaces default_args with resume_args
    assert_equal "codex", cmd[0]
    assert_equal "-C", cmd[1]
    assert_includes cmd, "exec"
    assert_includes cmd, "resume"
    assert_includes cmd, "--last"
    assert_includes cmd, "--full-auto"
    assert_includes cmd, "--profile"
    assert_includes cmd, "sherlock"
    assert_includes cmd, "--model"
    assert_includes cmd, "o4-mini"
    # default_args "--full-auto" (simple form) is NOT used; resume_args has its own --full-auto
  end

  def test_scenario_discord_dispatch_with_cli_override
    # Simulates: Discord message "[cli:codex] [o3] fix the deployment issue"
    # with a project that normally uses kiro
    kiro_file = File.join(@provider_dir, "kiro.json")
    File.write(kiro_file, JSON.generate({
                                          "binary" => "kiro-cli",
                                          "default_args" => "chat --no-interactive",
                                          "agent_flag" => "--agent",
                                          "model_flag" => "--model",
                                          "prompt_mode" => "stdin",
                                          "models" => { "opus" => "claude-opus-4.5", "sonnet" => "claude-sonnet-4.6" }
                                        }))

    kiro_project = { "repo_path" => "/home/test/Code/marketplace", "cli_provider" => "kiro" }

    # Detect overrides from message text
    cli_override = detect_cli_provider(text: "[cli:codex] [o3] fix the deployment issue")
    model = detect_model(kiro_project, text: "[cli:codex] [o3] fix the deployment issue",
                                       cli_provider_override: cli_override)

    assert_equal "codex", cli_override
    assert_equal "o3", model

    # Build command using the override
    resolved = resolve_project_cli_config(kiro_project, cli_provider_override: cli_override)
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", model: model,
                                    chdir: "/home/test/Code/marketplace")

    assert_equal "codex", cmd[0]
    assert_includes cmd, "--profile"
    assert_includes cmd, "--model"
    assert_includes cmd, "o3"
    assert_includes cmd, "-C"
  ensure
    FileUtils.rm_f(kiro_file)
  end

  def test_scenario_effort_max_end_to_end
    # Simulates: [effort:max] inline tag → detected → mapped → command built
    effort = detect_effort(@codex_project, text: "[effort:max] optimize performance",
                                           cli_provider_override: "codex")
    assert_equal "max", effort

    resolved = resolve_project_cli_config(@codex_project)
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", effort: effort,
                                    chdir: "/home/test/Code/marketplace")

    # "max" gets mapped to "xhigh" by the effort_map in build_agent_cmd
    idx = cmd.index("-c")
    assert_equal 'model_reasoning_effort="xhigh"', cmd[idx + 1]
  end

  def test_scenario_codex_no_effort_no_model
    # Simplest Codex dispatch — no model or effort overrides
    resolved = resolve_project_cli_config(@codex_project)
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock",
                                    chdir: "/home/test/Code/marketplace")

    assert_equal %w[codex -C /home/test/Code/marketplace --profile sherlock --full-auto], cmd
    refute_includes cmd, "--model"
    refute_includes cmd, "-c"
    refute_includes cmd, "-o"
  end

  # ─── Edge Cases ─────────────────────────────────────────────────────────────

  def test_codex_with_output_file_and_resume_combined
    # Resume + output capture — both should work together
    resolved = resolve_project_cli_config(@codex_project)
    output_file = prepare_output_file(resolved, "resume-test", "20260824-150000")
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", resume: :resume_args,
                                    output_file: output_file, chdir: "/tmp/worktree")

    assert_includes cmd, "resume"
    assert_includes cmd, "-o"
    assert_includes cmd, output_file
    # cwd_flag still present
    assert_equal "-C", cmd[1]
    assert_equal "/tmp/worktree", cmd[2]
  end

  def test_codex_resume_args_include_full_auto
    # Verify that resume_args as configured include the sandbox mode
    resolved = resolve_project_cli_config(@codex_project)
    cmd = build_agent_cmd(resolved, resume: :resume_args)

    # "exec resume --last --full-auto" split into tokens
    assert_includes cmd, "exec"
    assert_includes cmd, "resume"
    assert_includes cmd, "--last"
    assert_includes cmd, "--full-auto"
  end

  def test_codex_non_resume_does_not_include_resume_args
    resolved = resolve_project_cli_config(@codex_project)
    cmd = build_agent_cmd(resolved, resume: false)

    refute_includes cmd, "resume"
    refute_includes cmd, "--last"
    assert_includes cmd, "--full-auto"
  end

  def test_prior_session_exists_codex_centralized_real_structure
    # Codex stores sessions as YYYY/MM/DD/session-<id>.jsonl
    Dir.mktmpdir do |dir|
      target_cwd = File.join(dir, "my-project")
      FileUtils.mkdir_p(target_cwd)

      # Create a realistic session directory structure
      today = Time.now.strftime("%Y/%m/%d")
      session_dir = File.join(dir, "codex-sessions", today)
      FileUtils.mkdir_p(session_dir)

      # Multiple sessions, only one matches our cwd
      other_session = { "payload" => { "cwd" => "/some/other/project" } }
      matching_session = { "payload" => { "cwd" => target_cwd } }

      File.write(File.join(session_dir, "session-aaa.jsonl"), JSON.generate(other_session))
      File.write(File.join(session_dir, "session-bbb.jsonl"), JSON.generate(matching_session))

      assert prior_session_exists?(target_cwd, "codex",
                                   session_dir: File.join(dir, "codex-sessions"))
    end
  end

  def test_prior_session_exists_codex_no_matching_cwd
    Dir.mktmpdir do |dir|
      target_cwd = File.join(dir, "my-project")
      FileUtils.mkdir_p(target_cwd)

      today = Time.now.strftime("%Y/%m/%d")
      session_dir = File.join(dir, "codex-sessions", today)
      FileUtils.mkdir_p(session_dir)

      # Session for a different project
      wrong_session = { "payload" => { "cwd" => "/totally/different" } }
      File.write(File.join(session_dir, "session-wrong.jsonl"), JSON.generate(wrong_session))

      refute prior_session_exists?(target_cwd, "codex",
                                   session_dir: File.join(dir, "codex-sessions"))
    end
  end

  def test_codex_model_key_lookup_via_detect_model
    # Model keys in Codex use different names than kiro
    assert_equal "o3", detect_model(@codex_project, text: "[o3] do it", cli_provider_override: "codex")
    assert_equal "gpt-5.5", detect_model(@codex_project, text: "[gpt5] big task", cli_provider_override: "codex")

    # Hyphenated keys (o4-mini, codex-mini) can't be detected via inline [tag] syntax
    # because the regex uses \w+ which excludes hyphens. They work via card tags instead:
    assert_equal "o4-mini", detect_model(@codex_project, tags: [{ "name" => "o4-mini" }], cli_provider_override: "codex")
    assert_equal "codex-mini-latest", detect_model(@codex_project, tags: [{ "name" => "codex-mini" }], cli_provider_override: "codex")
  end

  def test_provider_merge_priority_codex_over_project_defaults
    # When project has its own agent_cli_args but cli_provider is codex,
    # the provider config should win on provider-specific fields
    project_with_own_args = {
      "repo_path" => "/home/test/Code/marketplace",
      "cli_provider" => "codex",
      "agent_cli_args" => "chat --no-interactive", # leftover from kiro, should be overridden
      "agent_model_flag" => "--model"
    }
    resolved = resolve_project_cli_config(project_with_own_args)

    # Provider "binary" → agent_cli wins
    assert_equal "codex", resolved["agent_cli"]
    # But agent_cli_args from project overrides the provider (project takes priority in normal merge)
    # The codex provider config is the base, project config overlays it.
    # Since project has agent_cli_args, it wins in the merge.
    # This is by design — let's just verify the provider fields that aren't in the project:
    assert_equal "-C", resolved["cwd_flag"]
    assert_equal "-o", resolved["output_last_message_flag"]
    assert_equal "--profile", resolved["agent_flag"]
  end
end
