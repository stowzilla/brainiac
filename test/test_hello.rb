# frozen_string_literal: true

require "minitest/autorun"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "hello"

class TestHello < Minitest::Test
  def test_hello_returns_hello
    assert_equal "hello", Hello.hello
  end

  def test_hello_returns_frozen_string
    assert Hello.hello.frozen?
  end
end
