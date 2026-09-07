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

    refute_match(%r{ambiguous argument 'origin/main'}, err)
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
      raise("git #{args.join(" ")} failed")
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
    assert_equal %w[belt deploy frontend fizzy-1299],
                 BeltEnvironment.deploy_command("fizzy-1299", frontend_only: true)
  end

  def test_frontend_only_command_does_not_append_frontend_as_extra_arg
    cmd = BeltEnvironment.deploy_command("fizzy-1299", frontend_only: true)
    refute_equal %w[belt deploy fizzy-1299 frontend], cmd
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

    assert_equal %w[belt deploy frontend fizzy-1299], captured[:args]
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

# Epic ephemeral env lookups (epic_env_for_branch / epic_env_for_pr).
#
# Epic envs are keyed by name (e.g. "epic-fp-ux") rather than a card number and
# carry `epic_branch` / `epic_pr` fields. Nothing used to read those fields, so
# epic PRs never auto-deployed. These lookups map an epic branch/PR back to its
# tracked env so the github plugin can redeploy it.
#
# The lookups read the real ephemeral_envs.json under BRAINIAC_DIR (set to a
# tmpdir by test_helper), so we write/restore that file per test.
class TestBeltEpicEnvLookup < Minitest::Test
  STATE_FILE = File.join(BeltConfig::BRAINIAC_DIR, "ephemeral_envs.json")

  EPIC_BRANCH = "epic/feature-parity-ux-platform-improvements"
  EPIC_PR = "https://github.com/stowzilla/feature_parity/pull/86"

  def setup
    @original = File.exist?(STATE_FILE) ? File.read(STATE_FILE) : nil
  end

  def teardown
    if @original
      File.write(STATE_FILE, @original)
    else
      FileUtils.rm_f(STATE_FILE)
    end
  end

  def write_state(state)
    File.write(STATE_FILE, JSON.pretty_generate(state))
  end

  def epic_entry(overrides = {})
    {
      "status" => "active",
      "project" => "feature-parity",
      "epic_branch" => EPIC_BRANCH,
      "epic_pr" => EPIC_PR,
      "worktree" => "/home/andy/Code/feature_parity--discord-epic-fp-ux-1546154442"
    }.merge(overrides)
  end

  # --- epic_env_for_branch ---

  def test_branch_lookup_returns_name_and_entry_on_match
    write_state({ "epic-fp-ux" => epic_entry })

    name, entry = BeltConfig.epic_env_for_branch(EPIC_BRANCH)

    assert_equal "epic-fp-ux", name
    assert_equal EPIC_BRANCH, entry["epic_branch"]
    assert_equal EPIC_PR, entry["epic_pr"]
  end

  def test_branch_lookup_returns_nil_when_no_match
    write_state({ "epic-fp-ux" => epic_entry })

    assert_nil BeltConfig.epic_env_for_branch("epic/some-other-branch")
  end

  def test_branch_lookup_ignores_destroyed_envs
    write_state({ "epic-fp-ux" => epic_entry("status" => "destroyed") })

    assert_nil BeltConfig.epic_env_for_branch(EPIC_BRANCH)
  end

  def test_branch_lookup_ignores_non_epic_entries
    # A regular card env matching the branch name but with no epic_branch field
    # must not be returned — only epic-tracked entries qualify.
    write_state({
                  "fizzy-1299" => {
                    "status" => "active",
                    "worktree" => "/tmp/wt"
                  }
                })

    assert_nil BeltConfig.epic_env_for_branch(EPIC_BRANCH)
  end

  def test_branch_lookup_returns_first_active_match
    write_state({
                  "epic-old" => epic_entry("status" => "destroyed"),
                  "epic-fp-ux" => epic_entry
                })

    name, = BeltConfig.epic_env_for_branch(EPIC_BRANCH)

    assert_equal "epic-fp-ux", name
  end

  def test_branch_lookup_nil_for_nil_branch
    write_state({ "epic-fp-ux" => epic_entry })

    assert_nil BeltConfig.epic_env_for_branch(nil)
  end

  def test_branch_lookup_nil_for_empty_branch
    write_state({ "epic-fp-ux" => epic_entry })

    assert_nil BeltConfig.epic_env_for_branch("")
  end

  def test_branch_lookup_nil_when_state_file_missing
    FileUtils.rm_f(STATE_FILE)

    assert_nil BeltConfig.epic_env_for_branch(EPIC_BRANCH)
  end

  def test_branch_lookup_nil_on_malformed_json
    File.write(STATE_FILE, "{ this is not valid json ]")

    assert_nil BeltConfig.epic_env_for_branch(EPIC_BRANCH)
  end

  def test_branch_lookup_tolerates_non_hash_entries
    # Guards against `entry.is_a?(Hash)` regressions — a stray scalar value in
    # the state file must not blow up the scan.
    write_state({
                  "schema_version" => "1.0",
                  "epic-fp-ux" => epic_entry
                })

    name, = BeltConfig.epic_env_for_branch(EPIC_BRANCH)

    assert_equal "epic-fp-ux", name
  end

  # --- epic_env_for_pr ---

  def test_pr_lookup_returns_name_and_entry_on_match
    write_state({ "epic-fp-ux" => epic_entry })

    name, entry = BeltConfig.epic_env_for_pr(EPIC_PR)

    assert_equal "epic-fp-ux", name
    assert_equal EPIC_PR, entry["epic_pr"]
  end

  def test_pr_lookup_returns_nil_when_no_match
    write_state({ "epic-fp-ux" => epic_entry })

    assert_nil BeltConfig.epic_env_for_pr("https://github.com/stowzilla/feature_parity/pull/999")
  end

  def test_pr_lookup_ignores_destroyed_envs
    write_state({ "epic-fp-ux" => epic_entry("status" => "destroyed") })

    assert_nil BeltConfig.epic_env_for_pr(EPIC_PR)
  end

  def test_pr_lookup_requires_epic_branch_field
    # An entry can only match by PR if it is a real epic entry (has epic_branch).
    write_state({
                  "epic-fp-ux" => {
                    "status" => "active",
                    "epic_pr" => EPIC_PR,
                    "worktree" => "/tmp/wt"
                  }
                })

    assert_nil BeltConfig.epic_env_for_pr(EPIC_PR)
  end

  def test_pr_lookup_nil_for_nil_pr
    write_state({ "epic-fp-ux" => epic_entry })

    assert_nil BeltConfig.epic_env_for_pr(nil)
  end

  def test_pr_lookup_nil_for_empty_pr
    write_state({ "epic-fp-ux" => epic_entry })

    assert_nil BeltConfig.epic_env_for_pr("")
  end

  def test_pr_lookup_nil_when_state_file_missing
    FileUtils.rm_f(STATE_FILE)

    assert_nil BeltConfig.epic_env_for_pr(EPIC_PR)
  end
end
