# frozen_string_literal: true

require "minitest/autorun"
require "json"

begin
  require "rantly"
  require "rantly/minitest_extensions"
rescue LoadError
  # rantly is optional for CI
end

# Add project root to load path so monitor scripts can be required
$LOAD_PATH.unshift File.expand_path("..", __dir__)
$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
