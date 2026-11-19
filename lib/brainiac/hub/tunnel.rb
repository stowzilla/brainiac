# frozen_string_literal: true

require "open3"

module Brainiac
  module Hub
    # Runs a tunnel process, reads its public URL from the output, and restarts
    # it if it exits. A new URL triggers a fresh check-in, so the URL is allowed
    # to change every time.
    class Tunnel
      PRESETS = {
        "cloudflared" => {
          "command" => ["cloudflared", "tunnel", "--url", "http://127.0.0.1:%<port>d"],
          "url_pattern" => 'https://(?!api\.)[a-z0-9-]+\.trycloudflare\.com'
        }
      }.freeze
      RESTART_DELAY = 10

      attr_reader :url

      # @param setting [String, Hash] a preset name, or { "command" => [...], "url_pattern" => "..." }
      def self.from_config(setting, port:, &on_url)
        spec = setting.is_a?(Hash) ? setting : PRESETS[setting.to_s]
        raise ArgumentError, "Unknown hub tunnel '#{setting}' (known: #{PRESETS.keys.join(", ")})" unless spec

        command = Array(spec["command"]).map { |part| format(part.to_s, port: port) }
        new(command: command, url_pattern: Regexp.new(spec["url_pattern"].to_s), &on_url)
      end

      def initialize(command:, url_pattern:, &on_url)
        @command = command
        @url_pattern = url_pattern
        @on_url = on_url
        @stopping = false
      end

      def start
        @thread = Thread.new do
          until @stopping
            run_once
            sleep RESTART_DELAY unless @stopping
          end
        end
      end

      def stop
        @stopping = true
        Process.kill("TERM", @pid) if @pid
      rescue Errno::ESRCH
        nil
      end

      # Feed one line of tunnel output. Public so it can be tested without a process.
      def read_line(line)
        found = line[@url_pattern]
        return unless found && found != @url

        @url = found
        LOG.info "[Hub] Tunnel URL: #{found}"
        @on_url&.call(found)
      end

      private

      def run_once
        Open3.popen2e(*@command) do |stdin, output, wait|
          stdin.close
          @pid = wait.pid
          output.each_line { |line| read_line(line) }
          LOG.warn "[Hub] Tunnel exited (#{wait.value.exitstatus})" unless @stopping
        end
      rescue Errno::ENOENT
        LOG.error "[Hub] Tunnel command not found: #{@command.first}. Install it or set hub.public_url instead."
        sleep 60
      rescue StandardError => e
        LOG.error "[Hub] Tunnel error: #{e.message}"
      ensure
        @url = nil
        @pid = nil
      end
    end
  end
end
