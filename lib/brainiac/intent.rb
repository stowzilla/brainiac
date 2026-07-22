# frozen_string_literal: true

# Local LLM-based intent detection.
#
# Uses a lightweight local model (via Ollama) to classify whether an incoming
# message requires an agent to respond. This saves expensive API tokens by
# filtering out messages that are just humans chatting, reactions, or noise.
#
# Also detects when an agent's own response implies pending work — if the agent
# said "I'll do X" but the session ended without completing the work, this
# signals that the agent should be re-dispatched.
#
# Configuration (in ~/.brainiac/brainiac.json):
#
#   "intent": {
#     "enabled": true,
#     "endpoint": "http://localhost:11434/api/chat",
#     "model": "qwen3:1.7b",
#     "timeout": 10,
#     "temperature": 0.1
#   }
#
# Plugins use this via:
#   requires_response = check_intent(message, agent_name: "Galen", context: "Discord thread")
#   return unless requires_response
#
# Returns true (agent should respond), false (skip), or true on any failure
# (fail-open so we never accidentally ignore a real request).

INTENT_CONFIG_DEFAULTS = {
  "enabled" => false,
  "endpoint" => "http://localhost:11434/api/chat",
  "model" => "qwen2.5:3b",
  "timeout" => 10,
  "temperature" => 0.0
}.freeze

INTENT_PROMPT_TEMPLATE = <<~PROMPT
  Agents in this chat: {{AGENT_ROSTER}}
  {{LAST_RESPONDER}}

  Human's message: "{{MESSAGE}}"

  Is this message directed at {{AGENT_NAME}}? Answer yes or no.
PROMPT

# Words/phrases that indicate pure acknowledgment — no action needed from the agent.
ACKNOWLEDGMENT_PATTERN = /\A\s*(thanks|thank you|thx|ty|ok|okay|k|got it|sounds good|cool|nice|👍|🙏|✅)\s*[.!]?\s*\z/i

PENDING_WORK_PROMPT_TEMPLATE = <<~PROMPT
  You are analyzing a message posted by an AI agent named {{AGENT_NAME}}. Your job: determine if this message indicates the agent intends to do more work that hasn't been completed yet.

  Rules:
  - If the agent says it will do something, is about to start work, or promises a follow-up action → yes
  - If the agent is reporting completed work, summarizing what was done, or delivering a final answer → no
  - If the agent is asking a clarifying question and waiting for a human response → no
  - If the agent says things like "give me a sec", "I'll implement this", "let me do that", "working on it" → yes
  - If uncertain, lean toward no (avoid unnecessary re-dispatches)

  Respond with ONLY "yes" or "no" — nothing else.

  Agent's message:
  {{MESSAGE}}
PROMPT

# Custom error for missing Ollama models — provides actionable install instructions.
class OllamaModelNotFoundError < RuntimeError
  attr_reader :model_name, :endpoint

  def initialize(model_name, endpoint)
    @model_name = model_name
    @endpoint = endpoint
    super(<<~MSG.strip)
      Ollama model '#{model_name}' is not installed.

      To install it, run:
        ollama pull #{model_name}

      Or change the model in ~/.brainiac/brainiac.json → intent.model

      Available models can be listed with:
        ollama list
    MSG
  end
end

# Load intent config from brainiac.json, merging with defaults.
def intent_config
  raw = BRAINIAC_CONFIG["intent"] || {}
  INTENT_CONFIG_DEFAULTS.merge(raw)
end

# Validate that the configured intent model is available in Ollama.
# Called at server startup — aborts with a helpful error if the model is missing.
#
# @param config [Hash] Intent configuration
# @raise [OllamaModelNotFoundError] if the model isn't installed
def validate_intent_model!(config)
  base_uri = URI(config["endpoint"])
  show_uri = URI("#{base_uri.scheme}://#{base_uri.host}:#{base_uri.port}/api/show")

  http = Net::HTTP.new(show_uri.host, show_uri.port)
  http.open_timeout = 5
  http.read_timeout = 5

  request = Net::HTTP::Post.new(show_uri.path, "Content-Type" => "application/json")
  request.body = JSON.generate({ model: config["model"] })

  response = http.request(request)

  if response.code == "404" || (!response.is_a?(Net::HTTPSuccess) && response.body&.include?("not found"))
    raise OllamaModelNotFoundError.new(config["model"], config["endpoint"])
  end

  true
rescue Errno::ECONNREFUSED
  raise "Ollama is not running at #{config["endpoint"]}. Start it with: ollama serve"
rescue Net::OpenTimeout, Net::ReadTimeout
  LOG.warn "[Intent] Could not validate model (Ollama timed out) — will check at first use"
  true
end

# Check whether a message requires an agent to respond.
#
# Uses a layered approach:
# 1. Deterministic pre-checks (fast, no LLM):
#    - If message names another agent → skip
#    - If this agent was last to speak AND message isn't pure acknowledgment → respond
#    - If a different agent was last to speak AND message doesn't name this agent → skip
# 2. LLM fallback (only for ambiguous cases — no agent spoke, or mixed signals)
#
# @param message [String] The message text to classify
# @param agent_name [String] The agent being addressed
# @param channel [String] Context description (e.g., "Discord thread", "Fizzy card comment")
# @param context [String, nil] Recent conversation history for flow detection
# @return [Boolean] true if the agent should respond, false if it can be skipped
def check_intent(message, agent_name:, channel: "conversation", context: nil)
  config = intent_config
  return true unless config["enabled"]
  return true if message.nil? || message.strip.empty?

  # Deterministic pre-check: if the message explicitly names another agent
  # and does NOT name this agent, skip without consulting the LLM.
  # This handles the common case of "Effie, tell me another" when checking Galen.
  if intent_names_other_agent?(message, agent_name)
    LOG.info "[Intent] Deterministic skip for #{agent_name} — message addresses another agent"
    return false
  end

  # Deterministic conversational-flow check: use last-responder detection to
  # resolve the common case without hitting the LLM at all.
  last_responder = detect_last_responder_name(context)

  if last_responder
    is_acknowledgment = message.strip.match?(ACKNOWLEDGMENT_PATTERN)

    if last_responder.downcase == agent_name.downcase
      # This agent was the last to speak — human is continuing with us
      if is_acknowledgment
        LOG.info "[Intent] Deterministic skip for #{agent_name} — pure acknowledgment, no action needed"
        return false
      end
      LOG.info "[Intent] Deterministic respond for #{agent_name} — was last to speak, human continues"
      return true
    else
      # A different agent was the last to speak — this message is probably for them
      # UNLESS it explicitly names this agent (already checked above via intent_names_other_agent? for OTHER agents,
      # but also check if it mentions THIS agent's name directly)
      if message_mentions_agent?(message, agent_name)
        LOG.info "[Intent] Deterministic respond for #{agent_name} — named in message despite #{last_responder} speaking last"
        return true
      end
      LOG.info "[Intent] Deterministic skip for #{agent_name} — #{last_responder} was last to speak"
      return false
    end
  end

  # No clear last responder detected — fall through to LLM for classification.
  # This handles cases like: no agents have spoken yet, or context is unavailable.
  roster_block = build_intent_agent_roster(agent_name)
  last_responder_block = "No agent has spoken recently."

  prompt = INTENT_PROMPT_TEMPLATE
           .gsub("{{AGENT_NAME}}", agent_name)
           .gsub("{{AGENT_ROSTER}}", roster_block)
           .gsub("{{LAST_RESPONDER}}", last_responder_block)
           .gsub("{{MESSAGE}}", message.strip)

  LOG.info "[Intent] Checking intent for #{agent_name} (#{channel}): #{message.strip.slice(0, 80)}..."
  LOG.debug "[Intent] Full prompt:\n#{prompt}" if LOG.debug?
  response = query_local_llm(prompt, config, system: "Answer yes or no only.")
  result = positive_intent?(response)
  LOG.info "[Intent] Result for #{agent_name}: #{result ? "RESPOND" : "SKIP"} (model: #{config["model"]})"
  result
rescue OllamaModelNotFoundError => e
  LOG.error "[Intent] #{e.message}"
  LOG.error "[Intent] Disabling intent classification until model is installed."
  BRAINIAC_CONFIG["intent"] ||= {}
  BRAINIAC_CONFIG["intent"]["enabled"] = false
  true
rescue StandardError => e
  LOG.warn "[Intent] Classification failed (fail-open): #{e.message}"
  true
end

# Query the local LLM via Ollama's HTTP API.
#
# @param prompt [String] The classification prompt
# @param config [Hash] Intent configuration
# @param system [String, nil] Optional system message for output format control
# @return [String] Raw response text from the model
def query_local_llm(prompt, config, system: nil)
  endpoint = config["endpoint"]
  # Use /api/chat with think:false to disable thinking mode on models like Qwen3.
  # The /api/generate endpoint always uses thinking tokens, which generates hundreds
  # of hidden tokens for a simple yes/no answer (2.5s+ vs 0.2s with think:false).
  chat_uri = URI(endpoint.sub(%r{/api/generate\z}, "/api/chat"))

  messages = []
  messages << { role: "system", content: system } if system
  messages << { role: "user", content: prompt }

  payload = {
    model: config["model"],
    messages: messages,
    stream: false,
    think: false,
    options: { temperature: config["temperature"], num_predict: 5 }
  }

  http = Net::HTTP.new(chat_uri.host, chat_uri.port)
  http.open_timeout = config["timeout"]
  http.read_timeout = config["timeout"]

  request = Net::HTTP::Post.new(chat_uri.path, "Content-Type" => "application/json")
  request.body = JSON.generate(payload)

  response = http.request(request)

  unless response.is_a?(Net::HTTPSuccess)
    raise OllamaModelNotFoundError.new(config["model"], config["endpoint"]) if response.code == "404" && response.body&.include?("not found")

    raise "Ollama returned #{response.code}: #{response.body&.slice(0, 200)}"
  end

  body = JSON.parse(response.body)
  body.dig("message", "content") || ""
rescue Errno::ECONNREFUSED
  raise "Ollama not running at #{endpoint}. Start it with: ollama serve"
rescue Net::OpenTimeout, Net::ReadTimeout
  raise "Ollama timed out after #{config["timeout"]}s"
end

# Parse the LLM's yes/no response into a boolean.
# Fail-open: anything that isn't clearly "no" returns true.
#
# @param response [String] Raw response from the model
# @return [Boolean]
def positive_intent?(response)
  cleaned = response.to_s.strip.downcase.gsub(/[^a-z]/, "")
  cleaned != "no"
end

# Check whether an agent's own message implies pending work that wasn't completed.
# Used to detect when an agent posted "I'll do X" but the session ended without
# actually doing the work — signaling the agent should be re-dispatched.
#
# Fail-closed: returns false on any error (don't re-dispatch on classification failure).
#
# @param message [String] The agent's posted message
# @param agent_name [String] The agent who posted it
# @return [Boolean] true if the message implies uncommitted work
def check_pending_work(message, agent_name:)
  config = intent_config
  return false unless config["enabled"]
  return false if message.nil? || message.strip.empty?

  prompt = PENDING_WORK_PROMPT_TEMPLATE
           .gsub("{{AGENT_NAME}}", agent_name)
           .gsub("{{MESSAGE}}", message.strip)

  response = query_local_llm(prompt, config)
  result = pending_work_detected?(response)
  LOG.info "[Intent] Pending work detected in #{agent_name}'s message" if result
  result
rescue StandardError => e
  LOG.warn "[Intent] Pending work check failed (fail-closed): #{e.message}"
  false
end

# Parse the LLM's yes/no response for pending work detection.
# Fail-closed: anything that isn't clearly "yes" returns false.
#
# @param response [String] Raw response from the model
# @return [Boolean]
def pending_work_detected?(response)
  cleaned = response.to_s.strip.downcase.gsub(/[^a-z]/, "")
  cleaned == "yes"
end

# Deterministic check: does the message explicitly name another known agent
# without mentioning this agent? If so, the message is clearly directed elsewhere.
#
# Only triggers when:
# 1. The message contains another agent's display name (case-insensitive word boundary match)
# 2. The message does NOT contain this agent's name
#
# This avoids the LLM entirely for obvious cases like "Effie, tell me another"
# when evaluating whether Galen should respond.
#
# Determines if the message is DIRECTLY ADDRESSED to another agent (not just mentioning them).
# Only triggers on vocative patterns — where the name is used to call someone, not refer to them.
#
# Patterns that indicate direct address (skip this agent):
#   - "Effie, tell me a joke" (name + comma at start)
#   - "hey Effie one more" (greeting + name)
#   - "Another one Effie" (name at end, imperative)
#   - "Effie tell me more" (name at start, imperative — no comma but first word)
#
# Patterns that are merely MENTIONING (do NOT skip):
#   - "What do you think about Effie's answer?" (talking about Effie)
#   - "Was Effie nice to you?" (asking about Effie)
#   - "I liked what Effie said" (referencing Effie)
#
# @param message [String] The message text
# @param agent_name [String] The agent being evaluated
# @return [Boolean] true if another agent is directly addressed and this one isn't
def intent_names_other_agent?(message, agent_name)
  return false unless defined?(AGENT_REGISTRY) && !AGENT_REGISTRY.empty?

  msg_lower = message.downcase.strip
  agent_lower = agent_name.downcase

  # If this agent is DIRECTLY ADDRESSED (vocative), never skip — message is for us
  return false if directly_addressed_to?(msg_lower, agent_lower)

  # Check if any OTHER agent is directly addressed (not merely mentioned)
  AGENT_REGISTRY.each do |key, entry|
    display = entry.is_a?(Hash) ? (entry["display_name"] || key.capitalize) : key.capitalize
    other_lower = display.downcase
    next if other_lower == agent_lower
    next unless msg_lower.match?(/\b#{Regexp.escape(other_lower)}\b/)

    # Other agent is directly addressed — skip even if our name is mentioned in the body.
    # e.g. "Effie, tell Galen you're sorry" → Effie is addressee, Galen is just mentioned.
    return true if directly_addressed_to?(msg_lower, other_lower)
  end

  false
end

# Heuristics for detecting direct address (vocative use of a name).
# Returns true when the name is used to CALL someone, not talk ABOUT them.
#
# @param msg [String] Lowercased, stripped message
# @param name [String] Lowercased agent name to check
# @return [Boolean]
def directly_addressed_to?(msg, name)
  escaped = Regexp.escape(name)

  # Pattern 1: Name at the very start (with or without comma/colon)
  # "Effie, tell me a joke" / "Effie tell me more" / "Effie: do the thing"
  return true if msg.match?(/\A#{escaped}[\s,:!]/i)

  # Pattern 2: Name at the very end (imperative directed at them)
  # "Another one Effie" / "one more Effie"
  # BUT NOT when preceded by a preposition — "agree with Effie?" is about Effie, not to her
  if msg.match?(/\s#{escaped}\s*[.!?]?\z/i)
    prepositions = /\b(?:with|about|from|to|for|of|by|like|than|as|at|on|against|toward|towards)\s+#{escaped}\s*[.!?]?\z/i
    return true unless msg.match?(prepositions)
  end

  # Pattern 3: Greeting/vocative prefix + name
  # "hey Effie" / "yo Effie" / "ok Effie" / "thanks Effie"
  return true if msg.match?(/\b(?:hey|hi|yo|ok|okay|thanks|thank you|please)\s+#{escaped}\b/i)

  # Pattern 4: Name followed by comma mid-sentence (vocative comma)
  # "so Effie, what do you think?"
  return true if msg.match?(/\b#{escaped}\s*,/i)

  false
end

# Build a compact agent roster string for the intent prompt.
# Returns a comma-separated list of agent display names.
#
# @param agent_name [String] The current agent (unused but kept for interface consistency)
# @return [String] Comma-separated agent names
def build_intent_agent_roster(agent_name)
  return agent_name unless defined?(AGENT_REGISTRY) && !AGENT_REGISTRY.empty?

  names = AGENT_REGISTRY.map do |key, entry|
    entry.is_a?(Hash) ? (entry["display_name"] || key.capitalize) : key.capitalize
  end.uniq

  return agent_name if names.empty?

  names.join(", ")
end

# Detect the last agent to respond in the conversation context.
# Returns a prompt-friendly string telling the model who was last to respond.
#
# The context is formatted as "username: message\n..." lines.
# We scan backwards to find the most recent line authored by a known agent.
#
# @param context [String, nil] Conversation history
# @param agent_name [String] The current agent being evaluated
# @return [String] Prompt block describing the last responder
def detect_last_responder(context, agent_name)
  return "No agent has spoken yet." if context.nil? || context.strip.empty?
  return "No agent has spoken yet." unless defined?(AGENT_REGISTRY) && !AGENT_REGISTRY.empty?

  # Build a lookup of agent display names (lowercase) to their proper display name
  agent_names = {}
  AGENT_REGISTRY.each do |key, entry|
    display = entry.is_a?(Hash) ? (entry["display_name"] || key.capitalize) : key.capitalize
    agent_names[display.downcase] = display
  end

  # Scan context lines in reverse to find the last agent message
  lines = context.strip.lines.reverse
  lines.each do |line|
    # Lines are formatted as "username: message content"
    match = line.match(/\A(\S+?):\s/)
    next unless match

    username = match[1].downcase
    if agent_names.key?(username)
      responder = agent_names[username]
      if responder.downcase == agent_name.downcase
        return "#{responder} was the last to speak. The human is continuing the conversation with #{responder}."
      else
        return "#{responder} was the last to speak. The human is continuing the conversation with #{responder}."
      end
    end
  end

  "No agent has spoken yet."
end

# Detect the last agent to respond — returns just the display name (or nil).
# Used for deterministic conversational-flow checks without LLM involvement.
#
# @param context [String, nil] Conversation history
# @return [String, nil] Display name of last agent to speak, or nil
def detect_last_responder_name(context)
  return nil if context.nil? || context.strip.empty?
  return nil unless defined?(AGENT_REGISTRY) && !AGENT_REGISTRY.empty?

  agent_names = {}
  AGENT_REGISTRY.each do |key, entry|
    display = entry.is_a?(Hash) ? (entry["display_name"] || key.capitalize) : key.capitalize
    agent_names[display.downcase] = display
  end

  context.strip.lines.reverse_each do |line|
    match = line.match(/\A(\S+?):\s/)
    next unless match

    username = match[1].downcase
    return agent_names[username] if agent_names.key?(username)
  end

  nil
end

# Check if a message contains a direct reference to a specific agent's name.
# More permissive than intent_names_other_agent? — catches any occurrence of the name.
#
# @param message [String] The message text
# @param agent_name [String] The agent name to look for
# @return [Boolean] true if the agent is mentioned by name
def message_mentions_agent?(message, agent_name)
  return false if message.nil? || agent_name.nil?

  escaped = Regexp.escape(agent_name)
  message.match?(/\b#{escaped}\b/i)
end
