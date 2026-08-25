# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/suppliers"

class TestSupplierBaseAdapter < Minitest::Test
  def setup
    @adapter = Brainiac::Suppliers::BaseAdapter.new(
      supplier_id: "test-supplier",
      account_config: { "api_key" => "test123" }
    )
  end

  def test_initializes_with_supplier_id_and_config
    assert_equal "test-supplier", @adapter.supplier_id
    assert_equal({ "api_key" => "test123" }, @adapter.account_config)
  end

  def test_channel_name_returns_class_short_name
    assert_equal "BaseAdapter", @adapter.channel_name
  end

  def test_supports_returns_false_for_base_adapter
    refute @adapter.supports?(:search)
    refute @adapter.supports?(:pricing)
    refute @adapter.supports?(:ordering)
  end

  def test_supported_capabilities_returns_empty_array
    assert_equal [], @adapter.supported_capabilities
  end

  def test_search_catalog_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.search_catalog("test") }
  end

  def test_fetch_price_raises_not_implemented
    item = Brainiac::Suppliers::CatalogItem.new(
      catalog_item_id: "ci-1", supplier_id: "s-1", external_id: "EXT-1", name: "Test"
    )
    assert_raises(NotImplementedError) { @adapter.fetch_price(item) }
  end

  def test_submit_order_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.submit_order({}) }
  end

  def test_check_order_status_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.check_order_status("ref-1") }
  end

  def test_validate_credentials_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.validate_credentials! }
  end

  def test_sync_catalog_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.sync_catalog }
  end

  def test_to_h_returns_adapter_summary
    expected = { channel: "BaseAdapter", supplier_id: "test-supplier", capabilities: [] }
    assert_equal expected, @adapter.to_h
  end
end

class TestCatalogItem < Minitest::Test
  def setup
    @item = Brainiac::Suppliers::CatalogItem.new(
      catalog_item_id: "amzn-B001234",
      supplier_id: "amazon-business",
      external_id: "B001234",
      name: "Heavy Duty Tape",
      description: "Industrial packing tape, 6 rolls",
      category: "Office Supplies",
      unit_of_measure: "case",
      metadata: { "asin" => "B001234", "prime_eligible" => true }
    )
  end

  def test_initializes_with_required_fields
    assert_equal "amzn-B001234", @item.catalog_item_id
    assert_equal "amazon-business", @item.supplier_id
    assert_equal "B001234", @item.external_id
    assert_equal "Heavy Duty Tape", @item.name
  end

  def test_initializes_optional_fields
    assert_equal "Industrial packing tape, 6 rolls", @item.description
    assert_equal "Office Supplies", @item.category
    assert_equal "case", @item.unit_of_measure
    assert_equal "B001234", @item.metadata["asin"]
  end

  def test_default_unit_of_measure_is_each
    item = Brainiac::Suppliers::CatalogItem.new(
      catalog_item_id: "ci-1", supplier_id: "s-1", external_id: "EXT-1", name: "Test"
    )
    assert_equal "each", item.unit_of_measure
  end

  def test_to_h_serializes_all_fields
    hash = @item.to_h
    assert_equal "amzn-B001234", hash["catalog_item_id"]
    assert_equal "amazon-business", hash["supplier_id"]
    assert_equal "B001234", hash["external_id"]
    assert_equal "Heavy Duty Tape", hash["name"]
    assert_equal "Industrial packing tape, 6 rolls", hash["description"]
    assert_equal "Office Supplies", hash["category"]
    assert_equal "case", hash["unit_of_measure"]
    assert_equal({ "asin" => "B001234", "prime_eligible" => true }, hash["metadata"])
  end

  def test_to_h_omits_nil_fields
    item = Brainiac::Suppliers::CatalogItem.new(
      catalog_item_id: "ci-1", supplier_id: "s-1", external_id: "EXT-1", name: "Test"
    )
    hash = item.to_h
    refute hash.key?("description")
    refute hash.key?("category")
    refute hash.key?("last_synced_at")
  end

  def test_from_h_round_trips
    hash = @item.to_h
    restored = Brainiac::Suppliers::CatalogItem.from_h(hash)
    assert_equal @item.catalog_item_id, restored.catalog_item_id
    assert_equal @item.supplier_id, restored.supplier_id
    assert_equal @item.external_id, restored.external_id
    assert_equal @item.name, restored.name
    assert_equal @item.description, restored.description
    assert_equal @item.category, restored.category
    assert_equal @item.unit_of_measure, restored.unit_of_measure
  end

  def test_equality_by_id_and_supplier
    other = Brainiac::Suppliers::CatalogItem.new(
      catalog_item_id: "amzn-B001234", supplier_id: "amazon-business",
      external_id: "B001234", name: "Different Name"
    )
    assert_equal @item, other
  end

  def test_inequality_different_ids
    other = Brainiac::Suppliers::CatalogItem.new(
      catalog_item_id: "amzn-B009999", supplier_id: "amazon-business",
      external_id: "B009999", name: "Heavy Duty Tape"
    )
    refute_equal @item, other
  end

  def test_to_s_format
    assert_equal "Heavy Duty Tape (B001234) [amazon-business]", @item.to_s
  end
end

class TestPriceRecord < Minitest::Test
  def setup
    @record = Brainiac::Suppliers::PriceRecord.new(
      price_record_id: "pr-001",
      catalog_item_id: "amzn-B001234",
      supplier_id: "amazon-business",
      amount_cents: 1299,
      currency: "USD",
      price_type: "business",
      source: "api_poll",
      observed_at: "2026-08-25T12:00:00Z"
    )
  end

  def test_initializes_with_required_fields
    assert_equal "pr-001", @record.price_record_id
    assert_equal "amzn-B001234", @record.catalog_item_id
    assert_equal "amazon-business", @record.supplier_id
    assert_equal 1299, @record.amount_cents
  end

  def test_amount_returns_decimal_dollars
    assert_in_delta 12.99, @record.amount, 0.001
  end

  def test_display_price_formats_correctly
    assert_equal "$12.99", @record.display_price
  end

  def test_display_price_with_even_dollars
    record = Brainiac::Suppliers::PriceRecord.new(
      price_record_id: "pr-002", catalog_item_id: "ci-1",
      supplier_id: "s-1", amount_cents: 500
    )
    assert_equal "$5.00", record.display_price
  end

  def test_tiered_returns_false_without_quantity
    refute @record.tiered?
  end

  def test_tiered_returns_true_with_quantity_min
    record = Brainiac::Suppliers::PriceRecord.new(
      price_record_id: "pr-003", catalog_item_id: "ci-1",
      supplier_id: "s-1", amount_cents: 999,
      quantity_min: 10, quantity_max: 49
    )
    assert record.tiered?
  end

  def test_default_currency_is_usd
    record = Brainiac::Suppliers::PriceRecord.new(
      price_record_id: "pr-004", catalog_item_id: "ci-1",
      supplier_id: "s-1", amount_cents: 100
    )
    assert_equal "USD", record.currency
  end

  def test_default_price_type_is_list
    record = Brainiac::Suppliers::PriceRecord.new(
      price_record_id: "pr-005", catalog_item_id: "ci-1",
      supplier_id: "s-1", amount_cents: 100
    )
    assert_equal "list", record.price_type
  end

  def test_observed_at_defaults_to_now
    record = Brainiac::Suppliers::PriceRecord.new(
      price_record_id: "pr-006", catalog_item_id: "ci-1",
      supplier_id: "s-1", amount_cents: 100
    )
    refute_nil record.observed_at
    # Should be a valid ISO8601 timestamp
    assert_match(/\d{4}-\d{2}-\d{2}T/, record.observed_at)
  end

  def test_to_h_serializes_all_fields
    hash = @record.to_h
    assert_equal "pr-001", hash["price_record_id"]
    assert_equal 1299, hash["amount_cents"]
    assert_equal "USD", hash["currency"]
    assert_equal "business", hash["price_type"]
    assert_equal "api_poll", hash["source"]
    assert_equal "2026-08-25T12:00:00Z", hash["observed_at"]
  end

  def test_from_h_round_trips
    hash = @record.to_h
    restored = Brainiac::Suppliers::PriceRecord.from_h(hash)
    assert_equal @record.price_record_id, restored.price_record_id
    assert_equal @record.amount_cents, restored.amount_cents
    assert_equal @record.currency, restored.currency
    assert_equal @record.price_type, restored.price_type
  end

  def test_equality_by_price_record_id
    other = Brainiac::Suppliers::PriceRecord.new(
      price_record_id: "pr-001", catalog_item_id: "ci-other",
      supplier_id: "s-other", amount_cents: 9999
    )
    assert_equal @record, other
  end

  def test_to_s_format
    assert_equal "$12.99 [business] @ 2026-08-25T12:00:00Z", @record.to_s
  end

  def test_to_s_with_tier
    record = Brainiac::Suppliers::PriceRecord.new(
      price_record_id: "pr-007", catalog_item_id: "ci-1",
      supplier_id: "s-1", amount_cents: 899,
      quantity_min: 10, price_type: "quantity_discount",
      observed_at: "2026-08-25T12:00:00Z"
    )
    assert_equal "$8.99 (qty 10+) [quantity_discount] @ 2026-08-25T12:00:00Z", record.to_s
  end
end

class TestSuppliersRegistry < Minitest::Test
  def setup
    @suppliers_file = File.join(TEST_BRAINIAC_DIR, "suppliers.json")
    File.write(@suppliers_file, JSON.generate({ "suppliers" => [], "schema_version" => "1.0" }))
    @registry = Brainiac::Suppliers::Registry.new
  end

  def teardown
    FileUtils.rm_f(@suppliers_file)
  end

  def test_register_adds_supplier
    supplier = @registry.register(
      supplier_id: "amzn-biz-1",
      name: "Amazon Business",
      adapter_type: "amazon_business",
      account_config: { "access_key" => "AK123", "secret_key" => "SK456", "partner_tag" => "tag-20" }
    )
    assert_equal "amzn-biz-1", supplier["supplier_id"]
    assert_equal "Amazon Business", supplier["name"]
    assert_equal "amazon_business", supplier["adapter_type"]
    assert_equal "active", supplier["status"]
  end

  def test_register_persists_to_disk
    @registry.register(
      supplier_id: "amzn-biz-1", name: "Amazon Business", adapter_type: "amazon_business"
    )
    raw = JSON.parse(File.read(@suppliers_file))
    assert_equal 1, raw["suppliers"].size
    assert_equal "amzn-biz-1", raw["suppliers"][0]["supplier_id"]
  end

  def test_register_rejects_unknown_adapter_type
    assert_raises(ArgumentError) do
      @registry.register(supplier_id: "s-1", name: "Test", adapter_type: "unknown_vendor")
    end
  end

  def test_register_rejects_duplicate_supplier_id
    @registry.register(supplier_id: "s-1", name: "First", adapter_type: "amazon_business")
    assert_raises(ArgumentError) do
      @registry.register(supplier_id: "s-1", name: "Duplicate", adapter_type: "amazon_business")
    end
  end

  def test_find_returns_supplier_by_id
    @registry.register(supplier_id: "amzn-1", name: "Amazon", adapter_type: "amazon_business")
    found = @registry.find("amzn-1")
    assert_equal "Amazon", found["name"]
  end

  def test_find_returns_nil_for_unknown
    assert_nil @registry.find("nonexistent")
  end

  def test_suppliers_lists_all
    @registry.register(supplier_id: "s-1", name: "First", adapter_type: "amazon_business")
    @registry.register(supplier_id: "s-2", name: "Second", adapter_type: "amazon_business")
    assert_equal 2, @registry.suppliers.size
  end

  def test_update_modifies_supplier
    @registry.register(supplier_id: "s-1", name: "Old Name", adapter_type: "amazon_business")
    updated = @registry.update("s-1", name: "New Name", status: "inactive")
    assert_equal "New Name", updated["name"]
    assert_equal "inactive", updated["status"]
  end

  def test_update_raises_for_unknown_supplier
    assert_raises(ArgumentError) { @registry.update("nonexistent", name: "X") }
  end

  def test_remove_deletes_supplier
    @registry.register(supplier_id: "s-1", name: "Doomed", adapter_type: "amazon_business")
    assert @registry.remove("s-1")
    assert_nil @registry.find("s-1")
    assert_equal 0, @registry.suppliers.size
  end

  def test_remove_returns_false_for_unknown
    refute @registry.remove("nonexistent")
  end

  def test_adapter_for_returns_amazon_business_instance
    @registry.register(
      supplier_id: "amzn-1", name: "Amazon", adapter_type: "amazon_business",
      account_config: { "access_key" => "AK", "secret_key" => "SK", "partner_tag" => "tag" }
    )
    adapter = @registry.adapter_for("amzn-1")
    assert_instance_of Brainiac::Suppliers::AmazonBusiness, adapter
    assert_equal "amzn-1", adapter.supplier_id
    assert_equal "AK", adapter.account_config["access_key"]
  end

  def test_adapter_for_raises_for_unknown_supplier
    assert_raises(ArgumentError) { @registry.adapter_for("nonexistent") }
  end

  def test_add_catalog_item_stores_item
    @registry.register(supplier_id: "s-1", name: "Test", adapter_type: "amazon_business")
    item = Brainiac::Suppliers::CatalogItem.new(
      catalog_item_id: "ci-1", supplier_id: "s-1", external_id: "B001234", name: "Tape"
    )
    @registry.add_catalog_item("s-1", item)

    items = @registry.catalog_items_for("s-1")
    assert_equal 1, items.size
    assert_equal "Tape", items.first.name
  end

  def test_add_catalog_item_upserts_on_external_id
    @registry.register(supplier_id: "s-1", name: "Test", adapter_type: "amazon_business")
    item1 = Brainiac::Suppliers::CatalogItem.new(
      catalog_item_id: "ci-1", supplier_id: "s-1", external_id: "B001234", name: "Old Name"
    )
    item2 = Brainiac::Suppliers::CatalogItem.new(
      catalog_item_id: "ci-1", supplier_id: "s-1", external_id: "B001234", name: "New Name"
    )
    @registry.add_catalog_item("s-1", item1)
    @registry.add_catalog_item("s-1", item2)

    items = @registry.catalog_items_for("s-1")
    assert_equal 1, items.size
    assert_equal "New Name", items.first.name
  end

  def test_record_price_stores_observation
    @registry.register(supplier_id: "s-1", name: "Test", adapter_type: "amazon_business")
    price = Brainiac::Suppliers::PriceRecord.new(
      price_record_id: "pr-1", catalog_item_id: "ci-1",
      supplier_id: "s-1", amount_cents: 1500
    )
    @registry.record_price("s-1", price)

    history = @registry.price_history("s-1", "ci-1")
    assert_equal 1, history.size
    assert_equal 1500, history.first.amount_cents
  end

  def test_price_history_returns_most_recent_first
    @registry.register(supplier_id: "s-1", name: "Test", adapter_type: "amazon_business")

    ["2026-01-01T00:00:00Z", "2026-06-01T00:00:00Z", "2026-03-01T00:00:00Z"].each_with_index do |ts, i|
      price = Brainiac::Suppliers::PriceRecord.new(
        price_record_id: "pr-#{i}", catalog_item_id: "ci-1",
        supplier_id: "s-1", amount_cents: (10 + i) * 100,
        observed_at: ts
      )
      @registry.record_price("s-1", price)
    end

    history = @registry.price_history("s-1", "ci-1")
    assert_equal 3, history.size
    assert_equal "2026-06-01T00:00:00Z", history.first.observed_at
    assert_equal "2026-01-01T00:00:00Z", history.last.observed_at
  end

  def test_price_history_respects_limit
    @registry.register(supplier_id: "s-1", name: "Test", adapter_type: "amazon_business")

    5.times do |i|
      price = Brainiac::Suppliers::PriceRecord.new(
        price_record_id: "pr-#{i}", catalog_item_id: "ci-1",
        supplier_id: "s-1", amount_cents: 100 * (i + 1),
        observed_at: "2026-0#{i + 1}-01T00:00:00Z"
      )
      @registry.record_price("s-1", price)
    end

    history = @registry.price_history("s-1", "ci-1", limit: 2)
    assert_equal 2, history.size
  end

  def test_current_price_returns_most_recent
    @registry.register(supplier_id: "s-1", name: "Test", adapter_type: "amazon_business")

    [1000, 1200, 1100].each_with_index do |cents, i|
      price = Brainiac::Suppliers::PriceRecord.new(
        price_record_id: "pr-#{i}", catalog_item_id: "ci-1",
        supplier_id: "s-1", amount_cents: cents,
        observed_at: "2026-0#{i + 1}-01T00:00:00Z"
      )
      @registry.record_price("s-1", price)
    end

    current = @registry.current_price("s-1", "ci-1")
    assert_equal 1100, current.amount_cents # March is most recent
  end

  def test_current_price_returns_nil_when_no_records
    @registry.register(supplier_id: "s-1", name: "Test", adapter_type: "amazon_business")
    assert_nil @registry.current_price("s-1", "ci-1")
  end

  def test_reload_picks_up_external_changes
    @registry.register(supplier_id: "s-1", name: "Test", adapter_type: "amazon_business")

    # Simulate external change
    config = JSON.parse(File.read(@suppliers_file))
    config["suppliers"] << { "supplier_id" => "s-external", "name" => "External", "adapter_type" => "amazon_business" }
    File.write(@suppliers_file, JSON.generate(config))

    @registry.reload!
    assert_equal 2, @registry.suppliers.size
    assert @registry.find("s-external")
  end
end

class TestAmazonBusinessAdapter < Minitest::Test
  def setup
    @adapter = Brainiac::Suppliers::AmazonBusiness.new(
      supplier_id: "amzn-biz-1",
      account_config: {
        "access_key" => "AKIAIOSFODNN7EXAMPLE",
        "secret_key" => "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY",
        "partner_tag" => "stowzilla-20",
        "marketplace" => "www.amazon.com",
        "region" => "us-east-1"
      }
    )
  end

  def test_channel_name
    assert_equal "Amazon Business", @adapter.channel_name
  end

  def test_supported_capabilities
    capabilities = @adapter.supported_capabilities
    assert_includes capabilities, :search
    assert_includes capabilities, :pricing
    assert_includes capabilities, :catalog_sync
    refute_includes capabilities, :ordering
  end

  def test_supports_search
    assert @adapter.supports?(:search)
    assert @adapter.supports?(:pricing)
    assert @adapter.supports?(:catalog_sync)
    refute @adapter.supports?(:ordering)
    refute @adapter.supports?(:webhooks)
  end

  def test_submit_order_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.submit_order({}) }
  end

  def test_check_order_status_raises_not_implemented
    assert_raises(NotImplementedError) { @adapter.check_order_status("ref-1") }
  end

  def test_validate_credentials_raises_without_keys
    adapter = Brainiac::Suppliers::AmazonBusiness.new(
      supplier_id: "s-1", account_config: {}
    )
    assert_raises(Brainiac::Suppliers::AuthenticationError) do
      adapter.validate_credentials!
    end
  end

  def test_validate_credentials_raises_with_partial_keys
    adapter = Brainiac::Suppliers::AmazonBusiness.new(
      supplier_id: "s-1", account_config: { "access_key" => "AK" }
    )
    assert_raises(Brainiac::Suppliers::AuthenticationError) do
      adapter.validate_credentials!
    end
  end

  def test_to_h_includes_amazon_info
    info = @adapter.to_h
    assert_equal "Amazon Business", info[:channel]
    assert_equal "amzn-biz-1", info[:supplier_id]
    assert_includes info[:capabilities], :search
  end

  def test_sync_catalog_returns_empty_array
    # Default implementation for sync_catalog (Amazon doesn't support incremental sync)
    assert_equal [], @adapter.sync_catalog
  end
end

class TestSuppliersModule < Minitest::Test
  def setup
    @suppliers_file = File.join(TEST_BRAINIAC_DIR, "suppliers.json")
    FileUtils.rm_f(@suppliers_file)
  end

  def teardown
    FileUtils.rm_f(@suppliers_file)
  end

  def test_load_config_returns_default_when_file_missing
    config = Brainiac::Suppliers.load_config
    assert_equal [], config["suppliers"]
    assert_equal "1.0", config["schema_version"]
  end

  def test_load_config_parses_existing_file
    data = { "suppliers" => [{ "supplier_id" => "s-1" }], "schema_version" => "1.0" }
    File.write(@suppliers_file, JSON.generate(data))
    config = Brainiac::Suppliers.load_config
    assert_equal 1, config["suppliers"].size
  end

  def test_load_config_handles_malformed_json
    File.write(@suppliers_file, "not valid json{{{")
    config = Brainiac::Suppliers.load_config
    assert_equal [], config["suppliers"]
  end

  def test_save_config_writes_to_disk
    data = { "suppliers" => [{ "supplier_id" => "s-1", "name" => "Test" }], "schema_version" => "1.0" }
    Brainiac::Suppliers.save_config(data)
    assert File.exist?(@suppliers_file)
    loaded = JSON.parse(File.read(@suppliers_file))
    assert_equal "s-1", loaded["suppliers"][0]["supplier_id"]
  end

  def test_available_adapters_includes_amazon_business
    adapters = Brainiac::Suppliers.available_adapters
    assert_includes adapters, "amazon_business"
  end
end
