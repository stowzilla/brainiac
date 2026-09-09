# frozen_string_literal: true

require_relative "test_helper"

# Tests for MultiIO and tee_foreground_output! (lib/brainiac/config.rb).
#
# MultiIO fans stdout/stderr writes out to multiple targets so foreground
# `brainiac server` output lands both on the terminal AND in a log file agents
# can read. These tests use StringIO targets so we can assert what each target
# received without touching real terminals or files.
class TestMultiIO < Minitest::Test
  def setup
    @a = StringIO.new
    @b = StringIO.new
    @io = MultiIO.new(@a, @b)
  end

  # --- write ---

  def test_write_fans_out_to_all_targets
    @io.write("hello")
    assert_equal "hello", @a.string
    assert_equal "hello", @b.string
  end

  def test_write_returns_last_targets_result
    # StringIO#write returns the number of bytes written.
    assert_equal 5, @io.write("hello")
  end

  def test_write_handles_multiple_args
    @io.write("foo", "bar")
    assert_equal "foobar", @a.string
    assert_equal "foobar", @b.string
  end

  # --- puts ---

  def test_puts_fans_out_to_all_targets
    @io.puts("line")
    assert_equal "line\n", @a.string
    assert_equal "line\n", @b.string
  end

  def test_puts_returns_nil_like_real_io
    assert_nil @io.puts("line")
  end

  def test_puts_with_no_args_writes_newline_to_all
    @io.puts
    assert_equal "\n", @a.string
    assert_equal "\n", @b.string
  end

  # --- print ---

  def test_print_fans_out_to_all_targets
    @io.print("a", "b")
    assert_equal "ab", @a.string
    assert_equal "ab", @b.string
  end

  def test_print_returns_nil_like_real_io
    assert_nil @io.print("x")
  end

  # --- printf ---

  def test_printf_fans_out_to_all_targets
    @io.printf("%<n>04d", n: 42)
    assert_equal "0042", @a.string
    assert_equal "0042", @b.string
  end

  def test_printf_returns_nil_like_real_io
    assert_nil @io.printf("%<n>d", n: 1)
  end

  # --- << ---

  def test_shovel_fans_out_to_all_targets
    @io << "chunk"
    assert_equal "chunk", @a.string
    assert_equal "chunk", @b.string
  end

  def test_shovel_returns_self_for_chaining
    result = @io << "one"
    assert_same @io, result
    # Chaining should append to all targets.
    result << "two"
    assert_equal "onetwo", @a.string
    assert_equal "onetwo", @b.string
  end

  # --- flush ---

  def test_flush_returns_self
    assert_same @io, @io.flush
  end

  def test_flush_calls_flush_on_flushable_targets
    flushed = []
    target = Object.new
    target.define_singleton_method(:flush) { flushed << :flushed }
    io = MultiIO.new(target)
    io.flush
    assert_equal [:flushed], flushed
  end

  def test_flush_skips_targets_without_flush
    # A target that does not respond to :flush must not raise.
    target = Object.new
    io = MultiIO.new(target)
    assert_same io, io.flush
  end

  # --- sync / sync= ---

  def test_sync_always_true
    assert_equal true, @io.sync
  end

  def test_sync_assignment_propagates_to_targets
    @io.sync = true
    # StringIO supports sync=; both targets should report the new value.
    assert_equal true, @a.sync
    assert_equal true, @b.sync
  end

  def test_sync_assignment_returns_value
    assert_equal false, (@io.sync = false)
  end

  def test_sync_assignment_skips_targets_without_setter
    target = Object.new # no sync= method
    io = MultiIO.new(target)
    # Should not raise even though target lacks sync=.
    assert_equal true, (io.sync = true)
  end

  # --- delegation (method_missing) ---

  def test_delegates_unknown_methods_to_first_target
    # StringIO responds to #string; MultiIO does not define it, so it should
    # delegate to the first target.
    @a.write("first")
    @b.write("second")
    assert_equal "first", @io.string
  end

  def test_respond_to_reflects_first_target_capabilities
    # First target (StringIO) responds to :string, so MultiIO should too.
    assert_respond_to @io, :string
    # And to something StringIO genuinely lacks.
    refute_respond_to @io, :this_method_does_not_exist_anywhere
  end

  def test_method_missing_raises_for_truly_unknown_method
    assert_raises(NoMethodError) { @io.definitely_not_a_real_method }
  end

  # --- ordering / target isolation ---

  def test_write_hits_targets_in_order
    order = []
    t1 = Object.new
    t1.define_singleton_method(:write) { |*_| order << :first }
    t2 = Object.new
    t2.define_singleton_method(:write) { |*_| order << :second }
    MultiIO.new(t1, t2).write("x")
    assert_equal %i[first second], order
  end

  def test_single_target_works
    io = MultiIO.new(@a)
    io.puts("solo")
    assert_equal "solo\n", @a.string
  end
end

# Tests for tee_foreground_output!, which reopens $stdout/$stderr through a
# MultiIO when BRAINIAC_FOREGROUND_LOG is set. These mutate global state, so
# each test carefully saves and restores $stdout/$stderr and the env var.
class TestTeeForegroundOutput < Minitest::Test
  def setup
    @orig_stdout = $stdout
    @orig_stderr = $stderr
    @orig_env = ENV.fetch("BRAINIAC_FOREGROUND_LOG", nil)
  end

  def teardown
    $stdout = @orig_stdout
    $stderr = @orig_stderr
    if @orig_env.nil?
      ENV.delete("BRAINIAC_FOREGROUND_LOG")
    else
      ENV["BRAINIAC_FOREGROUND_LOG"] = @orig_env
    end
  end

  def test_noop_when_env_unset
    ENV.delete("BRAINIAC_FOREGROUND_LOG")
    tee_foreground_output!
    # $stdout/$stderr should be untouched (not wrapped in MultiIO).
    assert_same @orig_stdout, $stdout
    assert_same @orig_stderr, $stderr
  end

  def test_noop_when_env_empty
    ENV["BRAINIAC_FOREGROUND_LOG"] = ""
    tee_foreground_output!
    assert_same @orig_stdout, $stdout
    assert_same @orig_stderr, $stderr
  end

  def test_wraps_stdout_and_stderr_when_env_set
    log_path = File.join(TEST_BRAINIAC_DIR, "tmp", "fg-#{rand(100_000)}.log")
    ENV["BRAINIAC_FOREGROUND_LOG"] = log_path

    tee_foreground_output!

    assert_instance_of MultiIO, $stdout
    assert_instance_of MultiIO, $stderr
  ensure
    FileUtils.rm_f(log_path)
  end

  def test_stdout_writes_land_in_log_file
    log_path = File.join(TEST_BRAINIAC_DIR, "tmp", "fg-#{rand(100_000)}.log")
    ENV["BRAINIAC_FOREGROUND_LOG"] = log_path

    # Silence the terminal half by pointing the "real" stdout at a StringIO.
    fake_terminal = StringIO.new
    $stdout = fake_terminal
    tee_foreground_output!

    $stdout.puts "server started"
    $stdout.flush

    assert_equal "server started\n", File.read(log_path)
    # And the terminal half still received it too.
    assert_equal "server started\n", fake_terminal.string
  ensure
    FileUtils.rm_f(log_path)
  end

  def test_creates_log_directory_if_missing
    nested = File.join(TEST_BRAINIAC_DIR, "tmp", "does-not-exist-#{rand(100_000)}", "server.log")
    refute Dir.exist?(File.dirname(nested))
    ENV["BRAINIAC_FOREGROUND_LOG"] = nested

    $stdout = StringIO.new # silence the terminal half
    tee_foreground_output!
    $stdout.puts "boot"
    $stdout.flush

    assert File.exist?(nested)
    assert_includes File.read(nested), "boot"
  ensure
    FileUtils.rm_rf(File.dirname(nested))
  end

  def test_appends_rather_than_truncates
    log_path = File.join(TEST_BRAINIAC_DIR, "tmp", "fg-append-#{rand(100_000)}.log")
    File.write(log_path, "existing line\n")
    ENV["BRAINIAC_FOREGROUND_LOG"] = log_path

    $stdout = StringIO.new
    tee_foreground_output!
    $stdout.puts "new line"
    $stdout.flush

    contents = File.read(log_path)
    assert_includes contents, "existing line"
    assert_includes contents, "new line"
  ensure
    FileUtils.rm_f(log_path)
  end

  def test_failsafe_leaves_stdout_usable_on_error
    # Point the log at a path that cannot be created (a file where a directory
    # is expected), forcing File.open to fail. tee_foreground_output! should
    # rescue, warn, and leave $stdout as the original working IO.
    blocker = File.join(TEST_BRAINIAC_DIR, "tmp", "blocker-#{rand(100_000)}")
    FileUtils.mkdir_p(File.dirname(blocker))
    File.write(blocker, "i am a file, not a directory")
    bad_path = File.join(blocker, "server.log")
    ENV["BRAINIAC_FOREGROUND_LOG"] = bad_path

    # Capture the warning so it doesn't pollute test output.
    original_stderr = $stderr
    $stderr = StringIO.new

    begin
      tee_foreground_output!
    ensure
      warn_output = $stderr.string
      $stderr = original_stderr
    end

    # On failure, $stdout must remain a real, writable IO (not a broken MultiIO).
    refute_instance_of MultiIO, $stdout
    assert_match(/Could not tee foreground output/, warn_output)
  ensure
    FileUtils.rm_f(blocker)
  end
end
