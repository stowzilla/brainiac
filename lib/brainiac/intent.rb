# frozen_string_literal: true

# Local LLM-based intent detection.
#
# Uses a lightweight local model (via Ollama) to classify whether an incoming
# message requires an agent to respond. This saves expensive API tokens by
# filtering out messages that are just humans chatting, reactions, or noise.
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
  - If the message is giving {{AGENT_NAME}} instructions, asking {{AGENT_NAME}} a question, or continuing a conversation WITH {{AGENT_NAME}} → yes
  - If the message is humans talking to each other and {{AGENT_NAME}} is not being addressed → no
  - If the message is a simple acknowledgment (like "thanks", "ok", "got it") directed at {{AGENT_NAME}}'s previous work → no
  - If the message is asking a question to another person or agent → no
  - If uncertain, lean toward yes (better to respond unnecessarily than miss a request)

  Respond with ONLY "yes" or "no" — nothing else.

  Latest message:
  {{MESSAGE}}
PROMPT

# Load intent config from brainiac.json, merging with defaults.
def intent_config
  raw = BRAINIAC_CONFIG["intent"] || {}
  INTENT_CONFIG_DEFAULTS.merge(raw)
end

# Check whether a message requires an agent to respond.
#
# @param message [String] The message text to classify
# @param agent_name [String] The agent being addressed
# @param channel [String] Context description (e.g., "Discord thread", "Fizzy card comment")
# @return [Boolean] true if the agent should respond, false if it can be skipped
def check_intent(message, agent_name:, channel: "conversation")
  config = intent_config
  return true unless config["enabled"]
  return true if message.nil? || message.strip.empty?

  prompt = INTENT_PROMPT_TEMPLATE
    .gsub("{{AGENT_NAME}}", agent_name)
    .gsub("{{CHANNEL}}", channel)
    .gsub("{{MESSAGE}}", message.strip)

  response = query_local_llm(prompt, config)
  positive_intent?(response)
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
  raise "Ollama returned #{response.code}: #{response.body&.slice(0, 200)}" unless response.is_a?(Net::HTTPSuccess)

  body = JSON.parse(response.body)
  body["response"] || ""
rescue Errno::ECONNREFUSED
  raise "Ollama not running at #{config["endpoint"]}"
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
  return false if cleaned == "no"

  LOG.debug "[Intent] Classified as: #{response.strip}" if cleaned == "yes"
  true
end
