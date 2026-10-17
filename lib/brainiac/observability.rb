# frozen_string_literal: true

# Brainiac observability: consistent tagged logging, per-dispatch trace ids, and a
# single guard for the "run / rescue / log / swallow" pattern that had been copy-pasted
# across the codebase (Brainiac.emit, completion_step, forensics_guard, the heaviness
# and git-impact probes, …).
#
# Why this exists: a lot has been patched onto brainiac over time, and logging drifted
# into ~24 hand-written "[Component]" string prefixes plus scattered rescue blocks with
# inconsistent formatting. This centralizes three things so new code doesn't have to
# reinvent them and existing code can adopt them incrementally:
#
#   1. component_logger(name) — a thin wrapper over LOG that prefixes every line with
#      "[Name]" and, when a trace is active, a short "(trace)" correlation tag.
#   2. trace ids — a thread-local id so all log lines from one agent dispatch can be
#      correlated across the threads it touches (watcher, completion steps, hooks).
#   3. guard — one place that runs a block, rescues StandardError, logs it with the
#      component tag + a few backtrace frames, and returns a fallback. Sinatra's
#      throw-based `halt` is NOT a StandardError, so 4xx halts still propagate.
#
# Everything degrades gracefully if LOG isn't loaded yet (e.g. early boot / tests).
module Brainiac
  module Observability
    TRACE_KEY = :brainiac_trace_id

    # A logger bound to a component name. `log.info("msg")` emits "[Component] msg"
    # (with a trace tag when one is active). Levels: debug/info/warn/error.
    class ComponentLogger
      LEVELS = %i[debug info warn error].freeze

      def initialize(component)
        @component = component.to_s
      end

      LEVELS.each do |level|
        define_method(level) do |message|
          emit(level, message)
        end
      end

      # Log an exception consistently: "<label> failed: <Class>: <message>" + frames.
      def exception(error, label:, level: :error)
        emit(level, "#{label} failed: #{error.class}: #{error.message}")
        return unless error.backtrace

        emit(level, "  #{error.backtrace.first(3).join("\n  ")}")
      end

      private

      def emit(level, message)
        return unless defined?(LOG) && LOG

        LOG.public_send(level, "#{prefix}#{message}")
      rescue StandardError
        nil # logging must never raise
      end

      def prefix
        trace = Observability.trace_id
        trace ? "[#{@component}](#{trace}) " : "[#{@component}] "
      end
    end

    module_function

    # Get (memoized) a component logger. Cheap; safe to call per-call-site.
    def component_logger(name)
      (@component_loggers ||= {})[name.to_s] ||= ComponentLogger.new(name)
    end

    # The current thread's trace id, or nil when no trace is active.
    def trace_id
      Thread.current[TRACE_KEY]
    end

    # Run a block with a trace id bound to the current thread, restoring the previous
    # value afterward (safe to nest). Generates a short id when none is given.
    def with_trace(id = nil)
      previous = Thread.current[TRACE_KEY]
      Thread.current[TRACE_KEY] = id || new_trace_id
      yield Thread.current[TRACE_KEY]
    ensure
      Thread.current[TRACE_KEY] = previous
    end

    # Bind a trace id to the current thread without a block (for cross-thread handoff,
    # e.g. the completion watcher thread adopting the dispatch's id). Returns the id.
    def adopt_trace(id)
      Thread.current[TRACE_KEY] = id
    end

    def new_trace_id
      SecureRandom.hex(4)
    end

    # Run `block`, returning its value. On StandardError: log via the component logger
    # (using `label` for context) and return `fallback` (default nil). This is the one
    # true "rescue/log/swallow" helper — callers that need the error can pass a block
    # to `on_error`. `halt`/`throw` propagate untouched (not StandardError).
    def guard(component, label:, fallback: nil, on_error: nil)
      yield
    rescue StandardError => e
      component_logger(component).exception(e, label: label)
      on_error&.call(e)
      fallback
    end
  end

  class << self
    # Convenience top-level aliases so call sites read `Brainiac.logger(:Foo)`,
    # `Brainiac.with_trace { … }`, `Brainiac.guard(:Foo, label: …) { … }`.
    def logger(component)
      Observability.component_logger(component)
    end

    def trace_id
      Observability.trace_id
    end

    def with_trace(id = nil, &)
      Observability.with_trace(id, &)
    end

    def adopt_trace(id)
      Observability.adopt_trace(id)
    end

    def guard(component, label:, fallback: nil, on_error: nil, &)
      Observability.guard(component, label: label, fallback: fallback, on_error: on_error, &)
    end
  end
end
