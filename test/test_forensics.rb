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

  def test_parses_log_with_invalid_utf8_bytes
    # Agent logs can contain invalid UTF-8 / binary noise. This must not raise —
    # it previously 500'd the analytics endpoint (ArgumentError on regex match).
    path = File.join(@log_dir, "agent-binary-20261017-160000.log")
    File.binwrite(path, "Running kiro-cli in /w, logging to #{path}\n" \
                        "RuntimeError: bad \xC3\x28 \xFF\xFE bytes here\n")
    rec = analyzer.logs.first # must not raise on invalid UTF-8
    refute_nil rec
    assert_equal "kiro-cli", rec.agent_cli
    # the error signature is still detected despite the invalid bytes
    assert(rec.error_hits.any? { |h| h.include?("RuntimeError") })
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

  # --- performance tracking (trends / breakdowns / calibration) ------------

  # Build a correlated-session hash the way Analyzer#correlate would.
  def session(finished:, agent:, model: "sonnet", source: "fizzy", exit_status: 0,
              duration: 100, context: 20.0, credits: 1.0, errors: [])
    {
      agent: agent, model: model, source: source, card_key: nil,
      duration_seconds: duration, exit_status: exit_status,
      context_usage_pct: context, credits_used: credits,
      started_at: finished, finished_at: finished,
      log_error_hits: errors, resumed: false, has_history: true
    }
  end

  def test_metricset_basic_rates
    sessions = [
      session(agent: "Kaylee", finished: "2026-10-10T10:00:00Z", exit_status: 0),
      session(agent: "Kaylee", finished: "2026-10-10T11:00:00Z", exit_status: 1),
      session(agent: "Kaylee", finished: "2026-10-10T12:00:00Z", exit_status: 0, errors: ["boom"])
    ]
    m = Brainiac::Forensics::MetricSet.from(sessions)
    assert_equal 3, m[:sessions]
    assert_equal 3, m[:finished]
    assert_in_delta 0.333, m[:crash_rate], 0.001
    assert_in_delta 0.333, m[:error_rate], 0.001
  end

  def test_metricset_averages_and_credits
    sessions = [
      session(agent: "K", finished: "2026-10-10T10:00:00Z", duration: 100, context: 40.0, credits: 2.0),
      session(agent: "K", finished: "2026-10-10T11:00:00Z", duration: 200, context: 60.0, credits: 3.0)
    ]
    m = Brainiac::Forensics::MetricSet.from(sessions)
    assert_in_delta 150.0, m[:avg_duration_seconds], 0.01
    assert_in_delta 50.0, m[:avg_context_pct], 0.01
    assert_in_delta 60.0, m[:max_context_pct], 0.01
    assert_in_delta 5.0, m[:total_credits], 0.01
  end

  def test_trends_bucketed_by_day
    sessions = [
      session(agent: "K", finished: "2026-10-10T10:00:00Z"),
      session(agent: "K", finished: "2026-10-10T18:00:00Z"),
      session(agent: "K", finished: "2026-10-11T09:00:00Z")
    ]
    report = Brainiac::Forensics::PerformanceTracker.new(sessions, period: :day, now: @now).report
    buckets = report[:trends].map { |t| t[:bucket] }
    assert_equal %w[2026-10-10 2026-10-11], buckets
    assert_equal 2, report[:trends].first[:metrics][:sessions]
  end

  def test_trends_bucketed_by_week
    sessions = [
      session(agent: "K", finished: "2026-10-05T10:00:00Z"),
      session(agent: "K", finished: "2026-10-12T10:00:00Z")
    ]
    report = Brainiac::Forensics::PerformanceTracker.new(sessions, period: :week, now: @now).report
    assert_equal 2, report[:trends].size
    assert_match(/\A\d{4}-W\d{2}\z/, report[:trends].first[:bucket])
  end

  def test_breakdown_by_agent_sorted_by_volume
    sessions = [
      session(agent: "Kaylee", finished: "2026-10-10T10:00:00Z"),
      session(agent: "Kaylee", finished: "2026-10-10T11:00:00Z"),
      session(agent: "Galen", finished: "2026-10-10T12:00:00Z")
    ]
    report = Brainiac::Forensics::PerformanceTracker.new(sessions, now: @now).report
    assert_equal "Kaylee", report[:by_agent].first[:key]
    assert_equal 2, report[:by_agent].first[:metrics][:sessions]
  end

  def test_recommendation_high_crash_rate_targets_persona
    sessions = Array.new(5) do |i|
      session(agent: "Crashy", finished: "2026-10-10T1#{i}:00:00Z", exit_status: i < 2 ? 1 : 0)
    end
    report = Brainiac::Forensics::PerformanceTracker.new(sessions, now: @now).report
    persona_rec = report[:recommendations].find { |r| r[:target] == :persona }
    refute_nil persona_rec
    assert_equal "Crashy", persona_rec[:subject]
  end

  def test_recommendation_high_error_rate_targets_skills
    sessions = Array.new(4) do |i|
      session(agent: "Erry", finished: "2026-10-10T1#{i}:00:00Z", errors: ["RuntimeError: x"])
    end
    report = Brainiac::Forensics::PerformanceTracker.new(sessions, now: @now).report
    assert(report[:recommendations].any? { |r| r[:target] == :skills && r[:subject] == "Erry" })
  end

  def test_recommendation_heavy_context_targets_knowledge
    sessions = Array.new(3) do |i|
      session(agent: "K", model: "opus", finished: "2026-10-10T1#{i}:00:00Z", context: 90.0)
    end
    report = Brainiac::Forensics::PerformanceTracker.new(sessions, now: @now).report
    rec = report[:recommendations].find { |r| r[:target] == :knowledge && r[:subject] == "opus" }
    refute_nil rec
  end

  def test_recommendation_recurring_error_targets_brain
    sessions = Array.new(3) do |i|
      session(agent: "K#{i}", finished: "2026-10-10T1#{i}:00:00Z",
              errors: ["sh: tsc: command not found at /some/path/#{i}"])
    end
    report = Brainiac::Forensics::PerformanceTracker.new(sessions, now: @now).report
    brain_rec = report[:recommendations].find { |r| r[:subject] == "brain" }
    refute_nil brain_rec
    assert_match(/recurring error in 3 sessions/, brain_rec[:message])
  end

  def test_small_sample_not_moralized
    sessions = [session(agent: "Lonely", finished: "2026-10-10T10:00:00Z", exit_status: 1)]
    report = Brainiac::Forensics::PerformanceTracker.new(sessions, now: @now).report
    lonely = report[:recommendations].select { |r| r[:subject] == "Lonely" }
    assert_empty lonely
  end

  def test_performance_report_since_filter
    p1 = write_log(name: "old", timestamp: "20261001-100000")
    p2 = write_log(name: "new", timestamp: "20261015-100000")
    write_history([
                    { "agent" => "K", "model" => "sonnet", "source" => "fizzy", "log_file" => p1,
                      "exit_status" => 0, "finished_at" => "2026-10-01T10:00:00Z" },
                    { "agent" => "K", "model" => "sonnet", "source" => "fizzy", "log_file" => p2,
                      "exit_status" => 0, "finished_at" => "2026-10-15T10:00:00Z" }
                  ])
    report = analyzer.performance_report(since: Time.utc(2026, 10, 10))
    assert_equal 1, report[:overall][:sessions]
  end

  def test_performance_report_end_to_end
    path = write_log(name: "e2e", timestamp: "20261015-100000")
    write_history([{ "agent" => "K", "model" => "sonnet", "source" => "fizzy", "log_file" => path,
                     "exit_status" => 0, "duration_seconds" => 50, "finished_at" => "2026-10-15T10:00:00Z" }])
    report = analyzer.performance_report
    assert_equal :day, report[:period]
    assert_equal 1, report[:overall][:sessions]
    assert(report[:by_agent].any? { |b| b[:key] == "K" })
    assert(report[:by_model].any? { |b| b[:key] == "sonnet" })
  end

  # --- inventory (all brainiac parameters) --------------------------------

  # Build a fixture brain layout and return a paths hash for Inventory.
  def build_inventory_fixtures
    skills_dir = File.join(@dir, "skills")
    persona_dir = File.join(@dir, "persona")
    knowledge_dir = File.join(@dir, "knowledge")
    roles_dir = File.join(@dir, "roles")
    memory_dir = File.join(@dir, "memory")
    FileUtils.mkdir_p(File.join(skills_dir, "deploy-thing"))
    FileUtils.mkdir_p(File.join(skills_dir, "_archived", "old-skill"))
    FileUtils.mkdir_p(File.join(persona_dir, "kaylee"))
    FileUtils.mkdir_p(File.join(persona_dir, "galen"))
    FileUtils.mkdir_p(File.join(knowledge_dir, "lessons"))
    FileUtils.mkdir_p(roles_dir)
    # memory dirs: the long-term record. Avon worked a lot historically but has
    # no recent session-history record — must still surface as an available agent.
    FileUtils.mkdir_p(File.join(memory_dir, "kaylee"))
    FileUtils.mkdir_p(File.join(memory_dir, "avon"))
    3.times { |i| File.write(File.join(memory_dir, "kaylee", "card-#{i}.md"), "x") }
    5.times { |i| File.write(File.join(memory_dir, "avon", "card-#{i}.md"), "y") }

    File.write(File.join(skills_dir, "deploy-thing", "SKILL.md"),
               "---\nname: deploy-thing\ndescription: Deploy the thing\n---\nSteps\n")
    File.write(File.join(skills_dir, "deploy-thing", "SKILL.usage.json"),
               JSON.generate({ "views" => 5, "uses" => 3, "last_used" => "2026-10-10T00:00:00Z" }))
    File.write(File.join(skills_dir, "_archived", "old-skill", "SKILL.md"),
               "---\nname: old-skill\ndescription: archived\n---\n")
    File.write(File.join(knowledge_dir, "lessons", "a.md"), "x")
    File.write(File.join(knowledge_dir, "lessons", "b.md"), "y")
    File.write(File.join(roles_dir, "reviewer.md"), "# Reviewer")
    agents_file = File.join(@dir, "agents.json")
    File.write(agents_file, JSON.generate({ "kaylee" => { "display_name" => "Kaylee" }, "galen" => { "display_name" => "Galen" } }))
    profiles_file = File.join(@dir, "profiles.json")
    File.write(profiles_file, JSON.generate({ "q" => { "default" => true }, "k+" => {} }))

    { skills: skills_dir, persona: persona_dir, knowledge: knowledge_dir,
      roles: roles_dir, agents: agents_file, profiles: profiles_file, memory: memory_dir }
  end

  def inventory_sessions
    p1 = write_log(name: "s1", timestamp: "20261015-100000")
    p2 = write_log(name: "s2", timestamp: "20261015-110000")
    write_history([
                    { "agent" => "Kaylee", "model" => "sonnet", "source" => "fizzy", "log_file" => p1,
                      "exit_status" => 0, "duration_seconds" => 100, "finished_at" => "2026-10-15T10:01:00Z" },
                    # lowercase on purpose: must merge with "Kaylee" case-insensitively
                    { "agent" => "kaylee", "model" => "Sonnet", "source" => "discord", "log_file" => p2,
                      "exit_status" => 1, "duration_seconds" => 200, "finished_at" => "2026-10-15T11:01:00Z" }
                  ])
  end

  def test_inventory_agents_case_insensitive_merge
    inventory_sessions
    inv = analyzer.inventory_report(paths: build_inventory_fixtures)
    kaylees = inv[:agents].select { |a| a[:name].downcase == "kaylee" }
    assert_equal 1, kaylees.size, "kaylee/Kaylee must merge into one agent"
    assert_equal 2, kaylees.first[:usage][:sessions]
  end

  def test_inventory_models_case_insensitive_merge
    inventory_sessions # sonnet + Sonnet
    inv = analyzer.inventory_report(paths: build_inventory_fixtures)
    sonnets = inv[:models].select { |m| m[:name].downcase == "sonnet" }
    assert_equal 1, sonnets.size, "sonnet/Sonnet must merge"
    assert_equal 2, sonnets.first[:usage][:sessions]
  end

  def test_inventory_includes_historical_agents_without_recent_sessions
    inventory_sessions
    inv = analyzer.inventory_report(paths: build_inventory_fixtures)
    # Avon has memory files but no session-history record — must still appear.
    avon = inv[:agents].find { |a| a[:name].downcase == "avon" }
    refute_nil avon, "agent with memory history must be listed even without recent sessions"
    assert_equal 5, avon[:usage][:memory_files]
    assert_equal 0, avon[:usage][:sessions]
    # Galen is registry+persona only (no sessions, no memory) — still available.
    assert(inv[:agents].any? { |a| a[:name].downcase == "galen" })
  end

  def test_performance_breakdown_case_insensitive
    sessions = [
      session(agent: "Kaylee", finished: "2026-10-10T10:00:00Z"),
      session(agent: "kaylee", finished: "2026-10-10T11:00:00Z")
    ]
    report = Brainiac::Forensics::PerformanceTracker.new(sessions, now: @now).report
    kaylees = report[:by_agent].select { |b| b[:key].downcase == "kaylee" }
    assert_equal 1, kaylees.size
    assert_equal 2, kaylees.first[:metrics][:sessions]
  end

  def test_inventory_enumerates_all_categories
    inventory_sessions
    paths = build_inventory_fixtures
    inv = analyzer.inventory_report(paths: paths)
    %i[agents personas skills knowledge models sources profiles roles].each do |cat|
      assert inv.key?(cat), "missing category #{cat}"
    end
  end

  def test_inventory_skills_from_sidecar_excludes_archived
    inventory_sessions
    inv = analyzer.inventory_report(paths: build_inventory_fixtures)
    names = inv[:skills].map { |s| s[:name] }
    assert_includes names, "deploy-thing"
    refute_includes names, "old-skill"
    deploy = inv[:skills].find { |s| s[:name] == "deploy-thing" }
    assert_equal 3, deploy[:usage][:uses]
    assert_equal 5, deploy[:usage][:views]
  end

  def test_inventory_agents_tie_to_session_usage
    inventory_sessions
    inv = analyzer.inventory_report(paths: build_inventory_fixtures)
    kaylee = inv[:agents].find { |a| a[:name] == "Kaylee" }
    refute_nil kaylee
    assert kaylee[:available]
    assert_equal 2, kaylee[:usage][:sessions]
    assert_in_delta 0.5, kaylee[:usage][:crash_rate], 0.001
  end

  def test_inventory_personas_mirror_agent_sessions
    inventory_sessions
    inv = analyzer.inventory_report(paths: build_inventory_fixtures)
    kaylee = inv[:personas].find { |p| p[:name] == "kaylee" }
    refute_nil kaylee
    # persona "kaylee" resolves to agent usage (case-insensitive)
    assert_equal 2, kaylee[:usage][:sessions]
  end

  def test_inventory_excludes_orphan_log_names_from_agents
    write_log(name: "followup-999", timestamp: "20261015-120000") # no history record
    inventory_sessions
    inv = analyzer.inventory_report(paths: build_inventory_fixtures)
    names = inv[:agents].map { |a| a[:name] }
    refute_includes names, "followup-999"
    assert_includes names, "Kaylee"
  end

  def test_inventory_models_and_sources
    inventory_sessions
    inv = analyzer.inventory_report(paths: build_inventory_fixtures)
    # fixture now has sonnet + Sonnet (merged) across fizzy + discord sources
    assert(inv[:models].any? { |m| m[:name].downcase == "sonnet" })
    assert_includes inv[:sources].map { |s| s[:name] }, "fizzy"
    assert_includes inv[:sources].map { |s| s[:name] }, "discord"
  end

  def test_inventory_knowledge_counts_files_untracked
    inventory_sessions
    inv = analyzer.inventory_report(paths: build_inventory_fixtures)
    lessons = inv[:knowledge].find { |k| k[:name] == "lessons" }
    refute_nil lessons
    assert_equal 2, lessons[:usage][:files]
    refute lessons[:usage][:usage_tracked]
  end

  def test_inventory_profiles_and_roles
    inventory_sessions
    inv = analyzer.inventory_report(paths: build_inventory_fixtures)
    assert_includes inv[:profiles].map { |p| p[:name] }, "q"
    assert_includes inv[:roles].map { |r| r[:name] }, "reviewer"
  end

  def test_sessions_for_agent
    inventory_sessions
    sessions = analyzer.sessions_for("agent", "Kaylee")
    assert_equal 2, sessions.size
  end

  def test_sessions_for_model_case_insensitive
    inventory_sessions # both sessions are sonnet/Sonnet, one fizzy + one discord
    assert_equal 2, analyzer.sessions_for("model", "SONNET").size
    assert_equal 1, analyzer.sessions_for("source", "discord").size
  end

  def test_sessions_for_persona_resolves_to_agent
    inventory_sessions
    assert_equal 2, analyzer.sessions_for("persona", "kaylee").size
  end

  def test_sessions_for_unknown_dimension_empty
    inventory_sessions
    assert_empty analyzer.sessions_for("bogus", "x")
  end
end
