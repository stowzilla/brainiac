# frozen_string_literal: true

require_relative "test_helper"

class TestStall < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("stall-test")
    ACTIVE_SESSIONS_MUTEX.synchronize { ACTIVE_SESSIONS.clear }
  end

  def teardown
    FileUtils.rm_rf(@dir)
    ACTIVE_SESSIONS_MUTEX.synchronize { ACTIVE_SESSIONS.clear }
  end

  # --- pure classifier -----------------------------------------------------

  def classify(idle:, warned: false, warn: 600, kill: 0)
    Brainiac::Stall.classify(idle_seconds: idle, warned: warned, warn_seconds: warn, kill_seconds: kill)
  end

  def test_ok_when_not_idle_long_enough
    assert_equal :ok, classify(idle: 60)
    assert_equal :ok, classify(idle: 599)
  end

  def test_ok_when_idle_unknown
    assert_equal :ok, classify(idle: nil)
  end

  def test_warn_on_first_stall
    assert_equal :warn, classify(idle: 600)
    assert_equal :warn, classify(idle: 1200)
  end

  def test_waiting_after_already_warned
    assert_equal :waiting, classify(idle: 1200, warned: true)
  end

  def test_kill_when_cap_enabled_and_exceeded
    assert_equal :kill, classify(idle: 2000, warned: true, kill: 1800)
    assert_equal :kill, classify(idle: 2000, warned: false, kill: 1800)
  end

  def test_no_kill_when_cap_disabled
    assert_equal :waiting, classify(idle: 999_999, warned: true, kill: 0)
  end

  def test_kill_takes_precedence_over_warn
    # crossed both thresholds, never warned → kill wins
    assert_equal :kill, classify(idle: 2000, warned: false, warn: 600, kill: 1800)
  end

  # --- idle_seconds --------------------------------------------------------

  def test_idle_seconds_from_mtime
    log = File.join(@dir, "s.log")
    File.write(log, "x")
    File.utime(Time.now - 300, Time.now - 300, log)
    idle = Brainiac::Stall.idle_seconds(log, now: Time.now)
    assert_in_delta 300, idle, 2
  end

  def test_idle_seconds_nil_for_missing
    assert_nil Brainiac::Stall.idle_seconds(File.join(@dir, "nope.log"))
    assert_nil Brainiac::Stall.idle_seconds(nil)
  end

  # --- config --------------------------------------------------------------

  def test_config_defaults
    cfg = Brainiac::Stall.config
    assert_operator cfg[:warn_seconds], :>, 0
    assert_operator cfg[:poll_seconds], :>=, 5
  end

  def test_config_env_override
    ENV["BRAINIAC_STALL_WARN"] = "120"
    ENV["BRAINIAC_STALL_KILL"] = "900"
    assert_equal 120, Brainiac::Stall.config[:warn_seconds]
    assert_equal 900, Brainiac::Stall.config[:kill_seconds]
  ensure
    ENV.delete("BRAINIAC_STALL_WARN")
    ENV.delete("BRAINIAC_STALL_KILL")
  end

  def test_config_poll_clamped
    ENV["BRAINIAC_STALL_POLL"] = "1"
    assert_equal 5, Brainiac::Stall.config[:poll_seconds] # clamped to min 5
  ensure
    ENV.delete("BRAINIAC_STALL_POLL")
  end

  # --- scan_stalls! behavior ----------------------------------------------

  def stale_session(card_key, idle_age)
    log = File.join(@dir, "#{card_key}.log")
    File.write(log, "working…")
    File.utime(Time.now - idle_age, Time.now - idle_age, log)
    ACTIVE_SESSIONS_MUTEX.synchronize do
      ACTIVE_SESSIONS[card_key] = { pid: 999_999, started_at: Time.now - idle_age,
                                    log_file: log, channel_id: "chan-1", agent_name: "Avon" }
    end
    log
  end

  def test_scan_warns_stalled_session_once
    stale_session("discord-1", 700)
    notified = []
    notify = ->(ck, _info, idle, killed: false) { notified << [ck, idle, killed] }
    killer = ->(_ck) { flunk "should not kill when cap disabled" }

    first = scan_stalls!(warn_seconds: 600, kill_seconds: 0, notify: notify, kill: killer)
    assert_equal 1, first.size
    assert_equal :warned, first.first[:action]
    assert_equal 1, notified.size

    # second scan: already warned → no repeat notification
    second = scan_stalls!(warn_seconds: 600, kill_seconds: 0, notify: notify, kill: killer)
    assert_empty second
    assert_equal 1, notified.size, "must not re-warn the same stalled session"
  end

  def test_scan_does_not_warn_healthy_session
    stale_session("discord-2", 10) # fresh log
    notified = []
    actions = scan_stalls!(warn_seconds: 600, kill_seconds: 0,
                           notify: ->(*a, **k) { notified << [a, k] }, kill: ->(_) {})
    assert_empty actions
    assert_empty notified
  end

  def test_scan_kills_at_hard_cap
    stale_session("discord-3", 2000)
    killed = []
    notified = []
    scan_stalls!(warn_seconds: 600, kill_seconds: 1800,
                 notify: ->(ck, _i, _idle, killed: false) { notified << [ck, killed] },
                 kill: ->(ck) { killed << ck })
    assert_equal ["discord-3"], killed
    assert(notified.any? { |_ck, k| k == true }, "kill notification must flag killed: true")
  end

  def test_scan_handles_missing_log_gracefully
    ACTIVE_SESSIONS_MUTEX.synchronize do
      ACTIVE_SESSIONS["discord-4"] = { pid: 999_999, started_at: Time.now,
                                       log_file: File.join(@dir, "gone.log"), channel_id: "c", agent_name: "A" }
    end
    actions = scan_stalls!(warn_seconds: 600, kill_seconds: 0, notify: ->(*) {}, kill: ->(*) {})
    assert_empty actions # unknown idle → :ok, no action
  end
end
