# frozen_string_literal: true

# Turns a CLI's JSONL event stream into a readable agent log.
#
# run_agent spawns this as its own process between the agent and the log file when the
# provider sets `stream_format` (see run_agent / spawn_agent_with_formatter). It runs
# outside the server so a brainiac restart can't break the pipe and kill the agent.
#
#   claude ... --output-format stream-json --verbose | ruby stream_formatter.rb claude > log
#
# Lines that aren't JSON (mise noise, stderr, crashes) pass through unchanged, so the
# crash snippet still shows whatever went wrong. Summary lines start with "---" so
# detect_no_output_reason treats them as boilerplate, like it does kiro's banners.

require "json"

module StreamFormatter
  MAX_SUMMARY = 160

  module_function

  # Format a single line of stream output. Returns an array of log lines (maybe empty).
  def format_line(format, line)
    event = JSON.parse(line)
    return [line.chomp] unless event.is_a?(Hash)

    case format
    when "claude" then format_claude(event)
    else [line.chomp]
    end
  rescue JSON::ParserError
    [line.chomp]
  end

  def format_claude(event)
    case event["type"]
    when "system" then claude_system(event)
    when "assistant" then claude_assistant(event)
    when "user" then claude_tool_errors(event)
    when "result" then claude_result(event)
    else []
    end
  end

  def claude_system(event)
    return [] unless event["subtype"] == "init"

    ["--- claude #{event["claude_code_version"]} · #{event["model"]} · session #{event["session_id"]}"]
  end

  # Assistant text prints as-is; each tool call becomes a "▸ Tool: summary" line.
  # Events from a subagent carry parent_tool_use_id and are indented under it.
  def claude_assistant(event)
    indent = event["parent_tool_use_id"] ? "  " : ""
    Array(event.dig("message", "content")).flat_map do |block|
      case block["type"]
      when "text"
        text = block["text"].to_s.strip
        text.empty? ? [] : text.lines.map { |l| "#{indent}#{l.chomp}" } + [""]
      when "tool_use"
        summary = tool_summary(block["name"], block["input"] || {})
        ["#{indent}▸ #{block["name"]}#{": #{summary}" unless summary.empty?}"]
      else []
      end
    end
  end

  # Successful tool results are noise in a progress log; failed ones are worth a line.
  def claude_tool_errors(event)
    indent = event["parent_tool_use_id"] ? "    " : "  "
    Array(event.dig("message", "content")).filter_map do |block|
      next unless block.is_a?(Hash) && block["type"] == "tool_result" && block["is_error"]

      "#{indent}✗ #{truncate(first_line(result_text(block["content"])))}"
    end
  end

  def claude_result(event)
    parts = [event["subtype"] == "success" ? "done" : event["subtype"]]
    parts << "#{event["num_turns"]} turns" if event["num_turns"]
    parts << format_duration(event["duration_ms"]) if event["duration_ms"]
    parts << format("$%.2f", event["total_cost_usd"]) if event["total_cost_usd"]
    lines = ["--- #{parts.join(" · ")}"]
    # Errors (usage limits, API failures) only show up here, so print the message where
    # detect_no_output_reason can match it.
    lines.unshift("✗ #{event["result"]}") if event["is_error"] && event["result"]
    lines
  end

  def tool_summary(name, input)
    value = case name
            when "Bash" then input["command"]
            when "Read", "Edit", "Write", "MultiEdit" then input["file_path"]
            when "NotebookEdit" then input["notebook_path"]
            when "Grep", "Glob" then [input["pattern"], input["path"]].compact.join(" in ")
            when "Agent", "Task" then input["description"]
            when "WebFetch" then input["url"]
            when "WebSearch" then input["query"]
            when "Skill" then input["skill"]
            else input.values.find { |v| v.is_a?(String) }
            end
    truncate(first_line(value.to_s))
  end

  def result_text(content)
    return content.to_s unless content.is_a?(Array)

    content.filter_map { |c| c["text"] if c.is_a?(Hash) }.join("\n")
  end

  def first_line(text)
    text.strip.lines.first.to_s.chomp
  end

  def truncate(text)
    text.length > MAX_SUMMARY ? "#{text[0, MAX_SUMMARY - 1]}…" : text
  end

  def format_duration(millis)
    secs = (millis / 1000.0).round
    secs < 60 ? "#{secs}s" : "#{secs / 60}m#{format("%02d", secs % 60)}s"
  end

  def run(format, input: $stdin, output: $stdout)
    output.sync = true
    input.each_line do |line|
      format_line(format, line).each { |l| output.puts(l) }
    end
  end
end

StreamFormatter.run(ARGV.fetch(0, "claude")) if $PROGRAM_NAME == __FILE__
