# frozen_string_literal: true

# Fizzy webhook handlers: card assignment, comments, mentions, deploy shortcuts, dedup.
#
# This file loads all Fizzy sub-modules:
#   fizzy/dedup.rb       — Card duplicate detection (card_published)
#   fizzy/assignment.rb  — Card assignment handler (worktree creation, agent dispatch)
#   fizzy/deploy.rb      — Deploy shortcut comments and branch cloning
#   fizzy/comments.rb    — Comment routing, follow-ups, cross-agent mentions

require_relative "fizzy/dedup"
require_relative "fizzy/assignment"
require_relative "fizzy/deploy"
require_relative "fizzy/comments"
