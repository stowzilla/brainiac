# frozen_string_literal: true

require_relative "test_helper"

class TestModelRouter < Minitest::Test
  def setup
    # Must require model_router AFTER test_helper sets up the environment
    require_relative "../lib/brainiac/model_router"
    # Ensure clean state
    clear_model_router_cache!
  end

  def teardown
    clear_model_router_cache!
  end

  def with_fake_typesafe(status:, body:)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    thread = Thread.new do
      loop do
        client = server.accept
        request = ""
        loop do
          line = client.gets
          break if line.nil? || line.strip.empty?

          request += line
        end
        # Read request body if present
        _body = client.read(::Regexp.last_match(1).to_i) if request =~ /Content-Length: (\d+)/i
        client.print "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
        client.close
      rescue IOError
        break
      end
    end

    yield "http://127.0.0.1:#{port}/v1/systemone"
  ensure
    thread&.kill
    server&.close
  end

  def test_model_router_config_returns_defaults
    BRAINIAC_CONFIG.delete("model_router")
    config = model_router_config
    assert_equal false, config["enabled"]
    assert_equal "https://api.typesafe.ai/v1/systemone", config["typesafe_endpoint"]
    assert_equal "jev-latest", config["typesafe_model"]
    assert_equal 5, config["timeout"]
    assert_equal 300, config["cache_ttl"]
    assert_equal 0.4, config["min_confidence"]
    assert_equal %w[haiku sonnet], config["model_tiers"]["simple"]
  end

  def test_model_router_enabled_returns_false_when_disabled
    BRAINIAC_CONFIG["model_router"] = { "enabled" => false }
    refute model_router_enabled?
  end

  def test_model_router_enabled_returns_false_without_api_key
    BRAINIAC_CONFIG["model_router"] = { "enabled" => true }
    refute model_router_enabled?
  end

  def test_model_router_enabled_returns_true_with_valid_config
    BRAINIAC_CONFIG["model_router"] = { "enabled" => true, "typesafe_api_key" => "ts_test_key_123" }
    assert model_router_enabled?
  end

  def test_select_model_for_complexity_simple
    allowed = { "haiku" => "claude-haiku-4.5", "sonnet" => "claude-sonnet-4.6", "opus" => "claude-opus-4.5" }
    tiers = { "simple" => %w[haiku sonnet], "moderate" => %w[sonnet opus], "complex" => %w[opus] }

    result = select_model_for_complexity("simple", allowed, tiers)
    assert_equal "haiku", result
  end

  def test_select_model_for_complexity_simple_fallback
    # No haiku available — should fall back to sonnet
    allowed = { "sonnet" => "claude-sonnet-4.6", "opus" => "claude-opus-4.5" }
    tiers = { "simple" => %w[haiku sonnet], "moderate" => %w[sonnet opus], "complex" => %w[opus] }

    result = select_model_for_complexity("simple", allowed, tiers)
    assert_equal "sonnet", result
  end

  def test_select_model_for_complexity_complex
    allowed = { "haiku" => "claude-haiku-4.5", "sonnet" => "claude-sonnet-4.6", "opus" => "claude-opus-4.5" }
    tiers = { "simple" => %w[haiku sonnet], "moderate" => %w[sonnet opus], "complex" => %w[opus] }

    result = select_model_for_complexity("complex", allowed, tiers)
    assert_equal "opus", result
  end

  def test_select_model_for_complexity_returns_nil_when_no_tier_models_available
    allowed = { "deepseek" => "deepseek-3.2" }
    tiers = { "simple" => %w[haiku sonnet], "moderate" => %w[sonnet opus], "complex" => %w[opus] }

    result = select_model_for_complexity("simple", allowed, tiers)
    assert_nil result
  end

  def test_cache_operations
    cache_key = "discord:thread123"

    # Initially empty
    assert_nil check_router_cache(cache_key, 300)

    # Add entry
    update_router_cache(cache_key, complexity: "moderate", model: "sonnet")

    # Should be found
    cached = check_router_cache(cache_key, 300)
    assert_equal "moderate", cached[:complexity]
    assert_equal "sonnet", cached[:model]

    # Clear and verify empty
    clear_model_router_cache!
    assert_nil check_router_cache(cache_key, 300)
  end

  def test_cache_respects_ttl
    cache_key = "discord:thread456"
    update_router_cache(cache_key, complexity: "simple", model: "haiku")

    # With long TTL, should be found
    refute_nil check_router_cache(cache_key, 300)

    # With 0 TTL, should be expired
    assert_nil check_router_cache(cache_key, 0)
  end

  def test_select_model_via_jev_returns_nil_when_disabled
    BRAINIAC_CONFIG["model_router"] = { "enabled" => false }
    allowed = { "haiku" => "claude-haiku-4.5", "opus" => "claude-opus-4.5" }

    result = select_model_via_jev("test message", allowed_models: allowed)
    assert_nil result
  end

  def test_select_model_via_jev_returns_nil_for_empty_allowed_models
    BRAINIAC_CONFIG["model_router"] = { "enabled" => true, "typesafe_api_key" => "ts_test" }

    result = select_model_via_jev("test message", allowed_models: {})
    assert_nil result
  end

  def test_select_model_via_jev_with_successful_api_response
    response_body = JSON.generate({
                                    "model" => "jev-1.13.0",
                                    "answers" => {
                                      "complexity" => {
                                        "type" => "choice",
                                        "choice" => "complex",
                                        "probabilities" => { "simple" => 0.05, "moderate" => 0.15, "complex" => 0.8 },
                                        "confidence" => 0.75
                                      }
                                    },
                                    "usage" => { "input_tokens" => 100, "output_tokens" => 20 }
                                  })

    with_fake_typesafe(status: 200, body: response_body) do |endpoint|
      BRAINIAC_CONFIG["model_router"] = {
        "enabled" => true,
        "typesafe_api_key" => "ts_test_key",
        "typesafe_endpoint" => endpoint,
        "min_confidence" => 0.5
      }

      allowed = { "haiku" => "claude-haiku-4.5", "sonnet" => "claude-sonnet-4.6", "opus" => "claude-opus-4.5" }
      result = select_model_via_jev("Design a new microservice architecture for handling payments", allowed_models: allowed)

      assert_equal "opus", result
    end
  end

  def test_select_model_via_jev_returns_nil_on_low_confidence
    response_body = JSON.generate({
                                    "model" => "jev-1.13.0",
                                    "answers" => {
                                      "complexity" => {
                                        "type" => "choice",
                                        "choice" => "complex",
                                        "probabilities" => { "simple" => 0.35, "moderate" => 0.35, "complex" => 0.3 },
                                        "confidence" => 0.25
                                      }
                                    }
                                  })

    with_fake_typesafe(status: 200, body: response_body) do |endpoint|
      BRAINIAC_CONFIG["model_router"] = {
        "enabled" => true,
        "typesafe_api_key" => "ts_test_key",
        "typesafe_endpoint" => endpoint,
        "min_confidence" => 0.4
      }

      allowed = { "haiku" => "claude-haiku-4.5", "opus" => "claude-opus-4.5" }
      result = select_model_via_jev("maybe do something?", allowed_models: allowed)

      # Low confidence → returns nil (use default)
      assert_nil result
    end
  end

  def test_select_model_via_jev_fails_open_on_api_error
    BRAINIAC_CONFIG["model_router"] = {
      "enabled" => true,
      "typesafe_api_key" => "ts_test_key",
      "typesafe_endpoint" => "http://127.0.0.1:12345/nonexistent"
    }

    allowed = { "haiku" => "claude-haiku-4.5", "opus" => "claude-opus-4.5" }
    result = select_model_via_jev("test message", allowed_models: allowed)

    # Should fail open → returns nil (use default)
    assert_nil result
  end

  def test_select_model_via_jev_uses_cache
    cache_key = "discord:cached_thread"
    update_router_cache(cache_key, complexity: "simple", model: "haiku")

    BRAINIAC_CONFIG["model_router"] = {
      "enabled" => true,
      "typesafe_api_key" => "ts_test_key",
      # No endpoint needed — should use cache
      "typesafe_endpoint" => "http://127.0.0.1:12345/should_not_be_called"
    }

    allowed = { "haiku" => "claude-haiku-4.5", "opus" => "claude-opus-4.5" }
    result = select_model_via_jev("cached message", allowed_models: allowed, channel: :discord, context_id: "cached_thread")

    # Should return cached value without calling API
    assert_equal "haiku", result
  end

  def test_resolve_typesafe_api_key_with_literal_key
    config = { "typesafe_api_key" => "ts_abc123" }
    result = resolve_typesafe_api_key(config)
    assert_equal "ts_abc123", result
  end

  def test_resolve_typesafe_api_key_with_nil
    config = {}
    result = resolve_typesafe_api_key(config)
    assert_nil result
  end

  def test_model_router_questions_structure
    # Verify the questions structure is valid for TypeSafe API
    assert_equal "choice", MODEL_ROUTER_QUESTIONS["complexity"]["type"]
    assert_includes MODEL_ROUTER_QUESTIONS["complexity"]["criteria"].keys, "simple"
    assert_includes MODEL_ROUTER_QUESTIONS["complexity"]["criteria"].keys, "moderate"
    assert_includes MODEL_ROUTER_QUESTIONS["complexity"]["criteria"].keys, "complex"
  end
end
