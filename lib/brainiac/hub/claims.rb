# frozen_string_literal: true

require "open3"

module Brainiac
  module Hub
    # Branches checked out in worktrees on this machine, as hub work keys.
    #
    # GitHub events name a branch, not a card, so this is how the hub learns
    # which machine a pull request belongs to. The main checkout is skipped:
    # every machine has one.
    module Claims
      module_function

      def local_branch_keys(projects)
        projects.each_value.flat_map do |project|
          repo = project["github_repo"]
          path = project["repo_path"]
          next [] if repo.to_s.empty? || path.to_s.empty? || !Dir.exist?(path)

          output, status = Open3.capture2e("git", "-C", path, "worktree", "list", "--porcelain")
          next [] unless status.success?

          worktree_branches(output).map { |branch| "branch:#{repo}:#{branch}" }
        end.uniq
      rescue StandardError => e
        LOG.warn "[Hub] Could not list worktree branches: #{e.message}"
        []
      end

      def worktree_branches(porcelain)
        porcelain.split(/\n\n+/).drop(1).filter_map { |block| block[%r{^branch refs/heads/(.+)$}, 1] }
      end
    end
  end
end
