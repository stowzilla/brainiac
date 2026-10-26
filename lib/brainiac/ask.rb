# frozen_string_literal: true

# ask_agent: a synchronous, one-off agent call for plugins that need the answer back
# (e.g. deciding whether an incoming report is a bug). run_agent spawns a session and
# returns before there's any output, so it can't do this.

class AskAgentError < StandardError; end

ANSI_ESCAPE = %r{\e\[[0-9;?]*[ -/]*[@-~]}

# Ask an agent a question and return its reply as text.
#
# The agent and CLI resolve the same way run_agent's do: agent_name, else the project's
# agent_name, else the default agent; cli_provider, else the agent's, the project's, then
# brainiac.json's default_cli_provider.
#
# brain: true puts the agent's role, persona and brain knowledge ahead of the prompt, so the
#   whole agent answers rather than a bare model. topic seeds the knowledge search.
# readonly: true runs the provider's readonly_args instead of default_args. Raises
#   AskAgentError when the provider has none: text from strangers must never reach an agent
#   that can write files or run commands, so there's no falling back to default_args.
#
# Raises AskAgentError when the CLI times out or exits non-zero without a reply.
def ask_agent(prompt, project_config:, agent_name: nil, chdir: nil, readonly: false, brain: true, topic: "",
              project_key: nil, model: nil, cli_provider: nil, timeout: 300, log_name: "ask")
  agent_name ||= project_config["agent_name"] || AI_AGENT_NAME
  resolved = ask_agent_cli_config(project_config, cli_provider: cli_provider, agent_name: agent_name, readonly: readonly)
  chdir ||= resolved["repo_path"]
  raise AskAgentError, "working directory #{chdir.inspect} doesn't exist" unless chdir && Dir.exist?(chdir)

  if brain
    context = build_brain_context(agent_name: agent_name, card_title: topic, project_key: project_key)
    prompt = "#{context}\n## Task\n\n#{prompt}" unless context.empty?
  end

  timestamp = Time.now.strftime("%Y%m%d-%H%M%S")
  prompt_file = write_agent_prompt_file(prompt, log_name, timestamp)
  output_file = prepare_output_file(resolved, log_name, timestamp)
  cmd = build_agent_cmd(resolved, agent_config_name: agent_name.downcase.gsub(/[^a-z0-9-]/, "-"),
                                  model: model || resolved["agent_model"], prompt_file: prompt_file,
                                  output_file: output_file, chdir: chdir)
  LOG.info "[Ask] #{agent_name} via #{resolved["agent_cli"]}#{" (read-only)" if readonly} in #{chdir}: #{cmd.join(" ")}"

  stdout = run_ask_command(cmd, prompt_file, resolved, chdir: chdir, env: profile_spawn_env(agent_env_for(agent_name), nil),
                                                       timeout: timeout)
  (read_output_file(output_file) || stdout).gsub(ANSI_ESCAPE, "").strip
ensure
  FileUtils.rm_f(prompt_file) if prompt_file
end

# The resolved CLI config, with readonly_args swapped in for default_args when asked.
def ask_agent_cli_config(project_config, cli_provider:, agent_name:, readonly:)
  resolved = resolve_project_cli_config(project_config, cli_provider_override: cli_provider, agent_name: agent_name)
  return resolved unless readonly

  args = resolved["readonly_args"]
  if args.to_s.strip.empty?
    raise AskAgentError, "#{resolved["agent_cli"]} has no readonly_args in its cli-providers config, " \
                         "so it can't be run read-only"
  end

  resolved.merge("agent_cli_args" => args)
end

# Run the CLI and return its stdout. Kills the whole process group on timeout so the
# CLI's own children (tool calls, MCP servers) go with it.
def run_ask_command(cmd, prompt_file, resolved, chdir:, env:, timeout:)
  stdin_data = resolved["prompt_mode"] == "flag" ? "" : File.read(prompt_file)
  Open3.popen3(env, *cmd, chdir: chdir, pgroup: true) do |stdin, stdout, stderr, wait|
    readers = [Thread.new { stdout.read }, Thread.new { stderr.read }]
    begin
      stdin.write(stdin_data)
    rescue Errno::EPIPE
      nil # CLI exited before reading the prompt; its exit status says why.
    end
    stdin.close

    unless wait.join(timeout)
      begin
        Process.kill("TERM", -wait.pid)
      rescue Errno::ESRCH
        nil # Finished just as the clock ran out.
      end
      readers.each(&:join) # The kill closes the pipes, so these return.
      raise AskAgentError, "#{resolved["agent_cli"]} timed out after #{timeout}s"
    end

    out, err = readers.map(&:value)
    if !wait.value.success? && out.strip.empty?
      raise AskAgentError, "#{resolved["agent_cli"]} exited #{wait.value.exitstatus}: #{err.strip.lines.last(5).join}"
    end

    out
  end
end
