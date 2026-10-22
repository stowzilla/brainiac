# frozen_string_literal: true

require_relative "pa_api_client"
require_relative "pa_api_parser"

module Brainiac
  module Suppliers
    # Amazon Business supplier adapter.
    #
    # Implements the BaseAdapter interface for Amazon Business procurement.
    # Uses the Product Advertising API (PA-API 5.0) for catalog search and pricing,
    # and the Amazon Business Purchasing API for order placement and tracking.
    #
    # Account config expected keys:
    #   access_key    - PA-API access key
    #   secret_key    - PA-API secret key
    #   partner_tag   - Amazon Associates partner tag
    #   marketplace   - Amazon marketplace (default: "www.amazon.com")
    #   region        - AWS region for API calls (default: "us-east-1")
    #
    # Phase 1 (current): Catalog search, price fetching, credential validation.
    # Phase 2 (future): Order submission, status tracking, spend data import.
    class AmazonBusiness < BaseAdapter
      include PaApiClient
      include PaApiParser

      MARKETPLACE_HOSTS = {
        "US" => "www.amazon.com",
        "UK" => "www.amazon.co.uk",
        "DE" => "www.amazon.de",
        "CA" => "www.amazon.ca",
        "JP" => "www.amazon.co.jp"
      }.freeze

      PA_API_PATH = "/paapi5/searchitems"
      PA_API_GET_ITEMS_PATH = "/paapi5/getitems"

      def channel_name
        "Amazon Business"
      end

      def supported_capabilities
        %i[search pricing catalog_sync]
      end

      # Search Amazon's catalog via PA-API 5.0 SearchItems.
      #
      # @param query [String] Search keywords
      # @param options [Hash] Optional: category, max_results (1-10)
      # @return [Array<CatalogItem>] Matching items
      def search_catalog(query, **options)
        max_results = options.fetch(:max_results, 10).clamp(1, 10)
        category = options[:category]

        payload = build_search_payload(query, max_results: max_results, category: category)
        response = execute_pa_api_request(PA_API_PATH, "SearchItems", payload)

        parse_search_response(response)
      end

      # Fetch the current price for a catalog item by ASIN.
      #
      # @param catalog_item [CatalogItem] Must have external_id set to an ASIN
      # @return [PriceRecord] The current price observation
      def fetch_price(catalog_item)
        asin = catalog_item.external_id
        payload = build_get_items_payload([asin])
        response = execute_pa_api_request(PA_API_GET_ITEMS_PATH, "GetItems", payload)

        prices = parse_price_response(response, catalog_item)
        prices.first || raise(AdapterError, "No price found for ASIN #{asin}")
      end

      # Fetch prices for multiple catalog items in one batch (up to 10 ASINs per PA-API call).
      #
      # @param catalog_items [Array<CatalogItem>] Items to price (max 10)
      # @return [Array<PriceRecord>] Price observations
      def fetch_prices(catalog_items)
        catalog_items.each_slice(10).flat_map do |batch|
          asins = batch.map(&:external_id)
          payload = build_get_items_payload(asins)
          response = execute_pa_api_request(PA_API_GET_ITEMS_PATH, "GetItems", payload)

          batch.flat_map { |item| parse_price_response(response, item) }
        end
      end

      # Submit order via Amazon Business Purchasing API.
      # Phase 2 — currently raises NotImplementedError.
      def submit_order(_purchase_order)
        raise NotImplementedError, "Amazon Business order submission is planned for Phase 2"
      end

      # Check order status via Amazon Business Purchasing API.
      # Phase 2 — currently raises NotImplementedError.
      def check_order_status(_order_reference)
        raise NotImplementedError, "Amazon Business order status tracking is planned for Phase 2"
      end

      # Validate PA-API credentials by checking required fields are present,
      # then attempting a minimal search.
      #
      # @return [Boolean] true if credentials are valid
      # @raise [AuthenticationError] if credentials are invalid
      def validate_credentials!
        raise AuthenticationError, "Missing required credentials: access_key, secret_key, partner_tag" unless credentials_present?

        payload = build_search_payload("test", max_results: 1)
        execute_pa_api_request(PA_API_PATH, "SearchItems", payload)
        true
      rescue AuthenticationError
        raise
      rescue AdapterError => e
        raise AuthenticationError, "Invalid Amazon PA-API credentials: #{e.message}" if auth_related_error?(e)

        raise
      end

      # Sync catalog — returns empty for Amazon (no incremental sync API).
      def sync_catalog(since: nil)
        []
      end

      private

      def access_key
        account_config["access_key"]
      end

      def secret_key
        account_config["secret_key"]
      end

      def partner_tag
        account_config["partner_tag"]
      end

      def marketplace
        account_config["marketplace"] || MARKETPLACE_HOSTS["US"]
      end

      def region
        account_config["region"] || PaApiClient::PA_API_REGION
      end

      def credentials_present?
        access_key && secret_key && partner_tag
      end

      def auth_related_error?(error)
        error.message.include?("InvalidParameterValue") || error.message.include?("UnrecognizedClient")
      end

      def build_search_payload(query, max_results: 10, category: nil)
        payload = {
          "Keywords" => query,
          "Resources" => pa_api_resources,
          "ItemCount" => max_results,
          "PartnerTag" => partner_tag,
          "PartnerType" => "Associates",
          "Marketplace" => marketplace
        }
        payload["SearchIndex"] = category if category
        payload
      end

      def build_get_items_payload(asins)
        {
          "ItemIds" => asins,
          "Resources" => pa_api_resources,
          "PartnerTag" => partner_tag,
          "PartnerType" => "Associates",
          "Marketplace" => marketplace
        }
      end

      def pa_api_resources
        %w[
          ItemInfo.Title
          ItemInfo.Features
          ItemInfo.Classifications
          Offers.Listings.Price
          Offers.Listings.DeliveryInfo.IsPrimeEligible
          Offers.Listings.Availability.Message
          Offers.Listings.MerchantInfo
        ]
      end
    end
  end
end
