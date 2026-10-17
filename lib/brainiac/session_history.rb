# frozen_string_literal: true

require "timeout"

# Durable session history + "session heaviness" tracking.
#
# The in-memory RECENT_SESSIONS (see sessions.rb) only holds the last 10 finished
# sessions and is wiped on every brainiac restart. This module persists a durable,
# append-only record of every completed agent session to disk so the monitor (and
# anything else) can review real history: how long a session ran, which CLI/model it
# used, where it came from, and — where the provider exposes it — how "heavy" the
# session was (context window usage + credits spent).
#
# Storage: append-only JSONL at ~/.brainiac/session-history.jsonl (one record per line).
# JSONL is chosen deliberately: appends are atomic-ish and cheap, the file survives
# restarts, it's trivially tailable, and a corrupt line never poisons the whole file.
# The file is trimmed to SESSION_HISTORY_MAX records to bound growth.

SESSION_HISTORY_FILE = File.join(BRAINIAC_DIR, "session-history.jsonl")
SESSION_HISTORY_MAX = 500
SESSION_HISTORY_MUTEX = Mutex.new

# Append a completed-session record to the durable history file.
# `record` is a plain Hash; symbol keys are fine (serialized to JSON).
# Best-effort: any failure is logged and swallowed — history is never allowed to
# break the completion path.
def record_session_history(record)
  SESSION_HISTORY_MUTEX.synchronize do
    FileUtils.mkdir_p(File.dirname(SESSION_HISTORY_FILE))
    File.open(SESSION_HISTORY_FILE, "a") { |f| f.puts(JSON.generate(record)) }
    trim_session_history!
  end
  LOG.info "[SessionHistory] Recorded session for #{record["agent"] || "?"} → #{SESSION_HISTORY_FILE}"
  true
rescue StandardError => e
  LOG.warn "[SessionHistory] Failed to record session: #{e.class}: #{e.message}"
  false
end

# Read the most recent `limit` session records, newest first.
def read_session_history(limit: 50)
  return [] unless File.exist?(SESSION_HISTORY_FILE)

  lines = SESSION_HISTORY_MUTEX.synchronize { File.readlines(SESSION_HISTORY_FILE) }
  records = lines.filter_map do |line|
    line = line.strip
    next if line.empty?

    begin
      JSON.parse(line)
    rescue JSON::ParserError
      nil
    end
  end
  records.last(limit).reverse
rescue StandardError => e
  LOG.warn "[SessionHistory] Failed to read history: #{e.message}"
  []
end

# Keep the history file bounded. Call inside SESSION_HISTORY_MUTEX.
def trim_session_history!
  lines = File.readlines(SESSION_HISTORY_FILE)
  return if lines.size <= SESSION_HISTORY_MAX

  File.write(SESSION_HISTORY_FILE, lines.last(SESSION_HISTORY_MAX).join)
rescue StandardError => e
  LOG.warn "[SessionHistory] Failed to trim history: #{e.message}"
end

# Build the durable history record for a finished session and append it.
# Called from handle_agent_completion. Gathers timing, identity, and — via the
# provider-specific heaviness probe — context/credit usage. Never raises.
# Schema version for the durable session-history record. Bump when the record shape
# changes so analytics can adapt to older lines. v2 added going-forward instrumentation
# (trigger_type, effort, resumed, branch, work_item_id, prompt/output bytes, git impact).
SESSION_HISTORY_SCHEMA = 2

def archive_session_history(ctx:, exit_status:, signaled:)
  heaviness = session_heaviness(resolved: ctx[:resolved], chdir: ctx[:chdir])
  git_impact = session_git_impact(chdir: ctx[:chdir], head_before: ctx[:head_before])
  record = build_session_record(ctx: ctx, exit_status: exit_status, signaled: signaled,
                                finished_at: Time.now, heaviness: heaviness, git_impact: git_impact)
  record_session_history(record)
end

# Build the durable history record from completion context. Pure (no process spawn,
# no disk writes beyond what callers pass in) so it's unit-testable. Every field here
# is derived from data brainiac already has in-hand at completion time or from cheap
# local byte/line counts — no LLM calls, no added latency in the agent's critical path
# (this runs in the completion watcher thread after the agent process has already exited).
def build_session_record(ctx:, exit_status:, signaled:, finished_at:, heaviness: nil, git_impact: nil)
  started_at = ctx[:started_at]
  source_context = ctx[:source_context] || {}
  prompt_bytes = safe_file_bytes(ctx[:prompt_file])
  output_bytes = safe_file_bytes(ctx[:output_file])

  record = {
    "recorded_at" => finished_at.utc.iso8601,
    "schema" => SESSION_HISTORY_SCHEMA,
    "agent" => ctx[:agent_name] || ctx[:agent_config_name] || "Unknown",
    "card_key" => ctx[:card_key] || source_context[:card_key],
    "card_number" => ctx[:card_number] || source_context[:card_number],
    "source" => ctx[:source]&.to_s,
    "channel_id" => ctx[:channel_id] || source_context[:channel_id],
    # trigger_type: the "why dispatched" — derived from the log name brainiac already
    # assigns (assigned / followup / pr-comment / changes-requested / cron-run / …).
    "trigger_type" => trigger_type_from_log_name(ctx[:log_name]),
    "log_file" => ctx[:log_file],
    "cli" => ctx[:agent_cli],
    "model" => ctx[:model],
    "effort" => ctx[:effort],
    "profile" => ctx[:profile],
    "resumed" => ctx[:resumed] ? true : nil,
    "branch" => branch_from_chdir(ctx[:chdir]),
    "work_item_id" => ctx[:work_item_id],
    "started_at" => started_at&.utc&.iso8601,
    "finished_at" => finished_at.utc.iso8601,
    "duration_seconds" => started_at ? (finished_at - started_at).to_i : nil,
    "exit_status" => exit_status,
    "signaled" => signaled,
    "prompt_bytes" => prompt_bytes,
    "output_bytes" => output_bytes,
    "produced_output" => output_bytes&.positive?
  }
  record.merge!(heaviness) if heaviness
  record.merge!(git_impact) if git_impact
  record.compact!
  record
end

# Map brainiac's log_name (e.g. "assigned-1474", "pr-comment-48", "cron-run-foo",
# "followup-1096") to a coarse trigger type for analytics. Strips the trailing id.
def trigger_type_from_log_name(log_name)
  return nil unless log_name && !log_name.to_s.empty?

  base = log_name.to_s.sub(/-\d+\z/, "")       # drop trailing "-<number>"
  base = base.sub(/-[0-9a-f]{8,}.*\z/i, "")    # drop trailing hashy/discord ids
  base.empty? ? log_name.to_s : base
end

# Branch name inferred from the worktree dir: "<repo>--<branch>" → "<branch>".
def branch_from_chdir(chdir)
  return nil unless chdir

  base = File.basename(chdir.to_s)
  base.include?("--") ? base.split("--", 2).last : nil
end

# Git impact of the session: commits made and files changed since dispatch. Uses the
# pre-dispatch HEAD captured in ctx[:head_before] (a cheap local `git rev-parse` that
# already runs before spawn). Two local git calls at completion — no tokens, no network.
# Returns a Hash of string keys or nil when unavailable.
def session_git_impact(chdir:, head_before:)
  return nil unless chdir && head_before && !head_before.empty?

  head_after, = Open3.capture2("git", "rev-parse", "HEAD", chdir: chdir)
  head_after = head_after.strip
  return nil if head_after.empty?

  commits, = Open3.capture2("git", "rev-list", "--count", "#{head_before}..#{head_after}", chdir: chdir)
  files, = Open3.capture2("git", "diff", "--name-only", "#{head_before}..#{head_after}", chdir: chdir)
  {
    "git_commits" => commits.strip.to_i,
    "git_files_changed" => files.strip.empty? ? 0 : files.strip.lines.size,
    "git_head_moved" => head_before != head_after
  }
rescue StandardError => e
  LOG.warn "[SessionHistory] git impact capture failed for #{chdir}: #{e.message}" if defined?(LOG)
  nil
end

# File size in bytes, or nil if missing/unreadable. Used for prompt/output weight.
def safe_file_bytes(path)
  return nil unless path && File.exist?(path)

  File.size(path)
rescue SystemCallError
  nil
end

# --- Provider-generic session heaviness probe ---
#
# "How heavy was this session?" — context window usage + credits spent.
# This is inherently provider-specific: each CLI stores (or doesn't store) usage
# differently. Rather than hardcode any one CLI in this file, brainiac reads a
# `heaviness_probe` block from the provider's cli-providers/<name>.json. That config
# declares WHICH probe strategy to use and WHERE its data lives, e.g.:
#
#   "heaviness_probe": { "type": "kiro_sqlite", "db_path": "~/.local/share/kiro-cli/data.sqlite3" }
#
# The config controls the "what and where" (enable/disable a provider, point it at a
# moved db) with zero code changes. The "how" for each probe TYPE lives here in Ruby —
# a genuinely new storage mechanism (a provider that logs usage to JSON, an HTTP
# endpoint, etc.) still needs a small probe implementation, but pointing kiro at a new
# path or turning a provider's probe on/off is pure JSON.
#
# Providers with no `heaviness_probe` (or an unknown type) simply yield nil and the
# history record carries timing/identity only.
#
# Returns a Hash of string-keyed heaviness fields, or nil if unavailable:
#   context_window_tokens, context_usage_pct, context_used_tokens, credits_used
def session_heaviness(resolved:, chdir:)
  return nil unless resolved && chdir

  probe = resolved["heaviness_probe"]
  return nil unless probe.is_a?(Hash)

  case probe["type"]
  when "kiro_sqlite"
    kiro_session_heaviness(chdir, db_path: probe["db_path"])
  end
rescue StandardError => e
  LOG.warn "[SessionHistory] Heaviness probe failed for #{chdir}: #{e.message}"
  nil
end

# kiro-cli persists every conversation in a local sqlite keyed by working directory.
# Each conversation's JSON carries the model's context window, the latest request's
# context-usage percentage, and per-request credit usage. We read it read-only via the
# sqlite3 CLI (no gem dependency) and derive the heaviness fields. Best-effort: any
# problem (missing db, no row for this cwd, malformed json) yields nil.
#
# The db location comes from the provider's heaviness_probe.db_path so it's not baked
# into brainiac; KIRO_DEFAULT_DB_PATH is only the fallback.
KIRO_DEFAULT_DB_PATH = File.join(Dir.home, ".local", "share", "kiro-cli", "data.sqlite3")

def kiro_session_heaviness(chdir, db_path: nil)
  db = File.expand_path(db_path || KIRO_DEFAULT_DB_PATH)
  return nil unless File.exist?(db)

  key = File.expand_path(chdir)
  # The CTE picks the most recently updated conversation for this working directory,
  # then we pull the model's context window, the latest request's context-usage %, and
  # the summed credit spend. `.timeout` (via -cmd, so it doesn't emit output) keeps us
  # from hanging if kiro-cli is mid-write.
  sql = <<~SQL.gsub(/\s+/, " ").strip
    WITH latest AS (
      SELECT value FROM conversations_v2
      WHERE key = #{sqlite_quote(key)} ORDER BY updated_at DESC LIMIT 1
    )
    SELECT
      json_extract(value, '$.model_info.context_window_tokens'),
      (SELECT r.value ->> 'context_usage_percentage'
         FROM latest, json_each(json_extract(latest.value, '$.user_turn_metadata.requests')) r
         ORDER BY CAST(r.key AS INTEGER) DESC LIMIT 1),
      (SELECT ROUND(SUM(CAST(u.value ->> 'value' AS REAL)), 4)
         FROM latest, json_each(json_extract(latest.value, '$.user_turn_metadata.usage_info')) u
         WHERE (u.value ->> 'unit') = 'credit')
    FROM latest;
  SQL

  out = ""
  status = nil
  Timeout.timeout(6) do
    out, status = Open3.capture2(
      "sqlite3", "-separator", "\t", "-cmd", ".timeout 3000",
      "file:#{db}?mode=ro", sql
    )
  end
  return nil unless status&.success?

  row = out.strip
  return nil if row.empty?

  window, pct, credits = row.split("\t", 3)
  window = window.to_i
  return nil if window.zero?

  pct = pct.to_f
  fields = { "context_window_tokens" => window, "context_usage_pct" => pct.round(2) }
  fields["context_used_tokens"] = (window * pct / 100.0).round if pct.positive?
  fields["credits_used"] = credits.to_f.round(4) if credits && !credits.empty?
  fields
end

# Single-quote a string for safe literal interpolation into SQLite SQL.
def sqlite_quote(str)
  "'#{str.to_s.gsub("'", "''")}'"
end
