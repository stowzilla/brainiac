# frozen_string_literal: true

require_relative "test_helper"

class TestBrain < Minitest::Test
  def test_memory_dir_for_agent
    path = memory_dir_for("Sherlock")
    assert_equal File.join(MEMORY_BASE_DIR, "sherlock"), path
  end

  def test_memory_dir_normalizes_name
    path = memory_dir_for("Robin Hood")
    assert_equal File.join(MEMORY_BASE_DIR, "robin-hood"), path
  end

  def test_persona_dir_for_agent
    path = persona_dir_for("Robin")
    assert_equal File.join(PERSONA_BASE_DIR, "robin"), path
  end

  def test_persona_collection_for_agent
    assert_equal "sherlock-persona", persona_collection_for("Sherlock")
    assert_equal "robin-persona", persona_collection_for("Robin")
  end

  def test_load_persona_returns_nil_without_style_file
    assert_nil load_persona("Nobody")
  end

  def test_load_persona_reads_style_md_without_frontmatter
    dir = persona_dir_for("Robin")
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "style.md"), "---\nname: robin-style\n---\n# Robin\nDry wit.")
    content = load_persona("Robin")
    refute_includes content, "robin-style"
    assert_includes content, "Dry wit."
  ensure
    FileUtils.rm_rf(dir)
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
