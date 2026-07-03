# frozen_string_literal: true

require_relative "test_helper"

class TestNotifications < Minitest::Test
  def setup
    # Write a brainiac.json with notification config for tests
    @brainiac_config_file = File.join(TEST_BRAINIAC_DIR, "brainiac.json")
    config = {
      "default_agent" => "Galen",
      "notifications" => {
        "deploy" => { "channel" => "discord", "target" => "channel-123" },
        "restart" => { "channel" => "discord", "target" => "channel-456" },
        "default" => { "channel" => "discord", "target" => "channel-default" }
      }
    }
    File.write(@brainiac_config_file, JSON.generate(config))
    Brainiac.reset_hooks!
  end

  def test_notification_config_for_known_event
    config = notification_config_for(:deploy)
    assert_equal "discord", config["channel"]
    assert_equal "channel-123", config["target"]
  end

  def test_notification_config_for_unknown_event_uses_default
    config = notification_config_for(:unknown_event)
    assert_equal "discord", config["channel"]
    assert_equal "channel-default", config["target"]
  end

  def test_notification_config_missing_returns_empty
    File.write(@brainiac_config_file, JSON.generate({}))
    config = notification_config_for(:deploy)
    assert_equal({}, config)
  end

  def test_send_notification_emits_hook
    received = nil
    Brainiac.on(:notify) do |ctx|
      received = ctx
      :handled
    end

    result = send_notification(:deploy, "test message", channel: :discord, target: "ch-1")
    assert result
    assert_equal :deploy, received[:event]
    assert_equal :discord, received[:channel]
    assert_equal "ch-1", received[:target]
    assert_equal "test message", received[:message]
  end

  def test_send_notification_returns_false_without_handler
    result = send_notification(:deploy, "test message", channel: :discord, target: "ch-1")
    refute result
  end

  def test_send_notification_returns_false_without_target
    result = send_notification(:unknown, "test message")
    refute result
  end

  def test_send_notification_uses_config_when_no_explicit_channel
    Brainiac.on(:notify) { |_ctx| :handled }
    result = send_notification(:deploy, "deployed!")
    assert result
  end

  def test_notify_restart_convenience
    received = nil
    Brainiac.on(:notify) do |ctx|
      received = ctx
      :handled
    end
    notify_restart("back online")
    assert_equal :restart, received[:event]
    assert_equal "back online", received[:message]
  end
end
