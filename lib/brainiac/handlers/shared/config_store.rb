# frozen_string_literal: true

# Generic config file loading pattern shared across handlers.
#
# Each handler has the same pattern: load JSON → store in constant → reload on change.
# This module provides a single class that encapsulates that.

class ConfigStore
  attr_reader :path, :data

  def initialize(path, default: {})
    @path = path
    @default = default
    @data = load
  end

  def load
    return @default.dup unless File.exist?(@path)

    JSON.parse(File.read(@path))
  rescue JSON::ParserError => e
    LOG.error "Failed to parse config #{@path}: #{e.message}"
    @default.dup
  end

  def reload!
    @data.replace(load)
  end

  def [](key)
    @data[key]
  end

  def dig(*keys)
    @data.dig(*keys)
  end

  def fetch(key, *, &)
    @data.fetch(key, *, &)
  end

  def save!
    File.write(@path, JSON.pretty_generate(@data))
  end
end
