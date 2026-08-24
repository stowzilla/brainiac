# frozen_string_literal: true

require_relative "test_helper"

class TestOutputCapture < Minitest::Test
  def setup
    @codex_provider = {
      "binary" => "codex",
      "default_args" => "exec --full-auto -",
      "agent_flag" => nil,
      "model_flag" => "--model",
      "effort_flag" => nil,
      "prompt_mode" => "stdin",
      "output_last_message_flag" => "-o",
      "models" => { "o3" => "o3", "o4-mini" => "o4-mini", "auto" => "o4-mini" }
    }
    @provider_file = File.join(TEST_BRAINIAC_DIR, "cli-providers", "codex.json")
    File.write(@provider_file, JSON.generate({
                                               "binary" => "codex",
                                               "default_args" => "exec --full-auto -",
                                               "agent_flag" => nil,
                                               "model_flag" => "--model",
                                               "effort_flag" => nil,
                                               "prompt_mode" => "stdin",
                                               "output_last_message_flag" => "-o",
                                               "models" => { "o3" => "o3", "o4-mini" => "o4-mini", "auto" => "o4-mini" }
                                             }))
  end

  def teardown
    FileUtils.rm_f(@provider_file)
  end

  # --- load_cli_provider tests ---

  def test_load_cli_provider_parses_output_last_message_flag
    config = load_cli_provider("codex")
    assert_equal "-o", config["output_last_message_flag"]
  end

  def test_load_cli_provider_omits_output_last_message_flag_when_not_set
    # The kiro provider template doesn't have this flag
    kiro_file = File.join(TEST_BRAINIAC_DIR, "cli-providers", "kiro.json")
    File.write(kiro_file, JSON.generate({
                                          "binary" => "kiro-cli",
                                          "default_args" => "chat --trust-all-tools --no-interactive",
                                          "model_flag" => "--model",
                                          "prompt_mode" => "stdin"
                                        }))
    config = load_cli_provider("kiro")
    refute config.key?("output_last_message_flag")
  ensure
    FileUtils.rm_f(kiro_file)
  end

  # --- build_agent_cmd tests ---

  def test_build_agent_cmd_appends_output_flag_when_present
    resolved = {
      "agent_cli" => "codex",
      "agent_cli_args" => "exec --full-auto -",
      "output_last_message_flag" => "-o"
    }
    cmd = build_agent_cmd(resolved, output_file: "/tmp/output.md")
    assert_includes cmd, "-o"
    assert_includes cmd, "/tmp/output.md"
    # Verify flag and path are adjacent
    idx = cmd.index("-o")
    assert_equal "/tmp/output.md", cmd[idx + 1]
  end

  def test_build_agent_cmd_skips_output_flag_when_no_output_file
    resolved = {
      "agent_cli" => "codex",
      "agent_cli_args" => "exec --full-auto -",
      "output_last_message_flag" => "-o"
    }
    cmd = build_agent_cmd(resolved, output_file: nil)
    refute_includes cmd, "-o"
  end

  def test_build_agent_cmd_skips_output_flag_when_provider_lacks_flag
    resolved = {
      "agent_cli" => "kiro-cli",
      "agent_cli_args" => "chat --no-interactive"
    }
    cmd = build_agent_cmd(resolved, output_file: "/tmp/output.md")
    refute_includes cmd, "/tmp/output.md"
  end

  def test_build_agent_cmd_full_codex_command
    resolved = {
      "agent_cli" => "codex",
      "agent_cli_args" => "exec --full-auto -",
      "agent_flag" => nil,
      "agent_model_flag" => "--model",
      "allowed_models" => { "o3" => "o3", "o4-mini" => "o4-mini" },
      "output_last_message_flag" => "-o"
    }
    cmd = build_agent_cmd(resolved, agent_config_name: "sherlock", model: "o3", output_file: "/tmp/out.md")
    assert_equal "codex", cmd[0]
    assert_includes cmd, "--model"
    assert_includes cmd, "o3"
    assert_includes cmd, "-o"
    assert_includes cmd, "/tmp/out.md"
    # agent_flag is nil, so agent name should NOT be in cmd
    refute_includes cmd, "sherlock"
  end

  # --- read_output_file tests ---

  def test_read_output_file_returns_content
    tmpfile = File.join(TEST_BRAINIAC_DIR, "tmp", "test-output.md")
    FileUtils.mkdir_p(File.dirname(tmpfile))
    File.write(tmpfile, "Here is the agent's final response.\n")

    content = read_output_file(tmpfile)
    assert_equal "Here is the agent's final response.", content
  ensure
    FileUtils.rm_f(tmpfile)
  end

  def test_read_output_file_returns_nil_when_file_missing
    assert_nil read_output_file("/tmp/nonexistent-file-#{SecureRandom.hex(8)}.md")
  end

  def test_read_output_file_returns_nil_when_nil
    assert_nil read_output_file(nil)
  end

  def test_read_output_file_returns_nil_when_empty
    tmpfile = File.join(TEST_BRAINIAC_DIR, "tmp", "test-empty-output.md")
    FileUtils.mkdir_p(File.dirname(tmpfile))
    File.write(tmpfile, "   \n  ")

    assert_nil read_output_file(tmpfile)
  ensure
    FileUtils.rm_f(tmpfile)
  end

  def test_read_output_file_handles_json_content
    tmpfile = File.join(TEST_BRAINIAC_DIR, "tmp", "test-json-output.json")
    FileUtils.mkdir_p(File.dirname(tmpfile))
    json_content = '{"project_name": "Brainiac", "languages": ["Ruby"]}'
    File.write(tmpfile, json_content)

    content = read_output_file(tmpfile)
    assert_equal json_content, content

    # Verify it's valid JSON
    parsed = JSON.parse(content)
    assert_equal "Brainiac", parsed["project_name"]
  ensure
    FileUtils.rm_f(tmpfile)
  end

  # --- prepare_output_file tests ---

  def test_prepare_output_file_returns_path_when_flag_present
    resolved = { "output_last_message_flag" => "-o" }
    path = prepare_output_file(resolved, "test-dispatch", "20260824-120000")
    assert_match(%r{tmp/output/agent-test-dispatch-20260824-120000\.md$}, path)
    assert Dir.exist?(File.dirname(path))
  end

  def test_prepare_output_file_returns_nil_when_no_flag
    resolved = { "agent_cli" => "kiro-cli" }
    assert_nil prepare_output_file(resolved, "test-dispatch", "20260824-120000")
  end

  # --- output file cleanup (handle_agent_completion) ---

  def test_output_file_cleaned_up_after_completion
    # Create a temp output file simulating what the agent CLI would write
    output_dir = File.join(TEST_BRAINIAC_DIR, "tmp", "output")
    FileUtils.mkdir_p(output_dir)
    output_file = File.join(output_dir, "agent-cleanup-test-20260824-120000.md")
    File.write(output_file, "Agent response content")

    assert File.exist?(output_file), "Output file should exist before cleanup"

    # Simulate the cleanup that handle_agent_completion performs after hook emission
    FileUtils.rm_f(output_file)

    refute File.exist?(output_file), "Output file should be removed after completion"
  end
end
