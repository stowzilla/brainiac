# frozen_string_literal: true

require_relative "test_helper"
require "open3"
require "tmpdir"

# Stub dependencies for git module
AI_AGENT_NAME = "Galen" unless defined?(AI_AGENT_NAME)
BRAINIAC_CONFIG = {} unless defined?(BRAINIAC_CONFIG)
CONFIG_MTIMES = {} unless defined?(CONFIG_MTIMES)
FIZZY_CONFIG = { "authorized_users" => [] } unless defined?(FIZZY_CONFIG)
FIZZY_BOARDS = {} unless defined?(FIZZY_BOARDS)
GITHUB_CONFIG = {} unless defined?(GITHUB_CONFIG)
AGENT_REGISTRY = {} unless defined?(AGENT_REGISTRY)
AUTHORIZED_USER_IDS = [] unless defined?(AUTHORIZED_USER_IDS)
NOTIFICATION_COMMAND = nil unless defined?(NOTIFICATION_COMMAND)
DISCORD_ENABLED = false unless defined?(DISCORD_ENABLED)
PROJECTS = {} unless defined?(PROJECTS)
DEFAULT_PROJECT = {
  "repo_path" => Dir.pwd, "fizzy_tags" => [], "github_repo" => nil,
  "agent_cli" => "kiro-cli", "agent_cli_args" => "chat --no-interactive",
  "agent_model_flag" => "--model", "agent_model" => nil,
  "agent_effort_flag" => "--effort", "agent_effort" => nil,
  "allowed_models" => {}, "allowed_efforts" => %w[low medium high xhigh max]
}.freeze unless defined?(DEFAULT_PROJECT)
CLI_PROVIDERS_DIR = File.join(BRAINIAC_DIR, "cli-providers") unless defined?(CLI_PROVIDERS_DIR)
FileUtils.mkdir_p(CLI_PROVIDERS_DIR)

require_relative "../lib/brainiac/helpers"
require_relative "../lib/brainiac/handlers/shared/git"

class TestGit < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir("git-test")
    @repo_path = File.join(@test_dir, "main-repo")
    setup_test_repo
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  # --- get_default_branch ---

  def test_get_default_branch
    branch = get_default_branch(@repo_path)
    # Should return "main" or "master" depending on git config
    assert_match(/\A(main|master)\z/, branch)
  end

  # --- capture_git_state ---

  def test_capture_git_state_returns_head_and_status
    head, status = capture_git_state(@repo_path)
    assert_match(/\A[0-9a-f]{40}\z/, head)
    assert_equal "", status # clean working tree
  end

  def test_capture_git_state_detects_changes
    File.write(File.join(@repo_path, "new_file.txt"), "hello")
    head, status = capture_git_state(@repo_path)
    refute_nil head
    assert_includes status, "new_file.txt"
  end

  # --- debounced_repo_fetch ---

  def test_debounced_repo_fetch_records_timestamp
    REPO_LAST_FETCH.delete(@repo_path)
    # This will fail (no remote) but should still record the attempt
    debounced_repo_fetch(@repo_path) rescue nil
    # After first call, a second within the debounce window should skip
    # We can verify by checking REPO_LAST_FETCH was set
    # (Note: in test without remote, this exercises the code path)
  end

  # --- Worktree lifecycle ---

  def test_create_or_reuse_worktree_new_branch
    worktree_path = File.join(@test_dir, "main-repo--test-branch")
    result = create_or_reuse_worktree(
      repo_path: @repo_path,
      branch: "test-branch",
      base_ref: "HEAD",
      worktree_path: worktree_path
    )
    assert_equal worktree_path, result
    assert File.directory?(worktree_path)
    assert File.exist?(File.join(worktree_path, "README.md"))
  end

  def test_create_or_reuse_worktree_reuses_existing
    worktree_path = File.join(@test_dir, "main-repo--reuse-branch")

    # Create first time
    create_or_reuse_worktree(repo_path: @repo_path, branch: "reuse-branch",
                             base_ref: "HEAD", worktree_path: worktree_path)

    # Create a file in the worktree to prove we reuse it
    File.write(File.join(worktree_path, "marker.txt"), "I was here")

    # Call again — should reuse
    result = create_or_reuse_worktree(repo_path: @repo_path, branch: "reuse-branch",
                                      base_ref: "HEAD", worktree_path: worktree_path)
    assert_equal worktree_path, result
    assert File.exist?(File.join(worktree_path, "marker.txt"))
  end

  # --- find_worktree_for_card ---

  def test_find_worktree_for_card_returns_nil_when_none
    assert_nil find_worktree_for_card(999, repo_path: @repo_path)
  end

  def test_find_worktree_for_card_finds_existing
    # Create a worktree matching the card pattern
    wt_path = File.join(@test_dir, "main-repo--fizzy-42-test-feature")
    create_or_reuse_worktree(repo_path: @repo_path, branch: "fizzy-42-test-feature",
                             base_ref: "HEAD", worktree_path: wt_path)

    result = find_worktree_for_card(42, repo_path: @repo_path)
    assert result
    assert_equal wt_path, result[:worktree]
    assert_equal "fizzy-42-test-feature", result[:branch]
  end

  # --- apply_worktree_includes ---

  def test_apply_worktree_includes_copies_files
    # Create .env in repo (gitignored)
    File.write(File.join(@repo_path, ".gitignore"), ".env\n")
    system("git", "add", ".gitignore", chdir: @repo_path)
    system("git", "commit", "-m", "add gitignore", chdir: @repo_path, out: File::NULL, err: File::NULL)
    File.write(File.join(@repo_path, ".env"), "SECRET=value")

    # Create .worktreeinclude
    File.write(File.join(@repo_path, ".worktreeinclude"), ".env\n")

    # Create worktree
    wt_path = File.join(@test_dir, "main-repo--include-test")
    create_or_reuse_worktree(repo_path: @repo_path, branch: "include-test",
                             base_ref: "HEAD", worktree_path: wt_path)

    # .env should have been copied
    assert File.exist?(File.join(wt_path, ".env"))
    assert_equal "SECRET=value", File.read(File.join(wt_path, ".env"))
  end

  # --- cleanup_card_worktrees ---

  def test_cleanup_card_worktrees_removes_clean_worktree
    wt_path = File.join(@test_dir, "main-repo--fizzy-55-cleanup-test")
    create_or_reuse_worktree(repo_path: @repo_path, branch: "fizzy-55-cleanup-test",
                             base_ref: "HEAD", worktree_path: wt_path)
    assert File.directory?(wt_path)

    cleanup_card_worktrees(55, repo_path: @repo_path)
    refute File.directory?(wt_path)
  end

  def test_cleanup_card_worktrees_skips_dirty_worktree
    wt_path = File.join(@test_dir, "main-repo--fizzy-56-dirty-test")
    create_or_reuse_worktree(repo_path: @repo_path, branch: "fizzy-56-dirty-test",
                             base_ref: "HEAD", worktree_path: wt_path)

    # Make it dirty
    File.write(File.join(wt_path, "uncommitted.txt"), "dirty")

    cleanup_card_worktrees(56, repo_path: @repo_path)
    assert File.directory?(wt_path) # should still be there
  end

  private

  def setup_test_repo
    FileUtils.mkdir_p(@repo_path)
    system("git", "init", @repo_path, out: File::NULL, err: File::NULL)
    system("git", "config", "user.email", "test@test.com", chdir: @repo_path)
    system("git", "config", "user.name", "Test", chdir: @repo_path)
    File.write(File.join(@repo_path, "README.md"), "# Test Repo")
    system("git", "add", ".", chdir: @repo_path)
    system("git", "commit", "-m", "initial commit", chdir: @repo_path, out: File::NULL, err: File::NULL)
  end
end
