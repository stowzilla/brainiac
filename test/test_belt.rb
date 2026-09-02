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

class TestBeltFrontendOnlyChanges < Minitest::Test
  def setup
    @dir = Dir.mktmpdir("belt-frontend-test")
    setup_master_only_repo
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_resolves_origin_master_when_origin_main_missing
    add_frontend_commit

    assert BeltEnvironment.frontend_only_changes?(worktree: @dir)
  end

  def test_explicit_master_base_without_origin_prefix
    add_frontend_commit

    assert BeltEnvironment.frontend_only_changes?(worktree: @dir, base_branch: "master")
  end

  def test_backend_change_is_not_frontend_only
    FileUtils.mkdir_p(File.join(@dir, "lambda"))
    File.write(File.join(@dir, "lambda", "app.rb"), "puts 1\n")
    git("add", ".")
    git("commit", "-m", "backend")

    refute BeltEnvironment.frontend_only_changes?(worktree: @dir)
  end

  def test_returns_false_when_no_git_refs
    empty = Dir.mktmpdir("belt-no-git")
    refute BeltEnvironment.frontend_only_changes?(worktree: empty)
  ensure
    FileUtils.rm_rf(empty)
  end

  def test_does_not_leak_git_fatal_on_missing_main
    add_frontend_commit
    err = capture_io do
      BeltEnvironment.frontend_only_changes?(worktree: @dir)
    end[1]

    refute_match(/ambiguous argument 'origin\/main'/, err)
    refute_match(/unknown revision/, err)
  end

  private

  def setup_master_only_repo
    git("init", "-b", "master")
    git("config", "user.email", "test@test.com")
    git("config", "user.name", "Test")
    File.write(File.join(@dir, "README.md"), "# test\n")
    git("add", ".")
    git("commit", "-m", "initial")
    git("update-ref", "refs/remotes/origin/master", "HEAD")
    git("symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/master")
    git("checkout", "-b", "fizzy-1299-webhooks")
  end

  def add_frontend_commit
    FileUtils.mkdir_p(File.join(@dir, "frontend", "src"))
    File.write(File.join(@dir, "frontend", "src", "App.jsx"), "export default function App() {}\n")
    git("add", ".")
    git("commit", "-m", "frontend")
  end

  def git(*args)
    system("git", *args, chdir: @dir, out: File::NULL, err: File::NULL) ||
      raise("git #{args.join(' ')} failed")
  end
end
