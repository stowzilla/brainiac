# frozen_string_literal: true

require "openssl"

module Brainiac
  module Hub
    # Decides whether a delivery really came from the hub and whether it has
    # already run on this machine.
    class Ledger
      SIGNATURE_MAX_AGE = 300
      SEEN_JOBS_LIMIT = 2000

      def initialize(settings)
        @settings = settings
        @mutex = Mutex.new
        @seen_jobs = []
      end

      def valid_signature?(timestamp:, job_id:, path:, body:, signature:, now: Time.now.to_i)
        token = @settings.token.to_s
        return false if token.empty? || signature.to_s.empty?
        return false if (now - timestamp.to_i).abs > SIGNATURE_MAX_AGE

        expected = OpenSSL::HMAC.hexdigest("SHA256", token, "#{timestamp}.#{job_id}.#{path}.#{body}")
        expected.bytesize == signature.bytesize && OpenSSL.fixed_length_secure_compare(expected, signature)
      end

      # True the first time a job id is seen. The hub can deliver a job twice
      # (a slow acknowledgement looks like a failure), so each id runs once.
      def first_delivery?(job_id)
        @mutex.synchronize do
          return false if @seen_jobs.include?(job_id)

          @seen_jobs << job_id
          @seen_jobs.shift while @seen_jobs.size > SEEN_JOBS_LIMIT
          true
        end
      end
    end
  end
end
