# frozen_string_literal: true

module Brainiac
  module Suppliers
    # PA-API 5.0 request signing and HTTP execution.
    #
    # Extracted from AmazonBusiness adapter to keep class length manageable.
    # Implements AWS Signature V4 for Product Advertising API authentication.
    module PaApiClient
      PA_API_HOST = "webservices.amazon.com"
      PA_API_REGION = "us-east-1"
      PA_API_SERVICE = "ProductAdvertisingAPI"

      private

      # Execute a signed PA-API request.
      #
      # @param path [String] API endpoint path
      # @param operation [String] PA-API operation name
      # @param payload [Hash] Request body
      # @return [Hash] Parsed JSON response
      def execute_pa_api_request(path, operation, payload)
        uri = URI("https://#{PA_API_HOST}#{path}")
        body = JSON.generate(payload)
        timestamp = Time.now.utc.strftime("%Y%m%dT%H%M%SZ")
        date = timestamp[0, 8]

        headers = build_request_headers(timestamp, operation)
        headers["authorization"] = compute_aws_signature(
          method: "POST", path: path, headers: headers, body: body,
          timestamp: timestamp, date: date
        )

        send_http_request(uri, headers, body)
      end

      def build_request_headers(timestamp, operation)
        {
          "content-type" => "application/json; charset=utf-8",
          "host" => PA_API_HOST,
          "x-amz-date" => timestamp,
          "x-amz-target" => "com.amazon.paapi5.v1.ProductAdvertisingAPIv1.#{operation}",
          "content-encoding" => "amz-1.0"
        }
      end

      def send_http_request(uri, headers, body)
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = true
        http.open_timeout = 10
        http.read_timeout = 30

        request = Net::HTTP::Post.new(uri.path, headers)
        request.body = body

        response = http.request(request)
        handle_response(response)
      end

      def handle_response(response)
        case response.code.to_i
        when 200
          JSON.parse(response.body)
        when 401, 403
          raise AuthenticationError, "PA-API authentication failed (#{response.code}): #{response.body[0..200]}"
        when 429
          raise RateLimitError, "PA-API rate limit exceeded. Retry after backoff."
        else
          raise AdapterError, "PA-API error (#{response.code}): #{response.body[0..200]}"
        end
      end

      # Compute AWS Signature V4 for PA-API requests.
      #
      # @return [String] The Authorization header value
      def compute_aws_signature(method:, path:, headers:, body:, timestamp:, date:)
        canonical_request = build_canonical_request(method, path, headers, body)
        credential_scope = "#{date}/#{region}/#{PA_API_SERVICE}/aws4_request"

        string_to_sign = [
          "AWS4-HMAC-SHA256",
          timestamp,
          credential_scope,
          OpenSSL::Digest::SHA256.hexdigest(canonical_request)
        ].join("\n")

        signing_key = derive_signing_key(date)
        signature = OpenSSL::HMAC.hexdigest("SHA256", signing_key, string_to_sign)
        signed_headers = headers.keys.sort.join(";")

        "AWS4-HMAC-SHA256 Credential=#{access_key}/#{credential_scope}, " \
          "SignedHeaders=#{signed_headers}, Signature=#{signature}"
      end

      def build_canonical_request(method, path, headers, body)
        canonical_headers = headers.sort.map { |k, v| "#{k}:#{v}" }.join("\n")
        signed_headers = headers.keys.sort.join(";")
        payload_hash = OpenSSL::Digest::SHA256.hexdigest(body)

        [
          method,
          path,
          "", # query string (empty for POST)
          "#{canonical_headers}\n",
          signed_headers,
          payload_hash
        ].join("\n")
      end

      # Derive the signing key for AWS Signature V4.
      def derive_signing_key(date)
        k_date = hmac_sha256("AWS4#{secret_key}", date)
        k_region = hmac_sha256(k_date, region)
        k_service = hmac_sha256(k_region, PA_API_SERVICE)
        hmac_sha256(k_service, "aws4_request")
      end

      def hmac_sha256(key, data)
        OpenSSL::HMAC.digest("SHA256", key, data)
      end
    end
  end
end
