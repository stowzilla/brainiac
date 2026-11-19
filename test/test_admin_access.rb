# frozen_string_literal: true

require_relative "test_helper"

class TestAdminAccess < Minitest::Test
  LOCAL = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost:4567" }.freeze

  def setup
    SECURITY_ALERTS[:sent].clear
  end

  def test_direct_loopback_request_is_local
    assert local_request?(LOCAL)
    assert local_request?("REMOTE_ADDR" => "::1", "HTTP_HOST" => "[::1]:4567")
    assert local_request?("REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "127.0.0.1:4567")
  end

  def test_tunnel_request_is_not_local
    # ngrok and cloudflared connect from loopback and add forwarding headers.
    tunnel = { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "example.ngrok-free.dev", "HTTP_X_FORWARDED_FOR" => "203.0.113.9" }
    refute local_request?(tunnel)
    # Host rewritten to localhost by the tunnel still is not local.
    refute local_request?(LOCAL.merge("HTTP_X_FORWARDED_FOR" => "203.0.113.9"))
    refute local_request?(LOCAL.merge("HTTP_CF_CONNECTING_IP" => "203.0.113.9"))
  end

  def test_spoofed_host_is_not_local
    refute local_request?("REMOTE_ADDR" => "192.168.1.20", "HTTP_HOST" => "localhost:4567")
    refute local_request?("REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost.example.com")
    refute local_request?("REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "")
  end

  def test_local_request_needs_no_token
    assert_equal :ok, admin_access(LOCAL, nil, token: nil)
    assert_equal :ok, admin_access(LOCAL, nil, token: "secret")
  end

  def test_remote_request_is_refused_without_a_configured_token
    remote = LOCAL.merge("HTTP_X_FORWARDED_FOR" => "203.0.113.9")
    assert_equal :no_token, admin_access(remote, nil, token: nil)
    assert_equal :no_token, admin_access(remote, "", token: "")
    assert_equal :no_token, admin_access(remote, "anything", token: nil)
  end

  def test_remote_request_needs_the_right_token
    remote = LOCAL.merge("HTTP_X_FORWARDED_FOR" => "203.0.113.9")
    assert_equal :ok, admin_access(remote, "secret", token: "secret")
    assert_equal :bad_token, admin_access(remote, "wrong", token: "secret")
    assert_equal :bad_token, admin_access(remote, nil, token: "secret")
  end

  def test_request_origin_prefers_the_forwarded_client
    assert_equal "203.0.113.9", request_origin("REMOTE_ADDR" => "127.0.0.1", "HTTP_X_FORWARDED_FOR" => "203.0.113.9, 10.0.0.1")
    assert_equal "127.0.0.1", request_origin("REMOTE_ADDR" => "127.0.0.1")
  end

  def test_security_alert_is_rate_limited_per_kind
    assert security_alert("admin", "first", now: 1000)
    refute security_alert("admin", "second", now: 1100)
    assert security_alert("other", "different kind", now: 1100)
    assert security_alert("admin", "later", now: 1000 + SECURITY_ALERT_INTERVAL)
  end

  def test_notify_unauthorized_does_not_run_text_through_a_shell
    marker = File.join(TEST_BRAINIAC_DIR, "injected")
    notify_unauthorized("card_assigned", "x'; touch #{marker}; echo '", "card #1")
    refute File.exist?(marker)
  end
end
