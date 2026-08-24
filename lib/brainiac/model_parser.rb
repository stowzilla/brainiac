# frozen_string_literal: true

# Standalone model output parsing — shared between bin/brainiac (CLI) and lib/brainiac/helpers.rb (server).
# No dependencies beyond Ruby stdlib (json).

require "json"

# Parse the output of a list_models_command.
# Supports JSON output with a "models" array, or plain text lines with model names.
# Normalizes various field names (slug, model_name) to "model_id" for consistency.
def parse_list_models_output(output)
  # Try parsing the entire output as JSON first (handles well-formed JSON from any CLI)
  data = JSON.parse(output)
  if data.is_a?(Hash) && data["models"].is_a?(Array)
    return normalize_model_list(data["models"])
  end
  return normalize_model_list(data) if data.is_a?(Array)

  nil
rescue JSON::ParserError
  # Some CLIs output non-JSON text before the JSON (like kiro-cli with --format json).
  # Try to extract a JSON object containing a "models" key.
  json_match = output.match(/\{.*"models"\s*:\s*\[.*\]/m)
  if json_match
    begin
      data = JSON.parse(json_match[0])
      return normalize_model_list(data["models"]) if data["models"].is_a?(Array)
    rescue JSON::ParserError
      # Continue to text fallback
    end
  end

  # Try to extract a standalone JSON array
  array_match = output.match(/\[.*\]/m)
  if array_match
    begin
      data = JSON.parse(array_match[0])
      return normalize_model_list(data) if data.is_a?(Array)
    rescue JSON::ParserError
      # Continue to text fallback
    end
  end

  # Fallback: parse plain text output (one model per line, or tabular format)
  parse_list_models_text(output)
end

# Parse plain text model listing (e.g. "* auto   1.00x credits   Description here")
def parse_list_models_text(output)
  models = []
  output.each_line do |line|
    line = line.strip
    next if line.empty? || line.start_with?("Available") || line.start_with?("Default")

    # Match lines like: "* auto   1.00x credits   Description" or "  claude-sonnet-4.6   1.30x credits   Desc"
    if (m = line.match(/^[*\s]*(\S+)\s+(\d+\.\d+x\s+\w+)\s+(.+)$/))
      models << { "model_id" => m[1], "rate" => m[2].strip, "description" => m[3].strip }
    elsif (m = line.match(/^[*\s]*(\S+)\s*$/))
      # Just a model name on a line
      models << { "model_id" => m[1] }
    end
  end
  models.empty? ? nil : models
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
