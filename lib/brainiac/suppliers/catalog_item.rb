# frozen_string_literal: true

module Brainiac
  module Suppliers
    # A normalized representation of a purchasable product from any supplier.
    #
    # CatalogItem is channel-agnostic — it represents the same concept whether
    # the source is Amazon Business (ASIN), a local vendor (SKU), or a manufacturer.
    #
    # Identity: catalog_item_id + supplier_id (unique together)
    class CatalogItem
      attr_accessor :catalog_item_id, :supplier_id, :external_id, :name, :description,
                    :category, :unit_of_measure, :metadata, :last_synced_at

      # @param catalog_item_id [String] Internal unique identifier
      # @param supplier_id [String] The supplier this item belongs to
      # @param external_id [String] Supplier-specific identifier (ASIN, SKU, etc.)
      # @param name [String] Human-readable product name
      # @param description [String, nil] Product description
      # @param category [String, nil] Product category
      # @param unit_of_measure [String] Unit of measure (e.g., "each", "case", "box")
      # @param metadata [Hash] Adapter-specific extra data
      # @param last_synced_at [String, nil] ISO8601 timestamp of last sync
      def initialize(catalog_item_id:, supplier_id:, external_id:, name:, description: nil,
                     category: nil, unit_of_measure: "each", metadata: {}, last_synced_at: nil)
        @catalog_item_id = catalog_item_id
        @supplier_id = supplier_id
        @external_id = external_id
        @name = name
        @description = description
        @category = category
        @unit_of_measure = unit_of_measure
        @metadata = metadata
        @last_synced_at = last_synced_at
      end

      # Serialize to a Hash suitable for JSON persistence.
      #
      # @return [Hash]
      def to_h
        {
          "catalog_item_id" => catalog_item_id,
          "supplier_id" => supplier_id,
          "external_id" => external_id,
          "name" => name,
          "description" => description,
          "category" => category,
          "unit_of_measure" => unit_of_measure,
          "metadata" => metadata,
          "last_synced_at" => last_synced_at
        }.compact
      end

      # Deserialize from a Hash (e.g., loaded from JSON).
      #
      # @param hash [Hash] The serialized catalog item
      # @return [CatalogItem]
      def self.from_h(hash)
        new(
          catalog_item_id: hash["catalog_item_id"],
          supplier_id: hash["supplier_id"],
          external_id: hash["external_id"],
          name: hash["name"],
          description: hash["description"],
          category: hash["category"],
          unit_of_measure: hash["unit_of_measure"] || "each",
          metadata: hash["metadata"] || {},
          last_synced_at: hash["last_synced_at"]
        )
      end

      def ==(other)
        other.is_a?(CatalogItem) &&
          catalog_item_id == other.catalog_item_id &&
          supplier_id == other.supplier_id
      end

      def to_s
        "#{name} (#{external_id}) [#{supplier_id}]"
      end
    end
  end
end
