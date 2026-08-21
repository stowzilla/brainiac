require_relative "test_helper"
require_relative "../lib/brainiac/joke"

class TestJoke < Minitest::Test
  def test_random_joke_returns_a_joke_instance
    joke = Brainiac::Joke.random
    assert_instance_of Brainiac::Joke, joke
  end

  def test_joke_has_setup_and_punchline
    joke = Brainiac::Joke.random
    refute_nil joke.setup
    refute_nil joke.punchline
    refute_empty joke.setup
    refute_empty joke.punchline
  end

  def test_tell_combines_setup_and_punchline
    joke = Brainiac::Joke.new(setup: "Why?", punchline: "Because.")
    assert_equal "Why?\nBecause.", joke.tell
  end

  def test_to_s_delegates_to_tell
    joke = Brainiac::Joke.new(setup: "Why?", punchline: "Because.")
    assert_equal joke.tell, joke.to_s
  end

  def test_funny_is_always_true
    joke = Brainiac::Joke.random
    assert joke.funny?
  end

  def test_all_returns_array_of_jokes
    jokes = Brainiac::Joke.all
    assert_instance_of Array, jokes
    assert jokes.all?(Brainiac::Joke)
    assert_equal Brainiac::Joke::JOKES.length, jokes.length
  end

  def test_count_matches_jokes_constant
    assert_equal Brainiac::Joke::JOKES.length, Brainiac::Joke.count
  end

  def test_custom_joke
    joke = Brainiac::Joke.new(setup: "Knock knock", punchline: "Ruby who?")
    assert_equal "Knock knock", joke.setup
    assert_equal "Ruby who?", joke.punchline
  end

  def test_default_constructor_picks_from_collection
    joke = Brainiac::Joke.new
    setups = Brainiac::Joke::JOKES.map { |j| j[:setup] }
    assert_includes setups, joke.setup
  end

  def test_random_joke_class_method_returns_hash
    joke = Brainiac::Joke.random_joke
    assert_instance_of Hash, joke
    assert joke.key?(:setup)
    assert joke.key?(:punchline)
  end
end
