# frozen_string_literal: true

require_relative "test_helper"

# Model resolution across CLI providers: a model tag must resolve through the map of the
# provider that will actually run, and switching providers drops a stored model that was
# resolved for the old one.
class TestProviderSwitch < Minitest::Test
  def setup
    provider_dir = File.join(TEST_BRAINIAC_DIR, "cli-providers")
    FileUtils.mkdir_p(provider_dir)
    File.write(File.join(provider_dir, "kirotest.json"), JSON.generate(
                                                           "binary" => "kiro-cli", "default_args" => "chat", "model_flag" => "--model",
                                                           "models" => { "opus" => "claude-opus-4.5", "sonnet" => "claude-sonnet-4.6",
                                                                         "auto" => "auto" },
                                                           "efforts" => %w[low medium high]
                                                         ))
    File.write(File.join(provider_dir, "claudetest.json"), JSON.generate(
                                                             "binary" => "claude", "default_args" => "-p", "model_flag" => "--model",
                                                             "agent_flag" => nil,
                                                             "models" => { "opus" => "opus", "sonnet" => "sonnet", "auto" => "sonnet" },
                                                             "efforts" => %w[low medium high xhigh max]
                                                           ))
    @project = { "repo_path" => "/tmp/switch-project", "cli_provider" => "kirotest" }
    FileUtils.rm_f(WORK_ITEM_MAP_FILE)
  end

  def test_detect_model_uses_inline_cli_tag_map
    assert_equal ["sonnet", true], detect_model_explicit(@project, text: "[cli:claudetest] [sonnet] go")
    assert_equal ["claude-sonnet-4.6", true], detect_model_explicit(@project, text: "[sonnet] go")
  end

  def test_detect_effort_uses_inline_cli_tag_levels
    refute detect_effort_explicit(@project, text: "[effort:max]").last
    assert_equal ["max", true], detect_effort_explicit(@project, text: "[cli:claudetest] [effort:max]")
  end

  def test_update_work_item_overrides_clear_removes_keys
    wid = register_work_item(branch: "clear-test", project: "brainiac", agent: "Galen")
    update_work_item_overrides(work_item_id: wid, cli_provider: "kirotest", model: "claude-opus-4.5")

    update_work_item_overrides(work_item_id: wid, clear: [:model])

    assert_equal({ "cli_provider" => "kirotest" }, work_item_overrides_for(work_item_id: wid))
  end

  def test_resolve_work_item_overrides_switch_drops_stored_model
    wid = register_work_item(branch: "switch-test", project: "brainiac", agent: "Galen")
    update_work_item_overrides(work_item_id: wid, cli_provider: "kirotest", model: "claude-opus-4.5", effort: "high")

    resolved = resolve_work_item_overrides(work_item_id: wid, inline_cli_provider: "claudetest")

    assert_equal "claudetest", resolved[:cli_provider]
    assert_nil resolved[:model]
    assert_equal "high", resolved[:effort]
    assert_equal({ "cli_provider" => "claudetest", "effort" => "high" }, work_item_overrides_for(work_item_id: wid))
  end

  def test_resolve_work_item_overrides_same_provider_keeps_model
    wid = register_work_item(branch: "same-provider", project: "brainiac", agent: "Galen")
    update_work_item_overrides(work_item_id: wid, model: "claude-opus-4.5")

    resolved = resolve_work_item_overrides(work_item_id: wid, inline_cli_provider: "kirotest", default_cli_provider: "kirotest")

    assert_equal "claude-opus-4.5", resolved[:model]
  end

  def test_resolve_dispatch_overrides_switch_with_model_tag
    wid = register_work_item(branch: "dispatch-tag", project: "brainiac", agent: "Galen")
    resolve_dispatch_overrides(@project, text: "[opus] start", work_item_id: wid)
    assert_equal "claude-opus-4.5", work_item_overrides_for(work_item_id: wid)["model"]

    resolved = resolve_dispatch_overrides(@project, text: "[cli:claudetest] [sonnet] now", work_item_id: wid)

    assert_equal "claudetest", resolved[:cli_provider]
    assert_equal "sonnet", resolved[:model]
    assert resolved[:explicit_model]
  end

  def test_resolve_dispatch_overrides_switch_without_model_tag_uses_new_default
    wid = register_work_item(branch: "dispatch-notag", project: "brainiac", agent: "Galen")
    resolve_dispatch_overrides(@project, text: "[opus] start", work_item_id: wid)

    resolved = resolve_dispatch_overrides(@project, text: "[cli:claudetest] now", work_item_id: wid)

    assert_equal "claudetest", resolved[:cli_provider]
    assert_nil resolved[:model]
    refute resolved[:explicit_model]
    assert_nil work_item_overrides_for(work_item_id: wid)["model"]
  end

  def test_resolve_dispatch_overrides_model_tag_uses_stored_provider
    wid = register_work_item(branch: "dispatch-stored", project: "brainiac", agent: "Galen")
    resolve_dispatch_overrides(@project, text: "[cli:claudetest] start", work_item_id: wid)

    resolved = resolve_dispatch_overrides(@project, text: "[sonnet] follow-up", work_item_id: wid)

    assert_equal "claudetest", resolved[:cli_provider]
    assert_equal "sonnet", resolved[:model]
  end

  def test_resolve_dispatch_overrides_untagged_keeps_sticky_model
    wid = register_work_item(branch: "dispatch-sticky", project: "brainiac", agent: "Galen")
    resolve_dispatch_overrides(@project, text: "[opus] start", work_item_id: wid)

    resolved = resolve_dispatch_overrides(@project, text: "plain follow-up", work_item_id: wid)

    assert_equal "claude-opus-4.5", resolved[:model]
    refute resolved[:explicit_model]
    assert_equal "claude-opus-4.5", work_item_overrides_for(work_item_id: wid)["model"]
  end

  def test_append_model_to_cmd_warns_on_unknown_model
    resolved = resolve_project_cli_config(@project, cli_provider_override: "claudetest")
    cmd = []
    warnings = []
    LOG.stub(:warn, ->(msg) { warnings << msg }) { append_model_to_cmd(cmd, "claude-opus-4.5", resolved) }

    assert_empty cmd
    assert_match(/Dropping model 'claude-opus-4.5'/, warnings.join)
  end
end
