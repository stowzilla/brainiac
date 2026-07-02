# frozen_string_literal: true

# Shared git operations: worktree lifecycle, branching, fetching, cleanup.
#
# All git-related utilities live here. Handlers call these instead of
# reimplementing git worktree/branch logic.

# Debounced repo git fetch — avoids fetching the same repo multiple times within a short window.
REPO_LAST_FETCH = {}
REPO_FETCH_DEBOUNCE = 300 # 5 minutes

def debounced_repo_fetch(repo_path)
  last = REPO_LAST_FETCH[repo_path]
  if last && (Time.now - last) < REPO_FETCH_DEBOUNCE
    LOG.info "Skipping git fetch for #{repo_path} — fetched #{(Time.now - last).to_i}s ago"
    return
  end

  run_cmd("git", "fetch", "origin", chdir: repo_path)
  REPO_LAST_FETCH[repo_path] = Time.now
end

def get_default_branch(repo_path)
  default_branch = run_cmd("git", "rev-parse", "--abbrev-ref", "HEAD", chdir: repo_path).strip
  begin
    run_cmd("git", "symbolic-ref", "--short", "refs/remotes/origin/HEAD", chdir: repo_path).strip.sub("origin/", "")
  rescue StandardError
    default_branch
  end
end

# Capture git HEAD and working tree status for a directory.
def capture_git_state(chdir)
  head, = Open3.capture2("git", "rev-parse", "HEAD", chdir: chdir)
  status, = Open3.capture2("git", "status", "--porcelain", chdir: chdir)
  [head.strip, status.strip]
rescue StandardError
  [nil, nil]
end

# Trust the version manager config in a directory (supports mise and asdf)
def trust_version_manager(path, chdir:)
  if system("which mise >/dev/null 2>&1")
    run_cmd("mise", "trust", path, chdir: chdir)
  elsif system("which asdf >/dev/null 2>&1")
    LOG.info "asdf detected — no explicit trust needed for #{path}"
  else
    LOG.info "No version manager (mise/asdf) found — skipping trust for #{path}"
  end
rescue StandardError => e
  LOG.warn "Could not trust version manager in #{path}: #{e.message}"
end

# Copy gitignored files matching .worktreeinclude patterns from repo to worktree.
# Symlink directories matching .worktreelink patterns instead of copying.
def apply_worktree_includes(repo_path, worktree_path)
  copied = 0
  linked = 0

  [".worktreeinclude", ".worktreelink"].each do |filename|
    config_file = File.join(repo_path, filename)
    next unless File.exist?(config_file)

    symlink_mode = filename == ".worktreelink"
    patterns = File.readlines(config_file).map(&:strip).reject { |l| l.empty? || l.start_with?("#") }
    next if patterns.empty?

    patterns.each do |pattern|
      Dir.glob(pattern, File::FNM_DOTMATCH, base: repo_path).each do |match|
        src = File.join(repo_path, match)
        dest = File.join(worktree_path, match)
        next if File.exist?(dest) || File.symlink?(dest)

        _, _, st = Open3.capture3("git", "check-ignore", "-q", match, chdir: repo_path)
        next unless st.success?

        FileUtils.mkdir_p(File.dirname(dest))

        if symlink_mode && File.directory?(src)
          FileUtils.ln_s(src, dest)
          linked += 1
          LOG.info "Symlinked #{match} from main repo"
        elsif File.file?(src)
          FileUtils.cp(src, dest)
          copied += 1
        end
      end
    end
  end

  LOG.info "Worktree include: copied #{copied} file(s), symlinked #{linked} dir(s) for #{worktree_path}" if copied.positive? || linked.positive?
end

# Run a project-level hook script from .brainiac/<hook_name> if it exists.
def run_project_hook(repo_path, hook_name, extra_env: {})
  hook = File.join(repo_path, ".brainiac", hook_name)
  return unless File.exist?(hook)

  env = { "REPO_PATH" => repo_path }.merge(extra_env)
  LOG.info "Running .brainiac/#{hook_name} hook for #{repo_path}"
  output, status = Open3.capture2e(env, "bash", hook, chdir: repo_path)
  if status.success?
    LOG.info ".brainiac/#{hook_name} completed successfully"
  else
    LOG.warn ".brainiac/#{hook_name} failed (exit #{status.exitstatus}): #{output.strip}"
  end
end

# Create or reuse a git worktree for a given branch.
# Returns the worktree path on success.
def create_or_reuse_worktree(repo_path:, branch:, base_ref: nil, worktree_path: nil)
  worktree_path ||= File.join(File.dirname(repo_path), "#{File.basename(repo_path)}--#{branch}")
  base_ref ||= "origin/#{get_default_branch(repo_path)}"

  worktree_list = run_cmd("git", "worktree", "list", "--porcelain", chdir: repo_path)

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

  branch_exists = system("git", "rev-parse", "--verify", branch, chdir: repo_path, out: File::NULL, err: File::NULL)

  if branch_exists
    LOG.info "Branch #{branch} already exists, checking for existing worktree"
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

  trust_version_manager(worktree_path, chdir: worktree_path)
  apply_worktree_includes(repo_path, worktree_path)
  run_project_hook(repo_path, "worktree-setup", extra_env: { "WORKTREE_PATH" => worktree_path })

  worktree_path
end

# Clean up all worktrees associated with a card (primary + cross-agent review).
# Safe: skips worktrees with uncommitted changes.
def cleanup_card_worktrees(card_number, repo_path:, primary_worktree: nil, primary_branch: nil)
  return unless card_number

  repo_dir = File.dirname(repo_path)
  repo_base = File.basename(repo_path)
  cleaned = 0

  # Find worktrees that contain the card number in their name (any naming convention)
  candidates = Dir.glob(File.join(repo_dir, "#{repo_base}--*#{card_number}*")).select { |d| File.directory?(d) }
  candidates << primary_worktree if primary_worktree && File.directory?(primary_worktree) && !candidates.include?(primary_worktree)

  candidates.uniq.each do |wt_path|
    status_output, = Open3.capture3("git", "status", "--porcelain", chdir: wt_path)
    if status_output.strip.empty?
      branch_name = File.basename(wt_path).sub("#{repo_base}--", "")
      begin
        run_cmd("git", "worktree", "remove", wt_path, "--force", chdir: repo_path)
        run_cmd("git", "branch", "-D", branch_name, chdir: repo_path)
        cleaned += 1
        LOG.info "Cleaned up worktree #{wt_path} (branch: #{branch_name})"
      rescue StandardError => e
        LOG.warn "Failed to clean up worktree #{wt_path}: #{e.message}"
      end
    else
      LOG.warn "Worktree #{wt_path} has uncommitted changes — skipping cleanup"
    end
  end

  LOG.info "Card ##{card_number}: cleaned up #{cleaned} worktree(s)" if cleaned.positive?
end
