# frozen_string_literal: true

require "json"

module Brainiac
  # Unified config file loader that supports both JSON and TOML formats.
  #
  # For any config path, the loader checks for a .toml file first, then falls
  # back to .json. This allows users to optionally use TOML (with comments,
  # human-friendly syntax) while maintaining full backward compatibility with
  # existing JSON configs.
  #
  # Writing always produces JSON — configs are frequently machine-edited by
  # agents, and JSON round-trips cleanly without formatting/comment concerns.
  #
  # Usage:
  #   Brainiac::ConfigLoader.load("~/.brainiac/projects")    # tries .toml, then .json
  #   Brainiac::ConfigLoader.load("~/.brainiac/projects.json")  # explicit path works too
  #   Brainiac::ConfigLoader.load_file("/path/to/file.toml") # load a specific file
  #
  module ConfigLoader
    class ParseError < StandardError; end

    # Load a config by base path (without extension) or full path.
    # Returns parsed Hash/Array, or the default value if the file doesn't exist.
    #
    # Options:
    #   symbolize_names: pass through to JSON parser (TOML always uses string keys)
    #
    def self.load(path, default: {}, symbolize_names: false)
      resolved = resolve_path(path)
      return default unless resolved

      load_file(resolved, symbolize_names: symbolize_names)
    rescue ParseError
      default
    end

    # Load a specific file (must exist). Raises ParseError on invalid content.
    def self.load_file(path, symbolize_names: false)
      content = File.read(path)

      case File.extname(path).downcase
      when ".toml"
        require_tomlrb!
        Tomlrb.parse(content)
      when ".json"
        JSON.parse(content, symbolize_names: symbolize_names)
      else
        raise ParseError, "Unsupported config format: #{File.extname(path)} (expected .json or .toml)"
      end
    rescue Tomlrb::ParseError => e
      raise ParseError, "TOML parse error in #{path}: #{e.message}"
    rescue JSON::ParserError => e
      raise ParseError, "JSON parse error in #{path}: #{e.message}"
    end

    # Resolve a path to the actual config file that exists on disk.
    # Given a base path (no extension), checks .toml first, then .json.
    # Given a full path with extension, returns it if it exists.
    # Returns nil if no matching file is found.
    def self.resolve_path(path)
      # If path already has a recognized extension, use it directly
      ext = File.extname(path).downcase
      if [".json", ".toml"].include?(ext)
        return File.exist?(path) ? path : nil
      end

      # Try TOML first, then JSON
      toml_path = "#{path}.toml"
      return toml_path if File.exist?(toml_path)

      json_path = "#{path}.json"
      return json_path if File.exist?(json_path)

      nil
    end

    # Check which format a config is stored in.
    # Returns :toml, :json, or nil if not found.
    def self.format_for(path)
      resolved = resolve_path(path)
      return nil unless resolved

      case File.extname(resolved).downcase
      when ".toml" then :toml
      when ".json" then :json
      end
    end

    # Write config data. Always writes JSON (machine-friendly for agent edits).
    # If you need to create a TOML file, write it manually — this method is for
    # programmatic config updates that agents perform.
    def self.write(path, data, pretty: true)
      json_path = path.end_with?(".json") ? path : "#{path}.json"
      content = pretty ? JSON.pretty_generate(data) : JSON.generate(data)
      File.write(json_path, content)
      json_path
    end

    # Returns true if tomlrb is available
    def self.toml_available?
      require_tomlrb!
      true
    rescue LoadError
      false
    end

    private_class_method def self.require_tomlrb!
      require "tomlrb" unless defined?(Tomlrb)
    rescue LoadError
      raise LoadError,
            "The 'tomlrb' gem is required to read TOML config files. Install it with: gem install tomlrb"
    end
  end
end
