# frozen_string_literal: true

# Shared inline tag parsing for handler messages.
#
# Messages from any channel can contain inline tags like:
#   [project:my-project], [opus], [effort:high], [cli:grok], [chat], [plan]
#
# This module provides a single parser that extracts all tags and returns
# a structured result with the cleaned text.

# Parse inline tags from message text.
# Returns a hash:
#   {
#     project: "my-project" or nil,
#     model_tag: "opus" or nil (raw tag, not resolved model ID),
#     effort: "high" or nil,
#     cli_provider: "grok" or nil,
#     chat_mode: true/false,
#     planning: true/false,
#     deploy_intent: "dev01" / :auto / nil,
#     worktree_override: "branch-name" or nil,
#     clean_text: "the message with all tags stripped"
#   }
def parse_inline_tags(text)
  result = {
    project: nil,
    model_tag: nil,
    effort: nil,
    cli_provider: nil,
    chat_mode: false,
    planning: false,
    deploy_intent: nil,
    worktree_override: nil,
    clean_text: text.dup
  }

  # [project:my-project]
  if (match = result[:clean_text].match(/\[project:(\S+)\]/i))
    result[:project] = match[1]
    result[:clean_text].sub!(match[0], "")
  end

  # [effort:high]
  if (match = result[:clean_text].match(/\[effort:(\w+)\]/i))
    result[:effort] = match[1].downcase
    result[:clean_text].sub!(match[0], "")
  end

  # [cli:grok]
  if (match = result[:clean_text].match(/\[cli:(\w+)\]/i))
    result[:cli_provider] = match[1].downcase
    result[:clean_text].sub!(match[0], "")
  end

  # [chat], [question], [?]
  if result[:clean_text].match?(/\[(chat|question|\?)\]/i)
    result[:chat_mode] = true
    result[:clean_text].sub!(/\[(chat|question|\?)\]/i, "")
  end

  # [plan]
  if result[:clean_text].match?(/\[plan\]/i)
    result[:planning] = true
    result[:clean_text].sub!(/\[plan\]/i, "")
  end

  # [deploy] or [deploy:dev01]
  if (match = result[:clean_text].match(/\[deploy(?::([^\]]+))?\]/i))
    result[:deploy_intent] = match[1]&.strip&.downcase || :auto
    result[:clean_text].sub!(match[0], "")
  end

  # [worktree:branch-name]
  if (match = result[:clean_text].match(/\[worktree:([^\]]+)\]/))
    result[:worktree_override] = match[1].strip
    result[:clean_text].sub!(match[0], "")
  end

  # Model tag: any remaining [word] that isn't a known tag — detected separately
  # because it depends on the project's allowed_models config. We just capture
  # the raw match here for the caller to resolve.
  if (match = result[:clean_text].match(/\[(\w+)\]/))
    result[:model_tag] = match[1].downcase
    result[:clean_text].sub!(match[0], "")
  end

  result[:clean_text].strip!
  result
end
