# frozen_string_literal: true

module Brainiac
  module Suppliers
    # Response parsing logic for Amazon PA-API responses.
    #
    # Converts raw PA-API JSON into CatalogItem and PriceRecord objects.
    # Extracted from AmazonBusiness adapter to manage class length.
    module PaApiParser
      private

      # Parse SearchItems response into CatalogItem objects.
      def parse_search_response(response)
        items = response.dig("SearchResult", "Items") || []
        items.map { |item| build_catalog_item_from_response(item) }
      end

      def build_catalog_item_from_response(item)
        CatalogItem.new(
          catalog_item_id: "amzn-#{item["ASIN"]}",
          supplier_id: supplier_id,
          external_id: item["ASIN"],
          name: item.dig("ItemInfo", "Title", "DisplayValue") || "Unknown",
          description: extract_features(item),
          category: item.dig("ItemInfo", "Classifications", "Binding", "DisplayValue"),
          unit_of_measure: "each",
          metadata: {
            "asin" => item["ASIN"],
            "detail_url" => item["DetailPageURL"],
            "prime_eligible" => extract_prime_status(item)
          },
          last_synced_at: Time.now.utc.iso8601
        )
      end

      # Parse GetItems response into PriceRecord objects for a specific item.
      def parse_price_response(response, catalog_item)
        items = response.dig("ItemsResult", "Items") || []
        target = items.find { |i| i["ASIN"] == catalog_item.external_id }
        return [] unless target

        listings = target.dig("Offers", "Listings") || []
        listings.filter_map { |listing| build_price_record_from_listing(listing, catalog_item) }
      end

      def build_price_record_from_listing(listing, catalog_item)
        price_data = listing["Price"]
        return nil unless price_data

        amount_cents = parse_price_amount(price_data)
        return nil unless amount_cents

        PriceRecord.new(
          price_record_id: SecureRandom.uuid,
          catalog_item_id: catalog_item.catalog_item_id,
          supplier_id: supplier_id,
          amount_cents: amount_cents,
          currency: price_data["Currency"] || "USD",
          price_type: determine_price_type(listing),
          source: "api_poll",
          observed_at: Time.now.utc.iso8601,
          metadata: {
            "merchant" => listing.dig("MerchantInfo", "Name"),
            "availability" => listing.dig("Availability", "Message"),
            "prime_eligible" => listing.dig("DeliveryInfo", "IsPrimeEligible")
          }
        )
      end

      def extract_features(item)
        features = item.dig("ItemInfo", "Features", "DisplayValues")
        return nil unless features.is_a?(Array) && features.any?

        features.first(3).join(". ")
      end

      def extract_prime_status(item)
        listings = item.dig("Offers", "Listings") || []
        listings.any? { |l| l.dig("DeliveryInfo", "IsPrimeEligible") }
      end

      def parse_price_amount(price_data)
        if price_data["Amount"]
          (price_data["Amount"] * 100).round
        elsif price_data["DisplayAmount"]
          match = price_data["DisplayAmount"].match(/[\d,]+\.?\d*/)
          return nil unless match

          (match[0].delete(",").to_f * 100).round
        end
      end

      def determine_price_type(listing)
        if listing.dig("ProgramEligibility", "IsPrimeExclusive")
          "business"
        elsif listing.dig("Price", "Savings")
          "promotional"
        else
          "list"
        end
      end
    end
  end
end
