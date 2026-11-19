# frozen_string_literal: true

require "socket"

module Brainiac
  module Hub
    # The "hub" block of brainiac.json:
    #
    #   "hub": {
    #     "url": "https://<api id>.execute-api.<region>.amazonaws.com/prod",
    #     "token": "<node token>",        // or the BRAINIAC_HUB_TOKEN env var
    #     "machine": "mini",              // default: this machine's hostname
    #     "priority": 10,                 // lower number = preferred for new work
    #     "leader": true,                 // may hold the Discord gateways and cron
    #     "interval": 120,                // seconds between check-ins
    #     "tunnel": "cloudflared",        // managed tunnel, or use "public_url"
    #     "public_url": "https://..."     // fixed public URL for this machine
    #   }
    class Settings
      DEFAULT_INTERVAL = 120
      DEFAULT_PRIORITY = 100

      def initialize(config)
        @config = config || {}
      end

      def url = @config["url"].to_s.chomp("/")
      def token = ENV["BRAINIAC_HUB_TOKEN"] || @config["token"]
      def enabled? = !url.empty? && !token.to_s.empty?
      def tunnel = @config["tunnel"]
      def public_url = @config["public_url"].to_s.chomp("/")
      def priority = @config.fetch("priority", DEFAULT_PRIORITY).to_i
      def wants_leader? = @config.fetch("leader", true) ? true : false

      def machine_name
        name = @config["machine"].to_s.empty? ? Socket.gethostname.split(".").first : @config["machine"]
        name.to_s.downcase.gsub(/[^a-z0-9._-]/, "-")
      end

      def interval
        value = @config["interval"].to_i
        value.positive? ? value : DEFAULT_INTERVAL
      end
    end
  end
end
