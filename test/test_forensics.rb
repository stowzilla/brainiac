# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/forensics"

class TestForensics < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("forensics-test")
    @log_dir = File.join(@dir, "tmp")
    FileUtils.mkdir_p(@log_dir)
    @history_file = File.join(@dir, "session-history.jsonl")
    @now = Time.utc(2026, 10, 17, 15, 0, 0)
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  # --- helpers -------------------------------------------------------------

  def write_log(name:, timestamp:, cli: "kiro-cli", chdir: "/work", body: "", env_keys: nil, resume: false)
    path = File.join(@log_dir, "agent-#{name}-#{timestamp}.log")
    header = +""
    header << "I, [#{timestamp}]  INFO -- : Running #{cli} in #{chdir}, logging to #{path}\n"
    cmd = "Prompt: /tmp/p.md | Output: none | Command: #{cli} --agent x chat#{" (resuming session)" if resume}\n"
    header << cmd
    header << "Injecting 2 env var(s) for agent X: FIZZY_TOKEN, DISCORD_BOT_TOKEN\n" if env_keys
    File.write(path, header + body)
    path
  end

  def write_history(records)
    File.write(@history_file, "#{records.map { |r| JSON.generate(r) }.join("\n")}\n")
  end

  def analyzer(thresholds: {})
    Brainiac::Forensics::Analyzer.new(
      log_dirs: [@log_dir], history_file: @history_file, thresholds: thresholds, now: @now
    )
  end

  # --- log parsing ---------------------------------------------------------

  def test_parses_launch_header
    write_log(name: "assigned-42", timestamp: "20261017-100000", cli: "kiro-cli",
              chdir: "/work/repo", env_keys: true, resume: true)
    rec = analyzer.logs.first
    assert_equal "assigned-42", rec.log_name
    assert_equal "kiro-cli", rec.agent_cli
    assert_equal "/work/repo", rec.chdir
    assert_equal %w[FIZZY_TOKEN DISCORD_BOT_TOKEN], rec.env_keys
    assert rec.resumed
    refute_nil rec.timestamp
  end

  def test_scans_error_signatures
    write_log(name: "boom", timestamp: "20261017-101000",
              body: "doing work\nRuntimeError: something exploded\nmore\n")
    rec = analyzer.logs.first
    assert_equal 1, rec.error_hits.size
    assert_includes rec.error_hits.first, "RuntimeError"
  end

  def test_ignores_non_agent_files
    File.write(File.join(@log_dir, "not-an-agent.log"), "junk")
    assert_empty analyzer.logs
  end

  def test_scans_error_signatures_strips_ansi
    write_log(name: "ansi", timestamp: "20261017-101500",
              body: "\e[31mRuntimeError: boom\e[0m\n")
    rec = analyzer.logs.first
    assert_equal 1, rec.error_hits.size
    assert_equal "RuntimeError: boom", rec.error_hits.first
  end

  def test_logs_sorted_newest_first
    write_log(name: "a", timestamp: "20261017-090000")
    write_log(name: "b", timestamp: "20261017-110000")
    assert_equal "b", analyzer.logs.first.log_name
  end

  # --- history + correlation ----------------------------------------------

  def test_correlates_log_with_history
    path = write_log(name: "assigned-7", timestamp: "20261017-120000")
    write_history([{ "agent" => "Kaylee", "cli" => "kiro-cli", "log_file" => path,
                     "duration_seconds" => 42, "exit_status" => 0,
                     "finished_at" => "2026-10-17T12:05:00Z", "card_key" => "fizzy-7" }])
    sessions = analyzer.report[:sessions]
    assert_equal 1, sessions.size
    s = sessions.first
    assert_equal "Kaylee", s[:agent]
    assert s[:has_history]
    assert s[:log_present]
    assert_equal "fizzy-7", s[:card_key]
  end

  def test_orphan_log_without_history
    old_ts = (@now - (3 * 3600)).strftime("%Y%m%d-%H%M%S")
    path = write_log(name: "orphan", timestamp: old_ts)
    File.utime(@now - (3 * 3600), @now - (3 * 3600), path)
    report = analyzer.report
    orphan = report[:sessions].find { |s| !s[:has_history] }
    refute_nil orphan
    assert_equal 1, report[:summary][:orphan_logs]
    kinds = report[:anomalies].map { |a| a[:kind] }
    assert_includes kinds, :orphan_log
  end

  def test_recent_orphan_not_flagged_stale
    ts = (@now - 60).strftime("%Y%m%d-%H%M%S")
    path = write_log(name: "fresh", timestamp: ts)
    File.utime(@now - 60, @now - 60, path)
    kinds = analyzer.report[:anomalies].map { |a| a[:kind] }
    refute_includes kinds, :orphan_log
  end

  # --- anomaly detection ---------------------------------------------------

  def test_crash_anomaly
    path = write_log(name: "crash", timestamp: "20261017-130000")
    write_history([{ "agent" => "Kaylee", "log_file" => path, "exit_status" => 1,
                     "signaled" => false, "finished_at" => "2026-10-17T13:01:00Z" }])
    crash = analyzer.report[:anomalies].find { |a| a[:kind] == :crash }
    refute_nil crash
    assert_equal :high, crash[:severity]
    assert_equal 1, analyzer.report[:summary][:crashes]
  end

  def test_signaled_crash_message
    path = write_log(name: "killed", timestamp: "20261017-131000")
    write_history([{ "agent" => "Kaylee", "log_file" => path, "exit_status" => 137,
                     "signaled" => true, "finished_at" => "2026-10-17T13:11:00Z" }])
    crash = analyzer.report[:anomalies].find { |a| a[:kind] == :crash }
    assert_includes crash[:message], "killed by signal"
  end

  def test_clean_exit_no_crash
    path = write_log(name: "ok", timestamp: "20261017-140000")
    write_history([{ "agent" => "Kaylee", "log_file" => path, "exit_status" => 0,
                     "finished_at" => "2026-10-17T14:01:00Z" }])
    kinds = analyzer.report[:anomalies].map { |a| a[:kind] }
    refute_includes kinds, :crash
  end

  def test_heavy_context_anomaly
    path = write_log(name: "heavy", timestamp: "20261017-141000")
    write_history([{ "agent" => "Kaylee", "log_file" => path, "exit_status" => 0,
                     "context_usage_pct" => 92.5, "finished_at" => "2026-10-17T14:11:00Z" }])
    heavy = analyzer.report[:anomalies].find { |a| a[:kind] == :heavy_context }
    refute_nil heavy
    assert_includes heavy[:message], "92.5%"
  end

  def test_slow_session_anomaly
    path = write_log(name: "slow", timestamp: "20261017-142000")
    write_history([{ "agent" => "Kaylee", "log_file" => path, "exit_status" => 0,
                     "duration_seconds" => 3600, "finished_at" => "2026-10-17T15:20:00Z" }])
    slow = analyzer.report[:anomalies].find { |a| a[:kind] == :slow_session }
    refute_nil slow
    assert_equal :low, slow[:severity]
  end

  def test_error_signature_anomaly_from_log
    path = write_log(name: "err", timestamp: "20261017-143000",
                     body: "panic: runtime error\n")
    write_history([{ "agent" => "Kaylee", "log_file" => path, "exit_status" => 0,
                     "finished_at" => "2026-10-17T14:31:00Z" }])
    err = analyzer.report[:anomalies].find { |a| a[:kind] == :log_errors }
    refute_nil err
    assert_includes err[:message], "panic"
  end

  def test_custom_thresholds
    path = write_log(name: "tune", timestamp: "20261017-144000")
    write_history([{ "agent" => "Kaylee", "log_file" => path, "exit_status" => 0,
                     "duration_seconds" => 120, "finished_at" => "2026-10-17T14:42:00Z" }])
    a = analyzer(thresholds: { slow_session_seconds: 60 })
    assert(a.report[:anomalies].any? { |x| x[:kind] == :slow_session })
  end

  # --- robustness ----------------------------------------------------------

  def test_corrupt_history_line_skipped
    path = write_log(name: "mix", timestamp: "20261017-145000")
    good = JSON.generate({ "agent" => "Kaylee", "log_file" => path, "exit_status" => 0,
                           "finished_at" => "2026-10-17T14:51:00Z" })
    File.write(@history_file, "{not valid json\n#{good}\n")
    assert_equal 1, analyzer.history.size
  end

  def test_missing_dirs_and_history_safe
    a = Brainiac::Forensics::Analyzer.new(
      log_dirs: ["/nonexistent/path"], history_file: "/nonexistent/history.jsonl", now: @now
    )
    report = a.report
    assert_equal 0, report[:summary][:total_logs]
    assert_equal 0, report[:summary][:total_history_records]
    assert_empty report[:anomalies]
  end

  def test_summary_counts
    p1 = write_log(name: "s1", timestamp: "20261017-150000")
    p2 = write_log(name: "s2", timestamp: "20261017-150100")
    write_history([
                    { "agent" => "Kaylee", "log_file" => p1, "exit_status" => 0, "finished_at" => "2026-10-17T15:01:00Z" },
                    { "agent" => "Kaylee", "log_file" => p2, "exit_status" => 2, "finished_at" => "2026-10-17T15:02:00Z" }
                  ])
    s = analyzer.report[:summary]
    assert_equal 2, s[:total_logs]
    assert_equal 2, s[:total_history_records]
    assert_equal 2, s[:correlated_sessions]
    assert_equal 1, s[:crashes]
  end

  def test_report_has_generated_at
    assert_equal @now.utc.iso8601, analyzer.report[:generated_at]
  end
end
