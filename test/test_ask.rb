# frozen_string_literal: true

require_relative "test_helper"
require "minitest/mock"

# ask_agent: synchronous one-off agent calls, with a read-only mode for untrusted input.
class TestAsk < Minitest::Test
  def setup
    @provider_dir = File.join(TEST_BRAINIAC_DIR, "cli-providers")
    @workdir = Dir.mktmpdir("ask-workdir")
    # A fake CLI: prints its args, then echoes the prompt from stdin.
    @cli = File.join(@workdir, "fake-cli")
    File.write(@cli, "#!/bin/sh\necho \"ARGS: $*\"\ncat\n")
    File.chmod(0o755, @cli)
    write_provider("asktest", "default_args" => "--write-everything", "readonly_args" => "--read-only")
    write_provider("asknoro", "default_args" => "--write-everything")
    @project = { "repo_path" => @workdir, "cli_provider" => "asktest" }
  end

  def teardown
    FileUtils.rm_rf(@workdir)
    %w[asktest asknoro].each { |name| FileUtils.rm_f(File.join(@provider_dir, "#{name}.json")) }
    BRAINIAC_CONFIG.delete("default_cli_provider")
  end

  def write_provider(name, extra)
    File.write(File.join(@provider_dir, "#{name}.json"),
               JSON.generate({ "binary" => @cli, "agent_flag" => "--agent", "model_flag" => nil }.merge(extra)))
  end

  def test_returns_the_reply_using_default_args
    reply = ask_agent("is it a bug?", project_config: @project, brain: false)

    assert_includes reply, "--write-everything"
    assert_includes reply, "is it a bug?"
  end

  def test_readonly_swaps_in_readonly_args
    reply = ask_agent("is it a bug?", project_config: @project, readonly: true, brain: false)

    assert_includes reply, "--read-only"
    refute_includes reply, "--write-everything"
  end

  def test_readonly_refuses_a_provider_without_readonly_args
    error = assert_raises(AskAgentError) do
      ask_agent("rm -rf /", project_config: @project, cli_provider: "asknoro", readonly: true, brain: false)
    end
    assert_match(/no readonly_args/, error.message)
  end

  def test_passes_the_agent_resolved_from_the_project
    reply = ask_agent("hi", project_config: @project.merge("agent_name" => "Robin"), brain: false)

    assert_includes reply, "--agent robin"
  end

  def test_brain_context_goes_ahead_of_the_prompt
    stub(:build_brain_context, "## Brain — Persona\nyou are Sherlock\n") do
      reply = ask_agent("is it a bug?", project_config: @project)

      assert_operator reply.index("you are Sherlock"), :<, reply.index("## Task")
      assert_operator reply.index("## Task"), :<, reply.index("is it a bug?")
    end
  end

  def test_strips_ansi_escapes
    File.write(@cli, "#!/bin/sh\nprintf '\\033[32m{\"ok\":true}\\033[0m\\n'\n")

    assert_equal '{"ok":true}', ask_agent("x", project_config: @project, brain: false)
  end

  def test_raises_when_the_cli_fails_without_output
    File.write(@cli, "#!/bin/sh\necho 'auth expired' >&2\nexit 3\n")

    error = assert_raises(AskAgentError) { ask_agent("x", project_config: @project, brain: false) }
    assert_match(/exited 3: auth expired/, error.message)
  end

  def test_times_out
    File.write(@cli, "#!/bin/sh\nsleep 5\n")

    error = assert_raises(AskAgentError) { ask_agent("x", project_config: @project, brain: false, timeout: 0.3) }
    assert_match(/timed out/, error.message)
  end

  def test_default_cli_provider_is_the_last_fallback
    BRAINIAC_CONFIG["default_cli_provider"] = "asktest"

    resolved = resolve_project_cli_config({ "repo_path" => @workdir })

    assert_equal @cli, resolved["agent_cli"]
    assert_equal "--read-only", resolved["readonly_args"]
  end

  def test_project_cli_provider_beats_the_default
    BRAINIAC_CONFIG["default_cli_provider"] = "asknoro"

    assert_equal "--read-only", resolve_project_cli_config(@project)["readonly_args"]
  end
end
