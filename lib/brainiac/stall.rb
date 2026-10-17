# frozen_string_literal: true

# Hung-operation (stall) detection.
#
# An agent can get wedged on a long-running subprocess that never returns — a
# hung `xcodebuild`, a prompt waiting on stdin, a network call with no timeout.
# The process stays alive, so none of brainiac's existing safety nets fire:
# `session_active?` still sees a live pid, supersede only covers the first 60s,
# and the completion watcher's `Process.wait` blocks forever. The session just
# goes quiet.
#
# The reliable signal for "hung" is the session's LOG going silent: the agent
# writes to its log continuously while working, so when the log's mtime stops
# advancing while the process is still alive, it's stalled. This watchdog scans
# active sessions on an interval and, on the first stall, emits :session_stalled
# and notifies the originating channel ONCE so a human can intervene (kill via the
# existing ❌ reaction). If a hard cap is configured, it can also auto-kill.
#
# Thresholds (seconds) come from brainiac.json → "stall" (or env), so operators can
# tune per-machine without code changes:
#   { "stall": { "warn_seconds": 600, "kill_seconds": 0, "poll_seconds": 30 } }
# kill_seconds <= 0 disables auto-kill (warn-only — the default, least surprising).
module Brainiac
  module Stall
    DEFAULTS = { warn_seconds: 600, kill_seconds: 0, poll_seconds: 30 }.freeze

    module_function

    # Resolve thresholds from brainiac.json "stall" + env overrides, clamped sane.
    def config
      cfg = defined?(BRAINIAC_CONFIG) && BRAINIAC_CONFIG.is_a?(Hash) ? (BRAINIAC_CONFIG["stall"] || {}) : {}
      {
        warn_seconds: env_int("BRAINIAC_STALL_WARN", cfg["warn_seconds"], DEFAULTS[:warn_seconds]),
        kill_seconds: env_int("BRAINIAC_STALL_KILL", cfg["kill_seconds"], DEFAULTS[:kill_seconds]),
        poll_seconds: env_int("BRAINIAC_STALL_POLL", cfg["poll_seconds"], DEFAULTS[:poll_seconds]).clamp(5, 3600)
      }
    end

    def env_int(env_key, cfg_value, default)
      raw = ENV[env_key] || cfg_value
      raw.nil? || raw.to_s.strip.empty? ? default : raw.to_i
    end

    # Seconds since the session last produced output (log file mtime), or nil if the
    # log is missing/unreadable. This is the "quiet for how long" measure.
    def idle_seconds(log_file, now: Time.now)
      return nil unless log_file && File.exist?(log_file)

      (now - File.mtime(log_file)).to_i
    rescue SystemCallError
      nil
    end

    # Pure classifier: given how long a session has been idle, whether it's already
    # been warned, and the thresholds, decide what to do. No IO, fully testable.
    #
    # Returns one of:
    #   :ok      — still producing output (or not idle long enough)
    #   :warn    — crossed the warn threshold and hasn't been warned yet → notify once
    #   :kill    — crossed the (enabled) hard cap → auto-kill
    #   :waiting — stalled and already warned, but no kill cap reached → keep waiting
    def classify(idle_seconds:, warned:, warn_seconds:, kill_seconds:)
      return :ok if idle_seconds.nil? || idle_seconds < warn_seconds
      return :kill if kill_seconds.to_i.positive? && idle_seconds >= kill_seconds

      warned ? :waiting : :warn
    end
  end
end
