# frozen_string_literal: true

# Shared worktree lifecycle management for handlers.
#
# Both Fizzy and Discord create git worktrees with identical logic:
# fetch, check branch existence, create worktree, trust version manager,
# apply includes, run hooks. This module consolidates that.

# Create or reuse a git worktree for a given branch.
# Returns the worktree path on success.
#
# Options:
#   repo_path:  the main repo directory
#   branch:     the branch name to use
#   base_ref:   what to branch from (e.g. "origin/main") — only used if creating new
#   worktree_path: (optional) explicit path, defaults to sibling dir of repo
#
def create_or_reuse_worktree(repo_path:, branch:, base_ref: nil, worktree_path: nil)
  worktree_path ||= File.join(File.dirname(repo_path), "#{File.basename(repo_path)}--#{branch}")
  base_ref ||= "origin/#{get_default_branch(repo_path)}"

  # Get current worktree list once
  worktree_list = run_cmd("git", "worktree", "list", "--porcelain", chdir: repo_path)

  # Check if worktree directory exists but is orphaned (not tracked by git)
  if File.directory?(worktree_path)
    is_tracked = worktree_list.include?(worktree_path)

    if is_tracked
      LOG.info "Worktree directory #{worktree_path} is tracked by git"
    else
      LOG.warn "Orphaned worktree directory found at #{worktree_path}, removing it"
      begin
        FileUtils.rm_rf(worktree_path)
        LOG.info "Successfully removed orphaned directory"
      rescue StandardError => e
        LOG.error "Failed to remove orphaned directory: #{e.message}"
        raise
      end
    end
  end

  # Check if branch already exists
  branch_exists = system("git", "rev-parse", "--verify", branch, chdir: repo_path, out: File::NULL, err: File::NULL)

  if branch_exists
    LOG.info "Branch #{branch} already exists, checking for existing worktree"

    # Refresh worktree list after potential cleanup
    worktree_list = run_cmd("git", "worktree", "list", "--porcelain", chdir: repo_path)
    has_worktree = worktree_list.lines.any? { |line| line.strip == "worktree #{worktree_path}" }

    if has_worktree && File.directory?(worktree_path)
      LOG.info "Reusing existing worktree at #{worktree_path}"
    else
      LOG.info "Creating worktree from existing branch #{branch}"
      run_cmd("git", "worktree", "add", worktree_path, branch, chdir: repo_path)
    end
  else
    LOG.info "Creating new branch #{branch} and worktree"
    run_cmd("git", "worktree", "add", "-b", branch, worktree_path, base_ref, chdir: repo_path)
  end

  # Post-creation setup
  trust_version_manager(worktree_path, chdir: worktree_path)
  apply_worktree_includes(repo_path, worktree_path)
  run_project_hook(repo_path, "worktree-setup", extra_env: { "WORKTREE_PATH" => worktree_path })

  worktree_path
end

# Find an existing worktree for a card by scanning the filesystem.
# Returns { worktree: path, branch: name } or nil.
def find_worktree_for_card(card_number, repo_path:)
  return nil unless card_number

  repo_dir = File.dirname(repo_path)
  repo_base = File.basename(repo_path)
  candidates = Dir.glob(File.join(repo_dir, "#{repo_base}--fizzy-#{card_number}-*")).select { |d| File.directory?(d) }
  return nil if candidates.empty?

  worktree = candidates.first
  branch = File.basename(worktree).sub("#{repo_base}--", "")
  { worktree: worktree, branch: branch }
end
