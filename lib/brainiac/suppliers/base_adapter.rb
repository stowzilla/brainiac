# frozen_string_literal: true

module Brainiac
  module Suppliers
    # Abstract base class for supplier channel adapters.
    #
    # Each concrete adapter (Amazon Business, direct vendor, etc.) must implement
    # the interface defined here. Adapters are stateless — configuration comes from
    # the supplier account record passed at initialization.
    #
    # Subclasses MUST implement:
    #   - #search_catalog(query, **options)
    #   - #fetch_price(catalog_item)
    #   - #fetch_prices(catalog_items)
    #   - #submit_order(purchase_order)
    #   - #check_order_status(order_reference)
    #   - #validate_credentials!
    #
    # Subclasses MAY override:
    #   - #sync_catalog(since: nil)
    #   - #channel_name
    #   - #supports?(capability)
    class BaseAdapter
      attr_reader :supplier_id, :account_config

      # @param supplier_id [String] The supplier identifier
      # @param account_config [Hash] Channel-specific credentials and settings
      def initialize(supplier_id:, account_config:)
        @supplier_id = supplier_id
        @account_config = account_config
      end

      # Human-readable channel name for this adapter type.
      #
      # @return [String]
      def channel_name
        self.class.name.split("::").last
      end

      # Check whether this adapter supports a given capability.
      #
      # @param capability [Symbol] One of :search, :pricing, :ordering, :status, :catalog_sync, :webhooks
      # @return [Boolean]
      def supports?(capability)
        supported_capabilities.include?(capability)
      end

      # List capabilities this adapter supports.
      # Subclasses should override to declare their capabilities.
      #
      # @return [Array<Symbol>]
      def supported_capabilities
        []
      end

      # Search the supplier's catalog for items matching a query.
      #
      # @param query [String] Search terms
      # @param options [Hash] Adapter-specific search options (e.g., category, max_results)
      # @return [Array<CatalogItem>] Matching catalog items
      def search_catalog(_query, **_options)
        raise NotImplementedError, "#{self.class}#search_catalog must be implemented"
      end

      # Fetch the current price for a single catalog item.
      #
      # @param catalog_item [CatalogItem] The item to price
      # @return [PriceRecord] The current price observation
      def fetch_price(_catalog_item)
        raise NotImplementedError, "#{self.class}#fetch_price must be implemented"
      end

      # Fetch current prices for multiple catalog items (batch).
      # Default implementation calls fetch_price individually.
      #
      # @param catalog_items [Array<CatalogItem>] Items to price
      # @return [Array<PriceRecord>] Price observations
      def fetch_prices(catalog_items)
        catalog_items.map { |item| fetch_price(item) }
      end

      # Submit a purchase order to the supplier.
      #
      # @param purchase_order [Hash] Order details conforming to PO schema:
      #   { lines: [{ catalog_item_id:, quantity:, unit_price: }], shipping_address:, ... }
      # @return [Hash] Order confirmation: { order_reference:, status:, estimated_delivery: }
      def submit_order(_purchase_order)
        raise NotImplementedError, "#{self.class}#submit_order must be implemented"
      end

      # Check the status of a previously submitted order.
      #
      # @param order_reference [String] The supplier's order identifier
      # @return [Hash] Status details: { status:, tracking:, items: [...] }
      def check_order_status(_order_reference)
        raise NotImplementedError, "#{self.class}#check_order_status must be implemented"
      end

      # Validate that the adapter's credentials are correct and the account is accessible.
      #
      # @return [Boolean] true if credentials are valid
      # @raise [AuthenticationError] if credentials are invalid
      def validate_credentials!
        raise NotImplementedError, "#{self.class}#validate_credentials! must be implemented"
      end

      # Sync the supplier's full catalog (or changes since a timestamp).
      # Not all adapters support this — check supports?(:catalog_sync) first.
      #
      # @param since [Time, nil] Only fetch changes after this time (nil = full sync)
      # @return [Array<CatalogItem>] New or updated catalog items
      def sync_catalog(since: nil)
        raise NotImplementedError, "#{self.class} does not support catalog sync"
      end

      # Return a summary of this adapter for display/logging.
      #
      # @return [Hash]
      def to_h
        {
          channel: channel_name,
          supplier_id: supplier_id,
          capabilities: supported_capabilities
        }
      end
    end

    # Raised when adapter credentials are invalid or expired.
    class AuthenticationError < StandardError; end

    # Raised when an API rate limit is hit.
    class RateLimitError < StandardError; end

    # Raised when a supplier API returns an unexpected response.
    class AdapterError < StandardError; end
  end
end
