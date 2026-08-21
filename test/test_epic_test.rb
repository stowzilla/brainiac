# frozen_string_literal: true

require "minitest/autorun"
require_relative "../lib/epic_test"

class TestEpicTest < Minitest::Test
  def test_greet_returns_hello_with_name
    assert_equal "Hello, World!", EpicTest.greet("World")
  end

  def test_greet_with_regular_name
    assert_equal "Hello, Galen!", EpicTest.greet("Galen")
  end

  def test_greet_with_empty_string
    assert_equal "Hello, !", EpicTest.greet("")
  end

  def test_greet_with_nil
    assert_equal "Hello, !", EpicTest.greet(nil)
  end

  def test_greet_with_spaces_in_name
    assert_equal "Hello, Mary Jane!", EpicTest.greet("Mary Jane")
  end

  def test_greet_with_unicode_characters
    assert_equal "Hello, José!", EpicTest.greet("José")
  end

  def test_greet_with_emoji
    assert_equal "Hello, 🤖!", EpicTest.greet("🤖")
  end

  def test_greet_with_punctuation
    assert_equal "Hello, O'Brien!", EpicTest.greet("O'Brien")
  end
end
