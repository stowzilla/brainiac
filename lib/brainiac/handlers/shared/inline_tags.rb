# frozen_string_literal: true

# Shared inline tag parsing for handler messages.
#
# Messages from any channel can contain inline tags like:
#   [project:my-project], [opus], [effort:high], [cli:grok], [chat], [plan],
#   [fresh], [branch:feature-xyz], [workitem:wi-abc123], [profile:k+] ([p:k+])
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
#     profile: "k+" or nil,
#     chat_mode: true/false,
#     planning: true/false,
#     fresh: true/false,
#     deploy_intent: "dev01" / :auto / nil,
#     worktree_override: "branch-name" or nil,
#     fork_branch: "topic" or true or nil (fork conversation to a new thread),
#     clean_text: "the message with all tags stripped"
#   }
def parse_inline_tags(text)
  result = {
    project: nil,
    model_tag: nil,
    effort: nil,
    cli_provider: nil,
    profile: nil,
    chat_mode: false,
    planning: false,
    fresh: false,
    deploy_intent: nil,
    worktree_override: nil,
    work_item: nil,
    branch_override: nil,
    fork_branch: nil,
    clean_text: text.dup
  }

  parse_value_tags(result)
  parse_flag_tags(result)
  parse_work_item_tags(result)
  parse_model_tag(result)

  result[:clean_text].strip!
  result
end

def parse_value_tags(result)
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

  # [profile:k+] or short alias [p:k+] — a named env bundle (e.g. an alternate
  # kiro-cli account via XDG_DATA_HOME). Values allow non-word chars like '+'.
  if (match = result[:clean_text].match(/\[(?:profile|p):([^\]]+)\]/i))
    result[:profile] = match[1].strip.downcase
    result[:clean_text].sub!(match[0], "")
  end

  # [deploy] or [deploy:dev01]
  if (match = result[:clean_text].match(/\[deploy(?::([^\]]+))?\]/i))
    result[:deploy_intent] = match[1]&.strip&.downcase || :auto
    result[:clean_text].sub!(match[0], "")
  end
end

def parse_flag_tags(result)
  # [chat], [question], [?]
  if result[:clean_text].match?(/\[(chat|question|\?)\]/i)
    result[:chat_mode] = true
    result[:clean_text].sub!(/\[(chat|question|\?)\]/i, "")
  end

  # [fresh] — start a new CLI session instead of resuming the existing one
  if result[:clean_text].match?(/\[fresh\]/i)
    result[:fresh] = true
    result[:clean_text].sub!(/\[fresh\]/i, "")
  end

  # [plan]
  return unless result[:clean_text].match?(/\[plan\]/i)

  result[:planning] = true
  result[:clean_text].sub!(/\[plan\]/i, "")
end

def parse_work_item_tags(result)
  # [worktree:branch-name] — legacy syntax, still supported
  if (match = result[:clean_text].match(/\[worktree:([^\]]+)\]/))
    result[:worktree_override] = match[1].strip
    result[:clean_text].sub!(match[0], "")
  end

  # [branch:branch-name] — preferred syntax for targeting a branch/worktree.
  # Note: bare [branch] (no colon/value) is handled below as a fork request.
  if (match = result[:clean_text].match(/\[branch:([^\]]+)\]/i))
    result[:branch_override] = match[1].strip
    # Also set worktree_override for backward compat with plugins that read it
    result[:worktree_override] ||= result[:branch_override]
    result[:clean_text].sub!(match[0], "")
  end

  # [workitem:wi-abc123] — target a specific work item by ID
  if (match = result[:clean_text].match(/\[workitem:([^\]]+)\]/i))
    result[:work_item] = match[1].strip
    result[:clean_text].sub!(match[0], "")
  end

  # [fork], [fork:topic], or bare [branch] — fork the conversation into a new thread.
  # The new thread starts unbound (no worktree) until implementation work begins.
  # Topic becomes the thread title; without a topic, the message content is used.
  # - [fork:belt-bug] → fork with "belt-bug" as the topic
  # - [fork] → fork with auto-generated topic from message content
  # - [branch] → alias for [fork] (bare [branch] with no value)
  if (match = result[:clean_text].match(/\[fork(?::([^\]]+))?\]/i))
    result[:fork_branch] = match[1]&.strip || true
    result[:clean_text].sub!(match[0], "")
  elsif result[:clean_text].match?(/\[branch\]/i) && !result[:branch_override]
    # Bare [branch] with no value acts as a fork request
    result[:fork_branch] = true
    result[:clean_text].sub!(/\[branch\]/i, "")
  end
end

def parse_model_tag(result)
  # Model tag: any remaining [word] that isn't a known tag — detected separately
  # because it depends on the project's allowed_models config. We just capture
  # the raw match here for the caller to resolve.
  if (match = result[:clean_text].match(/\[(\w+)\]/))
    result[:model_tag] = match[1].downcase
    result[:clean_text].sub!(match[0], "")
  end
end
