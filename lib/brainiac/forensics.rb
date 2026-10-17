# frozen_string_literal: true

require "json"
require "time"
require "yaml"

# Log / retrieval forensics for Brainiac agent sessions.
#
# Brainiac leaves two very different breadcrumbs behind every agent run:
#
#   1. Raw session logs — `<worktree>/tmp/agent-<name>-<timestamp>.log`. These are
#      the full stdout/stderr of the spawned CLI. The first lines (written by
#      `log_agent_launch`) carry the launch metadata: which CLI, the command line,
#      the working dir, injected env var *names* (never values), and whether the
#      session resumed.
#   2. Durable history — an append-only JSONL at `~/.brainiac/session-history.jsonl`
#      (see session_history.rb). One record per *finished* session with timing,
#      identity, exit status, and — where the provider exposes it — "heaviness"
#      (context-window usage + credits).
#
# The logs know a session *started*; the history knows how it *ended*. Neither
# alone tells the whole story. Forensics stitches them together by log file path,
# then flags the things a human reviewing an incident actually cares about: crashes,
# sessions that started but never produced a history record (the server died, the
# process was killed, it's still running), runaway context usage, suspiciously long
# runs, and logs carrying error/exception signatures.
#
# Everything here is read-only and best-effort. A malformed log or a corrupt JSONL
# line degrades to "less insight", never an exception in the caller.
module Brainiac
  module Forensics
    # Default thresholds for anomaly flagging. Tunable per-call via Analyzer.new.
    DEFAULTS = {
      slow_session_seconds: 1800,   # 30 min — unusually long for one dispatch
      heavy_context_pct: 85.0,      # context window getting dangerously full
      stale_running_seconds: 7200,  # a log with no history record older than 2h = orphaned
      error_signatures: [
        /\bTraceback \(most recent call last\)/,
        /\b[A-Z]\w*(?:Error|Exception):/,
        /\bpanic:/,
        /\bFATAL\b/,
        /segmentation fault/i,
        /command not found/,
        /\bERROR\b.*rate.?limit/i
      ]
    }.freeze

    # Metadata parsed out of the launch header + body of a raw agent log.
    LogRecord = Struct.new(
      :path, :log_name, :timestamp, :mtime, :size_bytes,
      :agent_cli, :command, :chdir, :env_keys, :resumed,
      :error_hits, :line_count, keyword_init: true
    )

    # Parses raw `agent-*.log` files into LogRecords. The launch header format comes
    # from log_agent_launch (helpers.rb); the body is scanned for error signatures.
    class LogParser
      # Matches `agent-<log_name>-<YYYYmmdd>-<HHMMSS>.log` (see run_agent in helpers.rb).
      LOG_FILENAME = /\Aagent-(?<name>.+)-(?<ts>\d{8}-\d{6})\.log\z/

      def initialize(error_signatures:)
        @error_signatures = error_signatures
      end

      # Parse every `agent-*.log` in a directory. Missing dir / IO errors → [].
      def parse_dir(dir)
        return [] unless dir && Dir.exist?(dir)

        Dir.glob(File.join(dir, "agent-*.log")).filter_map { |path| parse(path) }
      rescue SystemCallError
        []
      end

      def parse(path)
        name, ts = parse_filename(File.basename(path))
        head = safe_lines(path, limit: 40)
        LogRecord.new(
          path: path, log_name: name, timestamp: ts,
          mtime: safe_mtime(path), size_bytes: safe_size(path),
          agent_cli: extract(head, /Running (\S+) in /, 1),
          command: extract(head, /Command: (.+?)(?: \(resuming session\))?$/, 1),
          chdir: extract(head, /Running \S+ in (.+?), logging to/, 1),
          env_keys: extract_env_keys(head),
          resumed: head.any? { |l| l.include?("(resuming session)") },
          error_hits: scan_errors(path),
          line_count: head_count(path)
        )
      rescue SystemCallError, EncodingError, ArgumentError
        # Agent logs can contain invalid UTF-8 / binary noise; never let one bad
        # log take down the whole scan (and the analytics endpoint with it).
        nil
      end

      private

      # Read up to `limit` lines (or all) with invalid/undefined bytes scrubbed, so
      # downstream regex matching can't raise on malformed UTF-8. Returns [] on IO error.
      # Transcoding UTF-8→UTF-8 is a no-op in Ruby, so we scrub each line explicitly.
      def safe_lines(path, limit: nil)
        lines = []
        File.foreach(path) do |line|
          lines << line.scrub("")
          break if limit && lines.size >= limit
        end
        lines
      rescue SystemCallError
        []
      end

      def parse_filename(basename)
        m = LOG_FILENAME.match(basename)
        return [basename.delete_suffix(".log"), nil] unless m

        [m[:name], parse_timestamp(m[:ts])]
      end

      def parse_timestamp(stamp)
        Time.strptime(stamp, "%Y%m%d-%H%M%S")
      rescue ArgumentError
        nil
      end

      def extract(lines, regex, group)
        lines.each do |line|
          m = regex.match(line)
          return m[group].strip if m
        end
        nil
      end

      # "Injecting 2 env var(s) for agent X: FIZZY_TOKEN, DISCORD_BOT_TOKEN" → names only.
      def extract_env_keys(lines)
        raw = extract(lines, /Injecting \d+ env var\(s\) for agent [^:]*: (.+)$/, 1)
        return [] unless raw

        raw.split(",").map(&:strip).reject(&:empty?)
      end

      def scan_errors(path)
        hits = []
        safe_lines(path).each do |line|
          clean = strip_ansi(line).strip
          @error_signatures.each do |sig|
            if sig.match?(clean)
              hits << clean[0, 200]
              break
            end
          end
          break if hits.size >= 5
        end
        hits
      end

      # Agent CLIs emit ANSI color codes into their logs; strip them so error
      # signatures match on the underlying text and messages stay readable.
      def strip_ansi(line)
        line.gsub(/\e\[[\d;?]*[a-zA-Z]/, "")
      end

      def head_count(path)
        safe_lines(path).size
      end

      def safe_mtime(path)
        File.mtime(path)
      rescue SystemCallError
        nil
      end

      def safe_size(path)
        File.size(path)
      rescue SystemCallError
        0
      end
    end

    # One analysis pass over a directory of logs + the durable history file.
    # Produces a report Hash via #report — summary counts, correlated sessions,
    # and a flat list of anomalies suitable for CLI or JSON rendering.
    class Analyzer
      attr_reader :log_dirs, :history_file, :thresholds

      def initialize(log_dirs:, history_file:, thresholds: {}, now: Time.now)
        @log_dirs = Array(log_dirs)
        @history_file = history_file
        @thresholds = DEFAULTS.merge(thresholds)
        @now = now
        @parser = LogParser.new(error_signatures: @thresholds[:error_signatures])
      end

      # Parsed agent logs, newest first (by mtime).
      def logs
        @logs ||= @log_dirs.flat_map { |dir| @parser.parse_dir(dir) }
                           .sort_by { |r| r.mtime || Time.at(0) }
                           .reverse
      end

      # Durable history records (newest first), via session_history.rb when loaded,
      # with a self-contained fallback so the analyzer works in isolation/tests.
      def history
        @history ||= read_history
      end

      # The full forensic report.
      def report
        correlated = correlate
        anomalies = detect_anomalies(correlated)
        {
          generated_at: @now.utc.iso8601,
          summary: build_summary(correlated, anomalies),
          sessions: correlated,
          anomalies: anomalies
        }
      end

      # Performance-over-time report: trends, per-dimension breakdowns, and
      # calibration recommendations. `since` (a Time) scopes to recent sessions so
      # you can measure "has it improved since I changed the persona?".
      def performance_report(period: :day, since: nil)
        sessions = correlate
        sessions = scope_since(sessions, since) if since
        PerformanceTracker.new(sessions, period: period, now: @now).report
      end

      # Inventory of all brainiac parameters (agents/personas/skills/knowledge/
      # models/sources/profiles/roles) with per-item session usage. `paths` lets
      # tests point at fixture dirs; production uses the config constants.
      def inventory_report(paths: {})
        Inventory.new(correlate, paths: paths).report
      end

      # Sessions tied to a selected parameter value (for the drill-down selector).
      def sessions_for(dimension, value, paths: {})
        Inventory.new(correlate, paths: paths).sessions_for(dimension, value)
      end

      # ROI / effectiveness: per-card one-shot vs rework outcomes correlated with
      # memory volume, persona×task performance, and skill usage. Pulls memory counts
      # and skill inventory from Inventory so the correlations have something to join on.
      def effectiveness_report(paths: {})
        inv = Inventory.new(correlate, paths: paths)
        Effectiveness.new(correlate, memory_counts: inv.memory_counts, skills: inv.report[:skills]).report
      end

      private

      def scope_since(sessions, since)
        sessions.select do |s|
          t = parse_time(s[:finished_at] || s[:started_at])
          t && t >= since
        end
      end

      def read_history
        records = load_history_records
        records.sort_by { |r| parse_time(r["finished_at"] || r["recorded_at"]) || Time.at(0) }.reverse
      end

      def load_history_records
        # Prefer the canonical reader (handles trimming/mutex) only when we're pointed
        # at the canonical file; otherwise read the explicit history_file ourselves so
        # a CLI `--history` override (or a test fixture) is honored.
        if defined?(read_session_history) && defined?(SESSION_HISTORY_FILE) &&
           @history_file == SESSION_HISTORY_FILE
          return read_session_history(limit: 500)
        end

        parse_jsonl(@history_file)
      end

      def parse_jsonl(file)
        return [] unless file && File.exist?(file)

        File.readlines(file).filter_map do |line|
          line = line.strip
          next if line.empty?

          begin
            JSON.parse(line)
          rescue JSON::ParserError
            nil
          end
        end
      rescue SystemCallError
        []
      end

      # Join each history record to the raw log it names via the "log_file" field.
      # Logs with no matching history record are surfaced as orphans (started, no
      # recorded ending).
      def correlate
        logs_by_path = logs.to_h { |r| [r.path, r] }
        matched_paths = []

        sessions = history.map do |rec|
          log = logs_by_path[rec["log_file"]]
          matched_paths << rec["log_file"] if log
          merge_session(rec, log)
        end

        orphans = logs.reject { |r| matched_paths.include?(r.path) }
                      .map { |log| merge_session(nil, log) }

        (sessions + orphans).sort_by { |s| s[:sort_key] }.reverse
      end

      def merge_session(rec, log)
        {
          agent: rec&.dig("agent") || log&.log_name,
          cli: rec&.dig("cli") || log&.agent_cli,
          model: rec&.dig("model"),
          source: rec&.dig("source"),
          card_key: rec&.dig("card_key"),
          card_number: rec&.dig("card_number"),
          duration_seconds: rec&.dig("duration_seconds"),
          exit_status: rec&.dig("exit_status"),
          signaled: rec&.dig("signaled"),
          context_usage_pct: rec&.dig("context_usage_pct"),
          credits_used: rec&.dig("credits_used"),
          # Going-forward instrumentation (schema v2): surfaced for the UI/analytics.
          trigger_type: rec&.dig("trigger_type"),
          effort: rec&.dig("effort"),
          branch: rec&.dig("branch"),
          work_item_id: rec&.dig("work_item_id"),
          prompt_bytes: rec&.dig("prompt_bytes"),
          output_bytes: rec&.dig("output_bytes"),
          produced_output: rec&.dig("produced_output"),
          git_commits: rec&.dig("git_commits"),
          git_files_changed: rec&.dig("git_files_changed"),
          schema: rec&.dig("schema"),
          started_at: rec&.dig("started_at") || log_started_at(log),
          finished_at: rec&.dig("finished_at"),
          log_file: rec&.dig("log_file") || log&.path,
          log_present: !log.nil?,
          log_error_hits: log&.error_hits || [],
          resumed: log&.resumed || false,
          has_history: !rec.nil?,
          sort_key: session_sort_key(rec, log)
        }
      end

      def log_started_at(log)
        ts = log&.timestamp
        ts&.utc&.iso8601
      end

      def session_sort_key(rec, log)
        parse_time(rec&.dig("finished_at")) || log&.mtime ||
          parse_time(rec&.dig("recorded_at")) || Time.at(0)
      end

      def detect_anomalies(sessions)
        AnomalyDetector.new(logs: logs, thresholds: @thresholds, now: @now).detect(sessions)
      end

      def build_summary(sessions, anomalies)
        {
          total_logs: logs.size,
          total_history_records: history.size,
          correlated_sessions: sessions.size,
          orphan_logs: sessions.count { |s| !s[:has_history] && s[:log_present] },
          crashes: anomalies.count { |a| a[:kind] == :crash },
          anomaly_count: anomalies.size,
          anomalies_by_severity: anomalies.each_with_object(Hash.new(0)) { |a, h| h[a[:severity]] += 1 }
        }
      end

      def parse_time(str)
        return nil unless str

        Time.parse(str.to_s)
      rescue ArgumentError
        nil
      end
    end

    # Applies the anomaly rules to correlated sessions. Each rule returns an anomaly
    # Hash or nil; `detect` flattens them across all sessions. Split out of Analyzer
    # so each stays small and the rules are independently testable.
    class AnomalyDetector
      def initialize(logs:, thresholds:, now:)
        @logs = logs
        @thresholds = thresholds
        @now = now
      end

      def detect(sessions)
        sessions.flat_map { |s| anomalies_for(s) }
      end

      private

      def anomalies_for(session)
        [
          crash_anomaly(session), orphan_anomaly(session), heavy_context_anomaly(session),
          slow_anomaly(session), error_signature_anomaly(session)
        ].compact
      end

      def crash_anomaly(session)
        return unless session[:has_history]
        return if session[:exit_status].nil? || session[:exit_status].zero?

        detail = session[:signaled] ? "killed by signal" : "exit status #{session[:exit_status]}"
        anomaly(:crash, :high, session, "Agent session ended abnormally (#{detail})")
      end

      def orphan_anomaly(session)
        return if session[:has_history]
        return unless session[:log_present]

        age = log_age_seconds(session)
        return unless age && age > @thresholds[:stale_running_seconds]

        anomaly(:orphan_log, :medium, session,
                "Log has no history record and is #{(age / 3600.0).round(1)}h old " \
                "(server crash, killed process, or still running?)")
      end

      def heavy_context_anomaly(session)
        pct = session[:context_usage_pct]
        return unless pct && pct >= @thresholds[:heavy_context_pct]

        anomaly(:heavy_context, :medium, session, "Context window #{pct}% full — near limit")
      end

      def slow_anomaly(session)
        dur = session[:duration_seconds]
        return unless dur && dur > @thresholds[:slow_session_seconds]

        anomaly(:slow_session, :low, session, "Session ran #{(dur / 60.0).round(1)} min")
      end

      def error_signature_anomaly(session)
        hits = session[:log_error_hits]
        return if hits.nil? || hits.empty?

        anomaly(:log_errors, :medium, session,
                "#{hits.size} error signature(s) in log: #{hits.first}")
      end

      def anomaly(kind, severity, session, message)
        {
          kind: kind, severity: severity, agent: session[:agent], card_key: session[:card_key],
          log_file: session[:log_file], started_at: session[:started_at], message: message
        }
      end

      def log_age_seconds(session)
        mtime = @logs.find { |r| r.path == session[:log_file] }&.mtime
        return unless mtime

        @now - mtime
      end
    end

    # Aggregate performance metrics for a set of sessions. This is the unit that
    # every breakdown (per-agent, per-model, per-time-bucket) is built from, so a
    # bucket and the global rollup are described the same way.
    #
    # The point of these numbers is *calibration over time*: if a persona tweak or a
    # new skill actually helped, the agent's crash/error rate should fall and its
    # context/credit cost should drop in later buckets. These are the levers to watch.
    class MetricSet
      def self.from(sessions)
        finished = sessions.select { |s| s[:has_history] }
        {
          sessions: sessions.size,
          finished: finished.size,
          crash_rate: rate(finished) { |s| crashed?(s) },
          error_rate: rate(sessions) { |s| (s[:log_error_hits] || []).any? },
          resume_rate: rate(sessions) { |s| s[:resumed] },
          avg_duration_seconds: avg(finished) { |s| s[:duration_seconds] },
          p95_duration_seconds: pct(finished, 0.95) { |s| s[:duration_seconds] },
          avg_context_pct: avg(finished) { |s| s[:context_usage_pct] },
          max_context_pct: max(finished) { |s| s[:context_usage_pct] },
          total_credits: sum(finished) { |s| s[:credits_used] },
          avg_credits: avg(finished) { |s| s[:credits_used] }
        }
      end

      def self.crashed?(session)
        es = session[:exit_status]
        !es.nil? && !es.zero?
      end

      def self.rate(sessions, &)
        return 0.0 if sessions.empty?

        (sessions.count(&).to_f / sessions.size).round(3)
      end

      def self.values(sessions, &)
        sessions.filter_map(&)
      end

      def self.avg(sessions, &)
        vals = values(sessions, &)
        return nil if vals.empty?

        (vals.sum.to_f / vals.size).round(2)
      end

      def self.sum(sessions, &)
        vals = values(sessions, &)
        return nil if vals.empty?

        vals.sum.round(4)
      end

      def self.max(sessions, &)
        values(sessions, &).max
      end

      def self.pct(sessions, quantile, &)
        vals = values(sessions, &).sort
        return nil if vals.empty?

        vals[[(quantile * vals.size).ceil - 1, 0].max]
      end
    end

    # Turns correlated sessions into a performance-over-time report: time-bucketed
    # trends, per-dimension breakdowns (agent / model / source), and calibration
    # recommendations. This is the feedback loop Adam asked for — the output points
    # at *which* agent/persona/skill/knowledge to tune, not just "something broke".
    class PerformanceTracker
      # Calibration thresholds — when a breakdown crosses these, we recommend action.
      CRASH_RATE_WARN = 0.15     # >15% of finished sessions crashing
      ERROR_RATE_WARN = 0.30     # >30% of sessions carrying error signatures
      CONTEXT_WARN = 75.0        # avg context usage this high = knowledge/prompt bloat
      MIN_SAMPLE = 3             # don't moralize about an agent with 1 data point
      RECURRING_ERROR_MIN = 3    # same error signature across N sessions = systemic

      def initialize(sessions, period: :day, now: Time.now)
        @sessions = sessions
        # Breakdowns and per-agent/model recommendations only make sense for sessions
        # that produced a history record — those carry authoritative agent/model/source
        # identity. Orphan logs (log name only, no history) would otherwise masquerade
        # as "agents" like "followup-1047" and pollute the calibration signal.
        @finished = sessions.select { |s| s[:has_history] }
        @period = period
        @now = now
      end

      def report
        {
          generated_at: @now.utc.iso8601,
          period: @period,
          overall: MetricSet.from(@sessions),
          trends: trends,
          by_agent: breakdown { |s| s[:agent] },
          by_model: breakdown { |s| s[:model] },
          by_source: breakdown { |s| s[:source] },
          recommendations: recommendations
        }
      end

      private

      # Sessions grouped into time buckets (oldest first), each with its MetricSet,
      # so you can see whether the numbers improve after a calibration change.
      def trends
        bucketed = @sessions.group_by { |s| bucket_key(s) }.reject { |k, _| k.nil? }
        bucketed.sort_by { |k, _| k }.map do |key, group|
          { bucket: key, metrics: MetricSet.from(group) }
        end
      end

      def bucket_key(session)
        t = parse_time(session[:finished_at] || session[:started_at])
        return nil unless t

        case @period
        when :week then t.strftime("%G-W%V")
        when :month then t.strftime("%Y-%m")
        else t.strftime("%Y-%m-%d")
        end
      end

      # One MetricSet per distinct value of the yielded dimension, richest first.
      # Scoped to sessions with history so dimensions reflect real identity.
      # Grouping is case-insensitive (so "kaylee" and "Kaylee" merge); the display
      # key is the most common original casing.
      def breakdown(&)
        grouped = @finished.group_by { |s| (yield(s) || "unknown").to_s.downcase }
        items = grouped.map do |_key, group|
          { key: display_label(group, &), metrics: MetricSet.from(group) }
        end
        items.sort_by { |b| -b[:metrics][:sessions] }
      end

      # Pick the most frequently-seen original casing for a group's dimension value.
      def display_label(group, &)
        group.filter_map(&).map(&:to_s).reject(&:empty?)
             .tally.max_by { |_v, n| n }&.first || "unknown"
      end

      # Derive actionable calibration signals. Each recommendation names a target
      # (an agent, a model, or the knowledge base) and *why* — so the human knows
      # which persona/skill/knowledge file to go edit.
      def recommendations
        recs = []
        recs.concat(agent_recommendations)
        recs.concat(model_recommendations)
        recs.concat(recurring_error_recommendations)
        recs
      end

      def agent_recommendations
        breakdown { |s| s[:agent] }.flat_map do |b|
          next [] if b[:metrics][:sessions] < MIN_SAMPLE

          agent_signals(b[:key], b[:metrics])
        end
      end

      def agent_signals(agent, metrics)
        out = []
        if metrics[:crash_rate] && metrics[:crash_rate] >= CRASH_RATE_WARN
          out << rec(:persona, agent, "#{agent}: crash rate #{pctf(metrics[:crash_rate])} across " \
                                      "#{metrics[:finished]} sessions — review this agent's persona/skills and recent prompts")
        end
        if metrics[:error_rate] && metrics[:error_rate] >= ERROR_RATE_WARN
          out << rec(:skills, agent, "#{agent}: error rate #{pctf(metrics[:error_rate])} — likely a missing " \
                                     "tool/skill or stale knowledge; add a skill or knowledge entry for the recurring failure")
        end
        out
      end

      def model_recommendations
        breakdown { |s| s[:model] }.flat_map do |b|
          m = b[:metrics]
          next [] if b[:key] == "unknown" || m[:sessions] < MIN_SAMPLE
          next [] unless m[:avg_context_pct] && m[:avg_context_pct] >= CONTEXT_WARN

          [rec(:knowledge, b[:key], "model #{b[:key]}: avg context #{m[:avg_context_pct]}% — " \
                                    "trim injected knowledge/prompt size or raise the model, context is running hot")]
        end
      end

      # The same error signature recurring across many sessions is a systemic gap in
      # knowledge/skills, not a one-off — worth a knowledge entry or skill.
      def recurring_error_recommendations
        counts = Hash.new(0)
        @sessions.each do |s|
          (s[:log_error_hits] || []).each { |h| counts[normalize_error(h)] += 1 }
        end
        counts.select { |_sig, n| n >= RECURRING_ERROR_MIN }
              .sort_by { |_sig, n| -n }
              .map do |sig, n|
          rec(:knowledge, "brain", "recurring error in #{n} sessions: #{sig} — " \
                                   "capture the fix as a knowledge entry or skill so agents stop re-hitting it")
        end
      end

      # Collapse volatile bits (numbers, hex, paths) so "error at line 42" and
      # "error at line 99" count as the same recurring signature.
      def normalize_error(hit)
        hit.gsub(%r{/\S+}, "<path>").gsub(/0x[0-9a-f]+/i, "<addr>").gsub(/\d+/, "<n>").strip[0, 120]
      end

      def rec(target, subject, message)
        { target: target, subject: subject, message: message }
      end

      def pctf(rate)
        "#{(rate * 100).round(1)}%"
      end

      def parse_time(str)
        return nil unless str

        Time.parse(str.to_s)
      rescue ArgumentError
        nil
      end
    end

    # Enumerates every "brainiac parameter" that shapes an agent run — the inputs,
    # not just the outputs — and ties each to how it's been used in sessions.
    #
    # Categories: agents, personas, skills, knowledge, models, sources, profiles,
    # roles. Each item reports whether it's `available` (present on disk / in config)
    # and a `usage` blob. Usage fidelity varies by what brainiac actually records:
    #   - agents / models / sources: sessions carry these fields, so usage = real
    #     session counts + crash/error rates (via MetricSet).
    #   - skills: brain tracks view/use counts in SKILL.usage.json sidecars.
    #   - personas: one persona dir per agent, so persona usage mirrors that agent's
    #     sessions.
    #   - knowledge / profiles / roles: enumerable and available, but brainiac does
    #     not (yet) log which were injected per session — reported as inventory with
    #     usage_tracked: false so the UI is honest about it rather than faking numbers.
    #
    # Paths come from config constants (KNOWLEDGE_DIR, PERSONA_BASE_DIR, etc.) when
    # loaded; every lookup is guarded so the class is testable in isolation.
    class Inventory
      # Dimensions that correlate directly to a session field.
      SESSION_DIMENSIONS = %w[agent model source].freeze

      def initialize(sessions, paths: {})
        @sessions = sessions
        @finished = sessions.select { |s| s[:has_history] }
        @paths = paths
      end

      def report
        {
          agents: agents,
          personas: personas,
          skills: skills,
          knowledge: knowledge,
          models: dimension_items("model"),
          sources: dimension_items("source"),
          profiles: profiles,
          roles: roles
        }
      end

      # Sessions associated with a selected parameter value along a dimension.
      # dimension ∈ agent|model|source|persona (persona resolves to its agent).
      def sessions_for(dimension, value)
        field = dimension == "persona" ? "agent" : dimension
        return [] unless SESSION_DIMENSIONS.include?(field)

        key = value.to_s.downcase
        @sessions.select { |s| s[field.to_sym].to_s.downcase == key }
      end

      # Public: downcased agent key => memory-file count (for ROI correlations).
      def memory_counts
        memory_file_counts
      end

      private

      # agents: registry + anyone who shows up in a *finished* session (those carry
      # authoritative agent identity). Orphan log names are excluded so the list is
      # real agents, not per-card log names like "followup-1047".
      # agents: the real historical roster, not just whoever shows up in the recent
      # (trimmed, 500-max) session-history. We union four sources — the registry,
      # persona dirs, per-agent memory dirs (brain/memory/<agent>/, the long-term
      # record of work), and agents named in finished sessions — keyed case-
      # insensitively so "kaylee" and "Kaylee" are one agent. Usage reports both the
      # recent session count AND the memory-file count (the "have I actually used
      # this agent over time" signal), so an agent with history on another machine
      # still shows up as available with its memory footprint.
      def agents
        memory = memory_file_counts # downcased-key => count
        by_key = {}
        agent_name_sources.each do |name|
          key = name.to_s.downcase
          next if key.empty?

          by_key[key] ||= name
        end
        items = by_key.map do |key, label|
          usage = session_usage("agent", key).merge(memory_files: memory[key] || 0)
          { name: label, available: registry_agent_keys.include?(key), usage: usage }
        end
        items.sort_by { |a| [-(a[:usage][:sessions] || 0), -(a[:usage][:memory_files] || 0), a[:name].downcase] }
      end

      # personas: one dir per agent under PERSONA_BASE_DIR; usage = that agent's sessions.
      def personas
        dir = @paths[:persona] || (defined?(PERSONA_BASE_DIR) ? PERSONA_BASE_DIR : nil)
        list_dirs(dir).map do |name|
          { name: name, available: true, usage: session_usage("agent", name) }
        end
      end

      # skills: SKILL.md inventory + view/use counts from the .usage.json sidecars.
      def skills
        dir = @paths[:skills] || (defined?(SKILLS_DIR) ? SKILLS_DIR : nil)
        return [] unless dir && Dir.exist?(dir)

        items = Dir.glob(File.join(dir, "**", "SKILL.md")).reject { |p| p.include?("_archived/") }.map do |path|
          fm = Forensics.read_skill_frontmatter(path)
          { name: fm[:name] || File.basename(File.dirname(path)), available: true,
            description: fm[:description], usage: Forensics.read_skill_usage(path).merge(usage_tracked: true) }
        end
        items.sort_by { |s| -(s[:usage][:uses] || 0) }
      end

      # knowledge: enumerable by category; per-session injection isn't logged.
      def knowledge
        dir = @paths[:knowledge] || (defined?(KNOWLEDGE_DIR) ? KNOWLEDGE_DIR : nil)
        return [] unless dir && Dir.exist?(dir)

        by_cat = Dir.glob(File.join(dir, "**", "*.md")).group_by { |p| category_of(p, dir) }
        by_cat.map { |cat, files| { name: cat, available: true, usage: { files: files.size, usage_tracked: false } } }
              .sort_by { |k| -k[:usage][:files] }
      end

      def profiles
        config_keys(@paths[:profiles] || brainiac_file("profiles.json")).map do |name|
          { name: name, available: true, usage: { usage_tracked: false } }
        end
      end

      def roles
        dir = @paths[:roles] || (defined?(ROLES_DIR) ? ROLES_DIR : nil)
        Dir.glob(File.join(dir.to_s, "*.md")).map do |path|
          { name: File.basename(path, ".md"), available: true, usage: { usage_tracked: false } }
        end
      end

      # Distinct values of a session dimension (model/source), case-insensitive, each
      # with usage. Display label is the most common original casing.
      def dimension_items(field)
        grouped = @finished.group_by { |s| s[field.to_sym].to_s.downcase }.reject { |k, _| k.empty? }
        items = grouped.map do |key, group|
          label = group.filter_map { |s| s[field.to_sym] }.map(&:to_s).tally.max_by { |_v, n| n }&.first || key
          { name: label, available: true, usage: session_usage(field, key) }
        end
        items.sort_by { |i| -(i[:usage][:sessions] || 0) }
      end

      def session_usage(field, value)
        key = value.to_s.downcase
        matched = @sessions.select { |s| s[field.to_sym].to_s.downcase == key }
        finished = matched.select { |s| s[:has_history] }
        m = MetricSet.from(matched)
        { sessions: matched.size, finished: finished.size, usage_tracked: true,
          crash_rate: m[:crash_rate], error_rate: m[:error_rate],
          avg_duration_seconds: m[:avg_duration_seconds], avg_context_pct: m[:avg_context_pct] }
      end

      def finished_session_values(field)
        @finished.filter_map { |s| s[field.to_sym] }.map(&:to_s).uniq
      end

      def registry_agent_names
        @registry_agent_names ||= begin
          reg = if @paths[:agents]
                  parse_json(@paths[:agents])
                elsif defined?(AGENT_REGISTRY)
                  AGENT_REGISTRY
                else
                  {}
                end
          (reg || {}).map { |k, v| (v.is_a?(Hash) && v["display_name"]) || k }.map(&:to_s)
        end
      end

      # Downcased keys of all known registry agents (for the available? flag).
      def registry_agent_keys
        @registry_agent_keys ||= registry_agent_names.to_set(&:downcase)
      end

      # Every candidate agent name, from all four sources. Later sources only add
      # names not already seen (case-insensitively), and we prefer a registry/
      # persona display name over a raw session value for nicer casing.
      def agent_name_sources
        registry_agent_names +
          list_dirs(@paths[:persona] || (defined?(PERSONA_BASE_DIR) ? PERSONA_BASE_DIR : nil)) +
          memory_file_counts.keys +
          finished_session_values("agent")
      end

      # downcased agent key => number of memory files (brain/memory/<agent>/*).
      # The long-term record of which agents have actually done work over time —
      # survives session-history trimming and spans other machines via brain git sync.
      def memory_file_counts
        @memory_file_counts ||= begin
          dir = @paths[:memory] || (defined?(MEMORY_BASE_DIR) ? MEMORY_BASE_DIR : nil)
          counts = {}
          list_dirs(dir).each do |agent|
            counts[agent.downcase] = Dir.glob(File.join(dir, agent, "*")).size
          end
          counts
        end
      end

      def list_dirs(dir)
        return [] unless dir && Dir.exist?(dir)

        Dir.children(dir).select { |c| File.directory?(File.join(dir, c)) && !c.start_with?(".") }.sort
      rescue SystemCallError
        []
      end

      def category_of(path, root)
        rel = path.sub("#{root}/", "")
        rel.include?("/") ? rel.split("/").first : "(root)"
      end

      def config_keys(file)
        (parse_json(file) || {}).keys.map(&:to_s)
      end

      def brainiac_file(name)
        defined?(BRAINIAC_DIR) ? File.join(BRAINIAC_DIR, name) : nil
      end

      def parse_json(file)
        return nil unless file && File.exist?(file)

        JSON.parse(File.read(file))
      rescue StandardError
        nil
      end
    end

    # "Are our choices earning their keep?" — ROI analysis that correlates brainiac's
    # inputs (memory, skills, personas) with session *outcomes*, not just activity.
    #
    # The core outcome unit is the CARD, not the session. Multiple sessions on one card
    # tell a story: a single `assigned` session that produced output and nobody had to
    # follow up on is a "one-shot"; a card that needed `followup` or `changes-requested`
    # sessions is "rework". That's the signal behind "valuable performance".
    #
    #   one_shot  — resolved in a single productive pass (1 session, produced output,
    #               no followup/changes-requested)
    #   reworked  — needed follow-up or revision sessions
    #   abandoned — sessions ran but none produced output
    #
    # HONESTY: brainiac records which agent/trigger ran each session, so agent×task and
    # one-shot/rework are real. It does NOT yet log which *specific* skill/knowledge files
    # were injected per session, so skill→rework and memory→one-shot are reported as
    # correlations across agents (coarse), explicitly flagged attribution: "correlation".
    # Needs schema-v2 data (trigger_type) to be meaningful; older cards fall back to
    # session count.
    class Effectiveness
      def initialize(sessions, memory_counts: {}, skills: [])
        @finished = sessions.select { |s| s[:has_history] }
        @memory_counts = memory_counts # downcased agent => memory file count
        @skills = skills               # inventory skills (name/usage)
      end

      def report
        cards = card_outcomes
        {
          caveat: "Card outcomes are derived from trigger_type + produced_output (schema v2). " \
                  "agent/task splits are authoritative; memory→one-shot and skill→rework are " \
                  "correlations across agents, not per-session causal attribution.",
          overall: outcome_rollup(cards),
          by_agent: group_outcomes(cards) { |c| c[:agent] },
          by_task: group_outcomes(cards) { |c| c[:task] },
          by_persona_task: persona_task_matrix(cards),
          memory_vs_oneshot: memory_correlation(cards),
          skill_usage_vs_rework: skill_rework_signal(cards)
        }
      end

      private

      # Collapse sessions into one outcome per (card_key, agent). Cards without a
      # card_key (ad-hoc/discord) are grouped by their log/session id so they still count.
      def card_outcomes
        grouped = @finished.group_by { |s| [s[:card_key] || s[:log_file], (s[:agent] || "unknown").to_s.downcase] }
        grouped.map do |(_card, agent_key), sessions|
          triggers = sessions.filter_map { |s| s[:trigger_type] }
          # A card is classifiable only if at least one session carries schema-v2
          # outcome signal (trigger_type or a non-nil produced_output). Pure v1 records
          # don't tell us whether work landed in one pass, so they're :unknown — NOT
          # counted as failures, just "not yet instrumented".
          instrumented = sessions.any? { |s| s[:trigger_type] || !s[:produced_output].nil? }
          produced = sessions.any? { |s| s[:produced_output] }
          {
            agent: display_agent(sessions),
            agent_key: agent_key,
            task: instrumented ? primary_task(triggers) : "unknown",
            outcome: instrumented ? classify(triggers, produced, sessions.size) : :unknown,
            sessions: sessions.size,
            commits: sessions.sum { |s| s[:git_commits].to_i },
            crashed: sessions.any? { |s| crashed?(s) }
          }
        end
      end

      def classify(triggers, produced, session_count)
        return :abandoned unless produced

        reworked = triggers.intersect?(%w[followup changes-requested pr-comment])
        # Has trigger data but only an initiating one + multiple sessions → rework proxy.
        reworked ||= triggers.empty? && session_count > 1
        reworked ? :reworked : :one_shot
      end

      def primary_task(triggers)
        # The task is what *started* the card — prefer an initiating trigger.
        starter = triggers.find { |t| %w[assigned cron-run discord].include?(t) }
        starter || triggers.first || "unknown"
      end

      def outcome_rollup(cards)
        n = cards.size
        return { cards: 0 } if n.zero?

        one = cards.count { |c| c[:outcome] == :one_shot }
        rew = cards.count { |c| c[:outcome] == :reworked }
        ab = cards.count { |c| c[:outcome] == :abandoned }
        unknown = cards.count { |c| c[:outcome] == :unknown }
        # Rates are over *classified* (schema-v2-instrumented) cards only, so
        # un-instrumented history doesn't drag one-shot/rework toward zero.
        classified = n - unknown
        {
          cards: n, classified: classified, unknown: unknown,
          one_shot: one, reworked: rew, abandoned: ab,
          one_shot_rate: rate(one, classified), rework_rate: rate(rew, classified),
          avg_sessions_per_card: (cards.sum { |c| c[:sessions] }.to_f / n).round(2),
          avg_commits_per_card: (cards.sum { |c| c[:commits] }.to_f / n).round(2)
        }
      end

      def rate(count, total)
        return nil if total.to_i.zero?

        (count.to_f / total).round(3)
      end

      def group_outcomes(cards, &)
        groups = cards.group_by(&).map do |key, group|
          { key: key, metrics: outcome_rollup(group) }
        end
        groups.sort_by { |g| -g[:metrics][:cards] }
      end

      # agent × task grid: does a persona do better on some task types than others?
      def persona_task_matrix(cards)
        cells = cards.group_by { |c| [c[:agent], c[:task]] }.map do |(agent, task), group|
          { agent: agent, task: task, metrics: outcome_rollup(group) }
        end
        cells.sort_by { |cell| [-cell[:metrics][:cards], cell[:agent].to_s] }
      end

      # Correlate each agent's memory-file count with its one-shot rate. Correlation
      # only — more memory *may* help, but we can't prove causation from this alone.
      def memory_correlation(cards)
        rows = group_outcomes(cards) { |c| c[:agent] }.filter_map do |g|
          key = g[:key].to_s.downcase
          mem = @memory_counts[key]
          next unless mem && g[:metrics][:cards].to_i.positive?

          { agent: g[:key], memory_files: mem, cards: g[:metrics][:cards],
            one_shot_rate: g[:metrics][:one_shot_rate] }
        end
        { attribution: "correlation", note: "memory volume vs one-shot rate, per agent",
          points: rows.sort_by { |r| -r[:memory_files] } }
      end

      # Overall rework rate alongside total skill usage — the honest, coarse version of
      # "do skills reduce rework". Per-skill causal attribution needs injection logging.
      def skill_rework_signal(cards)
        total_uses = @skills.sum { |s| s.dig(:usage, :uses).to_i }
        roll = outcome_rollup(cards)
        {
          attribution: "correlation",
          note: "per-session skill injection isn't logged yet, so this is fleet-wide, not per-skill",
          total_skill_uses: total_uses, skills_available: @skills.size,
          rework_rate: roll[:rework_rate], one_shot_rate: roll[:one_shot_rate]
        }
      end

      def display_agent(sessions)
        sessions.filter_map { |s| s[:agent] }.map(&:to_s).reject(&:empty?)
                .tally.max_by { |_v, n| n }&.first || "unknown"
      end

      def crashed?(session)
        es = session[:exit_status]
        !es.nil? && !es.zero?
      end
    end

    # Reads a skill or persona's content from the brain dirs and annotates it with
    # metrics-derived pros/cons. Path-guarded: resolved paths must stay under the
    # configured base dir (no "../" traversal, no absolute-name escape).
    class ContentReader
      def initialize(skills_base:, persona_base:, agent_outcomes: [], now: Time.now)
        @skills_base = skills_base
        @persona_base = persona_base
        @agent_outcomes = agent_outcomes
        @now = now
      end

      def read(kind, name)
        case kind
        when "skill" then read_skill(name)
        when "persona" then read_persona(name)
        else { error: "unknown kind: #{kind}" }
        end
      end

      private

      def read_skill(name)
        dir = resolve_dir(@skills_base, name)
        return { error: "skill not found: #{name}" } unless dir

        file = File.join(dir, "SKILL.md")
        return { error: "SKILL.md not found for #{name}" } unless File.exist?(file)

        usage = Forensics.read_skill_usage(file)
        { kind: "skill", name: name, path: file, content: File.read(file),
          annotations: skill_annotations(usage) }
      rescue StandardError => e
        { error: e.message }
      end

      def read_persona(name)
        dir = resolve_dir(@persona_base, name)
        return { error: "persona not found: #{name}" } unless dir

        files = Dir.glob(File.join(dir, "**", "*.md"))
        return { error: "no persona files for #{name}" } if files.empty?

        content = files.map { |f| "# #{File.basename(f)}\n\n#{File.read(f)}" }.join("\n\n---\n\n")
        metrics = @agent_outcomes.find { |g| g[:key].to_s.downcase == name.to_s.downcase }
        { kind: "persona", name: name, path: dir, content: content,
          annotations: persona_annotations(metrics) }
      rescue StandardError => e
        { error: e.message }
      end

      # Resolve by exact-or-case-insensitive name, guarded to stay inside `base`.
      def resolve_dir(base, name)
        return nil unless base && Dir.exist?(base)

        safe = File.basename(name.to_s) # strip any path components
        candidate = File.join(base, safe)
        return candidate if File.directory?(candidate) && under?(base, candidate)

        match = Dir.children(base).find { |c| c.downcase == safe.downcase }
        match && File.directory?(File.join(base, match)) ? File.join(base, match) : nil
      rescue SystemCallError
        nil
      end

      def under?(base, path)
        File.expand_path(path).start_with?(File.expand_path(base) + File::SEPARATOR)
      end

      def skill_annotations(usage)
        pros = []
        cons = []
        uses = usage[:uses].to_i
        (uses >= 3 ? pros : cons) << "#{uses} recorded use(s)"
        if usage[:last_used]
          days = ((@now - parse_time(usage[:last_used])) / 86_400).round
          (days > 60 ? cons : pros) << "Last used #{days} day(s) ago"
        else
          cons << "Never recorded as used — may be stale or hard to match"
        end
        { pros: pros, cons: cons, attribution: "from SKILL.usage.json sidecar" }
      end

      def persona_annotations(group)
        return { pros: [], cons: ["No session outcomes recorded yet."], attribution: "none" } unless group

        m = group[:metrics]
        pros = []
        cons = []
        pros << "One-shot rate #{(m[:one_shot_rate] * 100).round}% over #{m[:cards]} card(s)" if m[:one_shot_rate]
        rate = m[:rework_rate]
        (rate && rate >= 0.3 ? cons : pros) << "Rework rate #{((rate || 0) * 100).round}%" if rate
        { pros: pros, cons: cons, attribution: "from per-card one-shot/rework outcomes" }
      end

      def parse_time(str)
        Time.parse(str.to_s)
      rescue ArgumentError
        @now
      end
    end

    module_function

    # Convenience entry point: build an analyzer over the standard brainiac locations
    # (all registered repos' tmp/, their worktree siblings, and ~/.brainiac/tmp/) plus
    # the durable session-history file, then return its report.
    #
    # `extra_dirs` lets callers (CLI --dir, a specific worktree) add ad-hoc log dirs.
    def analyze(extra_dirs: [], history_file: nil, thresholds: {}, now: Time.now)
      build_analyzer(extra_dirs, history_file, now, thresholds: thresholds).report
    end

    # Performance-tracking entry point: build the standard analyzer, then return its
    # performance report (trends + breakdowns + calibration recommendations).
    def performance(extra_dirs: [], history_file: nil, period: :day, since: nil, now: Time.now)
      build_analyzer(extra_dirs, history_file, now).performance_report(period: period, since: since)
    end

    # Inventory of all brainiac parameters with per-item session usage.
    def inventory(extra_dirs: [], history_file: nil, now: Time.now)
      build_analyzer(extra_dirs, history_file, now).inventory_report
    end

    # Sessions tied to a selected parameter value along a dimension.
    def sessions_for(dimension, value, extra_dirs: [], history_file: nil, now: Time.now)
      build_analyzer(extra_dirs, history_file, now).sessions_for(dimension, value)
    end

    # ROI / effectiveness report: are our choices earning their keep?
    def effectiveness(extra_dirs: [], history_file: nil, now: Time.now)
      build_analyzer(extra_dirs, history_file, now).effectiveness_report
    end

    # Shared constructor for the standard-locations analyzer used by every entry point.
    def build_analyzer(extra_dirs, history_file, now, thresholds: {})
      dirs = (default_log_dirs + Array(extra_dirs)).uniq
      Analyzer.new(log_dirs: dirs, history_file: history_file || default_history_file,
                   thresholds: thresholds, now: now)
    end

    # Read a skill or persona's content for the web UI, annotated with metrics-derived
    # pros/cons. kind ∈ "skill" | "persona". Path-guarded to the brain dirs. Delegates
    # to ContentReader (kept as its own class so this module stays cohesive/small).
    def read_content(kind, name, now: Time.now)
      skills_base = defined?(KNOWLEDGE_DIR) ? File.join(KNOWLEDGE_DIR, "skills") : nil
      persona_base = defined?(PERSONA_BASE_DIR) ? PERSONA_BASE_DIR : nil
      agent_outcomes = (kind == "persona" ? effectiveness[:by_agent] : [])
      ContentReader.new(skills_base: skills_base, persona_base: persona_base,
                        agent_outcomes: agent_outcomes, now: now).read(kind, name)
    end

    # tmp/ of every registered repo, every existing worktree sibling of those repos,
    # and brainiac's own tmp/. Mirrors the trust boundary in routes/api.rb's
    # log_file_allowed?.
    def default_log_dirs
      dirs = []
      if defined?(PROJECTS)
        PROJECTS.each_value do |project|
          repo = project["repo_path"]
          next unless repo && !repo.empty?

          dirs << File.join(repo, "tmp")
          dirs.concat(worktree_tmp_dirs(repo))
        end
      end
      dirs << File.join(BRAINIAC_DIR, "tmp") if defined?(BRAINIAC_DIR)
      dirs.uniq.select { |d| Dir.exist?(d) }
    end

    def worktree_tmp_dirs(repo)
      parent = File.dirname(repo)
      base = File.basename(repo)
      Dir.glob(File.join(parent, "#{base}--*", "tmp"))
    rescue SystemCallError
      []
    end

    def default_history_file
      return SESSION_HISTORY_FILE if defined?(SESSION_HISTORY_FILE)
      return File.join(BRAINIAC_DIR, "session-history.jsonl") if defined?(BRAINIAC_DIR)

      File.join(Dir.home, ".brainiac", "session-history.jsonl")
    end

    # Parse a SKILL.md's YAML frontmatter → { name:, description: }. Best-effort.
    def read_skill_frontmatter(path)
      content = File.read(path)
      return {} unless content.start_with?("---")

      parts = content.split("---", 3)
      return {} if parts.size < 3

      yaml = YAML.safe_load(parts[1]) || {}
      { name: yaml["name"], description: yaml["description"] }
    rescue StandardError
      {}
    end

    # Read a skill's SKILL.usage.json sidecar → view/use counts + timestamps.
    def read_skill_usage(path)
      usage_file = path.sub(/SKILL\.md$/, "SKILL.usage.json")
      data = (JSON.parse(File.read(usage_file)) if File.exist?(usage_file)) || {}
      { views: data["views"] || 0, uses: data["uses"] || 0,
        last_used: data["last_used"], last_viewed: data["last_viewed"] }
    rescue StandardError
      { views: 0, uses: 0, last_used: nil, last_viewed: nil }
    end
  end
end
