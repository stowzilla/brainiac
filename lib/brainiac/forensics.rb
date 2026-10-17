# frozen_string_literal: true

require "json"
require "time"

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
        head = File.foreach(path).first(40)
        LogRecord.new(
          path: path, log_name: name, timestamp: ts,
          mtime: safe_mtime(path), size_bytes: safe_size(path),
          agent_cli: extract(head, /Running (\S+) in /, 1),
          command: extract(head, /Command: (.+?)(?: \(resuming session\))?$/, 1),
          chdir: extract(head, /Running \S+ in (.+?), logging to/, 1),
          env_keys: extract_env_keys(head),
          resumed: head.any? { |l| l.include?("(resuming session)") },
          error_hits: scan_errors(path),
          line_count: count_lines(path)
        )
      rescue SystemCallError
        nil
      end

      private

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
        File.foreach(path) do |line|
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
      rescue SystemCallError
        hits
      end

      # Agent CLIs emit ANSI color codes into their logs; strip them so error
      # signatures match on the underlying text and messages stay readable.
      def strip_ansi(line)
        line.gsub(/\e\[[\d;?]*[a-zA-Z]/, "")
      end

      def count_lines(path)
        File.foreach(path).count
      rescue SystemCallError
        0
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

      private

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

    module_function

    # Convenience entry point: build an analyzer over the standard brainiac locations
    # (all registered repos' tmp/, their worktree siblings, and ~/.brainiac/tmp/) plus
    # the durable session-history file, then return its report.
    #
    # `extra_dirs` lets callers (CLI --dir, a specific worktree) add ad-hoc log dirs.
    def analyze(extra_dirs: [], history_file: nil, thresholds: {}, now: Time.now)
      dirs = (default_log_dirs + Array(extra_dirs)).uniq
      hist = history_file || default_history_file
      Analyzer.new(log_dirs: dirs, history_file: hist, thresholds: thresholds, now: now).report
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
  end
end
