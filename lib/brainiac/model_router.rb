# frozen_string_literal: true

# Automatic model selection via TypeSafe's Jev (System One) model.
#
# When no explicit [model] tag is present, this module calls Jev to classify
# the incoming message by task complexity and type, then maps that to an
# appropriate model from the project's allowed_models.
#
# Configuration (in ~/.brainiac/brainiac.json):
#
#   "model_router": {
#     "enabled": true,
#     "typesafe_api_key": "ts_..." OR "op://vault/item/field",
#     "cache_ttl": 300,
#     "timeout": 5,
#     "model_tiers": {
#       "simple": ["haiku", "sonnet"],
#       "moderate": ["sonnet"],
#       "complex": ["opus"]
#     }
#   }
#
# The model_tiers define fallback chains: for "simple" tasks, try haiku first,
# fall back to sonnet if the profile doesn't have haiku access. Each tier
# is tried in order until a model available in allowed_models is found.
#
# API key can be:
# - A literal key starting with "ts_"
# - A 1Password reference like "op://vault/item/field" (resolved via `op read`)

require "net/http"
require "json"
require "uri"

MODEL_ROUTER_DEFAULTS = {
  "enabled" => false,
  "typesafe_endpoint" => "https://api.typesafe.ai/v1/systemone",
  "typesafe_model" => "jev-latest",
  "timeout" => 5,
  "cache_ttl" => 300,
  "min_confidence" => 0.4,
  "model_tiers" => {
    "simple" => %w[haiku sonnet],
    "moderate" => %w[sonnet opus],
    "complex" => %w[opus]
  }
}.freeze

# Questions sent to Jev for task classification
MODEL_ROUTER_QUESTIONS = {
  "complexity" => {
    "type" => "choice",
    "instructions" => "What level of cognitive work does this message require?",
    "criteria" => {
      "simple" => "Quick factual answer, clarification, acknowledgment, or simple lookup",
      "moderate" => "Implementation task, bug fix, focused investigation, or straightforward code change",
      "complex" => "System design, architecture decisions, multi-file refactoring, novel problem solving, or creative work"
    }
  }
}.freeze

# Thread-safe cache for routing decisions
def model_router_cache
  @model_router_cache ||= {}
end

def model_router_cache_mutex
  @model_router_cache_mutex ||= Mutex.new
end

# Load model router config from brainiac.json, merging with defaults.
def model_router_config
  raw = BRAINIAC_CONFIG["model_router"] || {}
  MODEL_ROUTER_DEFAULTS.merge(raw)
end

# Check if model routing is enabled and configured.
def model_router_enabled?
  config = model_router_config
  config["enabled"] && resolve_typesafe_api_key(config).to_s.start_with?("ts_")
end

# Resolve the TypeSafe API key, supporting both literal keys and 1Password references.
#
# @param config [Hash] Model router configuration
# @return [String, nil] The resolved API key or nil if not configured
def resolve_typesafe_api_key(config)
  key_config = config["typesafe_api_key"]
  return nil if key_config.nil? || key_config.empty?

  # 1Password reference: op://vault/item/field
  if key_config.start_with?("op://")
    resolve_typesafe_key_from_1password(key_config)
  else
    key_config
  end
end

# Resolve a TypeSafe API key from 1Password using `op read`.
# Caches the result for 1 hour to avoid repeated CLI calls.
#
# @param op_ref [String] The 1Password reference (e.g., "op://vault/item/field")
# @return [String, nil] The resolved key or nil on failure
def resolve_typesafe_key_from_1password(op_ref)
  @typesafe_key_cache ||= {}
  @typesafe_key_cache_time ||= {}

  # Return cached value if fresh (1 hour TTL)
  if @typesafe_key_cache[op_ref] && @typesafe_key_cache_time[op_ref]
    age = Time.now - @typesafe_key_cache_time[op_ref]
    return @typesafe_key_cache[op_ref] if age < 3600
  end

  # Resolve via op CLI
  require "open3"
  output, status = Open3.capture2("op", "read", op_ref)

  if status.success?
    resolved = output.chomp
    @typesafe_key_cache[op_ref] = resolved
    @typesafe_key_cache_time[op_ref] = Time.now
    resolved
  else
    LOG.warn "[ModelRouter] Failed to resolve 1Password reference: #{op_ref}"
    nil
  end
rescue Errno::ENOENT
  LOG.warn "[ModelRouter] 1Password CLI (op) not found — install from https://1password.com/downloads/command-line"
  nil
end

# Select a model based on Jev classification of the message.
#
# @param message [String] The user's message/request
# @param allowed_models [Hash] The project's allowed_models mapping (e.g., {"opus" => "claude-opus-4.5"})
# @param channel [Symbol, nil] The channel for cache key differentiation (e.g., :discord, :fizzy)
# @param context_id [String, nil] Thread/card ID for per-conversation caching
# @return [String, nil] The selected model key (e.g., "opus") or nil to use default
def select_model_via_jev(message, allowed_models:, channel: nil, context_id: nil)
  return nil unless model_router_enabled?
  return nil if allowed_models.nil? || allowed_models.empty?

  config = model_router_config

  # Check cache first (same conversation often has similar complexity)
  cache_key = "#{channel}:#{context_id}" if context_id
  if cache_key
    cached = check_router_cache(cache_key, config["cache_ttl"])
    if cached
      LOG.debug "[ModelRouter] Cache hit for #{cache_key}: #{cached[:complexity]} → #{cached[:model]}"
      return cached[:model]
    end
  end

  # Call Jev for classification
  begin
    response = call_typesafe_api(message, config)
    return nil unless response

    complexity_answer = response.dig("answers", "complexity")
    return nil unless complexity_answer

    complexity = complexity_answer["choice"]
    confidence = complexity_answer["confidence"] || 0

    # Low confidence → don't override default (fail-safe)
    if confidence < config["min_confidence"]
      LOG.info "[ModelRouter] Low confidence (#{confidence}) for complexity=#{complexity}, using default model"
      return nil
    end

    # Map complexity to best available model
    model_key = select_model_for_complexity(complexity, allowed_models, config["model_tiers"])

    LOG.info "[ModelRouter] Classified as #{complexity} (confidence: #{confidence.round(2)}) → #{model_key || "default"}"

    # Cache the decision
    update_router_cache(cache_key, complexity: complexity, model: model_key) if cache_key && model_key

    model_key
  rescue StandardError => e
    LOG.warn "[ModelRouter] Jev classification failed: #{e.message}"
    nil # Fail-open: use default model on any error
  end
end

# Call TypeSafe API with the message and routing questions.
#
# @param message [String] The user's message
# @param config [Hash] Model router configuration
# @return [Hash, nil] The API response or nil on failure
def call_typesafe_api(message, config)
  api_key = resolve_typesafe_api_key(config)
  return nil unless api_key

  uri = URI(config["typesafe_endpoint"])
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = uri.scheme == "https"
  http.open_timeout = config["timeout"]
  http.read_timeout = config["timeout"]

  request = Net::HTTP::Post.new(uri)
  request["Authorization"] = "Bearer #{api_key}"
  request["Content-Type"] = "application/json"
  request.body = JSON.generate({
                                 "state" => message,
                                 "model" => config["typesafe_model"],
                                 "questions" => MODEL_ROUTER_QUESTIONS
                               })

  response = http.request(request)

  case response.code.to_i
  when 200
    JSON.parse(response.body)
  when 401
    LOG.error "[ModelRouter] TypeSafe API key invalid — check typesafe_api_key in brainiac.json"
    nil
  when 429
    LOG.warn "[ModelRouter] TypeSafe rate limited"
    nil
  else
    LOG.warn "[ModelRouter] TypeSafe API error: #{response.code} #{response.body}"
    nil
  end
rescue Net::OpenTimeout, Net::ReadTimeout
  LOG.warn "[ModelRouter] TypeSafe API timeout (#{config["timeout"]}s)"
  nil
rescue JSON::ParserError => e
  LOG.warn "[ModelRouter] TypeSafe API response parse error: #{e.message}"
  nil
end

# Select the best available model for a complexity tier.
#
# @param complexity [String] The complexity level ("simple", "moderate", "complex")
# @param allowed_models [Hash] The project's allowed_models
# @param model_tiers [Hash] Tier→model key mappings
# @return [String, nil] The first available model key, or nil if none found
def select_model_for_complexity(complexity, allowed_models, model_tiers)
  tier_models = model_tiers[complexity] || model_tiers["moderate"]
  return nil unless tier_models

  # Find first model in the tier that's available in this project/profile
  tier_models.each do |model_key|
    return model_key if allowed_models.key?(model_key)
  end

  # No tier model available — return nil to use default
  nil
end

# Check the routing cache for a recent decision.
#
# @param cache_key [String] The cache key (channel:context_id)
# @param ttl [Integer] Cache TTL in seconds
# @return [Hash, nil] Cached decision or nil
def check_router_cache(cache_key, ttl)
  model_router_cache_mutex.synchronize do
    entry = model_router_cache[cache_key]
    return nil unless entry

    age = Time.now - entry[:timestamp]
    return nil if age > ttl

    entry
  end
end

# Update the routing cache with a new decision.
#
# @param cache_key [String] The cache key
# @param complexity [String] The complexity classification
# @param model [String] The selected model key
def update_router_cache(cache_key, complexity:, model:)
  model_router_cache_mutex.synchronize do
    model_router_cache[cache_key] = {
      complexity: complexity,
      model: model,
      timestamp: Time.now
    }

    # Prune old entries (keep max 1000)
    if model_router_cache.size > 1000
      sorted = model_router_cache.sort_by { |_, v| v[:timestamp] }
      @model_router_cache = sorted.last(500).to_h
    end
  end
end

# Clear the router cache (useful for testing or config reload)
def clear_model_router_cache!
  model_router_cache_mutex.synchronize do
    model_router_cache.clear
  end
end
