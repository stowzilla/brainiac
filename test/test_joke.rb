# frozen_string_literal: true

require_relative "test_helper"
require_relative "../lib/brainiac/joke"

class TestJoke < Minitest::Test
  def test_random_returns_a_joke
    joke = Brainiac::Joke.random
    assert_instance_of Brainiac::Joke, joke
  end

  def test_tell_returns_string_with_setup_and_punchline
    joke = Brainiac::Joke.new(setup: "Why?", punchline: "Because.")
    assert_equal "Why? Because.", joke.tell
  end

  def test_to_s_matches_tell
    joke = Brainiac::Joke.new(setup: "Setup.", punchline: "Punch.")
    assert_equal joke.tell, joke.to_s
  end

  def test_all_returns_array_of_jokes
    jokes = Brainiac::Joke.all
    assert_instance_of Array, jokes
    assert jokes.all?(Brainiac::Joke)
  end

  def test_count_returns_ten
    assert_equal 10, Brainiac::Joke.count
  end

  def test_all_count_matches
    assert_equal Brainiac::Joke.count, Brainiac::Joke.all.length
  end

  def test_setup_accessor
    joke = Brainiac::Joke.new(setup: "Hello", punchline: "World")
    assert_equal "Hello", joke.setup
  end

  def test_punchline_accessor
    joke = Brainiac::Joke.new(setup: "Hello", punchline: "World")
    assert_equal "World", joke.punchline
  end

  def test_funny_is_true
    joke = Brainiac::Joke.random
    assert joke.funny?
  end

  def test_random_returns_different_jokes
    results = Array.new(20) { Brainiac::Joke.random.setup }
    assert results.uniq.length > 1, "Expected random to return different jokes"
  end
end
