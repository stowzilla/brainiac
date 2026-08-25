# frozen_string_literal: true

# Supplier Commerce Framework for Brainiac.
#
# Provides a channel-agnostic adapter pattern for supplier integrations.
# Each supplier channel (Amazon Business, direct vendors, etc.) implements
# a concrete adapter that conforms to the BaseAdapter interface.
#
# Configuration lives in ~/.brainiac/suppliers.json.
#
# Usage:
#   registry = Brainiac::Suppliers::Registry.new
#   adapter = registry.adapter_for("amazon_business")
#   items = adapter.search_catalog("paper towels")
#   price = adapter.fetch_price(catalog_item)

require_relative "suppliers/base_adapter"
require_relative "suppliers/catalog_item"
require_relative "suppliers/price_record"
require_relative "suppliers/pa_api_client"
require_relative "suppliers/pa_api_parser"
require_relative "suppliers/registry"
require_relative "suppliers/amazon_business"

module Brainiac
  module Suppliers
    SUPPLIERS_FILE = File.join(BRAINIAC_DIR, "suppliers.json")

    # Load the suppliers configuration from disk.
    #
    # @return [Hash] The parsed suppliers config
    def self.load_config
      return { "suppliers" => [], "schema_version" => "1.0" } unless File.exist?(SUPPLIERS_FILE)

      JSON.parse(File.read(SUPPLIERS_FILE))
    rescue JSON::ParserError => e
      LOG.error "[Suppliers] Failed to parse suppliers.json: #{e.message}"
      { "suppliers" => [], "schema_version" => "1.0" }
    end

    # Save the suppliers configuration to disk.
    #
    # @param config [Hash] The config hash to persist
    def self.save_config(config)
      FileUtils.mkdir_p(BRAINIAC_DIR)
      File.write(SUPPLIERS_FILE, JSON.pretty_generate(config))
    end

    # List all registered adapter class names.
    #
    # @return [Array<String>] Adapter type identifiers
    def self.available_adapters
      Registry::ADAPTER_TYPES.keys
    end
  end
end
