require_relative "test_helper"
require_relative "../lib/brainiac/greeting"

class TestGreeting < Minitest::Test
  def test_hello_default
    assert_equal "Hello, World!", Brainiac::Greeting.hello
  end

  def test_hello_custom_name
    assert_equal "Hello, Ruby!", Brainiac::Greeting.hello("Ruby")
  end

  def test_hello_empty_string
    assert_equal "Hello, !", Brainiac::Greeting.hello("")
  end

  def test_hello_with_spaces
    assert_equal "Hello, John Doe!", Brainiac::Greeting.hello("John Doe")
  end

  def test_hello_with_unicode
    assert_equal "Hello, 世界!", Brainiac::Greeting.hello("世界")
  end

  def test_hello_with_nil
    assert_equal "Hello, !", Brainiac::Greeting.hello(nil)
  end
end
