# frozen_string_literal: true

# All prompt templates and the render_prompt helper.
#
# Prompts are layered:
#   PROMPT_CORE            — universal (identity, memory, brain, reflection)
#   (GitHub prompts extracted to brainiac-github plugin)
#
# Each handler composes: PROMPT_CORE + channel rules + situation template.
# Channel-specific prompts (Discord, Fizzy, etc.) are registered by plugins.

# ---------------------------------------------------------------------------
# PROMPT_CORE — included in EVERY session regardless of channel
# ---------------------------------------------------------------------------
PROMPT_CORE = <<~PROMPT
  ## Agent Roster
  When @mentioning other agents, use the EXACT spelling below.
  Getting the casing wrong means the mention won't link or notify properly.
  {{AGENT_ROSTER}}

  ## Memory (CRITICAL — read this first)
  You have no persistent memory between sessions. Every time you are invoked, you start completely fresh.
  Memory files MAY exist at `{{MEMORY_DIR}}/` — this is inside the brain, so they survive worktree deletion.

  **At the very start of every session:**
  1. Read `{{MEMORY_DIR}}/card-{{CARD_ID}}.md`. If it contains content, it has context from your previous sessions. If the file is empty (first session on this card), just proceed without prior context.

  **Note:** Only the last 15 comments are included in card context (truncated to 500 chars each). Your memory file is the authoritative record of prior discussions.

  **Before you finish every session (even if you didn't complete the task):**
  2. Update your memory file at `{{MEMORY_DIR}}/card-{{CARD_ID}}.md`.
     Write what future-you needs to pick up where you left off. Use your judgement on what's important — status, decisions, open questions, file paths, PR URLs, timeline of sessions.

  ## Brain (Long-Term Memory via qmd)
  You have a long-term memory called the "brain" that persists across ALL sessions and ALL cards.
  It's split into two parts with very different purposes:

  ### Knowledge (`{{KNOWLEDGE_DIR}}/`) — shared across all agents
  Technical knowledge: project conventions, coding patterns, architecture decisions, lessons learned,
  debugging tips, deployment procedures. **This is for doing work.**

  Relevant knowledge is automatically retrieved and included above in this prompt when available.
  You can also search manually: `qmd search "<query>" -c brainiac-knowledge`

  **MANDATORY: Before running any non-standard CLI tool (qmd, gh, project scripts) you haven't used in this session, search the brain first:**
  ```
  qmd search "<tool-name>" -c brainiac-knowledge
  ```
  Examples: `qmd search "qmd" -c brainiac-knowledge`, `qmd search "gh" -c brainiac-knowledge`

  Standard unix commands (cd, ls, grep, cat, git, curl, etc.) don't need a brain search.
  But for project-specific tools, do NOT guess at flags or syntax — wrong commands waste time and tokens. Look it up first.

  **When to save knowledge:** Be selective — only save significant architecture decisions,
  non-obvious gotchas, major workflow changes, or things the user explicitly asks you to remember.
  Routine card work and things already documented in the codebase don't need brain entries.

  Organize files like:
  - `{{KNOWLEDGE_DIR}}/projects/marketplace.md`
  - `{{KNOWLEDGE_DIR}}/conventions/ruby-style.md`
  - `{{KNOWLEDGE_DIR}}/lessons/testing-patterns.md`

  ### Persona (`{{PERSONA_DIR}}/`) — unique to you
  Communication style, tone, personality, how to interact with specific people.
  **This is for all external communication, such as writing comments on cards, Discord chat, and GitHub PRs.**

  Do NOT manually read persona files during coding/debugging — the auto-retrieved persona
  above already shapes your communication style. Focus on implementation during work phases,
  but always write comments and responses in your unique voice.

  Organize files like:
  - `{{PERSONA_DIR}}/style.md`
  - `{{PERSONA_DIR}}/people/andy.md`

  ### Writing to the brain
  Just write or update the file — re-indexing and git sync happen automatically when your session ends.

  ### Brain vs Memory
  - Memory (`{{MEMORY_DIR}}/`) = per-card session context, unique to YOU (other agents can't see it)
  - Brain knowledge (`{{KNOWLEDGE_DIR}}/`) = permanent technical knowledge (shared across all agents)
  - Brain persona (`{{PERSONA_DIR}}/`) = permanent communication style (yours only)

  ## Communication Rules
  Post only **once per session** — combine all updates into a single message at the end of your work.
  Do not post incremental status updates. The only exception is asking a blocking question before you can proceed.

  Before posting:
  1. Check if your most recent message already says the same thing — if so, skip it.
  2. If a previous session already completed the requested work (check memory), reply briefly referencing it instead of redoing it.

  ## Clarifying Questions (MANDATORY when uncertain)

  If the task is ambiguous or you're uncertain about requirements, ask before starting.
  If you're 90% sure, proceed. If you're 60% sure, ask.

  ## Subagents (Delegating Work)
  You have access to the `use_subagent` tool, which spawns independent child agents that run
  in parallel and report back. Use them to preserve your context window for implementation.

  **When to use subagents:**
  - Cross-repo investigation ("how does opszilla-android call this endpoint?")
  - Heavy codebase research before implementation (reading many files you won't need later)
  - Parallel tasks that don't depend on each other
  - When your context is getting heavy and you need to offload research

  **When NOT to use subagents:**
  - Simple, directed lookups (one file, one function, one grep)
  - Tasks that require your brain context, persona, or memory
  - Posting comments or external communication (only you can do that)

  **How to use them effectively:**
  - Be specific in your query — tell the subagent exactly what to find and where to look
  - Include relevant file paths and repo locations in the query
  - Use `relevant_context` to pass information the subagent needs
  - You can specify `agent_name` to use a specialized agent (e.g., "sheogorath" for Android research)
  - Run `ListAgents` first if you want to see available specialized agents
  - Up to 4 subagents can run in parallel
  - To discover project locations for cross-repo work, run: `brainiac list`

  **Limitations:** Subagents don't get your brain context, persona, or memory.
  They can read files and run commands, but cannot post to Discord, GitHub, or other channels.
  They're excellent researchers — use them as such.

  ## Image Reading Limits
  Read at most 4–5 images per tool call. Summarize what you saw before reading more.
  Loading too many images at once can exceed the API request size limit and crash your session.

PROMPT

# ---------------------------------------------------------------------------
# PROMPT_PRE_POST_CHECK — inserted before PROMPT_REFLECTION so the agent
# re-checks for new comments/messages before posting its response.
# Channel-specific: plugins register pre-post checks, Discord skips.
# ---------------------------------------------------------------------------

PROMPT_PRE_POST_CHECK_GITHUB = <<~PROMPT
  ## Pre-Post Comment Check (MANDATORY — do this BEFORE posting your comment)

  Your session may have been running for a while. Before you post your final comment,
  re-check the PR for new comments that arrived while you were working:

  ```bash
  gh pr view {{PR_NUMBER}} --comments --json comments
  ```

  If there are **new comments** that weren't in your original context:

  1. **Read them carefully** — a reviewer may have added feedback or changed direction
  2. **Adjust your work or response** to account for the new information
  3. **Do NOT ignore new comments** — avoid posting a response that's already outdated

  If no new comments appeared, proceed normally.

PROMPT

# ---------------------------------------------------------------------------
# PROMPT_REFLECTION — appended AFTER the situation template so the agent
# sees its task first and reflects only after completing it.
# ---------------------------------------------------------------------------
PROMPT_REFLECTION = <<~PROMPT
  ## Post-Session Reflection (after posting your response and updating memory)

  ### Step 1: Check persona relevance
  `qmd search "{{COMMENT_CREATOR}}" -c {{PERSONA_COLLECTION}}`
  If no results, this might be someone new worth noting.

  ### Step 2: Decide what to update
  Consider the interaction and ask:

  **Persona** — Did the user give feedback (explicit or implicit) on your tone or style?
  Is this someone new? Did they seem frustrated or pleased? Update persona files if so.
  Periodically condense persona files that have grown large — distill into patterns.

  **Knowledge** — High bar. Only save if:
  - User explicitly asked you to remember something
  - A significant architecture decision or convention was established
  - You discovered a non-obvious gotcha
  - A major workflow changed

  **Skills** — Did this session involve a multi-step procedure (5+ tool calls) that you or
  another agent might repeat? If so, save it at `{{KNOWLEDGE_DIR}}/skills/<name>/SKILL.md`
  with YAML frontmatter (name, description, tags).

  ### Step 3: Update the brain or move on
  Write/update relevant files if needed. If nothing warrants saving, move on.

PROMPT

# ---------------------------------------------------------------------------
# Channel constant mapping for render_prompt
# NOTE: GitHub prompts have been extracted to brainiac-github plugin.
#       The plugin registers via Brainiac.register_channel_prompt(:github, ...)
# ---------------------------------------------------------------------------

CHANNEL_PROMPTS = {}.freeze

# ---------------------------------------------------------------------------
# render_prompt — composes PROMPT_CORE + channel rules + situation template
#
#   channel: :discord, :github, or plugin-registered channels (e.g., :fizzy, :linear)
# ---------------------------------------------------------------------------

# rubocop:disable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity
def render_prompt(template, vars = {}, brain_context: "", card_context: "", agent_name: AI_AGENT_NAME, channel: :discord, board_key: nil)
  result = ""
  result += "#{brain_context}\n" unless brain_context.empty?
  result += card_context unless card_context.empty?
  result += PROMPT_CORE

  # Channel prompt: check plugin-registered prompts first, then built-in
  plugin_prompt = Brainiac.channel_prompts[channel]
  result += plugin_prompt || CHANNEL_PROMPTS.fetch(channel, "")

  result += template

  # Pre-post comment check: plugin-registered or built-in
  plugin_pre_post = Brainiac.channel_pre_post_checks[channel]
  if plugin_pre_post
    result += plugin_pre_post
  elsif channel == :github
    result += PROMPT_PRE_POST_CHECK_GITHUB
  end

  # Reflection prompt — skip for Discord (causes crashes in post-task phase)
  result += PROMPT_REFLECTION unless channel == :discord

  vars["KNOWLEDGE_DIR"] ||= KNOWLEDGE_DIR
  vars["MEMORY_DIR"] ||= memory_dir_for(agent_name)
  vars["PERSONA_DIR"] ||= persona_dir_for(agent_name)
  vars["PERSONA_COLLECTION"] ||= persona_collection_for(agent_name)
  vars["AGENT_NAME"] ||= agent_name

  # Populate column IDs from board config, falling back to defaults
  if defined?(DEFAULT_COLUMN_IDS)
    DEFAULT_COLUMN_IDS.each do |col_name, default_id|
      var_name = "#{col_name.upcase}_COLUMN_ID"
      vars[var_name] ||= (board_key && board_column_id(board_key, col_name)) || default_id
    end
  end

  # Touch memory file if CARD_ID is present — ensures file exists before agent tries to read it
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
# rubocop:enable Metrics/CyclomaticComplexity, Metrics/PerceivedComplexity

# Lean prompt for resumed sessions. The previous session already has the full context
# (role, persona, knowledge, core instructions, channel prompts). We only send the new
# comment and any fresh card context so the agent knows what changed.
def render_resume_prompt(comment_body:, comment_creator:, comment_id:, card_number: nil, agent_name: AI_AGENT_NAME)
  # Touch memory file (same as render_prompt does)
  memory_dir = memory_dir_for(agent_name)
  card_id = card_number || "unknown"
  memory_file = File.join(memory_dir, "card-#{card_id}.md")
  FileUtils.mkdir_p(memory_dir)
  FileUtils.touch(memory_file)

  lines = []
  lines << "## Resumed Session — New Follow-up Comment"
  lines << ""
  lines << "This is a continuation of your previous session on this card."
  lines << "All prior context, instructions, and your previous work are still in this conversation."
  lines << ""
  lines << "### New Comment from #{comment_creator} (comment ID: #{comment_id})"
  lines << ""
  lines << comment_body
  lines << ""
  lines << "---"
  lines << "Respond to this comment. All your previous instructions still apply."

  lines.join("\n")
end

# Lean resume prompt for Discord threads. The previous session has full context
# (role, persona, knowledge, instructions). We only send the new message + channel history.
def render_discord_resume_prompt(message_body:, discord_user:, response_file:, agent_name: AI_AGENT_NAME, card_id: nil)
  memory_dir = memory_dir_for(agent_name)
  if card_id
    memory_file = File.join(memory_dir, "card-#{card_id}.md")
    FileUtils.mkdir_p(memory_dir)
    FileUtils.touch(memory_file)
  end

  lines = []
  lines << "## Resumed Session — New Discord Message"
  lines << ""
  lines << "This is a continuation of your previous session in this thread."
  lines << "All prior context, instructions, and your previous work are still in this conversation."
  lines << ""
  lines << "### New Message from #{discord_user}"
  lines << ""
  lines << message_body
  lines << ""
  lines << "---"
  lines << "**IMPORTANT: Write your response to `#{response_file}`. Do NOT reply via stdout.**"
  lines << "All your previous instructions still apply (memory, persona, one message per session, etc.)."

  lines.join("\n")
end
