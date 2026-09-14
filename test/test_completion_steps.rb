# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/session_history"

# Guards the completion-path regression where an unrescued exception in an early
# post-completion step (e.g. a notify path) silently aborted the whole sequence in the
# watcher thread — so durable session history was never archived. Each step now runs in
# isolation via completion_step; a failure in one must not prevent the others.
class TestCompletionSteps < Minitest::Test
  def setup
    FileUtils.rm_f(SESSION_HISTORY_FILE)
  end

  def teardown
    FileUtils.rm_f(SESSION_HISTORY_FILE)
  end

  def base_ctx
    {
      started_at: Time.now - 30,
      agent_name: "Sherlock",
      agent_config_name: "sherlock",
      source: :discord,
      source_context: { channel_id: "42" },
      log_file: File.join(TEST_BRAINIAC_DIR, "nope.log"),
      agent_cli: "kiro",
      model: "claude-sonnet-4.5",
      log_name: "sherlock-test",
      resolved: nil,
      chdir: nil
    }
  end

  def test_completion_step_swallows_and_isolates_failures
    ran = false
    completion_step("boom") { raise "kaboom" }
    completion_step("ok") { ran = true }
    assert ran, "a raising step must not prevent later steps from running"
  end

  def test_history_archived_even_when_earlier_step_raises
    # Force the notify step (which runs before archival) to blow up.
    original = method(:notify_no_output_if_needed)
    redefine_notify { |*, **| raise "notify blew up" }

    run_post_completion_steps(base_ctx, exit_status: 0, signaled: false, output_content: "done")

    assert File.exist?(SESSION_HISTORY_FILE), "session history must be archived despite an earlier step raising"
    record = JSON.parse(File.readlines(SESSION_HISTORY_FILE).last)
    assert_equal "Sherlock", record["agent"]
    assert_equal 0, record["exit_status"]
  ensure
    redefine_notify(&original)
  end

  def test_history_archived_on_normal_path
    run_post_completion_steps(base_ctx, exit_status: 0, signaled: false, output_content: "a real response")

    assert File.exist?(SESSION_HISTORY_FILE)
    assert_equal 1, File.readlines(SESSION_HISTORY_FILE).size
  end

  private

  # Redefine the top-level notify_no_output_if_needed (defined on Object) with the given
  # block. Passing an existing Method restores it. Warnings are suppressed to avoid
  # method-redefinition noise.
  def redefine_notify(&block)
    verbose = $VERBOSE
    $VERBOSE = nil
    Object.send(:define_method, :notify_no_output_if_needed, block)
    $VERBOSE = verbose
  end
end
