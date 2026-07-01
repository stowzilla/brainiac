# frozen_string_literal: true

require_relative "test_helper"

class TestBrain < Minitest::Test
  def test_memory_dir_for_agent
    path = memory_dir_for("Galen")
    assert_equal File.join(MEMORY_BASE_DIR, "galen"), path
  end

  def test_memory_dir_normalizes_name
    path = memory_dir_for("Sleeper Service")
    assert_equal File.join(MEMORY_BASE_DIR, "sleeper-service"), path
  end

  def test_persona_dir_for_agent
    path = persona_dir_for("GLaDOS")
    assert_equal File.join(PERSONA_BASE_DIR, "glados"), path
  end

  def test_persona_collection_for_agent
    assert_equal "galen-persona", persona_collection_for("Galen")
    assert_equal "glados-persona", persona_collection_for("GLaDOS")
  end

  def test_brain_git_repo_false_without_git_dir
    refute brain_git_repo?
  end

  def test_brain_git_repo_true_with_git_dir
    FileUtils.mkdir_p(File.join(BRAIN_BASE_DIR, ".git"))
    assert brain_git_repo?
  ensure
    FileUtils.rm_rf(File.join(BRAIN_BASE_DIR, ".git"))
  end
end
