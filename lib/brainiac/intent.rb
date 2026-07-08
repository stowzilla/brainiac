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
#     "endpoint": "http://localhost:11434/api/generate",
#     "model": "gemma3:4b",
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
  "endpoint" => "http://localhost:11434/api/generate",
  "model" => "gemma3:4b",
  "timeout" => 10,
  "temperature" => 0.1
}.freeze

INTENT_PROMPT_TEMPLATE = <<~PROMPT
  You are a message router for a {{CHANNEL}}. An AI agent named {{AGENT_NAME}} is participating in this conversation. Your job: determine if the latest message requires {{AGENT_NAME}} to take action or respond.

  Rules:
  - If the message addresses {{AGENT_NAME}} by name, gives {{AGENT_NAME}} instructions, or asks {{AGENT_NAME}} a question → yes
  - If the message continues a conversation directed at {{AGENT_NAME}} (e.g. {{AGENT_NAME}} was the last to respond and the human follows up) → yes
  - If the message starts with or addresses a DIFFERENT person/agent (not {{AGENT_NAME}}) → no
  - If the message is humans talking to each other and {{AGENT_NAME}} is not being addressed → no
  - If the message is a simple acknowledgment ("thanks", "ok", "got it") directed at {{AGENT_NAME}}'s previous work → no
  - If the message is asking a question to another person or agent (not {{AGENT_NAME}}) → no
  - If the message is responding to or commenting on what someone OTHER than {{AGENT_NAME}} just said → no
  - If the conversation context shows a DIFFERENT agent was the last to respond, and the human's follow-up does not mention {{AGENT_NAME}} by name → no
  - If uncertain, lean toward yes (better to respond unnecessarily than miss a request)

  Critical: "addresses someone else" means someone whose name is NOT {{AGENT_NAME}}. If the message says "{{AGENT_NAME}}, ..." that IS addressed to {{AGENT_NAME}} → yes.

  Respond with ONLY "yes" or "no" — nothing else.

  {{CONTEXT}}Latest message:
  {{MESSAGE}}
PROMPT

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
# @param message [String] The message text to classify
# @param agent_name [String] The agent being addressed
# @param channel [String] Context description (e.g., "Discord thread", "Fizzy card comment")
# @return [Boolean] true if the agent should respond, false if it can be skipped
def check_intent(message, agent_name:, channel: "conversation", context: nil)
  config = intent_config
  return true unless config["enabled"]
  return true if message.nil? || message.strip.empty?

  context_block = if context && !context.strip.empty?
                    # Keep only last 5 messages for the small local model — enough to determine
                    # conversational flow without overwhelming the context window.
                    recent = context.strip.lines.last(5).join
                    "Recent conversation (most recent last):\n#{recent}\n\n"
                  else
                    ""
                  end

  prompt = INTENT_PROMPT_TEMPLATE
           .gsub("{{AGENT_NAME}}", agent_name)
           .gsub("{{CHANNEL}}", channel)
           .gsub("{{CONTEXT}}", context_block)
           .gsub("{{MESSAGE}}", message.strip)

  LOG.info "[Intent] Checking intent for #{agent_name} (#{channel}): #{message.strip.slice(0, 80)}..."
  response = query_local_llm(prompt, config)
  result = positive_intent?(response)
  LOG.info "[Intent] Result: #{result ? "RESPOND" : "SKIP"} (model: #{config["model"]})"
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
# @return [String] Raw response text from the model
def query_local_llm(prompt, config)
  uri = URI(config["endpoint"])
  payload = {
    model: config["model"],
    prompt: prompt,
    stream: false,
    options: { temperature: config["temperature"] }
  }

  http = Net::HTTP.new(uri.host, uri.port)
  http.open_timeout = config["timeout"]
  http.read_timeout = config["timeout"]

  request = Net::HTTP::Post.new(uri.path, "Content-Type" => "application/json")
  request.body = JSON.generate(payload)

  response = http.request(request)

  unless response.is_a?(Net::HTTPSuccess)
    raise OllamaModelNotFoundError.new(config["model"], config["endpoint"]) if response.code == "404" && response.body&.include?("not found")

    raise "Ollama returned #{response.code}: #{response.body&.slice(0, 200)}"
  end

  body = JSON.parse(response.body)
  body["response"] || ""
rescue Errno::ECONNREFUSED
  raise "Ollama not running at #{config["endpoint"]}. Start it with: ollama serve"
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
