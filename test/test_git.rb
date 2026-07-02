# frozen_string_literal: true

require_relative "test_helper"

class TestGit < Minitest::Test
  def setup
    @test_dir = Dir.mktmpdir("git-test")
    @repo_path = File.join(@test_dir, "main-repo")
    setup_test_repo
  end

  def teardown
    FileUtils.rm_rf(@test_dir)
  end

  def test_get_default_branch
    branch = get_default_branch(@repo_path)
    assert_match(/\A(main|master)\z/, branch)
  end

  def test_capture_git_state
    head, status = capture_git_state(@repo_path)
    assert_match(/\A[0-9a-f]{40}\z/, head)
    assert_equal "", status
  end

  def test_capture_git_state_detects_changes
    File.write(File.join(@repo_path, "new_file.txt"), "hello")
    _head, status = capture_git_state(@repo_path)
    assert_includes status, "new_file.txt"
  end

  def test_create_worktree_new_branch
    wt_path = File.join(@test_dir, "main-repo--test-branch")
    result = create_or_reuse_worktree(repo_path: @repo_path, branch: "test-branch",
                                      base_ref: "HEAD", worktree_path: wt_path)
    assert_equal wt_path, result
    assert File.directory?(wt_path)
    assert File.exist?(File.join(wt_path, "README.md"))
  end

  def test_create_worktree_reuses_existing
    wt_path = File.join(@test_dir, "main-repo--reuse-branch")
    create_or_reuse_worktree(repo_path: @repo_path, branch: "reuse-branch",
                             base_ref: "HEAD", worktree_path: wt_path)
    File.write(File.join(wt_path, "marker.txt"), "I was here")
    result = create_or_reuse_worktree(repo_path: @repo_path, branch: "reuse-branch",
                                      base_ref: "HEAD", worktree_path: wt_path)
    assert_equal wt_path, result
    assert File.exist?(File.join(wt_path, "marker.txt"))
  end


  def test_cleanup_removes_clean_worktree
    wt_path = File.join(@test_dir, "main-repo--fizzy-55-cleanup")
    create_or_reuse_worktree(repo_path: @repo_path, branch: "fizzy-55-cleanup",
                             base_ref: "HEAD", worktree_path: wt_path)
    cleanup_work_item_worktrees(55, repo_path: @repo_path)
    refute File.directory?(wt_path)
  end

  def test_cleanup_skips_dirty_worktree
    wt_path = File.join(@test_dir, "main-repo--fizzy-56-dirty")
    create_or_reuse_worktree(repo_path: @repo_path, branch: "fizzy-56-dirty",
                             base_ref: "HEAD", worktree_path: wt_path)
    File.write(File.join(wt_path, "uncommitted.txt"), "dirty")
    cleanup_work_item_worktrees(56, repo_path: @repo_path)
    assert File.directory?(wt_path)
  end

  def test_apply_worktree_includes_copies_files
    File.write(File.join(@repo_path, ".gitignore"), ".env\n")
    system("git", "add", ".gitignore", chdir: @repo_path)
    system("git", "commit", "-m", "gitignore", chdir: @repo_path, out: File::NULL, err: File::NULL)
    File.write(File.join(@repo_path, ".env"), "SECRET=value")
    File.write(File.join(@repo_path, ".worktreeinclude"), ".env\n")
    wt_path = File.join(@test_dir, "main-repo--include-test")
    create_or_reuse_worktree(repo_path: @repo_path, branch: "include-test",
                             base_ref: "HEAD", worktree_path: wt_path)
    assert File.exist?(File.join(wt_path, ".env"))
    assert_equal "SECRET=value", File.read(File.join(wt_path, ".env"))
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
