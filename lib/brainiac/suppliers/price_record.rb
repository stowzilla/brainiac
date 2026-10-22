# frozen_string_literal: true

module Brainiac
  module Suppliers
    # A point-in-time price observation for a catalog item.
    #
    # Price is treated as a time-series — every observed price is recorded with
    # timestamp, source, and context. The "current price" is simply the most
    # recent observation, not a mutable field.
    #
    # This enables:
    #   - Cost history tracking (COGS calculations)
    #   - Price trend detection (alerts when prices change significantly)
    #   - Multi-supplier price comparison
    #   - Quantity discount tier tracking
    class PriceRecord
      attr_accessor :price_record_id, :catalog_item_id, :supplier_id,
                    :amount_cents, :currency, :quantity_min, :quantity_max,
                    :price_type, :source, :observed_at, :metadata

      # @param price_record_id [String] Unique record identifier
      # @param catalog_item_id [String] The catalog item this price belongs to
      # @param supplier_id [String] The supplier offering this price
      # @param amount_cents [Integer] Price in cents (avoids floating point)
      # @param currency [String] ISO 4217 currency code (default: USD)
      # @param quantity_min [Integer, nil] Minimum quantity for this price tier
      # @param quantity_max [Integer, nil] Maximum quantity for this price tier (nil = unlimited)
      # @param price_type [String] Type: "list", "business", "promotional", "negotiated", "quantity_discount"
      # @param source [String] How this price was observed: "api_poll", "manual", "webhook", "catalog_sync"
      # @param observed_at [String] ISO8601 timestamp when this price was observed
      # @param metadata [Hash] Adapter-specific extra data (e.g., offer_id, availability)
      def initialize(price_record_id:, catalog_item_id:, supplier_id:, amount_cents:,
                     currency: "USD", quantity_min: nil, quantity_max: nil,
                     price_type: "list", source: "api_poll", observed_at: nil, metadata: {})
        @price_record_id = price_record_id
        @catalog_item_id = catalog_item_id
        @supplier_id = supplier_id
        @amount_cents = amount_cents
        @currency = currency
        @quantity_min = quantity_min
        @quantity_max = quantity_max
        @price_type = price_type
        @source = source
        @observed_at = observed_at || Time.now.utc.iso8601
        @metadata = metadata
      end

      # Price as a decimal dollar amount.
      #
      # @return [Float]
      def amount
        amount_cents / 100.0
      end

      # Format price for display (e.g., "$12.99")
      #
      # @return [String]
      def display_price
        "$#{"%.2f" % amount}" # rubocop:disable Style/FormatString
      end

      # Whether this is a quantity-tiered price.
      #
      # @return [Boolean]
      def tiered?
        !quantity_min.nil?
      end

      # Serialize to a Hash suitable for JSON persistence.
      #
      # @return [Hash]
      def to_h
        {
          "price_record_id" => price_record_id,
          "catalog_item_id" => catalog_item_id,
          "supplier_id" => supplier_id,
          "amount_cents" => amount_cents,
          "currency" => currency,
          "quantity_min" => quantity_min,
          "quantity_max" => quantity_max,
          "price_type" => price_type,
          "source" => source,
          "observed_at" => observed_at,
          "metadata" => metadata
        }.compact
      end

      # Deserialize from a Hash (e.g., loaded from JSON).
      #
      # @param hash [Hash] The serialized price record
      # @return [PriceRecord]
      def self.from_h(hash)
        new(
          price_record_id: hash["price_record_id"],
          catalog_item_id: hash["catalog_item_id"],
          supplier_id: hash["supplier_id"],
          amount_cents: hash["amount_cents"],
          currency: hash["currency"] || "USD",
          quantity_min: hash["quantity_min"],
          quantity_max: hash["quantity_max"],
          price_type: hash["price_type"] || "list",
          source: hash["source"] || "api_poll",
          observed_at: hash["observed_at"],
          metadata: hash["metadata"] || {}
        )
      end

      def ==(other)
        other.is_a?(PriceRecord) && price_record_id == other.price_record_id
      end

      def to_s
        tier = tiered? ? " (qty #{quantity_min}+)" : ""
        "#{display_price}#{tier} [#{price_type}] @ #{observed_at}"
      end
    end
  end
end
