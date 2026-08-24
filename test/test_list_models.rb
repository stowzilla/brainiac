# frozen_string_literal: true

require_relative "test_helper"

class TestListModels < Minitest::Test
  def setup
    @providers_dir = File.join(TEST_BRAINIAC_DIR, "cli-providers")
    FileUtils.mkdir_p(@providers_dir)
  end

  def test_load_cli_provider_includes_list_models_command
    provider_data = {
      "binary" => "kiro-cli",
      "default_args" => "chat --no-interactive",
      "model_flag" => "--model",
      "list_models_command" => "kiro-cli chat --list-models --format json",
      "models" => { "auto" => "auto" }
    }
    File.write(File.join(@providers_dir, "test-provider.json"), JSON.generate(provider_data))

    config = load_cli_provider("test-provider")
    assert_equal "kiro-cli chat --list-models --format json", config["list_models_command"]
  end

  def test_load_cli_provider_omits_empty_list_models_command
    provider_data = {
      "binary" => "kiro-cli",
      "default_args" => "chat --no-interactive",
      "model_flag" => "--model",
      "list_models_command" => "",
      "models" => { "auto" => "auto" }
    }
    File.write(File.join(@providers_dir, "no-cmd.json"), JSON.generate(provider_data))

    config = load_cli_provider("no-cmd")
    refute config.key?("list_models_command")
  end

  def test_load_cli_provider_omits_nil_list_models_command
    provider_data = {
      "binary" => "kiro-cli",
      "default_args" => "chat --no-interactive",
      "model_flag" => "--model",
      "models" => { "auto" => "auto" }
    }
    File.write(File.join(@providers_dir, "nil-cmd.json"), JSON.generate(provider_data))

    config = load_cli_provider("nil-cmd")
    refute config.key?("list_models_command")
  end

  def test_parse_list_models_output_json_format
    json_output = <<~JSON
      {"models":[{"model_name":"auto","description":"Auto-select","model_id":"auto","rate_multiplier":1.0},{"model_name":"claude-sonnet-4.6","description":"Sonnet 4.6","model_id":"claude-sonnet-4.6","rate_multiplier":1.3}],"default_model":"auto"}
    JSON

    models = parse_list_models_output(json_output)
    assert_equal 2, models.size
    assert_equal "auto", models[0]["model_id"]
    assert_equal "claude-sonnet-4.6", models[1]["model_id"]
    assert_equal "Sonnet 4.6", models[1]["description"]
  end

  def test_parse_list_models_output_json_with_preceding_text
    # kiro-cli outputs an error line before the JSON when --format json is used without --output
    mixed_output = <<~OUTPUT
      error: unexpected argument '--output' found

        tip: to pass '--output' as a value, use '-- --output'

      Usage: kiro-cli-chat chat --list-models [INPUT]

      For more information, try '--help'.
      {"models":[{"model_name":"auto","description":"Auto","model_id":"auto","rate_multiplier":1.0}],"default_model":"auto"}
    OUTPUT

    models = parse_list_models_output(mixed_output)
    assert_equal 1, models.size
    assert_equal "auto", models[0]["model_id"]
  end

  def test_parse_list_models_output_plain_text
    text_output = <<~TEXT
      Available models (* = default):

      * auto                 1.00x credits      Models chosen by task
        claude-sonnet-4.6    1.30x credits      Claude Sonnet 4.6 model
        deepseek-3.2         0.25x credits      Experimental preview
    TEXT

    models = parse_list_models_output(text_output)
    assert_equal 3, models.size
    assert_equal "auto", models[0]["model_id"]
    assert_equal "claude-sonnet-4.6", models[1]["model_id"]
    assert_equal "deepseek-3.2", models[2]["model_id"]
    assert_equal "1.00x credits", models[0]["rate"]
  end

  def test_parse_list_models_output_empty_string
    models = parse_list_models_output("")
    assert_nil models
  end

  def test_parse_list_models_output_json_array
    json_output = '[{"model_id":"auto"},{"model_id":"claude-sonnet-4.6"}]'

    models = parse_list_models_output(json_output)
    assert_equal 2, models.size
    assert_equal "auto", models[0]["model_id"]
  end

  def test_list_models_for_provider_returns_nil_when_no_command
    provider_data = {
      "binary" => "kiro-cli",
      "default_args" => "chat --no-interactive",
      "model_flag" => "--model",
      "models" => { "auto" => "auto" }
    }
    File.write(File.join(@providers_dir, "no-list.json"), JSON.generate(provider_data))

    result = list_models_for_provider("no-list")
    assert_nil result
  end

  def test_list_models_for_provider_returns_nil_for_nonexistent_provider
    result = list_models_for_provider("nonexistent-provider")
    assert_nil result
  end

  def test_list_models_for_provider_with_echo_command
    # Use a simple echo command to simulate a CLI that outputs JSON
    json_data = '{"models":[{"model_id":"test-model","description":"Test"}],"default_model":"test-model"}'
    provider_data = {
      "binary" => "test-cli",
      "default_args" => "",
      "model_flag" => "--model",
      "list_models_command" => "echo '#{json_data}'",
      "models" => {}
    }
    File.write(File.join(@providers_dir, "echo-provider.json"), JSON.generate(provider_data))

    models = list_models_for_provider("echo-provider")
    assert_equal 1, models.size
    assert_equal "test-model", models[0]["model_id"]
  end

  def test_list_models_for_provider_returns_nil_on_command_failure
    provider_data = {
      "binary" => "test-cli",
      "default_args" => "",
      "model_flag" => "--model",
      "list_models_command" => "false",
      "models" => {}
    }
    File.write(File.join(@providers_dir, "fail-provider.json"), JSON.generate(provider_data))

    result = list_models_for_provider("fail-provider")
    assert_nil result
  end

  def test_parse_list_models_text_simple_names
    text_output = <<~TEXT
      model-a
      model-b
      model-c
    TEXT

    models = parse_list_models_text(text_output)
    assert_equal 3, models.size
    assert_equal "model-a", models[0]["model_id"]
    assert_equal "model-b", models[1]["model_id"]
    assert_equal "model-c", models[2]["model_id"]
  end

  def test_parse_list_models_output_normalizes_slug_to_model_id
    # Codex debug models uses "slug" instead of "model_id"
    json_output = <<~JSON
      {"models":[{"slug":"gpt-5.6-sol","display_name":"GPT-5.6-Sol","description":"Frontier model.","visibility":"list"},{"slug":"gpt-5.2","display_name":"GPT-5.2","description":"Older model.","visibility":"list"}]}
    JSON

    models = parse_list_models_output(json_output)
    assert_equal 2, models.size
    assert_equal "gpt-5.6-sol", models[0]["model_id"]
    assert_equal "gpt-5.2", models[1]["model_id"]
    assert_equal "GPT-5.6-Sol", models[0]["display_name"]
    assert_equal "Frontier model.", models[0]["description"]
  end

  def test_parse_list_models_output_preserves_visibility_field
    json_output = <<~JSON
      {"models":[{"slug":"gpt-5.6-sol","visibility":"list"},{"slug":"codex-auto-review","visibility":"hide"}]}
    JSON

    models = parse_list_models_output(json_output)
    assert_equal 2, models.size
    assert_equal "list", models[0]["visibility"]
    assert_equal "hide", models[1]["visibility"]
  end

  def test_normalize_model_list_leaves_model_id_intact
    models = [{ "model_id" => "auto", "description" => "Auto" }]
    result = normalize_model_list(models)
    assert_equal "auto", result[0]["model_id"]
  end

  def test_normalize_model_list_converts_slug
    models = [{ "slug" => "gpt-5.5", "display_name" => "GPT-5.5" }]
    result = normalize_model_list(models)
    assert_equal "gpt-5.5", result[0]["model_id"]
    refute result[0].key?("slug")
  end

  def test_normalize_model_list_converts_model_name
    models = [{ "model_name" => "claude-sonnet-4.6" }]
    result = normalize_model_list(models)
    assert_equal "claude-sonnet-4.6", result[0]["model_id"]
    refute result[0].key?("model_name")
  end

  def test_parse_list_models_output_raw_array_with_slug
    # Codex might output a raw JSON array (without wrapping "models" key)
    json_output = '[{"slug":"gpt-5.6-sol","display_name":"Sol"},{"slug":"gpt-5.2","display_name":"5.2"}]'

    models = parse_list_models_output(json_output)
    assert_equal 2, models.size
    assert_equal "gpt-5.6-sol", models[0]["model_id"]
    assert_equal "gpt-5.2", models[1]["model_id"]
  end

  # --- generate_short_model_key tests ---

  def test_generate_short_model_key_strips_claude_prefix
    assert_equal "sonnet-4-6", generate_short_model_key("claude-sonnet-4.6")
    assert_equal "opus-4-6", generate_short_model_key("claude-opus-4.6")
    assert_equal "haiku-4-5", generate_short_model_key("claude-haiku-4.5")
  end

  def test_generate_short_model_key_strips_grok_prefix
    assert_equal "build", generate_short_model_key("grok-build")
    assert_equal "3", generate_short_model_key("grok-3")
  end

  def test_generate_short_model_key_strips_gpt_prefix
    assert_equal "4o", generate_short_model_key("GPT-4o")
    assert_equal "5-6-sol", generate_short_model_key("GPT-5.6-Sol")
  end

  def test_generate_short_model_key_handles_mixed_case
    assert_equal "deepseek-v3", generate_short_model_key("DeepSeek-V3")
    assert_equal "minimax-m2-5", generate_short_model_key("MiniMax-M2.5")
    assert_equal "qwen3-coder-next", generate_short_model_key("Qwen3-Coder-Next")
  end

  def test_generate_short_model_key_handles_already_lowercase
    assert_equal "deepseek-3-2", generate_short_model_key("deepseek-3.2")
    assert_equal "auto", generate_short_model_key("auto")
  end

  def test_generate_short_model_key_strips_leading_and_trailing_dashes
    # A model like "GPT-4o" after prefix strip and downcase becomes "4o" — no leading dash
    assert_equal "4o", generate_short_model_key("GPT-4o")
    # An edge case: model id that starts with a special char after prefix strip
    assert_equal "test", generate_short_model_key(".test.")
  end

  def test_generate_short_model_key_collapses_multiple_dashes
    assert_equal "some-long-model-name", generate_short_model_key("some--long---model----name")
  end

  def test_generate_short_model_key_all_uppercase
    assert_equal "turbo", generate_short_model_key("TURBO")
  end
end
