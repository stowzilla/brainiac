# frozen_string_literal: true

# Planning mode — Q&A → plan → Fizzy steps.
#
# When a message includes [plan], the agent enters planning mode:
# instead of jumping straight into implementation, it gathers requirements,
# asks clarifying questions, and produces a step-by-step plan.

PROMPT_PLANNING_PREAMBLE = <<~PROMPT
  ## Planning Mode (ACTIVE)

  You are in **planning mode**. Do NOT start implementing yet.

  Your job is to:
  1. Understand the request fully — ask clarifying questions if anything is ambiguous
  2. Break the work into clear, discrete steps
  3. Present the plan for approval before proceeding

  ### Planning Process
  - Read the request carefully
  - Consider edge cases, dependencies, and scope
  - If you need clarification, ask ONE focused question (not a laundry list)
  - Once you have enough info, produce a numbered plan with concrete steps
  - Each step should be small enough to implement in a single session

  ### Output Format
  Present your plan as a numbered list. Each step should include:
  - What will be done
  - Which files/areas are affected
  - Any risks or decisions that need input

  Do NOT write code. Do NOT make changes. Plan only.

PROMPT

# Detect whether a message triggers planning mode.
#
# Returns a hash with planning info if active, or nil otherwise.
#   { card_id: "...", text: "..." }
#
# Planning is triggered by:
#   - The [plan] inline tag in the message text
#   - A "plan" or "planning" tag on the Fizzy card
def detect_planning_mode(text:, tags:, card_internal_id:, card_number:)
  is_planning = text.match?(/\[plan\]/i) || Array(tags).any? { |t| t.to_s.downcase.match?(/\Aplann?ing?\z/) }

  return nil unless is_planning

  {
    card_id: card_number || card_internal_id,
    text: text.sub(/\[plan\]/i, "").strip
  }
end

# Render a prompt with planning-mode preamble injected.
#
# Same signature as render_prompt but inserts PROMPT_PLANNING_PREAMBLE
# between the channel prompt and the situation template.
def render_planning_prompt(template, vars = {}, brain_context: "", card_context: "", agent_name: AI_AGENT_NAME, channel: :discord, board_key: nil)
  result = ""
  result += "#{brain_context}\n" unless brain_context.empty?
  result += card_context unless card_context.empty?
  result += PROMPT_CORE

  # Channel prompt: check plugin-registered prompts first, then built-in
  plugin_prompt = Brainiac.channel_prompts[channel]
  if plugin_prompt
    result += plugin_prompt
  else
    result += CHANNEL_PROMPTS.fetch(channel, PROMPT_DISCORD_CHANNEL)
  end

  # Inject planning preamble before the situation template
  result += PROMPT_PLANNING_PREAMBLE
  result += template

  # Pre-post comment check
  plugin_pre_post = Brainiac.channel_pre_post_checks[channel]
  if plugin_pre_post
    result += plugin_pre_post
  elsif channel == :github
    result += PROMPT_PRE_POST_CHECK_GITHUB
  end

  result += PROMPT_REFLECTION

  vars["KNOWLEDGE_DIR"] ||= KNOWLEDGE_DIR
  vars["MEMORY_DIR"] ||= memory_dir_for(agent_name)
  vars["PERSONA_DIR"] ||= persona_dir_for(agent_name)
  vars["PERSONA_COLLECTION"] ||= persona_collection_for(agent_name)
  vars["AGENT_NAME"] ||= agent_name

  # Populate column IDs from board config (defined by fizzy handler/plugin)
  if defined?(DEFAULT_COLUMN_IDS)
    DEFAULT_COLUMN_IDS.each do |col_name, default_id|
      var_name = "#{col_name.upcase}_COLUMN_ID"
      vars[var_name] ||= (board_key && board_column_id(board_key, col_name)) || default_id
    end
  end

  # Touch memory file if CARD_ID is present
  if vars["CARD_ID"]
    memory_file = File.join(vars["MEMORY_DIR"], "card-#{vars["CARD_ID"]}.md")
    FileUtils.mkdir_p(vars["MEMORY_DIR"])
    FileUtils.touch(memory_file)
  end

  roster = agent_roster
  roster_lines = roster.map { |_key, display| "  - @#{display}" }.join("\n")
  vars["AGENT_ROSTER"] ||= roster_lines

  vars.each { |key, val| result.gsub!("{{#{key}}}", val.to_s) }
  result
end
