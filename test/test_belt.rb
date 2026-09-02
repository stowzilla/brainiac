# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/handlers/shared/belt"

class TestBeltEnvironmentConfigured < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("belt-env-test")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_environment_configured_when_infrastructure_dir_exists
    FileUtils.mkdir_p(File.join(@dir, "infrastructure", "fizzy-1299"))
    assert BeltEnvironment.environment_configured?(worktree: @dir, env_name: "fizzy-1299")
  end

  def test_environment_not_configured_when_dir_missing
    FileUtils.mkdir_p(File.join(@dir, "infrastructure", "dev"))
    refute BeltEnvironment.environment_configured?(worktree: @dir, env_name: "fizzy-1299")
  end

  def test_environment_not_configured_for_nil_worktree
    refute BeltEnvironment.environment_configured?(worktree: nil, env_name: "fizzy-1")
  end

  def test_belt_app_detects_config_routes
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config", "routes.rb"), "app.get '/x'\n")
    assert BeltEnvironment.belt_app?(@dir)
  end

  def test_belt_app_false_without_routes
    refute BeltEnvironment.belt_app?(@dir)
  end
end
