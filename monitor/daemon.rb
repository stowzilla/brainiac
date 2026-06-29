#!/usr/bin/env ruby
# frozen_string_literal: true

# Brainiac Monitor Daemon
# Polls /api/status and exposes agent state via Unix socket for waybar/xbar.
# Modules (waybar/status.rb, xbar/plugin.rb) read from this socket.

require "fileutils"
require_relative "shared"

POLL_INTERVAL = 2 # seconds

@state = { sessions: [], count: 0, recent: [], last_update: nil }

def fetch_status
  uri = URI(API_URL)
  response = Net::HTTP.get_response(uri)
  return nil unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body)
rescue StandardError => e
  warn "Failed to fetch status: #{e.message}"
  nil
end

def update_state
  data = fetch_status
  return unless data

  @state = {
    sessions: data["sessions"],
    count: data["count"],
    recent: data["recent"] || [],
    last_update: Time.now.to_i
  }
end

def handle_client(client)
  client.puts @state.to_json
  client.close
rescue StandardError => e
  warn "Error handling client: #{e.message}"
end

def start_server
  FileUtils.rm_f(SOCKET_PATH)

  server = UNIXServer.new(SOCKET_PATH)
  File.chmod(0o666, SOCKET_PATH)

  File.write("/tmp/brainiac-daemon.pid", Process.pid)

  puts "Monitor daemon started, socket: #{SOCKET_PATH}"

  poller = Thread.new do
    loop do
      update_state
      sleep POLL_INTERVAL
    end
  end

  update_state

  loop do
    client = server.accept
    Thread.new { handle_client(client) }
  end
rescue Interrupt
  puts "\nShutting down..."
  poller&.kill
  FileUtils.rm_f(SOCKET_PATH)
  FileUtils.rm_f("/tmp/brainiac-daemon.pid")
  exit 0
end

start_server
