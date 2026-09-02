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

class TestBeltDeployCommand < Minitest::Test
  FakeStatus = Struct.new(:success?)

  def setup
    @dir = Dir.mktmpdir("belt-deploy-test")
    FileUtils.mkdir_p(File.join(@dir, "config"))
    File.write(File.join(@dir, "config", "routes.rb"), "app.get '/x'\n")
  end

  def teardown
    FileUtils.rm_rf(@dir)
  end

  def test_full_deploy_command_passes_auto
    assert_equal ["belt", "deploy", "fizzy-1299", "--auto"],
                 BeltEnvironment.deploy_command("fizzy-1299")
  end

  def test_frontend_only_command_uses_frontend_subcommand
    assert_equal ["belt", "deploy", "frontend", "fizzy-1299"],
                 BeltEnvironment.deploy_command("fizzy-1299", frontend_only: true)
  end

  def test_frontend_only_command_does_not_append_frontend_as_extra_arg
    cmd = BeltEnvironment.deploy_command("fizzy-1299", frontend_only: true)
    refute_equal ["belt", "deploy", "fizzy-1299", "frontend"], cmd
  end

  def test_cancelled_output_is_detected
    stdout = "Apply these changes to fizzy-1299? [y/N] \nCancelled.\n"
    assert BeltEnvironment.deploy_cancelled?(stdout, "")
  end

  def test_success_output_is_not_cancelled
    refute BeltEnvironment.deploy_cancelled?("✅ Deployed fizzy-1299 successfully!\n", "")
  end

  def test_deploy_invokes_auto_flag
    captured = capture_belt_cli(stdout: "✅ Deployed fizzy-1299 successfully!\n") do |fake|
      BeltEnvironment.deploy(worktree: @dir, env_name: "fizzy-1299", capture3: fake)
    end

    assert_equal ["belt", "deploy", "fizzy-1299", "--auto"], captured[:args]
    assert_equal @dir, captured[:kwargs][:chdir]
  end

  def test_deploy_frontend_only_invokes_frontend_subcommand
    captured = capture_belt_cli(stdout: "✅ Frontend deployed to fizzy-1299!\n") do |fake|
      BeltEnvironment.deploy(worktree: @dir, env_name: "fizzy-1299", frontend_only: true, capture3: fake)
    end

    assert_equal ["belt", "deploy", "frontend", "fizzy-1299"], captured[:args]
  end

  def test_cancelled_deploy_is_failure_even_when_exit_zero
    result = nil
    capture_belt_cli(stdout: "Apply these changes to fizzy-1299? [y/N] \nCancelled.\n", success: true) do |fake|
      result = BeltEnvironment.deploy(worktree: @dir, env_name: "fizzy-1299", capture3: fake)
    end

    refute result
  end

  def test_successful_deploy_returns_true
    result = nil
    capture_belt_cli(stdout: "✅ Deployed fizzy-1299 successfully!\n") do |fake|
      result = BeltEnvironment.deploy(worktree: @dir, env_name: "fizzy-1299", capture3: fake)
    end

    assert result
  end

  def test_nonzero_exit_is_failure
    result = nil
    capture_belt_cli(stdout: "", stderr: "boom", success: false) do |fake|
      result = BeltEnvironment.deploy(worktree: @dir, env_name: "fizzy-1299", capture3: fake)
    end

    refute result
  end

  def test_deploy_skipped_when_not_belt_app
    empty = Dir.mktmpdir("not-belt")
    called = false
    fake = lambda { |*|
      called = true
      ["", "", FakeStatus.new(true)]
    }
    refute BeltEnvironment.deploy(worktree: empty, env_name: "fizzy-1299", capture3: fake)
    refute called
  ensure
    FileUtils.rm_rf(empty)
  end

  private

  def capture_belt_cli(stdout:, stderr: "", success: true)
    captured = { args: nil, kwargs: nil }
    fake = lambda { |*args, **kwargs|
      captured[:args] = args
      captured[:kwargs] = kwargs
      [stdout, stderr, FakeStatus.new(success)]
    }
    yield fake
    captured
  end
end
