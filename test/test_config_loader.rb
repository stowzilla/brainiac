# frozen_string_literal: true

require_relative "test_helper"

class TestConfigLoader < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir("config-loader-test")
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  # --- resolve_path ---

  def test_resolve_path_prefers_toml_over_json
    json_path = File.join(@test_dir, "config.json")
    toml_path = File.join(@test_dir, "config.toml")
    File.write(json_path, '{"key": "json"}')
    File.write(toml_path, 'key = "toml"')

    result = Brainiac::ConfigLoader.resolve_path(File.join(@test_dir, "config"))
    assert_equal toml_path, result
  end

  def test_resolve_path_falls_back_to_json
    json_path = File.join(@test_dir, "config.json")
    File.write(json_path, '{"key": "json"}')

    result = Brainiac::ConfigLoader.resolve_path(File.join(@test_dir, "config"))
    assert_equal json_path, result
  end

  def test_resolve_path_returns_nil_when_nothing_exists
    result = Brainiac::ConfigLoader.resolve_path(File.join(@test_dir, "nonexistent"))
    assert_nil result
  end

  def test_resolve_path_with_explicit_json_extension
    json_path = File.join(@test_dir, "config.json")
    File.write(json_path, '{}')

    result = Brainiac::ConfigLoader.resolve_path(json_path)
    assert_equal json_path, result
  end

  def test_resolve_path_with_explicit_toml_extension
    toml_path = File.join(@test_dir, "config.toml")
    File.write(toml_path, "")

    result = Brainiac::ConfigLoader.resolve_path(toml_path)
    assert_equal toml_path, result
  end

  def test_resolve_path_explicit_extension_returns_nil_when_missing
    result = Brainiac::ConfigLoader.resolve_path(File.join(@test_dir, "nope.json"))
    assert_nil result
  end

  # --- load (JSON) ---

  def test_load_json_file
    File.write(File.join(@test_dir, "app.json"), '{"name": "brainiac", "version": 2}')

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "app"))
    assert_equal({ "name" => "brainiac", "version" => 2 }, result)
  end

  def test_load_json_with_nested_objects
    data = { "agents" => { "sherlock" => { "local" => true, "env" => { "TOKEN" => "abc" } } } }
    File.write(File.join(@test_dir, "agents.json"), JSON.generate(data))

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "agents"))
    assert_equal true, result.dig("agents", "sherlock", "local")
    assert_equal "abc", result.dig("agents", "sherlock", "env", "TOKEN")
  end

  def test_load_json_with_symbolize_names
    File.write(File.join(@test_dir, "config.json"), '{"name": "test", "count": 5}')

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "config"), symbolize_names: true)
    assert_equal "test", result[:name]
    assert_equal 5, result[:count]
  end

  def test_load_returns_default_when_file_missing
    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "missing"), default: { "fallback" => true })
    assert_equal({ "fallback" => true }, result)
  end

  def test_load_returns_default_on_invalid_json
    File.write(File.join(@test_dir, "bad.json"), "not valid json {{{")

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "bad"), default: {})
    assert_equal({}, result)
  end

  # --- load (TOML) ---

  def test_load_toml_file
    toml_content = <<~TOML
      # This is a comment
      name = "brainiac"
      version = 2
    TOML
    File.write(File.join(@test_dir, "app.toml"), toml_content)

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "app"))
    assert_equal "brainiac", result["name"]
    assert_equal 2, result["version"]
  end

  def test_load_toml_with_sections
    toml_content = <<~TOML
      [server]
      port = 4567
      host = "localhost"

      [server.ssl]
      enabled = false
    TOML
    File.write(File.join(@test_dir, "server.toml"), toml_content)

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "server"))
    assert_equal 4567, result.dig("server", "port")
    assert_equal "localhost", result.dig("server", "host")
    assert_equal false, result.dig("server", "ssl", "enabled")
  end

  def test_load_toml_with_arrays
    toml_content = <<~TOML
      tags = ["marketplace", "mp"]
      allowed_efforts = ["low", "medium", "high"]
    TOML
    File.write(File.join(@test_dir, "project.toml"), toml_content)

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "project"))
    assert_equal %w[marketplace mp], result["tags"]
    assert_equal %w[low medium high], result["allowed_efforts"]
  end

  def test_load_toml_with_inline_tables
    toml_content = <<~TOML
      [allowed_models]
      opus = "claude-opus-4.6"
      sonnet = "claude-sonnet-4.6"
      haiku = "claude-haiku-4.5"
      auto = "auto"
    TOML
    File.write(File.join(@test_dir, "models.toml"), toml_content)

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "models"))
    assert_equal "claude-opus-4.6", result.dig("allowed_models", "opus")
    assert_equal "auto", result.dig("allowed_models", "auto")
  end

  def test_load_toml_agent_registry_format
    toml_content = <<~TOML
      [sherlock]
      display_name = "Sherlock"
      local = true

      [sherlock.env]
      SERVICE_TOKEN = "token_sherlock"
      DISCORD_BOT_TOKEN = "Bot_sherlock"

      [robin]
      display_name = "Robin"
      local = false

      [robin.env]
      SERVICE_TOKEN = "token_robin"
    TOML
    File.write(File.join(@test_dir, "agents.toml"), toml_content)

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "agents"))
    assert_equal "Sherlock", result.dig("sherlock", "display_name")
    assert_equal true, result.dig("sherlock", "local")
    assert_equal "token_sherlock", result.dig("sherlock", "env", "SERVICE_TOKEN")
    assert_equal "Robin", result.dig("robin", "display_name")
    assert_equal false, result.dig("robin", "local")
  end

  def test_load_toml_projects_format
    toml_content = <<~TOML
      [marketplace]
      repo_path = "/home/you/Code/marketplace"
      github_repo = "stowzilla/marketplace"
      agent_cli = "kiro-cli"
      agent_cli_args = "chat --trust-all-tools --no-interactive"

      [marketplace.allowed_models]
      opus = "claude-opus-4.6"
      sonnet = "claude-sonnet-4.6"
      auto = "auto"

      [brainiac]
      repo_path = "/home/you/Code/brainiac"
      github_repo = "stowzilla/brainiac"
      default = true
    TOML
    File.write(File.join(@test_dir, "projects.toml"), toml_content)

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "projects"))
    assert_equal "/home/you/Code/marketplace", result.dig("marketplace", "repo_path")
    assert_equal "claude-opus-4.6", result.dig("marketplace", "allowed_models", "opus")
    assert_equal true, result.dig("brainiac", "default")
  end

  def test_load_toml_returns_default_on_parse_error
    File.write(File.join(@test_dir, "bad.toml"), "[invalid\nno closing bracket")

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "bad"), default: { "safe" => true })
    assert_equal({ "safe" => true }, result)
  end

  # --- load_file ---

  def test_load_file_raises_on_invalid_json
    File.write(File.join(@test_dir, "bad.json"), "{invalid")

    assert_raises(Brainiac::ConfigLoader::ParseError) do
      Brainiac::ConfigLoader.load_file(File.join(@test_dir, "bad.json"))
    end
  end

  def test_load_file_raises_on_invalid_toml
    File.write(File.join(@test_dir, "bad.toml"), "[broken\nnope")

    assert_raises(Brainiac::ConfigLoader::ParseError) do
      Brainiac::ConfigLoader.load_file(File.join(@test_dir, "bad.toml"))
    end
  end

  def test_load_file_raises_on_unsupported_extension
    File.write(File.join(@test_dir, "config.yaml"), "key: value")

    assert_raises(Brainiac::ConfigLoader::ParseError) do
      Brainiac::ConfigLoader.load_file(File.join(@test_dir, "config.yaml"))
    end
  end

  # --- format_for ---

  def test_format_for_detects_toml
    File.write(File.join(@test_dir, "config.toml"), 'key = "value"')

    assert_equal :toml, Brainiac::ConfigLoader.format_for(File.join(@test_dir, "config"))
  end

  def test_format_for_detects_json
    File.write(File.join(@test_dir, "config.json"), '{}')

    assert_equal :json, Brainiac::ConfigLoader.format_for(File.join(@test_dir, "config"))
  end

  def test_format_for_returns_nil_when_missing
    assert_nil Brainiac::ConfigLoader.format_for(File.join(@test_dir, "nonexistent"))
  end

  # --- write ---

  def test_write_produces_json
    data = { "name" => "brainiac", "agents" => %w[sherlock robin] }
    path = Brainiac::ConfigLoader.write(File.join(@test_dir, "output"), data)

    assert_equal File.join(@test_dir, "output.json"), path
    assert File.exist?(path)

    loaded = JSON.parse(File.read(path))
    assert_equal "brainiac", loaded["name"]
    assert_equal %w[sherlock robin], loaded["agents"]
  end

  def test_write_with_explicit_json_extension
    data = { "key" => "value" }
    path = Brainiac::ConfigLoader.write(File.join(@test_dir, "explicit.json"), data)

    assert_equal File.join(@test_dir, "explicit.json"), path
    assert File.exist?(path)
  end

  def test_write_compact_format
    data = { "a" => 1 }
    path = Brainiac::ConfigLoader.write(File.join(@test_dir, "compact"), data, pretty: false)

    content = File.read(path)
    refute content.include?("\n"), "Expected compact JSON without newlines"
  end

  # --- toml_available? ---

  def test_toml_available
    assert Brainiac::ConfigLoader.toml_available?
  end

  # --- TOML-specific features ---

  def test_toml_supports_comments
    toml_content = <<~TOML
      # Main configuration
      default_agent = "Sherlock"  # The primary agent

      # Dashboard settings
      dashboard_token = "secret123"
    TOML
    File.write(File.join(@test_dir, "brainiac.toml"), toml_content)

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "brainiac"))
    assert_equal "Sherlock", result["default_agent"]
    assert_equal "secret123", result["dashboard_token"]
  end

  def test_toml_supports_multiline_strings
    toml_content = <<~TOML
      description = \"\"\"
      This is a multi-line
      description that spans
      several lines.\"\"\"
    TOML
    File.write(File.join(@test_dir, "multi.toml"), toml_content)

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "multi"))
    assert_includes result["description"], "multi-line"
    assert_includes result["description"], "several lines."
  end

  def test_toml_supports_booleans_and_integers
    toml_content = <<~TOML
      enabled = true
      port = 4567
      rate_limit = 1.5
    TOML
    File.write(File.join(@test_dir, "types.toml"), toml_content)

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "types"))
    assert_equal true, result["enabled"]
    assert_equal 4567, result["port"]
    assert_equal 1.5, result["rate_limit"]
  end

  # --- Priority/precedence ---

  def test_toml_takes_precedence_when_both_exist
    File.write(File.join(@test_dir, "config.json"), '{"source": "json"}')
    File.write(File.join(@test_dir, "config.toml"), 'source = "toml"')

    result = Brainiac::ConfigLoader.load(File.join(@test_dir, "config"))
    assert_equal "toml", result["source"]
  end
end
