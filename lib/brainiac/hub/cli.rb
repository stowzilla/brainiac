# frozen_string_literal: true

require "json"
require "fileutils"
require "logger"
require "optparse"
require "uri"

LOG = Logger.new($stderr, level: Logger::WARN) unless defined?(LOG)

require_relative "../hub"

module Brainiac
  module Hub
    CLI_USAGE = <<~TEXT
      Usage: brainiac hub <command>

        setup --url URL --token TOKEN [options]   Make this machine a node of a hub
            --machine NAME        Name for this machine (default: hostname)
            --priority N          Lower number = preferred for new work (default: 100)
            --tunnel cloudflared  Let Brainiac run a tunnel and report its URL
            --public-url URL      Or: a fixed public URL that reaches this machine
            --interval SECONDS    Seconds between check-ins (default: 120)
            --no-leader           Never hold the Discord gateways / cron on this machine
        show                      Show this machine's hub settings
        status                    Machines, who is online, who leads, what is queued
        assignments [PREFIX]      Which machine owns which card / branch (e.g. PREFIX fizzy:)
        move KEY MACHINE          Move a card or branch to another machine (e.g. fizzy:1834 mini)
        release KEY               Forget the owner, so the next event picks a machine afresh
        disable                   Remove the hub settings from this machine

      `brainiac machines` is short for `brainiac hub status`.
      Restart the server after setup or disable: brainiac restart
    TEXT

    # `brainiac hub ...` — set this machine up as a hub node and inspect or
    # change where work lives.
    class CLI
      def initialize(config_path:, out: $stdout, node: nil)
        @config_path = config_path
        @out = out
        @node = node
      end

      # @return [Integer] exit status
      def run(args)
        command = args.shift
        case command
        when "setup" then setup(args)
        when "show" then show
        when "status", "machines", nil then status
        when "assignments", "list", "ls" then assignments(args.first)
        when "move", "assign" then move(args[0], args[1])
        when "release", "unassign" then release(args.first)
        when "disable" then disable
        else
          @out.puts CLI_USAGE
          %w[help --help -h].include?(command) ? 0 : 1
        end
      end

      private

      def load_config
        File.exist?(@config_path) ? JSON.parse(File.read(@config_path)) : {}
      end

      def save_config(config)
        FileUtils.mkdir_p(File.dirname(@config_path))
        File.write(@config_path, "#{JSON.pretty_generate(config)}\n")
        File.chmod(0o600, @config_path) # holds the node token
      end

      def node
        @node ||= Node.new(load_config["hub"]).tap do |node|
          node.client = Client.new(url: node.settings.url, token: node.settings.token)
        end
      end

      def hub_ready?
        return true if node.enabled?

        @out.puts "No hub configured on this machine. Run: brainiac hub setup --url URL --token TOKEN"
        false
      end

      def setup(args)
        hub = (load_config["hub"] || {}).dup
        parse_setup_options(args, hub)
        if hub["url"].to_s.empty? || (hub["token"].to_s.empty? && ENV["BRAINIAC_HUB_TOKEN"].to_s.empty?)
          @out.puts "Both --url and --token are needed (or set BRAINIAC_HUB_TOKEN instead of --token)."
          return 1
        end
        unless hub["tunnel"] || !hub["public_url"].to_s.empty?
          @out.puts "The hub needs a way to reach this machine. Pass --tunnel cloudflared or --public-url URL."
          return 1
        end

        save_config(load_config.merge("hub" => hub))
        settings = Settings.new(hub)
        @out.puts "✓ Hub settings saved to #{@config_path}"
        @out.puts "  machine:  #{settings.machine_name} (priority #{settings.priority})"
        @out.puts "  reach me: #{hub["public_url"] || "#{hub["tunnel"]} tunnel (URL reported on each start)"}"
        @out.puts "  leader:   #{settings.wants_leader? ? "may hold Discord gateways and cron" : "never"}"
        @out.puts "Restart the server to connect: brainiac restart"
        0
      end

      def parse_setup_options(args, hub)
        OptionParser.new do |opts|
          opts.on("--url URL") { |value| hub["url"] = value.chomp("/") }
          opts.on("--token TOKEN") { |value| hub["token"] = value }
          opts.on("--machine NAME") { |value| hub["machine"] = value }
          opts.on("--priority N", Integer) { |value| hub["priority"] = value }
          opts.on("--interval SECONDS", Integer) { |value| hub["interval"] = value }
          opts.on("--tunnel NAME") do |value|
            hub["tunnel"] = value
            hub.delete("public_url")
          end
          opts.on("--public-url URL") do |value|
            hub["public_url"] = value.chomp("/")
            hub.delete("tunnel")
          end
          opts.on("--[no-]leader") { |value| hub["leader"] = value }
        end.parse!(args)
      end

      def show
        hub = load_config["hub"]
        return @out.puts("No hub configured on this machine.").then { 0 } unless hub

        shown = hub.merge("token" => hub["token"] ? "#{hub["token"][0, 4]}… (hidden)" : nil).compact
        @out.puts JSON.pretty_generate(shown)
        0
      end

      def disable
        config = load_config
        return @out.puts("No hub configured on this machine.").then { 0 } unless config.delete("hub")

        save_config(config)
        @out.puts "✓ Hub settings removed. Restart the server: brainiac restart"
        0
      end

      def status
        return 1 unless hub_ready?

        data = node.client.get("/nodes")
        return @out.puts("Could not reach the hub at #{node.settings.url}").then { 1 } unless data

        nodes = data["nodes"] || []
        @out.puts "Hub: #{node.settings.url}"
        @out.puts "Leader (Discord gateways, cron): #{data["leader"] || "nobody"}"
        @out.puts nodes.empty? ? "No machines have checked in yet." : ""
        nodes.each { |entry| @out.puts status_line(entry, data) }
        print_queue(data["queued"] || {})
        0
      end

      def status_line(entry, data)
        marks = []
        marks << "this machine" if entry["name"] == node.settings.machine_name
        marks << "leader" if entry["name"] == data["leader"]
        state = entry["online"] ? "online " : "OFFLINE"
        seen = entry["last_seen_at"].to_i.positive? ? Time.at(entry["last_seen_at"].to_i).strftime("%Y-%m-%d %H:%M:%S") : "never"
        suffix = marks.empty? ? "" : "  (#{marks.join(", ")})"
        format("  %-16<name>s %<state>s  priority %-4<priority>d last seen %<seen>s%<suffix>s",
               name: entry["name"], state: state, priority: entry["priority"].to_i, seen: seen, suffix: suffix)
      end

      def print_queue(queued)
        return if queued.empty?

        @out.puts ""
        @out.puts "Waiting in the hub:"
        queued.each { |machine, count| @out.puts "  #{count} for #{machine == "*" ? "the first machine to check in" : machine}" }
      end

      def assignments(prefix)
        return 1 unless hub_ready?

        path = prefix.to_s.empty? ? "/assignments" : "/assignments?prefix=#{URI.encode_www_form_component(prefix)}"
        rows = (node.client.get(path) || {})["assignments"]
        return @out.puts("Could not reach the hub.").then { 1 } unless rows

        @out.puts "Nothing assigned#{" under #{prefix}" unless prefix.to_s.empty?}." if rows.empty?
        rows.each { |row| @out.puts format("  %-60<key>s %<machine>s", key: row["key"], machine: row["machine"]) }
        0
      end

      def move(key, machine)
        return @out.puts("Usage: brainiac hub move KEY MACHINE   (e.g. fizzy:1834 mini)").then { 1 } unless key && machine
        return 1 unless hub_ready?

        result = node.client.put("/assignments", { machine: machine.downcase, keys: [key], overwrite: true })
        return @out.puts("Could not reach the hub.").then { 1 } unless result

        @out.puts "✓ #{key} now belongs to #{machine.downcase}."
        @out.puts "  The worktree and CLI session stay on the old machine. Push the branch there first;"
        @out.puts "  the new machine picks up from the pushed branch and the brain's memory."
        0
      end

      def release(key)
        return @out.puts("Usage: brainiac hub release KEY").then { 1 } unless key
        return 1 unless hub_ready?

        result = node.client.delete("/assignments?key=#{URI.encode_www_form_component(key)}")
        return @out.puts("Could not reach the hub.").then { 1 } unless result

        @out.puts "✓ #{key} has no owner. The next event for it picks a machine by priority."
        0
      end
    end
  end
end
