# frozen_string_literal: true

require "json"
require "net/http"
require "uri"

module Brainiac
  module Hub
    # Minimal JSON client for the hub API. Returns the parsed body on 2xx, nil otherwise.
    class Client
      def initialize(url:, token:, timeout: 10)
        @base = url.to_s.chomp("/")
        @token = token
        @timeout = timeout
      end

      def get(path) = request(Net::HTTP::Get, path)
      def post(path, payload) = request(Net::HTTP::Post, path, payload)
      def put(path, payload) = request(Net::HTTP::Put, path, payload)
      def delete(path) = request(Net::HTTP::Delete, path)

      private

      def request(klass, path, payload = nil)
        uri = URI("#{@base}#{path}")
        request = klass.new(uri.request_uri)
        request["Authorization"] = "Bearer #{@token}"
        if payload
          request["Content-Type"] = "application/json"
          request.body = JSON.generate(payload)
        end

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: @timeout, read_timeout: @timeout) do |http|
          http.request(request)
        end
        unless response.code.to_i.between?(200, 299)
          LOG.warn "[Hub] #{klass::METHOD} #{path} -> #{response.code} #{response.body.to_s[0, 200]}"
          return nil
        end

        response.body.to_s.empty? ? {} : JSON.parse(response.body)
      rescue StandardError => e
        LOG.warn "[Hub] #{klass::METHOD} #{path} failed: #{e.message}"
        nil
      end
    end
  end
end
