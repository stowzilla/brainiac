# frozen_string_literal: true

module Brainiac
  module Suppliers
    # Manages the supplier registry — loading, saving, and resolving supplier
    # records and their associated adapters.
    #
    # Suppliers are persisted in ~/.brainiac/suppliers.json. Each supplier entry
    # includes identity, channel type, account credentials, and catalog item references.
    #
    # The registry provides:
    #   - Supplier CRUD (add, update, remove, list)
    #   - Adapter instantiation from supplier config
    #   - Catalog item storage per supplier
    #   - Price record storage per supplier/item
    class Registry
      # Map of adapter type identifiers to their implementation classes.
      # New adapters register here.
      ADAPTER_TYPES = {
        "amazon_business" => "Brainiac::Suppliers::AmazonBusiness"
      }.freeze

      attr_reader :config

      def initialize
        @config = Brainiac::Suppliers.load_config
      end

      # Reload config from disk.
      def reload!
        @config = Brainiac::Suppliers.load_config
      end

      # List all registered suppliers.
      #
      # @return [Array<Hash>] Supplier records
      def suppliers
        @config["suppliers"] || []
      end

      # Find a supplier by ID.
      #
      # @param supplier_id [String] The supplier identifier
      # @return [Hash, nil] The supplier record or nil
      def find(supplier_id)
        suppliers.find { |s| s["supplier_id"] == supplier_id }
      end

      # Register a new supplier.
      #
      # @param supplier_id [String] Unique identifier for this supplier
      # @param name [String] Human-readable supplier name
      # @param adapter_type [String] One of ADAPTER_TYPES keys
      # @param account_config [Hash] Channel-specific credentials and settings
      # @param metadata [Hash] Additional supplier metadata (contact, terms, etc.)
      # @return [Hash] The created supplier record
      def register(supplier_id:, name:, adapter_type:, account_config: {}, metadata: {})
        unless ADAPTER_TYPES.key?(adapter_type)
          raise ArgumentError, "Unknown adapter type '#{adapter_type}'. Available: #{ADAPTER_TYPES.keys.join(", ")}"
        end

        raise ArgumentError, "Supplier '#{supplier_id}' already exists" if find(supplier_id)

        supplier = {
          "supplier_id" => supplier_id,
          "name" => name,
          "adapter_type" => adapter_type,
          "account_config" => account_config,
          "metadata" => metadata,
          "status" => "active",
          "catalog_items" => [],
          "price_records" => [],
          "registered_at" => Time.now.utc.iso8601
        }

        @config["suppliers"] ||= []
        @config["suppliers"] << supplier
        save!
        supplier
      end

      # Update an existing supplier's configuration.
      #
      # @param supplier_id [String] The supplier to update
      # @param updates [Hash] Fields to merge into the supplier record
      # @return [Hash] The updated supplier record
      def update(supplier_id, **updates)
        supplier = find(supplier_id)
        raise ArgumentError, "Supplier '#{supplier_id}' not found" unless supplier

        updates.each do |key, value|
          supplier[key.to_s] = value
        end
        save!
        supplier
      end

      # Remove a supplier from the registry.
      #
      # @param supplier_id [String] The supplier to remove
      # @return [Boolean] true if removed
      def remove(supplier_id)
        initial_count = suppliers.size
        @config["suppliers"].reject! { |s| s["supplier_id"] == supplier_id }
        removed = suppliers.size < initial_count
        save! if removed
        removed
      end

      # Instantiate the adapter for a given supplier.
      #
      # @param supplier_id [String] The supplier whose adapter to build
      # @return [BaseAdapter] A configured adapter instance
      def adapter_for(supplier_id)
        supplier = find(supplier_id)
        raise ArgumentError, "Supplier '#{supplier_id}' not found" unless supplier

        adapter_class = resolve_adapter_class(supplier["adapter_type"])
        adapter_class.new(
          supplier_id: supplier_id,
          account_config: supplier["account_config"] || {}
        )
      end

      # Add a catalog item to a supplier's local catalog.
      #
      # @param supplier_id [String] The supplier
      # @param catalog_item [CatalogItem] The item to add
      # @return [Hash] The serialized item
      def add_catalog_item(supplier_id, catalog_item)
        supplier = find(supplier_id)
        raise ArgumentError, "Supplier '#{supplier_id}' not found" unless supplier

        supplier["catalog_items"] ||= []

        # Upsert: replace if same external_id exists
        supplier["catalog_items"].reject! { |i| i["external_id"] == catalog_item.external_id }
        supplier["catalog_items"] << catalog_item.to_h
        save!
        catalog_item.to_h
      end

      # Get all catalog items for a supplier.
      #
      # @param supplier_id [String] The supplier
      # @return [Array<CatalogItem>]
      def catalog_items_for(supplier_id)
        supplier = find(supplier_id)
        return [] unless supplier

        (supplier["catalog_items"] || []).map { |h| CatalogItem.from_h(h) }
      end

      # Record a price observation for a catalog item.
      #
      # @param supplier_id [String] The supplier
      # @param price_record [PriceRecord] The price observation
      # @return [Hash] The serialized price record
      def record_price(supplier_id, price_record)
        supplier = find(supplier_id)
        raise ArgumentError, "Supplier '#{supplier_id}' not found" unless supplier

        supplier["price_records"] ||= []
        supplier["price_records"] << price_record.to_h
        save!
        price_record.to_h
      end

      # Get price history for a catalog item (most recent first).
      #
      # @param supplier_id [String] The supplier
      # @param catalog_item_id [String] The catalog item
      # @param limit [Integer, nil] Max records to return
      # @return [Array<PriceRecord>]
      def price_history(supplier_id, catalog_item_id, limit: nil)
        supplier = find(supplier_id)
        return [] unless supplier

        records = (supplier["price_records"] || [])
                  .select { |r| r["catalog_item_id"] == catalog_item_id }
                  .sort_by { |r| r["observed_at"] || "" }
                  .reverse

        records = records.first(limit) if limit
        records.map { |h| PriceRecord.from_h(h) }
      end

      # Get the most recent price for a catalog item.
      #
      # @param supplier_id [String] The supplier
      # @param catalog_item_id [String] The catalog item
      # @return [PriceRecord, nil]
      def current_price(supplier_id, catalog_item_id)
        price_history(supplier_id, catalog_item_id, limit: 1).first
      end

      private

      # Resolve an adapter type string to its class.
      #
      # @param adapter_type [String] The adapter type key
      # @return [Class] The adapter class
      def resolve_adapter_class(adapter_type)
        class_name = ADAPTER_TYPES[adapter_type]
        raise ArgumentError, "Unknown adapter type '#{adapter_type}'" unless class_name

        class_name.split("::").reduce(Object) { |mod, name| mod.const_get(name) }
      end

      # Persist current config to disk.
      def save!
        Brainiac::Suppliers.save_config(@config)
      end
    end
  end
end
