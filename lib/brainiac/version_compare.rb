# frozen_string_literal: true

require "rubygems"

module Brainiac
  # Small, pure version-comparison helpers used by the upgrade CLI. Kept as its own
  # module so the logic is unit-testable without loading the whole CLI.
  module VersionCompare
    module_function

    # True when moving from `current` to `target` crosses a minor version within the
    # same 0.x major line (e.g. 0.1.10 → 0.2.0). Pre-1.0 a minor bump can carry
    # breaking changes, so the upgrade CLI confirms it with the user.
    def minor_move?(current, target)
      return false unless current && target

      cur = Gem::Version.new(current).segments
      tgt = Gem::Version.new(target).segments
      cur[0] == tgt[0] && tgt[1].to_i > cur[1].to_i
    rescue ArgumentError
      false
    end
  end
end
