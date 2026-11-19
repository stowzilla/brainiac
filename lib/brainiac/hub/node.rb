# frozen_string_literal: true

require "json"
require "net/http"
require "socket"
require "uri"

module Brainiac
  module Hub
    # This machine's side of the hub contract: check in, hold or give up the
    # leader role, verify deliveries, and pick up work that queued while away.
    class Node
      TUNNEL_SETTLE_SECONDS = 5

      attr_reader :settings, :ledger
      attr_accessor :client, :tunnel, :last_ok

      def initialize(config = {}, client: nil)
        @settings = Settings.new(config)
        @ledger = Ledger.new(@settings)
        @client = client
        @mutex = Mutex.new
        @leader = false
        @sent_claims = {}
        @wake = Queue.new
        @leader_events = Queue.new
      end

      def enabled? = settings.enabled?

      def public_url
        settings.public_url.empty? ? tunnel&.url : settings.public_url
      end

      # True when this machine should run the single-holder work (Discord
      # gateways, cron). Always true without a hub.
      #
      # A leader that cannot reach the hub gives the role up on its own after two
      # missed check-ins. The hub's lease lasts three, so the old leader has
      # stopped before another machine can take over.
      def leader?
        return true unless enabled?

        @mutex.synchronize { @leader && fresh? }
      end

      # Called once by the server after plugins are loaded.
      def start(port:)
        return unless enabled?

        @port = port
        @client ||= Client.new(url: settings.url, token: settings.token)
        start_tunnel
        start_leader_events
        @thread = Thread.new { run_loop }
        LOG.info "[Hub] Node '#{settings.machine_name}' -> #{settings.url} (check-in every #{settings.interval}s)"
      end

      # Clean shutdown: tell the hub we are gone so it stops pushing here and
      # frees the leader lease straight away.
      def stop
        return unless enabled? && @client

        @thread&.kill
        tunnel&.stop
        @client.delete("/nodes/#{settings.machine_name}")
        update_leader(false)
      rescue StandardError => e
        LOG.warn "[Hub] Deregister failed: #{e.message}"
      end

      # One check-in. Returns the hub's answer, or nil if it did not go through.
      def check_in
        url = public_url
        if url.to_s.empty?
          LOG.warn "[Hub] No public URL yet (tunnel still starting?) — skipping check-in"
          return step_down_if_stale
        end

        claims = pending_claims
        response = @client.post("/nodes", check_in_payload(url, claims))
        return step_down_if_stale unless response

        claims.each { |key| @sent_claims[key] = true }
        @mutex.synchronize { @last_ok = monotonic }
        update_leader(response["leader"] == settings.machine_name)
        replay(response["jobs"] || [])
        response
      end

      # Ask for a check-in now instead of at the next tick (e.g. the tunnel URL changed).
      def wake
        @wake << :now
      end

      # Leader hooks can be slow (opening a gateway per bot), so they run on
      # their own thread, in order, and never hold up a check-in.
      def start_leader_events
        @start_leader_events ||= Thread.new do
          loop do
            Brainiac.emit(@leader_events.pop, machine: settings.machine_name)
          rescue StandardError => e
            LOG.error "[Hub] Leader hook failed: #{e.message}"
          end
        end
      end

      private

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def fresh?
        @last_ok && (monotonic - @last_ok) < settings.interval * 2
      end

      def step_down_if_stale
        update_leader(false) if @mutex.synchronize { @leader && !fresh? }
        nil
      end

      def update_leader(value)
        changed = @mutex.synchronize do
          next false if @leader == value

          @leader = value
          true
        end
        return unless changed

        LOG.info "[Hub] #{value ? "This machine is now the leader" : "No longer the leader"} (Discord gateways, cron)"
        @leader_events << (value ? :hub_leader_acquired : :hub_leader_lost)
      end

      def check_in_payload(url, claims)
        { name: settings.machine_name, url: url, priority: settings.priority, interval: settings.interval,
          wants_leader: settings.wants_leader?, version: defined?(BRAINIAC_VERSION) ? BRAINIAC_VERSION : nil,
          claims: claims }
      end

      def pending_claims
        projects = defined?(PROJECTS) ? PROJECTS : {}
        Claims.local_branch_keys(projects).reject { |key| @sent_claims[key] }.first(200)
      end

      def run_loop
        wait_for_server
        loop do
          begin
            check_in
          rescue StandardError => e
            LOG.error "[Hub] Check-in error: #{e.message}"
            step_down_if_stale
          end
          @wake.pop(timeout: settings.interval)
          @wake.clear
        end
      end

      # The hub hands over queued work as soon as we check in, so the local
      # server has to be accepting connections first.
      def wait_for_server
        60.times do
          TCPSocket.new("127.0.0.1", @port).close
          return
        rescue SystemCallError
          sleep 1
        end
      end

      def start_tunnel
        return if settings.tunnel.nil? || settings.tunnel == false || !settings.public_url.empty?

        @tunnel = Tunnel.from_config(settings.tunnel, port: @port) do |_url|
          # Give the tunnel a moment to start routing before the hub pushes to it.
          Thread.new do
            sleep TUNNEL_SETTLE_SECONDS
            wake
          end
        end
        @tunnel.start
      end

      # Work that queued in the hub while this machine was away. It is posted to
      # our own server so it takes the same path as a live delivery.
      def replay(jobs)
        jobs.each do |job|
          response = post_locally(job)
          LOG.info "[Hub] Picked up queued job #{job["id"]} for #{job["path"]} (#{response.code})"
        rescue StandardError => e
          LOG.error "[Hub] Could not replay queued job #{job["id"]}: #{e.message}"
        end
      end

      def post_locally(job)
        uri = URI("http://127.0.0.1:#{@port}#{job["path"]}")
        request = Net::HTTP::Post.new(uri.request_uri)
        (job["headers"] || {}).each { |name, value| request[name] = value }
        request["X-Brainiac-Hub-Job"] = job["id"]
        request["X-Brainiac-Hub-Timestamp"] = job["timestamp"].to_s
        request["X-Brainiac-Hub-Signature"] = job["signature"].to_s
        request["Content-Type"] ||= "application/json" # a form content type would let Rack consume the body
        request.body = job["body"].to_s
        Net::HTTP.start(uri.host, uri.port, open_timeout: 5, read_timeout: 10) { |http| http.request(request) }
      end
    end
  end
end
