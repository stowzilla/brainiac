# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/session_history"

# Tests for the going-forward observability instrumentation added to the durable
# session-history record. Exercises the pure record builder + helpers (no process
# spawn), so they're fast and deterministic.
class TestSessionHistoryInstrumentation < Minitest::Test
  def setup
    @finished = Time.utc(2026, 10, 17, 16, 0, 0)
    @started = @finished - 125
  end

  def ctx(**over)
    {
      agent_name: "Kaylee", agent_config_name: "kaylee", agent_cli: "kiro-cli",
      model: "sonnet", effort: "high", profile: "q", source: :fizzy,
      card_key: "fizzy-1474", card_number: 1474, log_name: "assigned-1474",
      log_file: "/w/tmp/agent-assigned-1474-20261017-160000.log",
      chdir: "/home/me/Code/brainiac--fizzy-1474-build-forensics",
      started_at: @started, resumed: false, work_item_id: "wi-abc123"
    }.merge(over)
  end

  def build(ctx_over: {}, exit_status: 0, signaled: false, heaviness: nil, git_impact: nil)
    build_session_record(ctx: ctx(**ctx_over), exit_status: exit_status, signaled: signaled,
                         finished_at: @finished, heaviness: heaviness, git_impact: git_impact)
  end

  # --- core record ---------------------------------------------------------

  def test_record_carries_schema_version
    assert_equal SESSION_HISTORY_SCHEMA, build["schema"]
    assert_equal 2, SESSION_HISTORY_SCHEMA
  end

  def test_core_identity_and_timing
    r = build
    assert_equal "Kaylee", r["agent"]
    assert_equal "kiro-cli", r["cli"]
    assert_equal "sonnet", r["model"]
    assert_equal "high", r["effort"]
    assert_equal "q", r["profile"]
    assert_equal "fizzy", r["source"]
    assert_equal 125, r["duration_seconds"]
    assert_equal 0, r["exit_status"]
  end

  def test_work_item_and_branch
    r = build
    assert_equal "wi-abc123", r["work_item_id"]
    assert_equal "fizzy-1474-build-forensics", r["branch"]
  end

  # --- trigger_type --------------------------------------------------------

  def test_trigger_type_strips_trailing_id
    assert_equal "assigned", trigger_type_from_log_name("assigned-1474")
    assert_equal "followup", trigger_type_from_log_name("followup-1096")
    assert_equal "pr-comment", trigger_type_from_log_name("pr-comment-48")
    assert_equal "changes-requested", trigger_type_from_log_name("changes-requested-1229")
    assert_equal "cron-run", trigger_type_from_log_name("cron-run-123")
  end

  def test_trigger_type_strips_discord_ids
    assert_equal "discord", trigger_type_from_log_name("discord-1476587174089457747-1561018949204705341")
  end

  def test_trigger_type_nil_safe
    assert_nil trigger_type_from_log_name(nil)
    assert_nil trigger_type_from_log_name("")
  end

  def test_record_trigger_type
    assert_equal "assigned", build["trigger_type"]
    assert_equal "pr-comment", build(ctx_over: { log_name: "pr-comment-48" })["trigger_type"]
  end

  # --- branch_from_chdir ---------------------------------------------------

  def test_branch_from_chdir
    assert_equal "fizzy-42-fix", branch_from_chdir("/x/marketplace--fizzy-42-fix")
    assert_nil branch_from_chdir("/x/marketplace") # not a worktree
    assert_nil branch_from_chdir(nil)
  end

  # --- resumed -------------------------------------------------------------

  def test_resumed_true_recorded_false_omitted
    assert build(ctx_over: { resumed: true })["resumed"]
    # compact! drops false→nil so a non-resumed session doesn't carry the key
    refute build(ctx_over: { resumed: false }).key?("resumed")
  end

  # --- prompt/output bytes -------------------------------------------------

  def test_prompt_and_output_bytes
    Dir.mktmpdir do |d|
      prompt = File.join(d, "p.md")
      output = File.join(d, "o.md")
      File.write(prompt, "x" * 500)
      File.write(output, "y" * 20)
      r = build(ctx_over: { prompt_file: prompt, output_file: output })
      assert_equal 500, r["prompt_bytes"]
      assert_equal 20, r["output_bytes"]
      assert_equal true, r["produced_output"]
    end
  end

  def test_empty_output_means_no_output
    Dir.mktmpdir do |d|
      output = File.join(d, "o.md")
      File.write(output, "")
      r = build(ctx_over: { output_file: output })
      assert_equal 0, r["output_bytes"]
      assert_equal false, r["produced_output"]
    end
  end

  def test_missing_files_omitted
    r = build(ctx_over: { prompt_file: "/nope/p.md", output_file: nil })
    refute r.key?("prompt_bytes")
    refute r.key?("produced_output")
  end

  # --- git impact merge + heaviness merge ----------------------------------

  def test_git_impact_merged
    r = build(git_impact: { "git_commits" => 3, "git_files_changed" => 12, "git_head_moved" => true })
    assert_equal 3, r["git_commits"]
    assert_equal 12, r["git_files_changed"]
    assert r["git_head_moved"]
  end

  def test_heaviness_merged
    r = build(heaviness: { "context_usage_pct" => 72.5, "credits_used" => 1.23 })
    assert_in_delta 72.5, r["context_usage_pct"], 0.01
    assert_in_delta 1.23, r["credits_used"], 0.01
  end

  def test_compact_drops_nils
    r = build(ctx_over: { effort: nil, profile: nil, work_item_id: nil })
    refute r.key?("effort")
    refute r.key?("profile")
    refute r.key?("work_item_id")
  end

  # --- git impact capture (real local git) ---------------------------------

  def test_session_git_impact_counts_commits_and_files
    Dir.mktmpdir do |d|
      system("git", "init", "-q", chdir: d)
      system("git", "-C", d, "config", "user.email", "t@t.co")
      system("git", "-C", d, "config", "user.name", "T")
      File.write(File.join(d, "a.txt"), "1")
      system("git", "-C", d, "add", "-A")
      system("git", "-C", d, "commit", "-qm", "first")
      head_before, = Open3.capture2("git", "rev-parse", "HEAD", chdir: d)
      File.write(File.join(d, "b.txt"), "2")
      system("git", "-C", d, "add", "-A")
      system("git", "-C", d, "commit", "-qm", "second")
      impact = session_git_impact(chdir: d, head_before: head_before.strip)
      assert_equal 1, impact["git_commits"]
      assert_equal 1, impact["git_files_changed"]
      assert impact["git_head_moved"]
    end
  end

  def test_session_git_impact_nil_without_head
    assert_nil session_git_impact(chdir: "/tmp", head_before: nil)
    assert_nil session_git_impact(chdir: nil, head_before: "abc")
  end
end
