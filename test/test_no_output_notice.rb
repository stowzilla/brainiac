# frozen_string_literal: true

require_relative "test_helper"

# Tests for the "clean exit but no response" detection + notification path.
# Covers the case where a CLI (e.g. kiro-cli) prints a request/usage-limit notice and
# exits 0 without producing an answer — which the crash path (non-zero only) misses.
class TestNoOutputNotice < Minitest::Test
  def setup
    @log_dir = Dir.mktmpdir("no-output-test")
    @log_file = File.join(@log_dir, "agent.log")
  end

  def teardown
    FileUtils.rm_rf(@log_dir)
  end

  def write_log(content)
    File.write(@log_file, content)
  end

  # --- detect_no_output_reason ---

  def test_detects_monthly_request_limit
    write_log(<<~LOG)
      All tools are now trusted (!). Kiro will execute tools without asking for confirmation.
      ------
      Monthly request limit reached
      The limits reset on 10/01. Contact your administrator for account management.
       ▸ Time: 0s
    LOG
    reason = detect_no_output_reason(@log_file, nil)
    refute_nil reason
    assert_match(%r{request/usage limit}i, reason)
    assert_match(/monthly request limit reached/i, reason)
  end

  def test_detects_generic_rate_limit
    write_log("Error: rate limited, please try again later\n")
    reason = detect_no_output_reason(@log_file, nil)
    assert_match(%r{request/usage limit}i, reason)
  end

  def test_flags_empty_boilerplate_only_log_as_no_response
    write_log(<<~LOG)
      One or more mcp server did not load correctly. See log for details.
      ------
      All tools are now trusted (!). Kiro will execute tools without asking for confirmation.
      Agents can sometimes do unexpected things so understand the risks.
      Learn more at https://kiro.dev/docs/cli/chat/security/
       ▸ Time: 0s
    LOG
    reason = detect_no_output_reason(@log_file, nil)
    refute_nil reason
    assert_match(/no response/i, reason)
  end

  def test_returns_nil_when_output_content_present
    write_log("Monthly request limit reached\n")
    # Even if the log looks limited, a captured structured response means we DID respond.
    assert_nil detect_no_output_reason(@log_file, "Here is the answer you asked for.")
  end

  def test_returns_nil_when_log_has_real_agent_output
    write_log(<<~LOG)
      All tools are now trusted (!).
      ------
      I've reviewed the code and made the requested change to the parser.
      The build passes and tests are green.
       ▸ Time: 12s
    LOG
    assert_nil detect_no_output_reason(@log_file, nil)
  end

  def test_returns_nil_when_log_missing
    assert_nil detect_no_output_reason(File.join(@log_dir, "does-not-exist.log"), nil)
  end

  # --- notify_no_output_if_needed (gating) ---

  def test_notify_fires_agent_crashed_hook_with_no_output_flag
    write_log("Monthly request limit reached\n")
    captured = nil
    Brainiac.on(:agent_crashed) do |ctx|
      captured = ctx
      true
    end

    ctx = {
      source: :discord, log_file: @log_file, agent_name: "Galen",
      source_context: { channel_id: "123" }, project_config: {}
    }
    notify_no_output_if_needed(ctx, exit_status: 0, signaled: false, output_content: nil)

    refute_nil captured, "expected :agent_crashed to be emitted"
    assert_equal true, captured[:no_output]
    assert_match(%r{request/usage limit}i, captured[:no_output_reason])
    assert_equal :discord, captured[:source]
    assert_equal 0, captured[:exit_status]
  ensure
    Brainiac.reset_hooks!
  end

  def test_notify_skipped_when_no_source
    fired = false
    Brainiac.on(:agent_crashed) { |_ctx| fired = true }
    ctx = { source: nil, log_file: @log_file }
    notify_no_output_if_needed(ctx, exit_status: 0, signaled: false, output_content: nil)
    refute fired
  ensure
    Brainiac.reset_hooks!
  end

  def test_notify_skipped_on_nonzero_exit
    write_log("Monthly request limit reached\n")
    fired = false
    Brainiac.on(:agent_crashed) { |_ctx| fired = true }
    ctx = { source: :discord, log_file: @log_file, source_context: {} }
    notify_no_output_if_needed(ctx, exit_status: 1, signaled: false, output_content: nil)
    refute fired, "non-zero exits go through the crash path, not the no-output path"
  ensure
    Brainiac.reset_hooks!
  end

  def test_notify_skipped_when_output_present
    write_log("Monthly request limit reached\n")
    fired = false
    Brainiac.on(:agent_crashed) { |_ctx| fired = true }
    ctx = { source: :discord, log_file: @log_file, source_context: {} }
    notify_no_output_if_needed(ctx, exit_status: 0, signaled: false, output_content: "a real answer")
    refute fired
  ensure
    Brainiac.reset_hooks!
  end

  def test_notify_skipped_when_signaled
    write_log("Monthly request limit reached\n")
    fired = false
    Brainiac.on(:agent_crashed) { |_ctx| fired = true }
    ctx = { source: :discord, log_file: @log_file, source_context: {} }
    notify_no_output_if_needed(ctx, exit_status: 0, signaled: true, output_content: nil)
    refute fired
  ensure
    Brainiac.reset_hooks!
  end
end
