# frozen_string_literal: true

require "forwardable"
require "json"
require "uri"

require_relative "hub/settings"
require_relative "hub/client"
require_relative "hub/tunnel"
require_relative "hub/claims"
require_relative "hub/ledger"
require_relative "hub/node"
require_relative "hub/inbox"

# Multi-machine support: this machine as a node of a brainiac-hub.
#
# The hub is a small cloud app that receives webhooks and pushes each one to
# exactly one machine. A node's side of that contract:
#
#   - check in with the hub on start and on a timer (liveness, the leader
#     lease, branch claims, and pickup of anything queued while we were away)
#   - keep a public URL for the hub to push to (a managed tunnel or a fixed URL)
#   - acknowledge hub deliveries immediately, then run them
#   - hold or give up the "leader" role, which decides who runs the Discord
#     gateways and cron
#
# Everything is off unless brainiac.json has a "hub" block with a url and a
# token. With no hub configured, leader? is true and nothing else runs, so a
# single machine behaves exactly as before.
#
# See docs/multi-machine.md.
module Brainiac
  module Hub
    class << self
      extend Forwardable

      attr_writer :node

      def_delegators :node, :enabled?, :leader?, :settings, :client, :ledger
      def_delegators :ledger, :valid_signature?, :first_delivery?

      def node
        @node ||= Node.new(defined?(load_brainiac_config) ? load_brainiac_config["hub"] : {})
      end

      def start!(port:) = node.start(port: port)
      def stop! = node.stop
      def machine_name = settings.machine_name

      # --- hub API (CLI and plugins) ---

      # { "leader" => name, "nodes" => [...], "queued" => { machine => count } } or nil
      def status
        client.get("/nodes")
      end

      def assignments(prefix = nil)
        path = prefix.to_s.empty? ? "/assignments" : "/assignments?prefix=#{URI.encode_www_form_component(prefix)}"
        (client.get(path) || {})["assignments"] || []
      end

      # The machine that owns one work key, or nil (also nil if the hub did not answer).
      def owner(key)
        rows = (client.get("/assignments?key=#{URI.encode_www_form_component(key)}") || {})["assignments"] || []
        rows.find { |row| row["key"] == key }&.fetch("machine", nil)
      end

      # Forget a key's owner (the work is finished or its worktree is gone).
      def release(key)
        client.delete("/assignments?key=#{URI.encode_www_form_component(key)}")
      end

      # Give work keys to a machine. overwrite: false only fills in unowned keys.
      def assign(keys, machine, overwrite: true)
        client.put("/assignments", { machine: machine, keys: Array(keys), overwrite: overwrite })
      end

      # Hand a JSON payload to another machine through the hub.
      # Returns { "status" => "delivered" | "queued", "machine" => name } or nil.
      def relay(path:, payload:, keys: [], machine: nil, reassign: false)
        client.post("/relays", { path: path, body: JSON.generate(payload), keys: keys,
                                 machine: machine, reassign: reassign })
      end
    end
  end
end
