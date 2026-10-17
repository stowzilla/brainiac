# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/version_compare"

# The `brainiac update` CLI confirms a 0.x → 0.y minor-version move before upgrading
# core. The decision is made by Brainiac::VersionCompare.minor_move?.
class TestUpgradeConfirm < Minitest::Test
  def move?(current, target)
    Brainiac::VersionCompare.minor_move?(current, target)
  end

  def test_minor_bump_within_0x_is_a_move
    assert move?("0.1.10", "0.2.0")
    assert move?("0.1.0", "0.9.0")
  end

  def test_patch_bump_is_not_a_minor_move
    refute move?("0.1.10", "0.1.11")
    refute move?("0.2.0", "0.2.5")
  end

  def test_same_version_is_not_a_move
    refute move?("0.2.0", "0.2.0")
  end

  def test_downgrade_is_not_a_move
    refute move?("0.2.0", "0.1.0")
  end

  def test_major_bump_is_not_a_minor_move
    # crossing the major line (0.x → 1.y) isn't a same-major minor move
    refute move?("0.9.0", "1.0.0")
  end

  def test_minor_move_within_1x
    assert move?("1.1.0", "1.2.0")
  end

  def test_nil_inputs_are_safe
    refute move?(nil, "0.2.0")
    refute move?("0.1.0", nil)
  end

  def test_garbage_versions_are_safe
    refute move?("not-a-version", "0.2.0")
  end

  def test_current_version_is_bumped_to_minor
    assert_equal "0.2.0", Brainiac::VERSION
  end
end
