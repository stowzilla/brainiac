#!/usr/bin/env ruby
# frozen_string_literal: true

# One-time setup: installs Brainiac menu bar plugin into xbar or SwiftBar.
#
# Detects which app is installed and symlinks the plugin.
# Run this once — the plugin auto-refreshes on its configured interval.

require "fileutils"

PLUGIN_APPS = [
  {
    name: "SwiftBar",
    plugin_dir: File.expand_path("~/Library/Application Support/SwiftBar/Plugins"),
    app_path: "/Applications/SwiftBar.app"
  },
  {
    name: "xbar",
    plugin_dir: File.expand_path("~/Library/Application Support/xbar/plugins"),
    app_path: "/Applications/xbar.app"
  }
].freeze

SYMLINK_NAME = "brainiac.2s.rb"
SOURCE_PATH = File.join(File.dirname(File.expand_path(__FILE__)), "plugin.rb")

def detect_plugin_app
  PLUGIN_APPS.each do |app|
    return { name: app[:name], plugin_dir: app[:plugin_dir] } if Dir.exist?(app[:plugin_dir]) || File.exist?(app[:app_path])
  end
  nil
end

# --- Main ---

app = detect_plugin_app

unless app
  puts "No xbar or SwiftBar installation detected."
  puts ""
  puts "Install one of the following to use the Brainiac menu bar plugin:"
  puts "  • xbar:     https://xbarapp.com"
  puts "  • SwiftBar: https://github.com/swiftbar/SwiftBar"
  puts ""
  puts "After installing, re-run this script:"
  puts "  ruby #{__FILE__}"
  exit 0
end

puts "Detected #{app[:name]}"

FileUtils.mkdir_p(app[:plugin_dir])
link_path = File.join(app[:plugin_dir], SYMLINK_NAME)

File.delete(link_path) if File.exist?(link_path) || File.symlink?(link_path)
File.symlink(SOURCE_PATH, link_path)
File.chmod(0o755, SOURCE_PATH)

puts "✓ Installed Brainiac plugin into #{app[:name]}"
puts "  Symlink: #{link_path} → #{SOURCE_PATH}"
puts "  Refresh interval: 2s"
puts "  Restart #{app[:name]} to activate"
