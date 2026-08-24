# frozen_string_literal: true

# Standalone model output parsing — shared between bin/brainiac (CLI) and lib/brainiac/helpers.rb (server).
# No dependencies beyond Ruby stdlib (json).

require "json"

# Parse the output of a list_models_command.
# Supports JSON output with a "models" array, or plain text lines with model names.
# Normalizes various field names (slug, model_name) to "model_id" for consistency.
def parse_list_models_output(output)
  return nil if output.nil? || output.strip.empty?

  # Try parsing the entire output as JSON first (handles well-formed JSON from any CLI)
  begin
    data = JSON.parse(output)
    return normalize_model_list(data["models"]) if data.is_a?(Hash) && data["models"].is_a?(Array)
    return normalize_model_list(data) if data.is_a?(Array)
  rescue JSON::ParserError
    # Not pure JSON — try to extract JSON from mixed output
  end

  # Some CLIs output non-JSON text before the JSON (like kiro-cli with --format json).
  # Find the first line containing a JSON object with "models" and try parsing from there.
  lines = output.lines
  lines.each_with_index do |line, idx|
    next unless line.include?('"models"') && line.strip.start_with?("{")

    json_candidate = lines[idx..].join
    begin
      data = JSON.parse(json_candidate)
      return normalize_model_list(data["models"]) if data.is_a?(Hash) && data["models"].is_a?(Array)
    rescue JSON::ParserError
      # Try next candidate
    end
  end

  # Try to find a standalone JSON array starting with [{ (e.g. codex debug models raw output)
  # Intentionally separate loop: {models:[]} has priority over bare arrays
  lines.each_with_index do |line, idx| # rubocop:disable Style/CombinableLoops
    next unless line.strip.start_with?("[{", "[")

    json_candidate = lines[idx..].join
    begin
      data = JSON.parse(json_candidate)
      return normalize_model_list(data) if data.is_a?(Array) && data.first.is_a?(Hash)
    rescue JSON::ParserError
      # Try next candidate
    end
  end # rubocop:enable Style/CombinableLoops

  # Fallback: parse plain text output (one model per line, or tabular format)
  parse_list_models_text(output)
end

# Parse plain text model listing (e.g. "* auto   1.00x credits   Description here")
# Lines prefixed with "*" are marked as the default model.
def parse_list_models_text(output)
  models = []
  output.each_line do |line|
    line = line.strip
    next if line.empty? || line.start_with?("Available") || line.start_with?("Default")

    is_default = line.start_with?("*")

    # Match lines like: "* auto   1.00x credits   Description" or "  claude-sonnet-4.6   1.30x credits   Desc"
    if (m = line.match(/^[*\s]*(\S+)\s+(\d+\.\d+x\s+\w+)\s+(.+)$/))
      entry = { "model_id" => m[1], "rate" => m[2].strip, "description" => m[3].strip }
      entry["default"] = true if is_default
      models << entry
    elsif (m = line.match(/^[*\s]*(\S+)\s*$/))
      entry = { "model_id" => m[1] }
      entry["default"] = true if is_default
      models << entry
    end
  end
  models.empty? ? nil : models
end

# Generate a short key from a model_id for use in the models config map.
# Strips common provider prefixes, lowercases, and normalizes to kebab-case.
# Examples:
#   "claude-sonnet-4.6" => "sonnet-4-6"
#   "GPT-4o"            => "4o"
#   "DeepSeek-V3"       => "deepseek-v3"
def generate_short_model_key(model_id)
  model_id
    .downcase
    .sub(/^claude-/, "")
    .sub(/^grok-/, "")
    .sub(/^gpt-/, "")
    .gsub(/[^a-z0-9]/, "-").squeeze("-")
    .sub(/^-/, "")
    .sub(/-$/, "")
end

# Normalize model hashes to always have "model_id" as the primary identifier.
# Handles various CLI output formats: "slug" (codex), "model_name" (generic), "model_id" (kiro-cli).
def normalize_model_list(models)
  models.map do |m|
    next m if m["model_id"]

    m = m.dup
    m["model_id"] = m.delete("slug") || m.delete("model_name") || "unknown"
    m
  end
end
