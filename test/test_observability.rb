# frozen_string_literal: true

require_relative "test_helper"

class TestObservability < Minitest::Test
  # --- trace id lifecycle --------------------------------------------------

  def test_trace_id_nil_by_default
    assert_nil Brainiac.trace_id
  end

  def test_with_trace_binds_and_restores
    assert_nil Brainiac.trace_id
    Brainiac.with_trace("abc123") do
      assert_equal "abc123", Brainiac.trace_id
    end
    assert_nil Brainiac.trace_id, "trace id must be cleared after the block"
  end

  def test_with_trace_generates_id_when_none_given
    seen = nil
    Brainiac.with_trace { |id| seen = id }
    refute_nil seen
    assert_match(/\A[0-9a-f]+\z/, seen)
  end

  def test_with_trace_nests_and_restores_previous
    Brainiac.with_trace("outer") do
      Brainiac.with_trace("inner") { assert_equal "inner", Brainiac.trace_id }
      assert_equal "outer", Brainiac.trace_id
    end
  end

  def test_with_trace_restores_even_on_raise
    assert_raises(RuntimeError) do
      Brainiac.with_trace("x") { raise "boom" }
    end
    assert_nil Brainiac.trace_id
  end

  def test_adopt_trace_binds_without_block
    Brainiac.adopt_trace("handoff")
    assert_equal "handoff", Brainiac.trace_id
  ensure
    Brainiac.adopt_trace(nil)
  end

  def test_new_trace_id_is_unique_ish
    refute_equal Brainiac::Observability.new_trace_id, Brainiac::Observability.new_trace_id
  end

  # --- guard ---------------------------------------------------------------

  def test_guard_returns_block_value_on_success
    assert_equal 42, Brainiac.guard(:Test, label: "ok") { 42 }
  end

  def test_guard_returns_fallback_on_error
    result = Brainiac.guard(:Test, label: "boom", fallback: :fell_back) { raise "nope" }
    assert_equal :fell_back, result
  end

  def test_guard_nil_fallback_by_default
    assert_nil Brainiac.guard(:Test, label: "boom") { raise "nope" }
  end

  def test_guard_invokes_on_error_with_exception
    captured = nil
    Brainiac.guard(:Test, label: "boom", on_error: ->(e) { captured = e }) { raise ArgumentError, "bad" }
    assert_instance_of ArgumentError, captured
    assert_equal "bad", captured.message
  end

  def test_guard_does_not_swallow_throw
    # Sinatra's halt uses throw, not raise — guard must let it propagate.
    result = catch(:halt) do
      Brainiac.guard(:Test, label: "halts") { throw :halt, :halted }
    end
    assert_equal :halted, result
  end

  # --- component logger ----------------------------------------------------

  def test_component_logger_memoized
    a = Brainiac.logger(:Widget)
    b = Brainiac.logger(:Widget)
    assert_same a, b
  end

  def test_component_logger_prefixes_output
    out = capture_log(:info) { Brainiac.logger(:Widget).info("hello") }
    assert_includes out, "[Widget] hello"
  end

  def test_component_logger_includes_trace_tag_when_active
    out = capture_log(:info) do
      Brainiac.with_trace("tr42") { Brainiac.logger(:Widget).info("hi") }
    end
    assert_includes out, "[Widget](tr42) hi"
  end

  def test_component_logger_exception_formats_class_and_message
    out = capture_log(:error) do
      raise ArgumentError, "bad arg"
    rescue ArgumentError => e
      Brainiac.logger(:Widget).exception(e, label: "doing thing")
    end
    assert_includes out, "[Widget] doing thing failed: ArgumentError: bad arg"
  end

  def test_logging_never_raises_even_if_log_broken
    # exercise the rescue in ComponentLogger#emit — should silently no-op
    Brainiac.logger(:Widget).info(nil)
  end

  private

  # Temporarily point LOG at a StringIO at the given level and capture output.
  def capture_log(level)
    io = StringIO.new
    original_logger = LOG.instance_variable_get(:@logdev)&.dev
    original_level = LOG.level
    LOG.reopen(io)
    LOG.level = Logger.const_get(level.to_s.upcase)
    yield
    io.string
  ensure
    LOG.reopen(original_logger || $stdout)
    LOG.level = original_level
  end
end
