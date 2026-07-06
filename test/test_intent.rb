# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/intent"

class TestIntent < Minitest::Test
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
end
