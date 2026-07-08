# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/intent"
require "socket"

class TestIntent < Minitest::Test
  def with_fake_ollama(status:, body:)
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]

    thread = Thread.new do
      loop do
        client = server.accept
        _line = client.gets while (line = client.gets) && line.strip != ""
        client.print "HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nConnection: close\r\nContent-Length: #{body.bytesize}\r\n\r\n#{body}"
        client.close
      rescue IOError
        break
      end
    end

    yield "http://127.0.0.1:#{port}/api/generate"
  ensure
    thread&.kill
    server&.close
  end

  def test_check_intent_returns_true_when_disabled
    # Default config has enabled: false, so it should always return true (pass-through)
    assert check_intent("hey Sherlock do the thing", agent_name: "Sherlock")
  end

  def test_check_intent_returns_true_for_nil_message
    assert check_intent(nil, agent_name: "Sherlock")
  end

  def test_check_intent_returns_true_for_empty_message
    assert check_intent("", agent_name: "Sherlock")
    assert check_intent("   ", agent_name: "Sherlock")
  end

  def test_parse_intent_response_yes
    assert positive_intent?("yes")
    assert positive_intent?("Yes")
    assert positive_intent?("YES")
    assert positive_intent?(" yes ")
    assert positive_intent?("yes.")
  end

  def test_parse_intent_response_no
    refute positive_intent?("no")
    refute positive_intent?("No")
    refute positive_intent?("NO")
    refute positive_intent?(" no ")
    refute positive_intent?("no.")
  end

  def test_parse_intent_response_ambiguous_defaults_to_true
    # Fail-open: anything that isn't clearly "no" should return true
    assert positive_intent?("maybe")
    assert positive_intent?("I think yes")
    assert positive_intent?("probably")
    assert positive_intent?("")
  end

  def test_intent_config_returns_defaults
    config = intent_config
    assert_equal false, config["enabled"]
    assert_equal "http://localhost:11434/api/generate", config["endpoint"]
    assert_equal "gemma3:4b", config["model"]
    assert_equal 10, config["timeout"]
    assert_equal 0.1, config["temperature"]
  end

  def test_intent_prompt_template_interpolation
    prompt = INTENT_PROMPT_TEMPLATE
             .gsub("{{AGENT_NAME}}", "Galen")
             .gsub("{{CHANNEL}}", "Discord thread")
             .gsub("{{MESSAGE}}", "hey do the thing")
    assert_includes prompt, "Galen"
    assert_includes prompt, "Discord thread"
    assert_includes prompt, "hey do the thing"
  end

  def test_check_intent_with_enabled_config_and_connection_refused
    # Mutates BRAINIAC_CONFIG directly — safe because Style/MutableConstant is disabled
    # project-wide and the ensure block restores the original value.
    original = BRAINIAC_CONFIG.dup
    BRAINIAC_CONFIG["intent"] = { "enabled" => true, "endpoint" => "http://localhost:99999/api/generate", "timeout" => 1 }

    # Should fail-open (return true) when Ollama is not reachable
    result = check_intent("do the thing", agent_name: "Sherlock", channel: "Discord thread")
    assert result, "Should fail-open when LLM is unreachable"
  ensure
    BRAINIAC_CONFIG.replace(original)
  end

  def test_channel_parameter_passed_through
    prompt = INTENT_PROMPT_TEMPLATE
             .gsub("{{AGENT_NAME}}", "Robin")
             .gsub("{{CHANNEL}}", "Fizzy card comment")
             .gsub("{{MESSAGE}}", "test")
    assert_includes prompt, "Fizzy card comment"
    assert_includes prompt, "Robin"
  end

  # --- Pending work detection ---

  def test_check_pending_work_returns_false_when_disabled
    # Default config has enabled: false, so it should return false (no re-dispatch)
    refute check_pending_work("I'll implement this — give me a sec.", agent_name: "Sherlock")
  end

  def test_check_pending_work_returns_false_for_nil_message
    refute check_pending_work(nil, agent_name: "Sherlock")
  end

  def test_check_pending_work_returns_false_for_empty_message
    refute check_pending_work("", agent_name: "Sherlock")
    refute check_pending_work("   ", agent_name: "Sherlock")
  end

  def test_pending_work_detected_yes
    assert pending_work_detected?("yes")
    assert pending_work_detected?("Yes")
    assert pending_work_detected?("YES")
    assert pending_work_detected?(" yes ")
    assert pending_work_detected?("yes.")
  end

  def test_pending_work_detected_no
    refute pending_work_detected?("no")
    refute pending_work_detected?("No")
    refute pending_work_detected?("NO")
    refute pending_work_detected?(" no ")
    refute pending_work_detected?("no.")
  end

  def test_pending_work_detected_ambiguous_defaults_to_false
    # Fail-closed: anything that isn't clearly "yes" should return false
    refute pending_work_detected?("maybe")
    refute pending_work_detected?("I think so")
    refute pending_work_detected?("probably")
    refute pending_work_detected?("")
  end

  def test_check_pending_work_with_enabled_config_and_connection_refused
    # Mutates BRAINIAC_CONFIG directly — safe because Style/MutableConstant is disabled
    # project-wide and the ensure block restores the original value.
    original = BRAINIAC_CONFIG.dup
    BRAINIAC_CONFIG["intent"] = { "enabled" => true, "endpoint" => "http://localhost:99999/api/generate", "timeout" => 1 }

    # Should fail-closed (return false) when Ollama is not reachable
    result = check_pending_work("I'll do that now, give me a sec.", agent_name: "Sherlock")
    refute result, "Should fail-closed when LLM is unreachable"
  ensure
    BRAINIAC_CONFIG.replace(original)
  end

  def test_pending_work_prompt_template_interpolation
    prompt = PENDING_WORK_PROMPT_TEMPLATE
             .gsub("{{AGENT_NAME}}", "Galen")
             .gsub("{{MESSAGE}}", "I'll implement this — one-liner change")
    assert_includes prompt, "Galen"
    assert_includes prompt, "I'll implement this — one-liner change"
  end

  # --- Model validation ---

  def test_ollama_model_not_found_error_includes_install_instructions
    error = OllamaModelNotFoundError.new("qwen3:4b", "http://localhost:11434/api/generate")
    assert_includes error.message, "ollama pull qwen3:4b"
    assert_includes error.message, "~/.brainiac/brainiac.json"
    assert_includes error.message, "ollama list"
    assert_equal "qwen3:4b", error.model_name
    assert_equal "http://localhost:11434/api/generate", error.endpoint
  end

  def test_validate_intent_model_raises_when_ollama_not_running
    config = intent_config.merge("enabled" => true, "endpoint" => "http://localhost:99999/api/generate")
    error = assert_raises(RuntimeError) { validate_intent_model!(config) }
    assert_includes error.message, "Ollama is not running"
    assert_includes error.message, "ollama serve"
  end

  def test_validate_intent_model_raises_for_missing_model
    with_fake_ollama(status: "404 Not Found", body: '{"error":"model \'nonexistent:1b\' not found"}') do |endpoint|
      config = intent_config.merge("enabled" => true, "endpoint" => endpoint, "model" => "nonexistent:1b")
      error = assert_raises(OllamaModelNotFoundError) { validate_intent_model!(config) }
      assert_includes error.message, "ollama pull nonexistent:1b"
      assert_includes error.message, "~/.brainiac/brainiac.json"
    end
  end

  def test_check_intent_disables_intent_on_model_not_found
    with_fake_ollama(status: "404 Not Found", body: '{"error":"model \'nonexistent:1b\' not found"}') do |endpoint|
      original = BRAINIAC_CONFIG.dup
      BRAINIAC_CONFIG["intent"] = { "enabled" => true, "endpoint" => endpoint, "model" => "nonexistent:1b", "timeout" => 2 }

      result = check_intent("do the thing", agent_name: "Sherlock", channel: "test")

      # Should fail-open (return true)
      assert result, "Should fail-open when model is not found"
      # Should disable intent in config to prevent repeated errors
      refute BRAINIAC_CONFIG.dig("intent", "enabled"), "Intent should be disabled after model-not-found"
    ensure
      BRAINIAC_CONFIG.replace(original)
    end
  end
end
