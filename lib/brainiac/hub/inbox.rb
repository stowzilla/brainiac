# frozen_string_literal: true

require "stringio"

module Brainiac
  module Hub
    # Rack middleware for deliveries pushed by the hub.
    #
    # A hub delivery is acknowledged with 202 before the plugin route runs. The
    # webhook routes do real work before they answer (git fetch, worktree setup,
    # API calls), and the hub treats a slow answer as a dead machine and tries
    # the next one. Answering first is what stops two machines running one job.
    #
    # Anything under /hub/ is hub-only: it is refused without a valid signature.
    class Inbox
      ACCEPTED = [202, { "content-type" => "application/json" }, ['{"status":"accepted"}']].freeze
      DUPLICATE = [200, { "content-type" => "application/json" }, ['{"status":"duplicate"}']].freeze
      REFUSED = [401, { "content-type" => "application/json" }, ['{"error":"invalid hub signature"}']].freeze
      FORBIDDEN = [403, { "content-type" => "application/json" }, ['{"error":"not a hub route"}']].freeze
      # The admin API and dashboard are never hub deliveries. Queued work is
      # replayed from localhost, where their token check is skipped, so a hub
      # job must not be able to name them.
      OFF_LIMITS = %r{\A/(api|dashboard)(/|\z)}i

      def initialize(app, hub: Brainiac::Hub, async: true)
        @app = app
        @hub = hub
        @async = async
      end

      def call(env)
        job_id = env["HTTP_X_BRAINIAC_HUB_JOB"]
        hub_only = env["PATH_INFO"].to_s.start_with?("/hub/")
        return @app.call(env) unless hub_only || (job_id && @hub.enabled?)

        return FORBIDDEN if off_limits?(env["PATH_INFO"].to_s)

        body = env["rack.input"]&.read.to_s
        return REFUSED unless job_id && signed?(env, job_id, body)
        return DUPLICATE unless @hub.first_delivery?(job_id)

        deliver(env.merge("rack.input" => StringIO.new(body), "brainiac.hub.job" => job_id))
        ACCEPTED
      end

      private

      def off_limits?(path)
        path.match?(OFF_LIMITS) || path.split("/").include?("..")
      end

      def signed?(env, job_id, body)
        @hub.valid_signature?(
          timestamp: env["HTTP_X_BRAINIAC_HUB_TIMESTAMP"], job_id: job_id, path: env["PATH_INFO"].to_s,
          body: body, signature: env["HTTP_X_BRAINIAC_HUB_SIGNATURE"].to_s
        )
      end

      def deliver(env)
        work = lambda do
          status, _headers, response = @app.call(env)
          response.close if response.respond_to?(:close)
          LOG.info "[Hub] Job #{env["brainiac.hub.job"]} #{env["PATH_INFO"]} -> #{status}"
        rescue StandardError => e
          LOG.error "[Hub] Job #{env["brainiac.hub.job"]} failed: #{e.message}"
        end
        @async ? Thread.new(&work) : work.call
      end
    end
  end
end
